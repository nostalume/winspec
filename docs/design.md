# WinSpec Design Document

> A composable, declarative Windows configuration system.

---

## Executive Summary

**WinSpec** (Windows Specification) is a unified, composable architecture for configuring Windows systems. Configuration is expressed in native PowerShell data structures (.ps1 files), enabling full PowerShell ecosystem integration without external dependencies.

---

## Design Principles

| Principle | Description |
|-----------|-------------|
| **Native** | Configuration in PowerShell (.ps1), not YAML or JSON |
| **Composable** | Import and merge specifications |
| **Idempotent** | Declarative state management for system settings |
| **Triggerable** | One-time actions via explicit triggers |
| **Safe** | Built-in checkpoint/rollback support |

---

## Directory Structure

```
winspec/
├── winspec.ps1           # CLI entry point
├── exec.psm1             # Engine (renamed from core): resolve, plan, execute
├── checkpoint.psm1       # Restore point management
├── logging.psm1          # Unified logging
├── schema.psm1           # Type definitions and validation
├── registry-maps.psm1    # Registry configuration maps

├── pull.psm1             # NEW: pull command (replaces export + init)
├── push.psm1             # NEW: push command (replaces apply wrapper)
├── diff.psm1             # Compare states
├── merge.psm1            # Merge configs

├── managers/             # Declarative providers (idempotent)
│   ├── registry.psm1     # Registry operations
│   ├── service.psm1      # Windows services
│   ├── feature.psm1      # Windows features
│   └── package.psm1      # Package management (Scoop)

├── triggers/             # Trigger providers (non-idempotent)
│   ├── activation.psm1   # Windows/Office activation
│   ├── debloat.psm1      # System debloating
│   └── office.psm1       # Office deployment

└── tests/                # Test suite
    ├── *.Tests.ps1       # Pester test files
    └── run-tests.ps1     # Test runner
```

---

## Module Architecture

### Core Modules

| Module | Purpose |
|--------|---------|
| **exec.psm1** | Execution engine - spec resolution, provider execution, trigger execution |
| **pull.psm1** | Pull system state to config (combines export + init) |
| **push.psm1** | Push config to system (replaces apply) |
| **diff.psm1** | Compare system state with config |
| **merge.psm1** | Merge two configuration files |

### Common Modules

| Module | Purpose |
|--------|---------|
| **utils.psm1** | Value formatting, hashtable ops, config file I/O, path resolution |
| **state.psm1** | Provider discovery, system state capture, state comparison |
| **logging.psm1** | Unified logging functions |
| **schema.psm1** | Specification validation |
| **checkpoint.psm1** | System restore point management |
| **sandbox.psm1** | Sandbox execution for testing |

---

## Provider Types

### Two Provider Categories

| Type | Location | Characteristics | Idempotent | Examples |
|------|----------|-----------------|------------|----------|
| **Declarative** | `managers/` | State-based, testable | Yes | Registry, Service, Feature, Package |
| **Trigger** | `triggers/` | Action-based, fire-and-forget | No | Activation, Debloat, Office |

### Declarative Providers (Idempotent)

Users specify **what state** they want. Running multiple times produces the same result:

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

Engine: Test current state → Calculate diff → Apply only needed changes

### Trigger Providers (Non-Idempotent)

Users specify **what to trigger**. These are one-time actions:

```powershell
Trigger = @(
    @{ Name = "Activation" }           # Run activation
    @{ Name = "Debloat"; Value = "silent" }  # Run debloat with option
    @{ Name = "Office"; Value = "C:\Installers" }  # Download Office
)
```

Engine: Execute action → Report result

---

## Skipping Providers

WinSpec is modular - you can use only the providers you need. Simply omit the providers you don't want to configure:

```powershell
# Only configure Registry - other providers will be ignored
@{
    Name = "registry-only"
    Registry = @{
        Explorer = @{
            ShowHidden = $true
        }
    }
}
```

```powershell
# Only configure Package - no Registry, Service, Feature, or Triggers
@{
    Name = "packages-only"
    Package = @{
        Installed = @("git", "neovim")
    }
}
```

```powershell
# Only use Triggers - no declarative providers
@{
    Name = "triggers-only"
    Trigger = @(
        @{ Name = "Activation" }
    )
}
```

**When pulling with specific providers:**
```powershell
# Pull only Registry and Package state (ignore Service, Feature)
winspec pull -Providers Registry,Package -Output my-config.ps1
```

---

## CLI Interface (Git-like Commands)

WinSpec uses Git-like commands for state manipulation:

```powershell
# Pull: Export system state to config file
winspec pull                          # Pull to default location
winspec pull -Output config.ps1      # Pull to specific file
winspec pull -Providers Registry,Service  # Pull specific providers
winspec pull -DryRun                 # Preview what would be pulled

# Push: Apply config to system
winspec push -Spec config.ps1        # Push config to system
winspec push -Spec config.ps1 -DryRun   # Preview changes
winspec push -Spec config.ps1 -Checkpoint  # Create restore point
winspec push -Spec config.ps1 -WithTriggers # Include triggers

# Diff: Compare system vs config
winspec diff -Spec config.ps1        # Compare against live system
winspec diff -Spec config.ps1 -Against other.ps1  # Compare two configs
winspec diff -Spec config.ps1 -Providers Registry  # Diff specific providers

# Merge: Merge two configs
winspec merge -Base base.ps1 -Incoming incoming.ps1
winspec merge -Base base.ps1 -Incoming incoming.ps1 -Output merged.ps1
winspec merge -Base base.ps1 -Incoming incoming.ps1 -Strategy ours
winspec merge -Base base.ps1 -Incoming incoming.ps1 -Interactive

# Status: Show current state
winspec status
winspec status -Providers Registry,Service

# Apply (legacy alias for push)
winspec apply -Spec config.ps1

# Export (legacy alias for pull)
winspec export -Output config.ps1

# Init (legacy alias for pull)
winspec init

# Sync (legacy - use pull + push instead)
winspec sync -Spec config.ps1
```

