# WinSpec Configuration Guide

Complete guide for writing and using WinSpec specifications.

For detailed provider references, see:
- [registry-reference.md](registry-reference.md) - Registry provider details
- [service-reference.md](service-reference.md) - Service provider details  
- [feature-reference.md](feature-reference.md) - Feature provider details

---

## Configuration Resolution

WinSpec automatically finds your configuration files in this priority order:

1. **Explicit** `-ConfigPath` argument
2. **Environment** `$env:WINSPEC_CONFIG` variable
3. **User config** `%USERPROFILE%\.config\winspec\`
4. **Current directory** `.winspec.ps1` file

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

## Import Path Resolution

The `Import` field supports path resolution in this priority order:

1. **Absolute path**: `C:\Configs\base.ps1`
2. **Relative to current spec**: `.\base.ps1`
3. **Relative to config directory**: `%USERPROFILE%\.config\winspec\base.ps1`
4. **Built-in specs**: `base`, `minimal` (no extension needed)

```powershell
# Absolute path
Import = @("C:\MyConfigs\base.ps1")

# Relative to current file
Import = @(".\base.ps1")
Import = @("..\shared\defaults.ps1")

# Using built-in spec names
Import = @("base")

# Multiple imports (later overrides earlier)
Import = @(".\base.ps1", ".\custom.ps1")
```

---

## Declarative Providers

Declarative providers are **idempotent** - running them multiple times produces the same result.

### Registry Provider

See [registry-reference.md](registry-reference.md) for all available categories and properties.

### Package Provider

Ensures specified packages are installed via Scoop.

```powershell
Package = @{
    Installed = @("git", "neovim", "nodejs", "python", "7zip")
}
```

Scoop is automatically installed if not present.

### Service Provider

See [service-reference.md](service-reference.md) for how to find service names.

### Feature Provider

See [feature-reference.md](feature-reference.md) for how to find feature names.

---

## Trigger Providers

Triggers execute **one-time, non-idempotent actions**.

### Configuration Format

```powershell
Trigger = @(
    @{ Name = "TriggerName" [; Value = ...] [; Path = "..."] }
)
```

| Field | Required | Description |
|-------|----------|-------------|
| `Name` | Yes | Trigger name (built-in or custom) |
| `Value` | No | Option to pass to trigger (default: `$true`) |
| `Path` | No | Path to custom trigger script |
| `Enabled` | No | Enable/disable trigger (default: `$true`) |

### Built-in Triggers

| Trigger | Description |
|---------|-------------|
| `Activation` | Activate Windows/Office |
| `Debloat` | Remove bloatware |
| `Office` | Download Office installer |

### Writing Custom Triggers

#### Trigger Search Order

When you specify `@{ Name = "my-trigger" }`, WinSpec searches in this order:

1. **Explicit `Path`** if specified: `@{ Name = "my"; Path = ".\custom\trigger.ps1" }`
2. **Built-in triggers**: `winspec/triggers/<Name>.psm1`
3. **Config directory**: `%USERPROFILE%\.config\winspec\triggers\<Name>.ps1`
4. **Spec directory**: Directory where your `.ps1` spec file is located, then `triggers\<Name>.ps1`

> **Note:** `SpecDir` means the directory containing the specification file you're applying. For example, if you're applying `.\my-config.ps1`, the spec directory is the current directory.

Create a PowerShell script that accepts parameters and returns a status hashtable:

```powershell
# triggers/my-trigger.psm1
Import-Module (Join-Path $PSScriptRoot "..\your_module.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "MyTrigger"
        Type = "Trigger"
    }
}

function Invoke-Trigger {
    param (
        $Option = $true
    )

    return @{
        Status  = "Success"
        Message = "Trigger executed successfully"
    }
}


Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
```

**Trigger Script Requirements:**
- Accept `Invoke-Trigger`(fixed identifier) function
- Accept `$Option`(fixed identifier) parameter (any type)
- Support `-WhatIf` switch for dry run
- Return hashtable with `Status` key: `"Success"`, `"Error"`, `"DryRun"`, `"Skipped"`
- Optionally include `Message` for details

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

See [spec.md](spec.md) for complete CLI command reference.

---

*WinSpec Configuration Guide v2.0*
