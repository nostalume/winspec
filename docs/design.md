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
├── core.psm1             # Engine: resolve, plan, execute
├── checkpoint.psm1       # Restore point management
├── logging.psm1          # Unified logging
├── schema.psm1           # Type definitions and validation
├── registry-maps.ps1     # Registry configuration maps
│
├── managers/             # Declarative providers (idempotent)
│   ├── registry.psm1     # Registry operations
│   ├── service.psm1      # Windows services
│   ├── feature.psm1      # Windows features
│   └── package.psm1      # Package management (Scoop)
│
├── triggers/             # Trigger providers (non-idempotent)
│   ├── activation.psm1   # Windows/Office activation
│   ├── debloat.psm1      # System debloating
│   └── office.psm1       # Office deployment
│
└── tests/                # Test suite
    ├── *.Tests.ps1       # Pester test files
    └── run-tests.ps1     # Test runner
```

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

## PowerShell-Native Configuration

### Specification Format

```powershell
# example.ps1
@{
    Name = "developer"
    Description = "Developer workstation setup"
    
    # Import other specs (composition)
    Import = @(
        ".\base-config.ps1"
    )
    
    # === DECLARATIVE PROVIDERS (Idempotent) ===
    
    # Registry settings
    Registry = @{
        Clipboard = @{
            EnableHistory = $true
        }
        Explorer = @{
            ShowHidden = $true
            ShowFileExt = $true
        }
        Theme = @{
            AppTheme = "dark"
            SystemTheme = "dark"
        }
        Desktop = @{
            MenuShowDelay = "0"
        }
    }
    
    # Package management
    Package = @{
        Installed = @("git", "neovim", "nodejs", "python")
    }
    
    # Windows Services
    Service = @{
        wuauserv = @{ State = "stopped"; Startup = "disabled" }
    }
    
    # Windows Features
    Feature = @{
        "Microsoft-Windows-Subsystem-Linux" = "enabled"
        "VirtualMachinePlatform" = "enabled"
    }
    
    # === TRIGGERS (Non-Idempotent) ===
    Trigger = @(
        @{ Name = "Activation" }
        @{ Name = "Debloat"; Value = "silent" }
        @{ Name = "Office"; Value = "C:\Installers" }
    )
}
```

---

## CLI Interface

```powershell
# Apply a specification (declarative only, no triggers)
.\winspec.ps1 apply -Spec .\config.ps1

# Apply with triggers (runs everything)
.\winspec.ps1 apply -Spec .\config.ps1 -WithTriggers

# Apply specific trigger
.\winspec.ps1 trigger -Name activation
.\winspec.ps1 trigger -Name debloat -Option "silent"

# Dry run (preview changes)
.\winspec.ps1 apply -Spec .\config.ps1 -DryRun

# Apply with checkpoint
.\winspec.ps1 apply -Spec .\config.ps1 -Checkpoint

# Show current system state
.\winspec.ps1 status

# Rollback to checkpoint
.\winspec.ps1 rollback -Last
.\winspec.ps1 rollback -SequenceNumber 100

# List available providers
.\winspec.ps1 providers

# Validate a spec without applying
.\winspec.ps1 validate -Spec .\config.ps1
```

---

## Core Module Functions

### Main Entry Point

```powershell
function Invoke-WinSpec {
    param(
        [string]$Spec,
        [switch]$DryRun,
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
| `Import-Spec` | Load and parse a specification file |
| `Resolve-Spec` | Resolve imports and merge configurations |
| `Merge-Hashtables` | Recursively merge nested hashtables |
| `Test-SpecSchema` | Validate specification against schema |
| `Import-Manager` | Load a declarative provider module |
| `Invoke-DeclarativeProviders` | Execute all declarative providers |
| `Invoke-Triggers` | Execute trigger providers |
| `Find-TriggerScript` | Locate trigger scripts in various paths |
| `Invoke-CustomTrigger` | Execute custom trigger scripts |
| `Import-BuiltInTrigger` | Load built-in trigger modules |
| `Write-Report` | Generate execution report |

### Configuration Resolution

```powershell
function Resolve-ConfigLocation {
    param([string]$ConfigPath, [string]$SpecPath)
    # Resolution order:
    # 1. Explicit ConfigPath argument
    # 2. WINSPEC_CONFIG environment variable
    # 3. ~/.config/winspec/ directory
    # 4. .winspec.ps1 in current directory
}
```

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
.\winspec.ps1 apply -Spec .\config.ps1 -Checkpoint
```

Rollback if something goes wrong:

```powershell
.\winspec.ps1 rollback -Last
```

---

## Registry Maps

Registry configuration is defined in `registry-maps.ps1`:

```powershell
$Script:RegistryMaps = @{
    Clipboard = @{
        Path = "HKCU:\Software\Microsoft\Clipboard"
        Properties = @{
            EnableHistory = @{
                Name = "EnableClipboardHistory"
                Type = "DWord"
            }
        }
    }
    
    Explorer = @{
        Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Properties = @{
            ShowHidden = @{
                Name = "Hidden"
                Type = "DWord"
                Map = @{ $true = 1; $false = 2 }
            }
            ShowFileExt = @{
                Name = "HideFileExt"
                Type = "DWord"
                Map = @{ $true = 0; $false = 1 }
            }
        }
    }
    
    Theme = @{
        Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Properties = @{
            AppTheme = @{
                Name = "AppsUseLightTheme"
                Type = "DWord"
                Map = @{ "light" = 1; "dark" = 0 }
            }
        }
    }
}
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
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                      Core Engine                             │
│                     (core.psm1)                              │
├─────────────────────────────────────────────────────────────┤
│  Import-Spec  →  Resolve-Spec  →  Test-SpecSchema  →  Execute  │
│      │                │              │            │          │
│      ▼                ▼              ▼            ▼          │
│  Parse .ps1      Merge imports   Validate    Run providers   │
└─────────────────────┬───────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          │                       │
          ▼                       ▼
┌─────────────────────┐   ┌─────────────────────┐
│  Declarative        │   │  Triggers           │
│  (managers/)        │   │  (triggers/)        │
├─────────────────────┤   ├─────────────────────┤
│ • Registry          │   │ • Activation        │
│ • Service           │   │ • Debloat           │
│ • Feature           │   │ • Office            │
│ • Package           │   │                     │
└─────────────────────┘   └─────────────────────┘
```

---

*WinSpec Design Document v2.0*
