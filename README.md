# WinSpec

> A composable, declarative Windows configuration system.

---

## Motivation

Managing Windows configuration has traditionally been fragmented across multiple tools, scripts, and manual processes. Users often find themselves:

- **Juggling multiple tools**: PowerShell scripts, registry editors, package managers, and various utilities scattered across different contexts
- **Lacking reproducibility**: Manual configuration changes are hard to track, reproduce, or share across machines
- **No clear separation of concerns**: Mixing idempotent state management with one-time actions leads to unpredictable results
- **External dependencies**: Configuration tools often require YAML parsers, JSON schemas, or other non-native dependencies

**WinSpec** solves these problems by providing:

- **Unified architecture**: All Windows configuration in one cohesive system
- **PowerShell-native configuration**: No YAML, no JSON - just native PowerShell hashtables
- **Clear provider taxonomy**: Declarative (idempotent) vs Trigger (one-time) actions are explicitly separated
- **Composable specifications**: Import and merge configurations for modular, reusable setups
- **Zero external dependencies**: Pure PowerShell implementation works out of the box

---

## Introduction

**WinSpec** (Windows Specification) is a unified, composable architecture for managing Windows system configuration. Configuration is expressed in native PowerShell data structures, enabling full PowerShell ecosystem integration.

### Design Principles

| Principle | Description |
|-----------|-------------|
| **Native** | Configuration in PowerShell (`.ps1`), not YAML or JSON |
| **Grouped** | Directories only when necessary for organization |
| **Composable** | Import and merge specifications for modularity |
| **Idempotent** | Declarative state management - safe to run multiple times |
| **Triggerable** | One-time actions via explicit triggers |

### Provider Types

WinSpec distinguishes between two types of providers:

| Type | Location | Characteristics | Idempotent | Examples |
|------|----------|-----------------|------------|----------|
| **Declarative** | `managers/` | State-based, testable | Yes | Registry, Service, Feature, Package |
| **Trigger** | `triggers/` | Action-based, fire-and-forget | No | Activation, Debloat, Office |

**Declarative providers** let you specify *what state* you want. Running multiple times produces the same result - the engine tests current state, calculates diff, and applies only needed changes.

**Trigger providers** let you specify *what to trigger*. These are explicitly named because they are NOT idempotent - users understand that triggering activation twice may have different effects than triggering once.

---

## Installation

### Prerequisites

- Windows 10/11
- PowerShell 5.1 or PowerShell 7+
- Administrator privileges (for most operations)

### Install via Scoop (Recommended)

```powershell
# Add the bucket
scoop bucket add winspec https://github.com/lvyuemeng/winspec

# Install WinSpec
scoop install winspec

# Verify installation
winspec help
```

To update WinSpec:

```powershell
scoop update winspec
```

### Install from Source

1. Clone the repository:
   ```powershell
   git clone https://github.com/lvyuemeng/winspec.git
   cd winspec
   ```

2. (Optional) Run tests to verify installation:
   ```powershell
   .\winspec\tests\run-tests.ps1
   ```

3. Start using WinSpec:
   ```powershell
   .\winspec\winspec.ps1 help
   ```

---

## Usage

### Quick Start

Create a configuration file (e.g., `myconfig.ps1`):

```powershell
@{
    Name = "myconfig"
    Description = "My Windows configuration"
    
    Registry = @{
        Explorer = @{
            ShowHidden = $true
            ShowFileExt = $true
        }
    }
    
    Package = @{
        Installed = @("git", "neovim")
    }
}
```

Apply the configuration:

