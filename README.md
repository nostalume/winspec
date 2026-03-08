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

### WinSpec in Daily Use

WinSpec simplifies your Windows workflow with these common scenarios:

| Daily Task | WinSpec Solution |
|------------|------------------|
| **Set up a new PC** | Capture your configured system with `init`, apply to new machines |
| **Keep config in sync** | Use `sync` to bidirectionally sync system state with your config file |
| **Apply your setup** | Run `apply` to apply your declarative config (safe, idempotent) |
| **Check differences** | Use `diff` to see what's changed between system and your config |
| **Backup before changes** | Use `-Checkpoint` to create restore points before applying |
| **Rollback if needed** | Use `rollback` to restore to a previous checkpoint |

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

**Step 1: Initialize your configuration**

Capture your current system setup (or start fresh):

```powershell
# Initialize from current system state (saves to ~/.config/winspec/.winspec.ps1)
.\winspec\winspec.ps1 init

# Or initialize with template and comments
.\winspec\winspec.ps1 init -Template -Output my-config.ps1

# Interactive mode - choose what to include
.\winspec\winspec.ps1 init -Interactive
```

**Step 2: Apply your configuration**

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

**Step 3: Daily maintenance**

```powershell
# See what's different between system and your config
.\winspec\winspec.ps1 diff -Spec .\myconfig.ps1

# Interactive sync - update config from system or vice versa
.\winspec\winspec.ps1 sync -Spec .\myconfig.ps1 -SyncInteractive

# If something goes wrong, rollback
.\winspec\winspec.ps1 rollback -Last
```

### CLI Commands

 | Command | Description |
|---------|-------------|
| `apply` | Apply a specification file |
| `init` | Initialize a new configuration from system state |
| `trigger` | Execute a specific trigger |
| `status` | Show current system state |
| `rollback` | Rollback to a checkpoint |
| `providers` | List available providers |
| `validate` | Validate a spec without applying |
| `export` | Export current system state to a config file |
| `diff` | Compare system state with a spec |
| `merge` | Merge two specification files |
| `sync` | Interactive sync between system and config |
| `sandbox` | Test changes in a sandbox environment |
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

**Daily Workflows:**

```powershell
# === New Machine Setup ===
# 1. On your configured machine: export current state
.\winspec\winspec.ps1 export -Output my-setup.ps1

# 2. On new machine: apply the configuration
.\winspec\winspec.ps1 apply -Spec .\my-setup.ps1

# === Regular Maintenance ===
# Check if system matches your config
.\winspec\winspec.ps1 diff -Spec .\myconfig.ps1

# Sync changes (interactive - choose what to keep)
.\winspec\winspec.ps1 sync -Spec .\myconfig.ps1 -SyncInteractive

# Export current system state (capture new changes)
.\winspec\winspec.ps1 export -Output my-updated-config.ps1

# === Applying Changes ===
# Apply with checkpoint (safe - creates restore point first)
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -Checkpoint

# Dry run - see what would change
.\winspec\winspec.ps1 apply -Spec .\myconfig.ps1 -DryRun

# If something goes wrong
.\winspec\winspec.ps1 rollback -Last

# === Other Commands ===
# Initialize a new configuration from current system state
.\winspec\winspec.ps1 init

# Run specific trigger(s)
.\winspec\winspec.ps1 trigger "activation"
.\winspec\winspec.ps1 trigger @{ debloat = "silent" }

# Merge two config files
.\winspec\winspec.ps1 merge -Base base.ps1 -Incoming custom.ps1 -Output merged.ps1

# Validate a spec without applying
.\winspec\winspec.ps1 validate -Spec .\myconfig.ps1

# List available providers
.\winspec\winspec.ps1 providers
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

## Documentation

- **[docs/design.md](docs/design.md)** - Architecture and design principles
- **[docs/spec.md](docs/spec.md)** - Specification and provider development guide
- **[docs/configuration.md](docs/configuration.md)** - Configuration guide
- **[docs/contributing.md](docs/contributing.md)** - Contributing guide
- **[docs/registry-reference.md](docs/registry-reference.md)** - Registry provider details
- **[docs/service-reference.md](docs/service-reference.md)** - Service provider details
- **[docs/feature-reference.md](docs/feature-reference.md)** - Feature provider details

---

*WinSpec - Windows Configuration Made Simple*
