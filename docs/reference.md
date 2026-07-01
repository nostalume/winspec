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
- The previous process-local state cache has been removed; `Clear-SystemStateCache` currently remains as a no-op compatibility export.

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

### Apply flow

```text
Invoke-WinSpec
  -> Test-SpecSchema
  -> optional New-Checkpoint
  -> Get-ForwardedCommonParameters
  -> Invoke-Managers
       -> Get-Managers -ConfigPath <path>
       -> restrict by CLI -Providers or Spec.Providers
       -> Invoke-Manager
            -> module.ExportedCommands["Test-<Name>State"]
            -> module.ExportedCommands["Set-<Name>State"]
            -> optional module.ExportedCommands["Invoke-<Name>SandboxApply"]
  -> Invoke-Triggers
  -> Write-WinSpecResultSummary
```

Result shape:

```powershell
@{
    Registry = @{ Status = "Applied" }
    Feature  = @{ Status = "AlreadyInDesiredState" }
    Triggers = @{ debloat = @{ Status = "DryRun" } }
    Success  = $true
}
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

## Provider comparison implementation review

This section records current comparison semantics and known consistency gaps.

### Registry comparison

Implementation: `winspec/managers/registry.psm1` -> `Compare-RegistryState`.

Current algorithm:

1. Iterate desired categories and properties only.
2. Read corresponding system category/property if present.
3. Emit:
   - `Added` when desired property is absent from system state.
   - `Changed` when system value differs from desired value.
4. It does not emit `Removed` or `Equal` rows.

Assessment:

- Good: sparse desired registry specs do not produce noisy removals for every unmanaged registry value.
- Good: comparison operates on friendly/spec-shaped values after export translation.
- Gap: output semantics differ from Feature and Service because it suppresses `Removed`/`Equal` entirely.
- Gap: this should be documented as sparse-spec behavior or normalized across providers.

### Feature comparison

Implementation: `winspec/managers/feature.psm1` -> `Compare-FeatureState`.

Current algorithm:

1. Iterate desired feature names.
2. Emit `Added` if feature is missing from system export.
3. Emit `Changed` if exported state differs from desired state.
4. Iterate system feature names and emit `Removed` for any feature not present in desired.

Assessment:

- Good: detects features present in captured state but absent from desired.
- Correctness gap: desired values are schema-level lowercase (`enabled`/`disabled`), while `Export-FeatureState` returns Windows casing (`Enabled`/`Disabled`). Direct string comparison can mark equal states as changed.
- Noise gap: when comparing a sparse desired spec against a broad live export, removed-feature rows can dominate the diff even though omitted features may be intentionally unmanaged.
- Recommended next slice: normalize feature state values before comparison and decide whether provider comparisons should use sparse-spec semantics by default.

### Service comparison

Implementation: `winspec/managers/service.psm1` -> `Compare-ServiceState`.

Current algorithm:

1. Iterate desired services.
2. Emit `Added` if the service is absent from system export.
3. Emit `Equal` if both `State` and `Startup` match.
4. Otherwise emit `Changed` for the whole service object.
5. Iterate system services and emit `Removed` when absent from desired.

Assessment:

- Good: can report `Equal`, `Changed`, `Added`, and `Removed` rows.
- Correctness gap: desired spec uses lowercase values (`running`, `stopped`, `automatic`, `manual`, `disabled`), while service export uses PowerShell/.NET casing (`Running`, `Stopped`, `Automatic`, etc.). Direct comparison can mark equal states as changed.
- Granularity gap: state and startup differences are collapsed into one service-level row. That is usable, but less precise than registry property-level rows.
- Scope gap: default provider list is currently `Registry`, `Feature`; `Service` is built in and schema-valid but not part of the default capture/compare provider list unless selected.

### Cross-provider comparison consistency

Current diff row shape is conceptually shared:

```powershell
[pscustomobject]@{
    Type        = "Added" # or Removed/Changed/Equal
    Path        = "Provider.Path"
    SystemValue = <current>
    ConfigValue = <desired>
}
```

Consistency issues to resolve later:

1. Normalize provider exported values to spec-level values before comparison.
2. Decide sparse-spec semantics: omitted desired keys may mean unmanaged, not removed.
3. Decide row granularity: provider-level object rows vs leaf/property rows.
4. Include `Service` in default providers or document why it is explicit-only.

---

## Sandbox consistency review

`sandbox.psm1` currently provides a persistent marker file, snapshots, history, and in-memory mock state. The orchestration layer checks sandbox state through `Test-WinSpecSandboxActive` and `Get-WinSpecSandboxMode` wrappers.

### Current sandbox data model

Files:

```text
~/.config/winspec/sandbox/sandbox.json
~/.config/winspec/sandbox/snapshots/<name>.json
~/.config/winspec/sandbox/history/<timestamp>.json
```

In-memory context shape:

```powershell
@{
    Mode      = "DryRun" | "Mock" | "Live"
    Snapshot  = "default"
    StartTime = <date>
    Changes   = @()
    State     = <provider state map>
    Original  = <initial state clone>
}
```

### Correctness gaps

1. **Persisted active sandbox vs process-local context**

   `Test-SandboxActive` checks whether `sandbox.json` exists, but `Get-SandboxMode` returns `Live` when `$Script:SandboxContext` is not populated. A new PowerShell process can see sandbox active while reporting mode as `Live`.

   Target fix: make `Get-SandboxMode` load `Get-SandboxContext` when process-local context is null.

2. **Mutation persistence**

   `Update-SandboxState` mutates only `$Script:SandboxContext.State`. It does not rewrite `sandbox.json`. `Exit-Sandbox` reloads context from disk via `Get-SandboxContext`, so in-memory changes may be absent from saved history.

   Target fix: after state/change mutation, persist the updated context atomically to `sandbox.json`.

3. **JSON type locality**

   `Import-SandboxState` returns `ConvertFrom-Json` objects without `-AsHashtable`, but provider sandbox mutation code often treats state as a hashtable with indexers and `.ContainsKey()`.

   Target fix: use `ConvertFrom-Json -AsHashtable` consistently for sandbox state files, or normalize state objects at load boundaries.

4. **Initial sandbox state shape mismatch**

   `New-SandboxState` uses `Registry.Explorer.HideFileExt`, but the public spec field is `ShowFileExt`. This makes mock state diverge from registry provider spec shape.

   Target fix: seed mock state with spec-shaped keys only.

5. **Service sandbox is incomplete**

   `Invoke-ServiceSandbox` currently tracks startup changes but does not fully model service `State` changes.

   Target fix: simulate both `State` and `Startup` using the same spec shape as `Service` config.

6. **Dead comparator path**

   `sandbox.psm1` has `Register-ProviderComparator`, `Compare-ProviderState`, and `Invoke-SandboxDryRun`, but no built-in comparators are registered and the dry-run function is not exported. The active path is provider-specific `Invoke-<Name>SandboxApply`, not this comparator engine.

   Target fix: either delete the unused comparator engine or wire it into the same module-scoped provider comparison path used by `state.psm1`. Ponytail default: delete unless a caller needs it.

7. **Provider locality**

   `$Script:Providers = @("Registry", "Service", "Feature")` is hard-coded in sandbox dry-run. It does not reflect user providers discovered via `ConfigPath`.

   Target fix: do not keep a separate sandbox provider list. Reuse `Get-Managers -ConfigPath` if sandbox dry-run remains.

8. **Cache/locality model**

   Normal state cache has been removed from `state.psm1`, but sandbox persists globally under the user profile, not per config path or repo. Snapshot names are global.

   Target fix: include config/workspace identity in sandbox scope or document that sandbox state is a user-global WinSpec context.

### Recommended sandbox cleanup order

1. Fix process-local context loading: `Get-SandboxMode` and state access should hydrate from `sandbox.json`.
2. Persist mutations after `Update-SandboxState` and `Update-SandboxChanges`.
3. Normalize JSON state as hashtables at load/save boundaries.
4. Fix seeded state keys to match public spec shape.
5. Complete Service state simulation.
6. Delete or wire the unused comparator/dry-run engine.
7. Decide whether sandbox root is user-global or config/workspace-local, then document/enforce it.

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
