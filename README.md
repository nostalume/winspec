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

WinSpec simplifies your Windows workflow with Git-like commands:

| Daily Task | WinSpec Solution |
|------------|------------------|
| **Set up a new PC** | Capture your configured system with `pull`, push to new machines |
| **Keep config in sync** | Use `pull` to capture system state, then `push` to apply |
| **Apply your setup** | Run `push` to apply your declarative config (safe, idempotent) |
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
| **Declarative** | `managers/` | State-based, testable | Yes | Registry, Service, Feature |
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

**Step 1: Pull system state to config**

Capture your current system setup (or start fresh):

```powershell
# Pull current system state to default location (~/.config/winspec/.winspec.ps1)
.\winspec\winspec.ps1 pull

# Or pull to specific file with template and comments
.\winspec\winspec.ps1 pull -Output my-config.ps1 -Template

# Interactive mode - choose what to include
.\winspec\winspec.ps1 pull -Interactive
```

**Step 2: Push configuration to system**

```powershell
# Push a specification to system (declarative only, safe)
.\winspec\winspec.ps1 push -Spec .\myconfig.ps1

# Dry run (preview changes without applying)
.\winspec\winspec.ps1 push -Spec .\myconfig.ps1 -DryRun

# Push with checkpoint (create restore point first)
.\winspec\winspec.ps1 push -Spec .\myconfig.ps1 -Checkpoint

# Show current system state
.\winspec\winspec.ps1 status
```

**Step 3: Daily maintenance**

```powershell
# See what's different between system and your config
.\winspec\winspec.ps1 diff -Spec .\myconfig.ps1

# Pull updated system state (capture new changes)
.\winspec\winspec.ps1 pull -Output my-updated-config.ps1

# If something goes wrong, rollback
.\winspec\winspec.ps1 rollback -Last
```

### CLI Commands

 | Command | Description |
 |---------|-------------|
 | **pull** | Pull system state to config file (Git-like, primary) |
 | **push** | Push config to system (Git-like, primary) |
 | **diff** | Compare system state with a spec |
 | **merge** | Merge two specification files |
 | **status** | Show current system state |
 | `trigger` | Execute a specific trigger |
 | `rollback` | Rollback to a checkpoint |
 | `providers` | List available providers |
 | `validate` | Validate a spec without applying |
 | `sandbox` | Test changes in a sandbox environment |
 | `help` | Show help message |

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

### Skipping Providers

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
# Pull only Registry and Feature state (ignore Service)
winspec pull -Providers Registry,Feature -Output my-config.ps1
```

### Examples

**Daily Workflows:**

```powershell
# === New Machine Setup ===
# 1. On your configured machine: pull current system state
.\winspec\winspec.ps1 pull -Output my-setup.ps1

# 2. On new machine: push the configuration
.\winspec\winspec.ps1 push -Spec .\my-setup.ps1

# === Regular Maintenance ===
# Check if system matches your config
.\winspec\winspec.ps1 diff -Spec .\myconfig.ps1

# Pull updated system state (capture new changes)
.\winspec\winspec.ps1 pull -Output my-updated-config.ps1

# === Applying Changes ===
# Push with checkpoint (safe - creates restore point first)
.\winspec\winspec.ps1 push -Spec .\myconfig.ps1 -Checkpoint

# Dry run - see what would change
.\winspec\winspec.ps1 push -Spec .\myconfig.ps1 -DryRun

# If something goes wrong
.\winspec\winspec.ps1 rollback -Last

# === Other Commands ===
# Initialize a new configuration from current system state
.\winspec\winspec.ps1 init

# Run specific trigger(s)
.\winspec\winspec.ps1 trigger "activation"
.\winspec\winspec.ps1 trigger "activation", "debloat"

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

These scripts require administrator privileges. Always run trigger changes with `-DryRun`/`-WhatIf` first and review remote sources before live execution.

---

## License

See [LICENSE-MIT](LICENSE-MIT) for details.

---

## Documentation

- **[docs/architecture.md](docs/architecture.md)** - Abstractions, concepts, and provider architecture
- **[docs/api.md](docs/api.md)** - User-facing CLI, specification, and provider-extension API
- **[docs/development.md](docs/development.md)** - Contributing, testing, CI, and release workflow
- **[docs/AGENT.md](docs/AGENT.md)** - Toolchain, stack, and operating principles for coding agents
- **[docs/reference.md](docs/reference.md)** - Ephemeral file layout, spec fields, provider schemas, and contracts

---

*WinSpec - Windows Configuration Made Simple*
