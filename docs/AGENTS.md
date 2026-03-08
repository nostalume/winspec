# AGENTS.md

This document provides guidelines for agentic coding assistants working in this SysKit repository.

## Project Overview

SysKit is a PowerShell-based system toolkit for Windows that provides declarative system configuration management. It uses a provider-based architecture inspired by NixOS, where configuration is defined in YAML and applied through specialized PowerShell modules.

**Language**: PowerShell 7+  
**Configuration Format**: YAML  
**Key Dependencies**: `powershell-yaml` module

## Build, Lint, and Test Commands

This is a scripts-based project without a formal build system. PowerShell scripts are executed directly.

### Running Scripts

```powershell
# Apply configuration from profiles.yml
.\nix-win\apply.ps1

# Apply with custom config
.\nix-win\apply.ps1 -Config ".\custom.yml"

# Skip checkpoint creation
.\nix-win\apply.ps1 -SkipCheckpoint

# Activate Windows/Office
.\activation.ps1

# Run debloat script
.\debloat.ps1 -Silent -CreateRestorePoint

# Download Office installer
.\office.ps1 -dir "C:\Installers"

# Scoop management (split from scoop-tool.ps1)
.\scoop-install.ps1 -Source proxy        # Install Scoop with proxy
.\scoop-install.ps1 -Source native       # Install Scoop natively
.\scoop-resolve.ps1 -To spc              # Update bucket references to 'spc'
.\scoop-resolve.ps1 -To spc -DryRun      # Preview changes without writing
.\scoop-proxy.ps1 -Bucket main -Url https://gh-proxy.org  # Set proxy for bucket
.\scoop-proxy.ps1 -Bucket main -Reset    # Remove proxy, reset to original URL
```

### Code Analysis

```powershell
# Check PowerShell syntax
pwsh -NoLogo -Command "Get-ChildItem -Path 'C:\Path\To\Scripts' -Filter '*.ps1' -Recurse | ForEach-Object { $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null); Write-Host "OK: $($_.Name)" }"

# Analyze script files for common issues
pwsh -Command "Find-Strings -Path './*.ps1' -Pattern 'Invoke-Expression' | Select-Object LineNumber, Line"
```

### Testing

There are no formal tests in this repository. When adding tests:
- Use Pester as the testing framework
- Place tests in a `tests/` directory
- Name test files `*.Tests.ps1`
- Run with: `Invoke-Pester -Path ./tests`

### Exit Codes

All scripts should follow this exit code standard:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Dependency missing (Scoop/Git not found) |
| 3 | Invalid parameters |

## Code Style Guidelines

### General Principles

- Follow PowerShell best practices and the PowerShell Community Book
- Write idempotent, declarative code where possible
- Prefer `Write-Verbose` over `Write-Host` for debugging information
- Use `ShouldProcess` (`-WhatIf`, `-Confirm`) for destructive operations

### Naming Conventions

- **Functions**: PascalCase (e.g., `Invoke-WindowsFeature`, `Sync-Property`)
- **Variables**: camelCase (e.g., `$currentState`, `$desiredValue`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `$DEFAULT_TIMEOUT`)
- **Parameters**: camelCase (e.g., `-RegPath`, `-DesiredValue`)
- **Private functions**: Prefix with `Get-` for getters, `Set-` for setters, `Test-` for testers
- **Module names**: PascalCase (e.g., `logger.psm1`, `registry.psm1`)
- **Configuration keys**: kebab-case (e.g., `create-restore-point` in YAML)

### CmdletBinding and Parameters

All functions that need common parameters (WhatIf, Confirm, Verbose) should use `[CmdletBinding()]`:

```powershell
function Invoke-Something {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [parameter(Mandatory = $false)]
        [string]$Config = ".\profiles.yml",
        
        [parameter(Mandatory = $false)]
        [switch]$SkipCheckpoint
    )
    # Function body
}
```

Parameter attributes:
- Use `Mandatory = $true/$false` for required/optional parameters
- Use `[switch]` for boolean flags
- Use `[string]` for single values, `[string[]]` for arrays
- Use `[hashtable]` for structured data
- Use `[System.Collections.ArrayList]` for mutable collections

### Error Handling

```powershell
try {
    # Risky operation
    Invoke-WebRequest $url -OutFile $target -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Error "Installation failed: $_"
    exit 1
}

# For non-critical errors, use ErrorAction SilentlyContinue
$curFeature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
if (-not $curFeature) {
    Write-Error "Feature '$featureName' not found."
    continue
}

# Use $PSItem or $_ for exception details
catch {
    Write-LogError -Name $Name
    if ($PSItem) {
        Write-Log -Level "ERROR" -Msg "$($PSItem.Exception.Message)"
    }
}
```