```powershell
# Apply a specification (declarative only, safe)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1

# Dry run (preview changes without applying)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -DryRun

# Apply with checkpoint (create restore point first)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -Checkpoint

# Show current system state
.\winspec\winspec.ps1 status
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `apply` | Apply a specification file |
| `trigger` | Execute a specific trigger |
| `status` | Show current system state |
| `rollback` | Rollback to a checkpoint |
| `providers` | List available providers |
| `validate` | Validate a spec without applying |
| `help` | Show help message |

### CLI Options

| Option | Description |
|--------|-------------|
| `-Spec` | Path to specification file |
| `-DryRun` | Preview changes without applying |
| `-Checkpoint` | Create restore point before applying |
| `-WithTriggers` | Include trigger execution |

### Specification Format

```powershell
# myconfig.ps1
@{
    Name = "myconfig"
    Description = "My Windows configuration"
    
    # Import other specs (composition)
    Import = @(
        ".\base-config.ps1"
    )
    
    # === DECLARATIVE PROVIDERS (Idempotent) ===
    
    # Registry: fine-grained state management
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
    
    # Package: ensure these are installed
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
    
    # Array of triggers to execute
    Trigger = @(
        @{ Name = "Activation" }                          # Run activation
        @{ Name = "Debloat"; Value = "silent" }           # Run debloat with option
        @{ Name = "Office"; Value = "C:\Installers" }      # Download Office to path
    )
}
```

### Examples

```powershell
# Apply with triggers (includes non-idempotent actions)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -WithTriggers

# Apply with checkpoint (create restore point first)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -Checkpoint

# Run specific trigger(s)
.\winspec\winspec.ps1 trigger -Name activation
.\winspec\winspec.ps1 trigger -Name debloat -Option "silent"
.\winspec\winspec.ps1 trigger -Name @("activation", "debloat")

# Run all available triggers
.\winspec\winspec.ps1 trigger

# Rollback to last checkpoint
.\winspec\winspec.ps1 rollback -Last

# Validate a spec without applying
.\winspec\winspec.ps1 validate -Spec .\myconfig.ps1

# List available providers
.\winspec\winspec.ps1 providers
```

---

## Project Structure

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

## Security Notes

Trigger providers download and execute remote scripts:

- **Activation**: Downloads from `https://get.activated.win`
- **Debloat**: Downloads from `https://debloat.raphi.re/`
- **Office**: Downloads from Microsoft CDN

These scripts require administrator privileges. Always review remote scripts before execution. Use `-DryRun` to preview actions without executing them.

---

## License

See [LICENSE-MIT](LICENSE-MIT) for details.

---

## Contributing

Contributions are welcome! Here's how to get started:

### Development Setup

1. Clone the repository
2. Run tests to ensure everything works:
   ```powershell
   .\winspec\tests\run-tests.ps1
   ```

### Creating a New Declarative Provider

1. Create a new file in `winspec/managers/` following the naming convention `{name}.psm1`
2. Implement the required functions:

```powershell
# managers/myprovider.psm1
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{ 
        Name = "MyProvider"
        Type = "Declarative" 
    }
}

function Test-MyProviderState {
    param ([hashtable]$Desired)
    # Returns $true if in desired state
}

function Set-MyProviderState {
    param ([hashtable]$Desired, [switch]$WhatIf)
    # Apply desired state
}

Export-ModuleMember Get-ProviderInfo, Test-MyProviderState, Set-MyProviderState
```

### Creating a New Trigger Provider

1. Create a new file in `winspec/triggers/` following the naming convention `{name}.psm1`
2. Implement the required functions:

```powershell
# triggers/mytrigger.psm1
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{ 
        Name = "MyTrigger"
        Type = "Trigger" 
    }
}

function Invoke-MyTriggerTrigger {
    param ($Option, [switch]$WhatIf)
    # Execute trigger action
}

Export-ModuleMember Get-ProviderInfo, Invoke-MyTriggerTrigger
```

3. Add tests in `winspec/tests/`
4. Update documentation in [`docs/providers.md`](docs/spec.md)

### Guidelines

- Follow existing code style and naming conventions
- Use the logging module for consistent output
- Support `-WhatIf` for preview functionality
- Return consistent result hashtables with `Status` key
- Handle errors gracefully with meaningful messages

---

## Documentation

- **[docs/design.md](docs/design.md)** - Architecture and design principles
- **[docs/providers.md](docs/spec.md)** - Provider development guide

---

*WinSpec - Windows Configuration Made Simple*
