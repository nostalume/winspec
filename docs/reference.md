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

Built-in Service provider safety allow-list:

| Name | Display name |
| --- | --- |
| `WinDefend` | Microsoft Defender Antivirus Service |
| `WdNisSvc` | Microsoft Defender Antivirus Network Inspection Service |
| `SecurityHealthService` | Windows Security Health Service |
| `DiagTrack` | Connected User Experiences and Telemetry |
| `dmwappushservice` | WAP Push Message Routing Service |
| `WSearch` | Windows Search |
| `wuauserv` | Windows Update |
| `UsoSvc` | Update Orchestrator Service |
| `BITS` | Background Intelligent Transfer Service |
| `Dnscache` | DNS Client |
| `Dhcp` | DHCP Client |
| `NlaSvc` | Network Location Awareness |
| `RemoteRegistry` | Remote Registry |
| `TermService` | Remote Desktop Services |
| `WinRM` | Windows Remote Management |
| `SysMain` | SysMain |
| `WerSvc` | Windows Error Reporting Service |
| `Spooler` | Print Spooler |

Service safety behavior:

- Export defaults to the allow-list above.
- Explicit service export requests are filtered to the same allow-list.
- Live apply refuses unmanaged services with `Reason = "ServiceNotManaged"`.
- Live apply refuses non-elevated processes with `Reason = "RequiresAdministrator"`; it does not spawn an elevated service script.

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

## State-management workflow graph

`winspec/state.psm1` owns the implementation flow for provider discovery, state capture, comparison, declarative apply, trigger dispatch, and result summarization.

### Capture flow

```text
Get-SystemState
  -> Get-Managers -ConfigPath <path>
  -> Resolve-ProviderList -Providers <filter>
  -> Export-ProviderState
       -> Resolve-ProviderCommand -Operation Export
       -> Import exact provider module with -PassThru
       -> module.ExportedCommands["Export-<Name>State"]
  -> @{ <Name> = <spec-shaped provider state> }
```

Notes:

- Built-in managers come from `winspec/managers/*.psm1`.
- User managers come from `<ConfigPath>/managers/*.psm1`.
- State capture is fresh by default. The previous process-local state cache, `Clear-SystemStateCache`, and `-NoCache` surfaces have been removed.

### Compare flow

```text
Compare-SystemState
  -> ResolveProviderList
  -> Get-Managers -ConfigPath <path>
  -> provider-name -> provider-object map
  -> Compare-ProviderState -Provider <provider object>
       -> Resolve-ProviderCommand -Operation Compare
       -> module.ExportedCommands["Compare-<Name>State"]
  -> aggregate Added / Removed / Changed / Equal
```

`Compare-SystemState` must pass provider objects, not provider-name strings, because command resolution needs both `.Name` and `.Path`.


### Pull flow

```text
Invoke-Pull
  -> resolve provider selection from CLI -Providers or Spec.Providers
  -> Get-SystemState -Providers <selection> -ConfigPath <path>
       -> built-in managers plus <ConfigPath>/managers/*.psm1
  -> optional Merge-Configuration when output exists and -Apply is set
  -> optional minimal pruning
  -> Save-Configuration when Output is set and not DryRun
```

`pull` output format is extension-driven by `Save-Configuration`: `.json` writes JSON; other extensions write PowerShell hashtable syntax. `pull` does not expose a separate format switch. Expected failures are structured as `NoStateCaptured`, `OutputExists`, or `MergeFailed`; successful pull still returns the captured config hashtable directly.

### Apply flow

```text
Invoke-WinSpec
  -> Test-SpecSchema
  -> optional New-Checkpoint
       -> if requested checkpoint fails: return Reason=CheckpointFailed before mutation
  -> Get-ForwardedCommonParameters
  -> Invoke-Managers
       -> Get-Managers -ConfigPath <path>
       -> restrict by CLI -Providers or Spec.Providers
       -> Resolve-ProviderRuntime (command-local, no global cache)
       -> Invoke-Manager
            -> runtime.Commands["Test-<Name>State"]
            -> runtime.Commands["Set-<Name>State"]
            -> optional runtime.Commands["Invoke-<Name>SandboxApply"]
  -> Invoke-Triggers
  -> derive Success from nested provider/trigger Status=Error values
  -> Write-WinSpecResultSummary
```

Result shape:

```powershell
@{
    Registry = @{ Status = "Applied" }
    Feature  = @{ Status = "AlreadyInDesiredState" }
    Triggers = @{ debloat = @{ Status = "DryRun" } }
    Success  = $true  # false if any nested provider/trigger reports Status="Error"
}
```



