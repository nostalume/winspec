# WinSpec Reference

This is the ephemeral implementation reference for WinSpec. It holds concrete file layout, specification fields, provider schemas, and provider contracts that may change as the codebase changes.

For stable concepts, read [architecture.md](architecture.md). For user workflows and CLI usage, read [api.md](api.md). For contribution workflow, read [development.md](development.md). For agent principles, read [AGENT.md](AGENT.md).

---

## File layout map

```text
winspec/
  winspec.ps1          CLI entry point and command dispatcher
  state.psm1           provider discovery, state capture, compare, apply, triggers
  utils.psm1           spec path resolution, import/loading, serialization, merge helpers
  schema.psm1          spec validation
  logging.psm1         user-visible logging helpers
  checkpoint.psm1      Windows restore point and rollback support
  sandbox.psm1         sandbox context, snapshots, simulated changes
  pull.psm1            capture state to specs
  push.psm1            apply specs
  diff.psm1            diff command wrapper
  merge.psm1           spec merge engine
  registry-maps.psm1   friendly registry category/property map
  managers/            declarative idempotent providers
  triggers/            explicit non-idempotent providers

tests/
  Integration.Tests.ps1
  Provider.Tests.ps1
  Trigger.Tests.ps1
  State.Tests.ps1
  fixtures/            sample specifications

docs/
  architecture.md      stable concepts and boundaries
  api.md               user-facing CLI/spec API
  development.md       contribution and development workflow
  AGENT.md             agent toolchain/principles only
  reference.md         concrete, ephemeral implementation reference
```

---

## Specification fields

A specification is a PowerShell `.ps1` file that returns a hashtable.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `Name` | string | No | Specification name for logging and humans. |
| `Description` | string | No | Human-readable description. |
| `Import` | array | No | Other specs to import before applying this spec. |
| `Providers` | string array | No | Optional allow-list for provider operations. |
| `Registry` | hashtable | No | Registry category/property state. |
| `Service` | hashtable | No | Windows service state/startup config. |
| `Feature` | hashtable | No | Windows Optional Feature state. |
| `Trigger` | string/array | No | Explicit non-idempotent trigger names to run. |
| `TriggerConfig` | hashtable | No | Trigger parameter maps keyed by trigger name. |

Minimal example:

```powershell
@{
    Name = "example"
    Registry = @{
        Explorer = @{ ShowHidden = $true; ShowFileExt = $true }
    }
}
```

Composition example:

```powershell
@{
    Name = "developer-workstation"
    Import = @("./base.ps1")
    Registry = @{ Theme = @{ AppTheme = "dark"; SystemTheme = "dark" } }
    Feature = @{ "Microsoft-Windows-Subsystem-Linux" = "enabled" }
}
```

---

## Provider discovery

WinSpec discovers providers by scanning module files and calling `Get-ProviderInfo`.

| Provider family | Built-in directory | User/config directory shape | Type value |
| --- | --- | --- | --- |
| Declarative manager | `winspec/managers/*.psm1` | `<config>/managers/*.psm1` | `Declarative` |
| Trigger | `winspec/triggers/*.psm1` | `<config>/triggers/*.psm1` | `Trigger` |

`Get-ProviderInfo` returns at least:

```powershell
@{
    Name = "Registry"
    Type = "Declarative"
    Description = "..."
}
```

The `Name` value is the command stem for declarative manager functions: `Test-<Name>State`, `Set-<Name>State`, `Export-<Name>State`, and `Compare-<Name>State`.

---

## Declarative manager contract

A declarative manager should export:

```powershell
function Get-ProviderInfo { ... }
function Export-<Name>State { ... }
function Compare-<Name>State { param($System, $Desired) ... }
function Test-<Name>State { param([hashtable]$Desired) ... }
function Set-<Name>State { param([hashtable]$Desired) ... }
```

Common result shape:

```powershell
@{ Status = "Applied" }
@{ Status = "AlreadySet" }
@{ Status = "DryRun" }
@{ Status = "Error"; Message = "..." }
```

Manager rules:

- `Test-<Name>State` must not mutate live state.
- `Set-<Name>State` should apply only missing changes.
- Export functions should return spec-shaped state.
- Compare functions should return diff rows consumable by `state.psm1`/`diff.psm1`.
- Mutating operations should use `SupportsShouldProcess` or equivalent dry-run behavior.

---

## Trigger contract

A trigger should export:

```powershell
function Get-ProviderInfo { ... }
function Invoke-Trigger { param(<typed trigger parameters>) ... }
```

Common result shape:

```powershell
@{ Status = "Success"; Message = "..." }
@{ Status = "DryRun"; Message = "Would execute" }
@{ Status = "Skipped"; Message = "..." }
@{ Status = "Error"; Message = "..." }
```

Triggers are explicit and non-idempotent. Keep remote script execution, activation, debloat, and installer actions in trigger modules rather than declarative managers.

---

## Built-in provider schemas

### Registry

`Registry` manages friendly categories mapped in `winspec/registry-maps.psm1`.

```powershell
Registry = @{
    Clipboard = @{ EnableHistory = $true }
    Explorer  = @{ ShowHidden = $true; ShowFileExt = $true }
    Taskbar   = @{ Alignment = "left"; ShowTaskViewButton = $false; SearchMode = "icon" }
    Start     = @{ ShowRecommendations = $false; ShowRecentlyAddedApps = $true }
    Theme     = @{ AppTheme = "dark"; SystemTheme = "dark" }
    Desktop   = @{ MenuShowDelay = "0"; ForegroundLockTimeout = 0 }
}
```

| Category | Properties | Registry path | Metadata |
| --- | --- | --- | --- |
| `Clipboard` | `EnableHistory` | `HKCU:\Software\Microsoft\Clipboard` | `Scope=HKCU`; no admin; no restart |
| `Explorer` | `ShowHidden`, `ShowFileExt` | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Scope=HKCU`; no admin; Explorer restart |
| `Taskbar` | `Alignment`, `ShowTaskViewButton`, `SearchMode`, `ShowWidgets`, `ShowChat` | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Scope=HKCU`; no admin; Explorer restart |
| `Start` | `ShowRecommendations`, `ShowRecentlyAddedApps`, `ShowRecentlyOpenedItems` | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Scope=HKCU`; no admin; Explorer restart |
| `Theme` | `AppTheme`, `SystemTheme` | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` | `Scope=HKCU`; no admin; no restart |
| `Desktop` | `MenuShowDelay`, `ForegroundLockTimeout` | `HKCU:\Control Panel\Desktop` | `Scope=HKCU`; no admin; sign out |

Each map category defines `Description`, `Scope`, `RequiresAdmin`, and `RestartHint`. Each property defines `Name`, `Type`, `Description`, `Default`, and optional `AllowedValues`/`Map`. `Test-SpecSchema` rejects unknown registry categories/properties and invalid mapped values before apply.

Registry property translations:

| Config property | Registry value | Type/translation |
| --- | --- | --- |
| `Clipboard.EnableHistory` | `EnableClipboardHistory` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Explorer.ShowHidden` | `Hidden` | `DWord`; `$true` -> `1`, `$false` -> `2` |
| `Explorer.ShowFileExt` | `HideFileExt` | `DWord`; `$true` -> `0`, `$false` -> `1` |
| `Taskbar.Alignment` | `TaskbarAl` | `DWord`; `left` -> `0`, `center` -> `1` |
| `Taskbar.ShowTaskViewButton` | `ShowTaskViewButton` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Taskbar.SearchMode` | `SearchboxTaskbarMode` | `DWord`; `hidden` -> `0`, `icon` -> `1`, `box` -> `2` |
| `Taskbar.ShowWidgets` | `TaskbarDa` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Taskbar.ShowChat` | `TaskbarMn` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Start.ShowRecommendations` | `Start_IrisRecommendations` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Start.ShowRecentlyAddedApps` | `Start_TrackProgs` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Start.ShowRecentlyOpenedItems` | `Start_TrackDocs` | `DWord`; `$true` -> `1`, `$false` -> `0` |
| `Theme.AppTheme` | `AppsUseLightTheme` | `DWord`; `light` -> `1`, `dark` -> `0` |
| `Theme.SystemTheme` | `SystemUsesLightTheme` | `DWord`; `light` -> `1`, `dark` -> `0` |
| `Desktop.MenuShowDelay` | `MenuShowDelay` | string milliseconds |
| `Desktop.ForegroundLockTimeout` | `ForegroundLockTimeout` | `DWord` milliseconds |