### Imports and Modules

Import modules at the top of provider files:

```powershell
Import-Module "logger.psm1"

function Invoke-SomeAction {
    # Uses logger functions
}
```

Export module members at the end:

```powershell
Export-ModuleMember -Function Write-LogApplied, Write-LogChange, Write-LogError
```

### Logging

Use the `logger.psm1` module for consistent output. Log levels: INFO, OK, APPLIED, CHANGE, ERROR.

```powershell
Write-LogProcess -Name "PropertyName"
Write-LogOk -Name "PropertyName" -DesiredValue "Value"
Write-LogChange -Name "PropertyName" -CurrentValue "Old" -DesiredValue "New"
Write-LogApplied -Name "PropertyName" -DesiredValue "Value"
Write-LogError -Name "PropertyName"
```

### Formatting

- Use tabs for indentation (observe existing file patterns)
- Limit line length to ~100 characters where reasonable
- Use backtick for line continuation (`)
- Use splatting for cmdlets with many parameters:
  ```powershell
  Sync-Property -Name $prop.name `
      -RegPath ($prop.regPath ?? $defaults.regPath) `
      -RegProperty $prop.regProperty
  ```
- Use here-strings for multi-line messages:
  ```powershell
  $HELP_MSG = """
  This is a help message.
  Multiple lines supported.
  """
  ```

### Type Handling

- Use `$null` comparison: `-not $variable` or `$variable -eq $null`
- Use null-coalescing operator `??` for defaults
- Use boolean conversion: `[bool]$feature.state`
- Use hash tables for mappings:
  ```powershell
  $reverseMap = @{}
  foreach ($key in $StateMap.Keys) { $reverseMap[$StateMap[$key]] = $key }
  ```

### Provider Architecture

Follow the Test-Set pattern for idempotent operations:

1. **Test function**: Checks current state, returns boolean
2. **Get function**: Retrieves current state as hashtable
3. **Set function**: Applies desired state

Example from `timezone.psm1`:
```powershell
function Get-TimezoneState { ... }
function Set-TimezoneState { ... }
function Test-TimezoneState { ... }
```

### Registry Operations

Use helper functions from `registry.psm1`:
- `Get-RegistryValue` with default fallback
- `Set-RegistryValue` with type specification
- `Sync-Property` for declarative property sync
- `Sync-RegistryState` for bulk operations

### YAML Configuration

- Use `Import-YamlParser` from `parser.psm1`
- Structure configs with imports for modularity
- Use kebab-case for keys
- Document supported properties in comments

### Security Considerations

- Never hardcode secrets; use environment variables or Credential Manager
- Validate all inputs before use
- Prefer `Invoke-RestMethod` over `Invoke-WebRequest` for APIs
- Use `-UseBasicParsing` when not needing full IE engine
- Always create restore points before system modifications

## Directory Structure

```
syskit/
├── activation.ps1        # Windows/Office activation
├── debloat.ps1           # Debloat script wrapper
├── office.ps1            # Office 365 installer
├── scoop-install.ps1     # Install Scoop (proxy/native)
├── scoop-resolve.ps1     # Update bucket references in install.json
├── scoop-proxy.ps1       # Configure bucket git proxy
├── nix-win/
│   ├── apply.ps1         # Main configuration engine
│   ├── profiles.yml      # Default configuration
│   └── providers/
│       ├── parser.psm1   # YAML parsing
│       ├── logger.psm1   # Logging utilities
│       ├── registry.psm1 # Registry operations
│       ├── feature.psm1  # Windows features
│       └── timezone.psm1 # Timezone management
└── docs/
    ├── nix-like.md       # Architecture documentation
    ├── ai/
    │   ├── context.md    # AI context and scope
    │   └── scan.md       # Scanning behavior rules
    └── invariants/
        └── scoop-tool.md # Invariants for scoop scripts
```

## Common Patterns

### Idempotent Property Sync
```powershell
$curState = Get-CurrentState
if ($curState -eq $DesiredState) {
    Write-LogOk -Name $Name -DesiredValue $DesiredState
    return
}
Write-LogChange -Name $Name -CurrentValue $curState -DesiredValue $DesiredState
if ($PSCmdlet.ShouldProcess(...)) {
    Set-DesiredState
    Write-LogApplied -Name $Name -DesiredValue $DesiredState
}
```

### Help Messages
```powershell
$HELP_MSG = """
Usage: script.ps1 [Options]

Options:
    -Option: Description
"""

if ($args -match '^(?:-h|-\?|/\?|--help)$') {
    Write-Host $HELP_MSG
    exit 0
}
```

## Called Function Paths

This section documents the function call flow for WinSpec commands to clarify the execution path for agentic coding.

### CLI Entry Point

**File**: `winspec/winspec.ps1`

The main CLI script dispatches commands to their respective handlers:

```powershell
# Command dispatch via switch statement
switch ($Command) {
    "apply"    { Invoke-WinSpec }
    "export"   { Export-SystemState }
    "diff"     { Compare-SystemState }
    "merge"    { Merge-Configuration }
    "sync"     { Invoke-Sync }
    ...
}
```

### Export Command Flow

**CLI**: `.\winspec.ps1 export -Output <path>`

**Call Path**:
```
winspec.ps1
  └─ Export-SystemState (winspec/export.psm1)
       ├─ Import-Module managers/package.psm1
       │   └─ Export-PackageState
       ├─ Import-Module managers/registry.psm1
       │   └─ Export-RegistryState
       ├─ Import-Module managers/service.psm1
       │   └─ Export-ServiceState
       └─ Import-Module managers/feature.psm1
           └─ Export-FeatureState
```

### Diff Command Flow

**CLI**: `.\winspec.ps1 diff -Spec <spec.ps1> [-Against <state.ps1>]`

**Call Path**:
```
winspec.ps1
  └─ Compare-SystemState (winspec/diff.psm1)
       ├─ Export-SystemState (if Against not specified)
       ├─ Import-Module managers/package.psm1
       │   └─ Compare-PackageState
       ├─ Import-Module managers/registry.psm1
       │   └─ Compare-RegistryState
       ├─ Import-Module managers/service.psm1
       │   └─ Compare-ServiceState
       └─ Import-Module managers/feature.psm1
           └─ Compare-FeatureState
```

### Merge Command Flow

**CLI**: `.\winspec.ps1 merge -Base <base.ps1> -Incoming <incoming.ps1> -Output <out.ps1> -Strategy <strategy>`

**Call Path**:
```
winspec.ps1
  └─ Merge-Configuration (winspec/merge.psm1)
       ├─ Import-MergeSpec
       ├─ Invoke-MergeEngine
       │   ├─ Resolve-MergeItem (per key)
       │   │   ├─ Test-ValuesEqual
       │   │   ├─ Resolve-ByStrategy
       │   │   └─ Invoke-ConflictResolution (if interactive)
       │   └─ Merge-ValuesUnion
       └─ Export-MergedConfig
```

**Strategies**: `auto`, `union`, `ours`, `theirs`

### Sync Command Flow

**CLI**: `.\winspec.ps1 sync -Spec <spec.ps1> -SyncInteractive`

**Call Path**:
```
winspec.ps1
  └─ Invoke-Sync (winspec/sync.psm1)
       ├─ Export-SystemState (winspec/export.psm1)
       ├─ Compare-ForSync
       │   └─ Compare-*State (provider compare functions)
       ├─ Invoke-SyncPrompt (per difference, if interactive)
       │   ├─ Format-SyncValue
       │   └─ Resolve-SyncAuto
       ├─ Apply-SyncChanges
       │   └─ Set-*State (provider set functions)
       └─ Save-SyncConfig
```

**Sync Strategies**:
- `export`: System state wins, update config
- `import`: Config wins, update system
- `mirror`: Add missing from both sides (default)

### Provider Function Contract

Each declarative provider in `winspec/managers/` implements:

| Function | Purpose | Called By |
|----------|---------|-----------|
| `Export-{Name}State` | Export current system state | Export-SystemState |
| `Compare-{Name}State` | Compare system vs desired | Compare-SystemState, Compare-ForSync |
| `Test-{Name}State` | Test if changes needed | Invoke-WinSpec |
| `Set-{Name}State` | Apply changes | Invoke-WinSpec, Apply-SyncChanges |

### Apply Command Flow

**CLI**: `.\winspec.ps1 apply -Spec <spec.ps1>`

**Call Path**:
```
winspec.ps1
  └─ Invoke-WinSpec (winspec/core.psm1)
       ├─ Import-Spec
       ├─ Resolve-Spec
       │   └─ Merge-Hashtables
       ├─ Test-SpecSchema
       └─ Invoke-Plan (per provider)
            ├─ Test-{Name}State
            └─ Set-{Name}State
```

## Notes for Agents

- Always inspect code before executing, as noted in README.md
- Prefer PowerShell 7+ features (null-coalescing, ternary, etc.)
- This is a personal toolkit; changes should be intentional and tested
- No CI/CD exists; manual testing is required
- Consider Windows-specific constraints (registry paths, service names)