### Sandbox integration behavior

`Invoke-Push` owns sandbox lifecycle for push execution:

```text
Invoke-Push -DryRun
  -> Enter-Sandbox -Mode DryRun
  -> Invoke-WinSpec
  -> provider test/apply path reports DryRun
  -> Exit-Sandbox -DiscardChanges
```

If a mock sandbox is already active, `Invoke-Push` reuses it instead of replacing it:

```text
Enter-Sandbox -Mode Mock
Invoke-Push -Spec <spec>
  -> Invoke-WinSpec
  -> Invoke-Manager
  -> module.ExportedCommands["Invoke-<Name>SandboxApply"]
  -> Update-SandboxState / Update-SandboxChanges
```

The orchestrator resolves sandbox commands through the loaded sandbox module rather than a private stale import so provider modules and push orchestration share the same persisted sandbox context. Provider modules remain loaded after invocation; unloading a provider module during a push can also remove shared dependency commands such as logging or sandbox helpers that later providers/triggers still need.

### Checkpoint and rollback behavior

Checkpoint creation is explicit and privilege-gated. When `push -Checkpoint` requests a checkpoint, failure aborts the push before provider or trigger mutation:

```text
New-Checkpoint
  -> Test-SystemRestoreEnabled
  -> Test-IsAdmin
  -> Checkpoint-Computer
```

Failure result shape:

```powershell
@{ Success = $false; Reason = "SystemRestoreDisabled" }
@{ Success = $false; Reason = "RequiresAdministrator" }
@{ Success = $false; Reason = "CheckpointFailed"; Error = "..." }
@{ Success = $false; Reason = "CheckpointFailed"; Checkpoint = @{ Reason = "RequiresAdministrator" } }
```

Rollback selects either an explicit sequence number or the newest restore point whose description starts with `WinSpec` when `-Last` is used. `Restore-Computer` is called only inside `ShouldProcess`; under `-WhatIf`, rollback returns a structured result and does not restore the machine.

Rollback result shape:

```powershell
@{ Success = $true; SequenceNumber = 30; Description = "WinSpec-..." }
@{ Success = $false; Reason = "SystemRestoreDisabled" }
@{ Success = $false; Reason = "NoRestorePoints" }
@{ Success = $false; Reason = "RollbackTargetRequired" }
@{ Success = $false; Reason = "RestorePointNotFound" }
@{ Success = $false; Reason = "WhatIf" }
@{ Success = $false; Reason = "RestoreFailed"; Error = "..." }
```

### Trigger flow

```text
Invoke-Triggers
  -> Resolve-Triggers
       -> CLI -Triggers, else Spec.Trigger, else none
       -> TriggerConfig.<name> parameter map
  -> Invoke-TriggerProvider
       -> Import exact trigger module with -PassThru
       -> module.ExportedCommands["Invoke-Trigger"]
       -> & Invoke-Trigger @TriggerConfig.<name> @CommonParameters
```

Special selection rule: CLI `-Triggers *` means every discovered trigger.

---

---

## State-management follow-up plan

Development review notes and implementation slices live in [report/state-management-follow-up.md](report/state-management-follow-up.md). This reference keeps only the current public/internal API surface.

---

## CLI option reference

| Command | Important options |
| --- | --- |
| `pull` | `-Output`, `-Providers`, `-Interactive`, `-Apply`, `-DryRun`, `-ConfigPath` |
| `push` | `-Spec`, `-Providers`, `-Triggers`, `-DryRun`, `-Checkpoint` |
| `diff` | `-Spec`, `-Against`, `-Providers` |
| `merge` | `-Base`, `-Incoming`, `-Output`, `-Strategy`, `-Interactive` |
| `status` | `-Providers`, `-Output` |
| `sandbox` | `-Enter`, `-Exit`, `-List`, `-Mode`, `-Snapshot` |
| `rollback` | `-Last`, `-SequenceNumber` |
| `validate` | `-Spec` |
| `providers` | optional resolved config path context |
| `trigger` | trigger names or `*` |

---

## Reference maintenance rule

This file is allowed to be concrete and ephemeral. Update it whenever modules, provider schemas, function names, or file layout change. Keep stable design claims out of this file unless they directly describe the current implementation surface.


### Pull output path and skipped providers

Directory outputs are normalized before capture: `winspec pull -Output ~/.config/winspec` writes `~/.config/winspec/.winspec.ps1`. If that file already exists and `-Apply` is not supplied, pull exits before provider capture so privilege-bound providers do not emit unrelated warnings. Providers that return empty state are not listed as captured.
