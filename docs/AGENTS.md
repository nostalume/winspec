# AGENTS.md

This document provides guidelines for agentic coding assistants working in the WinSpec project.

## Project Overview

WinSpec (Windows Specification) is a unified, composable architecture for configuring Windows systems. Configuration is expressed in native PowerShell data structures (.ps1 files), enabling full PowerShell ecosystem integration without external dependencies.

**Language**: PowerShell 7+
**Configuration Format**: Native PowerShell (.ps1)
**Architecture**: Provider-based, inspired by NixOS

---

## Design Philosophy

WinSpec is built on five core principles:

| Principle | Description |
|-----------|-------------|
| **Native** | Configuration in PowerShell (.ps1), not YAML or JSON |
| **Composable** | Import and merge specifications |
| **Idempotent** | Declarative state management for system settings |
| **Triggerable** | One-time actions via explicit triggers |
| **Safe** | Built-in checkpoint/rollback support |

---

## Provider Architecture

### Two Provider Categories

WinSpec uses a modular provider system with two categories:

| Type | Location | Characteristics | Idempotent |
|------|----------|-----------------|------------|
| **Declarative** | `managers/` | State-based, testable | Yes |
| **Trigger** | `triggers/` | Action-based, fire-and-forget | No |

### Declarative Providers (Idempotent)

Declarative providers follow the principle of idempotency. Users specify **what state** they want, and running multiple times produces the same result:

```powershell
Registry = @{
    Explorer = @{
        ShowHidden = $true
        ShowFileExt = $true
    }
}

Package = @{
    Installed = @("git", "neovim", "nodejs")
}
```

The engine handles: Test current state → Calculate diff → Apply only needed changes

### Trigger Providers (Non-Idempotent)

Trigger providers are one-time actions. Users specify **what to trigger**:

```powershell
Trigger = @(
    @{ Name = "Activation" }
    @{ Name = "Debloat"; Value = "silent" }
)
```

The engine handles: Execute action → Report result

### Provider Skipping

WinSpec is modular—you can use only the providers you need. Simply omit providers you don't want to configure:

```powershell
# Only configure Registry
@{ Registry = @{ ... } }

# Only use Triggers
@{ Trigger = @(...) }
```

---

## Extension Points

### Adding a Declarative Provider

1. Create `managers/{name}.psm1`
2. Implement functions:
   - `Get-ProviderMetadata` - Returns provider metadata
   - `Test-{Name}State` - Returns `$true` if in desired state
   - `Set-{Name}State` - Applies desired state
3. No additional registration needed—discovered automatically

### Adding a Trigger Provider

1. Create `triggers/{name}.psm1`
2. Implement functions:
   - `Get-ProviderMetadata` - Returns provider metadata
   - `Invoke-{Name}Trigger` - Executes the trigger action
3. No additional registration needed—discovered automatically

---

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

### CmdletBinding and Parameters

All functions that need common parameters (WhatIf, Confirm, Verbose) should use `[CmdletBinding()]`:

```powershell
function Invoke-Something {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [parameter(Mandatory = $false)]
        [string]$Config = ".\config.ps1",
        
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
```

### Logging

Use the `logging.psm1` module for consistent output. Log levels: INFO, OK, APPLIED, CHANGE, ERROR.

```powershell
Write-Log -Level "INFO" -Message "Processing..."
Write-LogOk -Name $item -DesiredValue $value
Write-LogApplied -Name $item -DesiredValue $value
Write-LogChange -Name $item -CurrentValue $current -DesiredValue $desired
Write-LogError -Name $item -Details $error
Write-LogHeader -Title "Section"
Write-LogSection -Name "Provider"
```

### Formatting

- Use tabs for indentation (observe existing file patterns)
- Limit line length to ~100 characters where reasonable
- Use backtick for line continuation (`` ` ``)
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

### Idempotent Property Sync Pattern

Follow the Test-Set pattern for idempotent operations:

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

---

## CLI Interface

WinSpec uses Git-like commands for state manipulation:

| Command | Purpose |
|---------|---------|
| `pull` | Export system state to config file |
| `push` | Apply config to system |
| `diff` | Compare system vs config |
| `merge` | Merge two configs |
| `status` | Show current state |

Legacy aliases: `export` → `pull`, `apply` → `push`, `init` → `pull`

---

## Path Resolution

WinSpec resolves paths in this priority order:

1. Explicit `-Spec` or `-Output` argument
2. `$env:WINSPEC_CONFIG` environment variable
3. `~/.config/winspec/` directory
4. `.winspec.ps1` in current directory

---

## Security Considerations

- Never hardcode secrets; use environment variables or Credential Manager
- Validate all inputs before use
- Prefer `Invoke-RestMethod` over `Invoke-WebRequest` for APIs
- Use `-UseBasicParsing` when not needing full IE engine
- Always create restore points before system modifications (`-Checkpoint`)

---

## Testing

Use Pester as the testing framework:
- Place tests in a `tests/` directory
- Name test files `*.Tests.ps1`
- Run with: `Invoke-Pester -Path ./tests`

---

## Exit Codes

All scripts should follow this exit code standard:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Dependency missing |
| 3 | Invalid parameters |

---

## Notes for Agents

- Always inspect code before executing
- Prefer PowerShell 7+ features (null-coalescing, ternary, etc.)
- This is a personal toolkit; changes should be intentional and tested
- No CI/CD exists; manual testing is required
- Consider Windows-specific constraints (registry paths, service names)
