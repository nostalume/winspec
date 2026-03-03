# WinSpec Specification Guide

Complete guide for using built-in providers, writing specifications, and developing custom providers.

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

| Category | Properties | Description |
|----------|------------|-------------|
| `Clipboard` | `EnableHistory` | Clipboard history |
| `Explorer` | `ShowHidden`, `ShowFileExt` | File Explorer |
| `Theme` | `AppTheme`, `SystemTheme` | Windows theme |
| `Desktop` | `MenuShowDelay` | Desktop behavior |

See [registry-reference.md](registry-reference.md) for complete reference.

---

### Package Provider

Ensures packages are installed via Scoop.

| Field | Type | Description |
|-------|------|-------------|
| `Installed` | array | Package names to install |

```powershell
Package = @{
    Installed = @("git", "neovim", "nodejs")
}
```

Auto-installs Scoop if not present.

---

### Service Provider

Manages Windows services.

| Field | Type | Values |
|-------|------|--------|
| `State` | string | `"running"`, `"stopped"` |
| `Startup` | string | `"automatic"`, `"manual"`, `"disabled"` |

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

---

### Feature Provider

Manages Windows optional features.

| Value | Description |
|-------|-------------|
| `"enabled"` | Enable feature |
| `"disabled"` | Disable feature |

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

```powershell
Trigger = @(
    @{ Name = "Activation" }
    @{ Name = "Debloat"; Value = "silent" }
    @{ Name = "Office"; Value = "C:\Installers" }
)
```

### Custom Triggers

**Search Order:**
1. Explicit `Path` if specified
2. Built-in: `winspec/triggers/<Name>.psm1`
3. Spec directory: `<SpecDir>/triggers/<Name>.ps1`
4. Config directory: `<ConfigDir>/triggers/<Name>.ps1`

**Script Format:**
```powershell
param($Value = $true, [switch]$WhatIf)
if ($WhatIf) { return @{ Status = "DryRun" } }
# Custom logic
return @{ Status = "Success"; Message = "Done" }
```

**Disable Triggers:**
```powershell
Trigger = @(
    @{ Name = "Activation"; Enabled = $false }
)
# Or: Trigger = @()  # Disable all
```

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

```powershell
# Explicit path
.\winspec\winspec.ps1 apply -Spec .\spec.ps1 -ConfigPath C:\WinSpec\Config

# Environment variable
$env:WINSPEC_CONFIG = "C:\WinSpec\Config"
```

### Composition

Specs can import others. Later specs override earlier ones for conflicting keys.

```powershell
# base.ps1
@{ Registry = @{ Theme = @{ AppTheme = "light" } } }

# custom.ps1
@{ 
    Import = @(".\base.ps1")
    Registry = @{ Theme = @{ AppTheme = "dark" } }  # Overrides base
}
```

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