### Feature

`Feature` manages Windows Optional Features.

```powershell
Feature = @{
    "Microsoft-Windows-Subsystem-Linux" = "enabled"
    "VirtualMachinePlatform" = "enabled"
    "Containers" = "disabled"
}
```

Values:

| Config value | Windows state |
| --- | --- |
| `"enabled"` | `Enabled` |
| `"disabled"` | `Disabled` |

Useful discovery commands:

```powershell
Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State
Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -like "*Linux*" }
```

Common features:

| Feature name | Description |
| --- | --- |
| `Microsoft-Windows-Subsystem-Linux` | Windows Subsystem for Linux |
| `VirtualMachinePlatform` | WSL 2 support |
| `HypervisorPlatform` | Hyper-V platform |
| `Containers` | Windows Containers |
| `Microsoft-Hyper-V-All` | Full Hyper-V |

### Service

`Service` manages service status and startup mode.

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

| Field | Values |
| --- | --- |
| `State` | `"running"`, `"stopped"` |
| `Startup` | `"automatic"`, `"manual"`, `"disabled"` |

Value translations:

| Config value | Windows value |
| --- | --- |
| `State = "running"` | `Running` |
| `State = "stopped"` | `Stopped` |
| `Startup = "automatic"` | `Auto` |
| `Startup = "manual"` | `Manual` |
| `Startup = "disabled"` | `Disabled` |

Useful discovery commands:

```powershell
Get-Service | Select-Object Name, Status, StartType | Sort-Object Name
Get-Service | Where-Object { $_.DisplayName -like "*Windows*" }
Get-WmiObject -Class Win32_Service | Select-Object Name, DisplayName, State, StartMode
```

Common services:

| Name | Display name |
| --- | --- |
| `wuauserv` | Windows Update |
| `WinDefend` | Windows Defender |
| `Spooler` | Print Spooler |
| `WSearch` | Windows Search |
| `BITS` | Background Intelligent Transfer Service |

### Trigger and TriggerConfig

`Trigger` selects explicit non-idempotent actions. `TriggerConfig` supplies parameters for each selected trigger.

```powershell
Trigger = @("activation", "debloat", "office")

TriggerConfig = @{
    activation = @{ Method = "KMS38" }
    debloat    = @{ Silent = $true }
    office     = @{ Path = "C:\Installers"; Cache = $true }
}
```

Built-in triggers:

| Trigger | Config parameters | Notes |
| --- | --- | --- |
| `activation` | `Method` | Activation helper; may download/execute remote script. |
| `debloat` | `Silent` | Debloat helper; may download/execute remote script. |
| `office` | `Path`, `Cache` | Office installer helper. |

Live remote/download actions must stay opt-in and respect native PowerShell execution controls such as `-WhatIf`/dry-run. Runtime confirmation belongs to command execution, not to stored trigger config.

---

## CLI option reference

| Command | Important options |
| --- | --- |
| `pull` | `-Output`, `-Providers`, `-Interactive`, `-Apply`, `-DryRun`, `-NoCache` |
| `push` | `-Spec`, `-Providers`, `-Triggers`, `-DryRun`, `-Checkpoint` |
| `diff` | `-Spec`, `-Against`, `-Providers`, `-NoCache` |
| `merge` | `-Base`, `-Incoming`, `-Output`, `-Strategy`, `-Interactive` |
| `status` | `-Providers`, `-Output`, `-NoCache` |
| `sandbox` | `-Enter`, `-Exit`, `-List`, `-Mode`, `-Snapshot` |
| `rollback` | `-Last`, `-SequenceNumber` |
| `validate` | `-Spec` |
| `providers` | optional resolved config path context |
| `trigger` | trigger names or `*` |

---

## Reference maintenance rule

This file is allowed to be concrete and ephemeral. Update it whenever modules, provider schemas, function names, or file layout change. Keep stable design claims out of this file unless they directly describe the current implementation surface.
