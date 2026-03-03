# WinSpec Configuration Guide

Complete guide for writing and using WinSpec specifications.

---

## Quick Start

A specification is a PowerShell `.ps1` file that returns a hashtable:

```powershell
# my-config.ps1
@{
    Name = "my-config"
    Registry = @{
        Theme = @{ AppTheme = "dark" }
    }
}
```

Apply it:
```powershell
.\winspec.ps1 apply -Spec .\my-config.ps1
```

---

## Specification Structure

| Field | Type | Description |
|-------|------|-------------|
| `Name` | string | Specification name for logging |
| `Description` | string | Human-readable description |
| `Import` | array | Paths to other specs to import |
| `Registry` | hashtable | Windows registry settings |
| `Package` | hashtable | Package installation (Scoop) |
| `Service` | hashtable | Windows service configuration |
| `Feature` | hashtable | Windows optional features |
| `Trigger` | array | One-time actions to execute |

---

## Configuration Resolution

WinSpec automatically finds your configuration files in this priority order:

1. **Explicit** `-ConfigPath` argument
2. **Environment** `$env:WINSPEC_CONFIG` variable
3. **User config** `%USERPROFILE%\.config\winspec\`
4. **Current directory** `.winspec.ps1` file

### User Configuration Directory

```
%USERPROFILE%\.config\winspec\
├── triggers\          # Custom trigger scripts
│   ├── my-trigger.ps1
│   └── custom-setup.ps1
├── managers\          # Custom declarative providers
│   └── my-provider.psm1
└── ...                # Other config files
```

---

## Declarative Providers

Declarative providers are **idempotent** - running them multiple times produces the same result. They only make changes when needed.

### Registry Provider

Configure Windows registry settings through predefined categories.

**Available Categories:**

| Category | Description |
|----------|-------------|
| `Clipboard` | Clipboard history settings |
| `Explorer` | File Explorer behavior |
| `Theme` | Windows light/dark theme |
| `Desktop` | Desktop behavior settings |

**Example:**
```powershell
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
        MenuShowDelay = "0"  # Instant menu display
    }
}
```

For all available registry settings, see [registry-reference.md](registry-reference.md).

### Package Provider

Ensures specified packages are installed via Scoop.

```powershell
Package = @{
    Installed = @("git", "neovim", "nodejs", "python", "7zip")
}
```

Scoop is automatically installed if not present.

### Service Provider

Manages Windows service states and startup types.

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

**Valid states:** `running`, `stopped`  
**Valid startup types:** `automatic`, `manual`, `disabled`

### Feature Provider

Manages Windows optional features.

```powershell
Feature = @{
    "Microsoft-Windows-Subsystem-Linux" = "enabled"
    "VirtualMachinePlatform" = "enabled"
}
```

**Valid values:** `enabled`, `disabled`

---

## Trigger Providers

Triggers execute **one-time, non-idempotent actions**. They are explicitly separated from declarative providers to make it clear that running them multiple times may have different effects.

### Configuration Format

Triggers use an **array of hashtables**:

```powershell
Trigger = @(
    @{ Name = "TriggerName" [; Value = ...] [; Path = "..."] [; Enabled = $true/$false] }
)
```

| Field | Required | Description |
|-------|----------|-------------|
| `Name` | Yes | Trigger name (built-in or custom) |
| `Value` | No | Option to pass to trigger (default: `$true`) |
| `Path` | No | Path to custom trigger script |
| `Enabled` | No | Enable/disable trigger (default: `$true`) |

### Built-in Triggers

| Trigger | Description | Example |
|---------|-------------|---------|
| **Activation** | Activate Windows/Office | `@{ Name = "Activation" }` |
| **Debloat** | Remove bloatware | `@{ Name = "Debloat"; Value = "silent" }` |
| **Office** | Download Office installer | `@{ Name = "Office"; Value = "C:\Installers" }` |

**Complete Trigger Example:**
```powershell
Trigger = @(
    # Built-in triggers
    @{ Name = "Activation" }
    @{ Name = "Debloat"; Value = "silent" }
    @{ Name = "Office"; Value = "C:\Installers"; Enabled = $false }
    
    # Custom triggers
    @{ Name = "backup"; Path = ".\triggers\backup.ps1"; Value = "daily" }
)
```

### Custom Triggers

Place PowerShell scripts in your configuration directory:

```powershell
# %USERPROFILE%\.config\winspec\triggers\my-custom.ps1
param(
    [Parameter(Mandatory = $false)]
    $Value = $true,
    [switch]$WhatIf
)

if ($WhatIf) {
    return @{ Status = "DryRun"; Message = "Would execute custom trigger" }
}

# Your custom logic here
return @{ Status = "Success"; Message = "Done" }
```

---

## Specification Composition

Specifications can import other specifications. Later specs override earlier ones for conflicting keys.

```powershell
# base.ps1
@{
    Name = "base"
    Registry = @{
        Theme = @{ AppTheme = "light" }
    }
}

# custom.ps1
@{
    Name = "custom"
    Import = @(".\base.ps1")
    
    Registry = @{
        Theme = @{ AppTheme = "dark" }  # Overrides base
    }
    Package = @{
        Installed = @("git")  # Merged with base
    }
}
```

---

## Commands

### Apply Configuration

```powershell
# Apply declarative only
.\winspec.ps1 apply -Spec .\my-config.ps1

# Apply with triggers
.\winspec.ps1 apply -Spec .\my-config.ps1 -WithTriggers

# Preview changes (dry run)
.\winspec.ps1 apply -Spec .\my-config.ps1 -DryRun

# Apply with checkpoint
.\winspec.ps1 apply -Spec .\my-config.ps1 -Checkpoint
```

### Run Triggers

Run a single trigger:
```powershell
.\winspec.ps1 trigger -Name activation
.\winspec.ps1 trigger -Name debloat -Option "silent"
```

Run multiple triggers:
```powershell
.\winspec.ps1 trigger -Name @("activation", "debloat")
.\winspec.ps1 trigger -Name @("activation", "debloat") -Option "silent"
```

Run all available triggers:
```powershell
.\winspec.ps1 trigger
```

### Validate Without Applying

```powershell
.\winspec.ps1 validate -Spec .\my-config.ps1
```

### List Available Providers

```powershell
.\winspec.ps1 providers

# With custom config directory
.\winspec.ps1 providers -ConfigPath C:\MyConfig
```

### Check System Status

```powershell
.\winspec.ps1 status
```

### Rollback Changes

```powershell
.\winspec.ps1 rollback -Last
.\winspec.ps1 rollback -SequenceNumber 100
```

---

## Complete Example

```powershell
# developer.ps1
@{
    Name = "developer"
    Description = "Developer workstation configuration"
    
    Import = @(".\base.ps1")
    
    Registry = @{
        Clipboard = @{ EnableHistory = $true }
        Explorer = @{ ShowHidden = $true; ShowFileExt = $true }
        Theme = @{ AppTheme = "dark"; SystemTheme = "dark" }
        Desktop = @{ MenuShowDelay = "0" }
    }
    
    Package = @{
        Installed = @("git", "neovim", "nodejs", "python", "7zip", "vscode")
    }
    
    Service = @{
        wuauserv = @{ State = "stopped"; Startup = "disabled" }
    }
    
    Feature = @{
        "Microsoft-Windows-Subsystem-Linux" = "enabled"
        "VirtualMachinePlatform" = "enabled"
    }
    
    Trigger = @(
        @{ Name = "Debloat"; Value = "silent" }
    )
}
```

---

*WinSpec Configuration Guide v2.0*
