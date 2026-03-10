# WinSpec Specification Guide

Complete guide for using built-in providers, writing specifications, and developing custom providers.

For configuration details, see [configuration.md](configuration.md).

---

## Provider Types

| Type | Location | Characteristics | Idempotent |
|------|----------|-----------------|------------|
| **Declarative** | `managers/` | State-based (registry, packages, services, features) | Yes |
| **Trigger** | `triggers/` | Action-based (activation, debloating) | No |

Declarative providers test current state and apply changes only when needed. Trigger providers execute actions every invocation.

---

## Specification Format

A specification is a PowerShell `.ps1` file returning a hashtable:

```powershell
@{
    Name = "example"
    Description = "Example specification"
    Import = @(".\specs\default.ps1")     # Composition
    Registry = @{ ... }                     # Declarative providers
    Package = @{ ... }
    Service = @{ ... }
    Feature = @{ ... }
    Trigger = @(                            # Non-idempotent triggers
        @{ Name = "Activation" }
    )
}
```

### Specification Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Name` | string | No | Specification name for logging |
| `Description` | string | No | Human-readable description |
| `Import` | array | No | Paths to other specs to import |
| `Registry` | hashtable | No | Registry configuration |
| `Package` | hashtable | No | Package management |
| `Service` | hashtable | No | Windows services |
| `Feature` | hashtable | No | Windows optional features |
| `Trigger` | array | No | Trigger actions to execute |

---

## Declarative Providers

### Registry Provider

Manages Windows registry settings with predefined categories.

See [registry-reference.md](registry-reference.md) for all available registry settings.

### Package Provider

Ensures packages are installed via Scoop.

**Prerequisite:** Scoop must be installed manually before using this provider.

```powershell
# Install Scoop (run in PowerShell)
irm get.scoop.sh | iex
```

| Field | Type | Description |
|-------|------|-------------|
| `Installed` | array | Package names to install |

```powershell
Package = @{
    Installed = @("git", "neovim", "nodejs")
}
```

Uses `scoop export` to efficiently determine current package state.

### Service Provider

Manages Windows services.

See [service-reference.md](service-reference.md) for how to find proper service names and available values.

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

### Feature Provider

Manages Windows optional features.

See [feature-reference.md](feature-reference.md) for how to find proper feature names and available values.

```powershell
Feature = @{
    "Microsoft-Windows-Subsystem-Linux" = "enabled"
}
```

---

## Trigger Providers

Execute one-time, non-idempotent actions.

### Trigger Configuration

```powershell
Trigger = @(
    @{ Name = "TriggerName"; Value = ...; Path = "..."; Enabled = $true/$false }
)
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `Name` | string | Yes | Trigger name |
| `Value` | any | No | Value to pass (default: `$true`) |
| `Path` | string | No | Path to custom script |
| `Enabled` | bool | No | Enable/disable (default: `$true`) |

### Built-in Triggers

| Trigger | Value | Description |
|---------|-------|-------------|
| `Activation` | `$true` | Activate Windows/Office |
| `Debloat` | `$true`, `"silent"` | Remove bloatware |
| `Office` | `"C:\Path"` | Download Office installer |

### Custom Triggers

See [configuration.md](configuration.md) for detailed guide on writing custom triggers.

**Search Order:**
1. Explicit `Path` if specified
2. Built-in: `winspec/triggers/<Name>.psm1`
3. Spec directory: Directory where your `.ps1` spec file is located
4. Config directory: `%USERPROFILE%\.config\winspec\triggers\<Name>.ps1`

---

## Custom Provider Development

### Declarative Provider Contract

```powershell
function Get-ProviderMetadata {
    return @{ Name = "Example"; Type = "Declarative"; Description = "..." }
}

function Test-ExampleState {
    param ([hashtable]$Desired)
    return $true/$false
}

function Set-ExampleState {
    param ([hashtable]$Desired, [switch]$WhatIf)
    return @{ Status = "Applied"/"AlreadySet"/"Error"/"DryRun"; Message = "..." }
}

Export-ModuleMember Get-ProviderMetadata, Test-ExampleState, Set-ExampleState
```

### Trigger Provider Contract

```powershell
function Get-ProviderMetadata {
    return @{ Name = "Example"; Type = "Trigger"; Description = "..." }
}

function Invoke-ExampleTrigger {
    param ($Option = $true, [switch]$WhatIf)
    return @{ Status = "Success"/"Error"/"DryRun"/"Skipped"; Message = "..." }
}

Export-ModuleMember Get-ProviderMetadata, Invoke-ExampleTrigger
```

### Declarative Template

```powershell
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderMetadata { ... }

function Get-MyProviderState { param ([string]$ItemName) }