---

## Core Module Functions (exec.psm1)

### Main Entry Point

```powershell
function Invoke-WinSpec {
    param(
        [string]$Spec,
        [switch]$DryRun,      # Now uses ShouldProcess internally
        [switch]$Checkpoint,
        [switch]$WithTriggers
    )
    # 1. Parse specification
    # 2. Resolve imports
    # 3. Validate schema
    # 4. Create checkpoint (if requested)
    # 5. Execute declarative providers
    # 6. Execute triggers (if WithTriggers)
    # 7. Generate report
}
```

### Supporting Functions

| Function | Purpose |
|----------|---------|
| `Resolve-Spec` | Resolve imports and merge configurations |
| `Invoke-Managers` | Execute all declarative providers |
| `Invoke-Triggers` | Execute trigger providers |
| `Get-SystemStatus` | Get current system status |
| `Get-ProviderNames` | Discover available providers |

---

## Path Resolution

WinSpec resolves paths in this priority order:

1. Explicit `-Spec` or `-Output` argument
2. `$env:WINSPEC_CONFIG` environment variable
3. `~/.config/winspec/` directory
4. `.winspec.ps1` in current directory

---

## Checkpoint System

### Functions

```powershell
function Test-SystemRestoreEnabled { }
function Enable-SystemRestore { }
function New-Checkpoint { }
function Get-Checkpoints { }
function Invoke-Rollback { }
function Test-CheckpointCapability { }
```

### Usage

Create a checkpoint before applying changes:

```powershell
winspec push -Spec config.ps1 -Checkpoint
```

Rollback if something goes wrong:

```powershell
winspec rollback -Last
```

---

## Schema Validation

The `schema.psm1` module validates specifications:

```powershell
function Test-SpecSchema {
    param([hashtable]$Config)
    # Validates:
    # - Known keys only
    # - Registry categories exist in maps
    # - Package.Installed is an array
    # - Feature values are 'enabled'/'disabled'
    # - Service states are valid
    # - Trigger is an array of hashtables with Name field
}
```

---

## Logging

Unified logging via `logging.psm1`:

```powershell
Write-Log -Level "INFO" -Message "Processing..."
Write-LogOk -Name $item -DesiredValue $value
Write-LogApplied -Name $item -DesiredValue $value
Write-LogChange -Name $item -CurrentValue $current -DesiredValue $desired
Write-LogError -Name $item -Details $error
Write-LogHeader -Title "Section"
Write-LogSection -Name "Provider"
```

Log levels: INFO, OK, APPLIED, CHANGE, WARN, ERROR

---

## Testing

Run the test suite:

```powershell
cd winspec/tests
.\run-tests.ps1
```

Or with Pester directly:

```powershell
Import-Module Pester
Invoke-Pester winspec/tests
```

---

## Extension Points

### Adding a Declarative Provider

1. Create `managers/{name}.psm1`
2. Implement functions:
   - `Get-ProviderMetadata` - Returns `@{ Name = "..."; Type = "Declarative" }`
   - `Test-{Name}State` - Returns `$true` if in desired state
   - `Set-{Name}State` - Applies desired state
3. No additional registration needed - discovered automatically

### Adding a Trigger Provider

1. Create `triggers/{name}.psm1`
2. Implement functions:
   - `Get-ProviderMetadata` - Returns `@{ Name = "..."; Type = "Trigger" }`
   - `Invoke-{Name}Trigger` - Executes the trigger action
3. No additional registration needed - discovered automatically

---

## Architecture Flow

```
┌─────────────────────────────────────────────────────────────┐
│                        CLI Entry                             │
│                    (winspec.ps1)                             │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
    ┌────────┐   ┌────────┐   ┌──────────┐
    │ pull   │   │ push   │   │ diff     │
    └────┬───┘   └────┬───┘   └────┬─────┘
         │           │            │
         ▼           ▼            ▼
    ┌─────────────────────────────────────────────────────────┐
    │                      Core Engine                       │
    │                     (exec.psm1)                        │
    ├─────────────────────────────────────────────────────────┤
    │  Resolve-Spec  →  Validate  →  Execute                  │
    │      │               │            │                     │
    │      ▼               ▼            ▼                     │
    │  Import/Merge   Validate     Run providers            │
    └─────────────────────┬───────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │ Declarative│  │  Triggers  │  │   State    │
    │(managers/) │  │(triggers/) │  │(state.psm1)│
    ├────────────┤  ├────────────┤  ├────────────┤
    │ • Registry │  │ • Activ.   │  │ • Capture  │
    │ • Service │  │ • Debloat  │  │ • Compare  │
    │ • Feature │  │ • Office   │  │            │
    │ • Package │  │            │  │            │
    └────────────┘  └────────────┘  └────────────┘
```

---

## Backward Compatibility

The following legacy commands are supported as aliases:

| Legacy Command | New Command | Notes |
|---------------|-------------|-------|
| `export` | `pull` | Export system state |
| `init` | `pull` | Initialize config |
| `apply` | `push` | Apply config to system |
| `Export-SystemState` | `Invoke-Pull` | Module function |
| `Apply-Configuration` | `Invoke-Push` | Module function |

---

*WinSpec Design Document v3.1 - Updated with implementation completion*