function Test-MyProviderState {
    param ([hashtable]$Desired)
    foreach ($item in $Desired.Keys) {
        if ((Get-MyProviderState -ItemName $item) -ne $Desired[$item]) { return $false }
    }
    return $true
}

function Set-MyProviderState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ([hashtable]$Desired, [switch]$WhatIf)
    $results = @{}
    foreach ($item in $Desired.Keys) {
        $current = Get-MyProviderState -ItemName $item
        if ($current -eq $Desired[$item]) {
            Write-LogOk -Name $item -DesiredValue $Desired[$item]
            $results[$item] = @{ Status = "AlreadySet" }
            continue
        }
        Write-LogChange -Name $item -CurrentValue $current -DesiredValue $Desired[$item]
        if ($PSCmdlet.ShouldProcess($item, "Set state")) {
            try {
                # Apply change
                Write-LogApplied -Name $item -DesiredValue $Desired[$item]
                $results[$item] = @{ Status = "Applied" }
            }
            catch {
                Write-LogError -Name $item -Details $_.Exception.Message
                $results[$item] = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }
    }
    return $results
}
```

### Trigger Template

```powershell
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderMetadata { ... }

function Invoke-MyTriggerTrigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ($Option = $true, [switch]$WhatIf)
    if ($WhatIf) { return @{ Status = "DryRun"; Message = "Would execute" } }
    try {
        # Execute action
        Write-Log -Level "APPLIED" -Message "Executed"
        return @{ Status = "Success"; Message = "Completed" }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed: $($_.Exception.Message)"
        return @{ Status = "Error"; Message = $_.Exception.Message }
    }
}
```

---

## Installation & Configuration

### Provider Locations

| Scope | Declarative | Triggers |
|-------|-------------|----------|
| System | `winspec/managers/{name}.psm1` | `winspec/triggers/{name}.psm1` |
| User | `%USERPROFILE%\.config\winspec\managers\{name}.psm1` | `%USERPROFILE%\.config\winspec\triggers\{name}.psm1` |

Custom path: `@{ Name = "trigger"; Path = ".\triggers\custom.ps1" }`

### Config Location Resolution (Priority Order)

1. `-ConfigPath` argument
2. `$env:WINSPEC_CONFIG` environment variable
3. `%USERPROFILE%\.config\winspec\`
4. `.winspec.ps1` in current directory

### CLI Commands

| Command | Description |
|---------|-------------|
| **pull** | Pull system state to config file (Git-like) |
| **push** | Push config to system (Git-like) |
| **diff** | Compare system state with a spec |
| **merge** | Merge two specification files |
| **status** | Show current system state |
| `apply` | Apply a specification file (legacy alias for push) |
| `init` | Initialize a new configuration from system state (legacy alias for pull) |
| `trigger` | Execute a specific trigger |
| `export` | Export current system state (legacy alias for pull) |
| `sync` | Interactive sync (legacy, use pull + push instead) |
| `rollback` | Rollback to a checkpoint |
| `providers` | List available providers |
| `validate` | Validate a spec without applying |
| `sandbox` | Test changes in a sandbox environment |
| `help` | Show help message |

---

## Testing & Validation

### Testing with Pester

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\managers\myprovider.psm1" -Force
}

Describe "MyProvider" {
    It "Returns correct provider info" {
        $info = Get-ProviderMetadata
        $info.Name | Should -Be "MyProvider"
    }
}
```

### Validation

```powershell
.\winspec\winspec.ps1 validate -Spec .\specs\developer.ps1
```

Checks: PowerShell syntax, field types, provider schema validation.

---

## Best Practices

1. **Always import logging:**
   ```powershell
   Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force
   ```

2. **Use logging functions:**
   - `Write-LogOk` - State already correct
   - `Write-LogChange` - About to change
   - `Write-LogApplied` - Change applied
   - `Write-LogError` - Error occurred

3. **Support ShouldProcess:**
   ```powershell
   [CmdletBinding(SupportsShouldProcess = $true)]
   if ($PSCmdlet.ShouldProcess($target, $action)) { # Make changes }
   ```

4. **Return consistent results:**
   - Declarative: `@{ Status = "Applied"/"AlreadySet"/"Error"/"DryRun" }`
   - Trigger: `@{ Status = "Success"/"Error"/"DryRun"/"Skipped"; Message = "..." }`

5. **Handle errors gracefully:**
   ```powershell
   try { # Operation }
   catch { return @{ Status = "Error"; Message = $_.Exception.Message } }
   ```

6. **Check state before changing:**
   ```powershell
   if ($current -eq $desired) { return @{ Status = "AlreadySet" } }
   ```

---

*WinSpec Specification Guide v3.0*
