# WinSpec API Guide

This is the user-facing API for WinSpec: commands, specification shape, provider sections, and extension points. It avoids internal architecture detail; see [architecture.md](architecture.md) for concepts and [development.md](development.md) for contributor workflow.

---

## What WinSpec exposes

WinSpec exposes three practical APIs:

1. **CLI API**: `winspec <command> [options]` for pull, push, diff, merge, status, validation, sandbox, triggers, and rollback.
2. **Specification API**: PowerShell `.ps1` files returning hashtables.
3. **Provider API**: PowerShell module contracts for adding managers and triggers.

---

## Installation and invocation

From source:

```powershell
git clone https://github.com/nostalume/winspec.git
cd winspec
./winspec/winspec.ps1 help
```

After Scoop installation or PATH setup, examples may use `winspec` instead of `./winspec/winspec.ps1`.

Most live-system operations require Administrator privileges. Providers that require elevation fail explicitly when the current process is not elevated; WinSpec does not silently mutate services from a non-admin process.

---

## CLI API

### Command summary

| Command | Purpose |
| --- | --- |
| `pull` | Capture current system state into a spec file. |
| `push` | Apply a spec to the system. |
| `diff` | Compare a spec against the live system or another spec. |
| `merge` | Merge two specs. |
| `status` | Print current provider state as JSON. |
| `providers` | List discovered built-in and user providers. |
| `validate` | Validate a spec without applying it. |
| `trigger` | Execute selected non-idempotent triggers. |
| `sandbox` | Enter, inspect, list, or exit sandbox mode. |
| `rollback` | Restore a Windows System Restore checkpoint. |
| `help` | Show general or command-specific help. |

Global options include:

| Option | Meaning |
| --- | --- |
| `-Spec <path>` | Specification file path. |
| `-Output <path>` | Output path for commands that write files. |
| `-Providers <names>` | Restrict operation to named providers. |
| `-DryRun` | Preview changes without applying. |
| `-Help` | Show help for the selected command. |

### `pull`

Capture live state into a configuration file.

```powershell
# Pull to the resolved default spec path
winspec pull

# Pull to a specific file
winspec pull -Output ./my-config.ps1

# Pull only selected providers
winspec pull -Providers Registry,Feature -Output ./registry-and-features.ps1

# Preview capture without writing
winspec pull -DryRun

# Interactive selection
winspec pull -Interactive

# Merge captured state into an existing output spec
winspec pull -Output ./my-config.ps1 -Apply
```

Important options:

| Option | Meaning |
| --- | --- |
| `-Output` | Destination file. Defaults to the resolved spec path. |
| `-Providers` | Provider names to capture. |
| `-Interactive` | Select captured items interactively. |
| `-Apply` | Merge with existing output instead of replacing blindly. |

Output format is extension-driven by the destination file path (`.json` writes JSON; other extensions write PowerShell hashtable syntax). `pull` uses the same provider universe as push/diff: built-in managers plus user managers under the resolved config path when one is supplied.

Expected pull failures are structured: no captured provider state returns `Reason = "NoStateCaptured"`, existing output without `-Apply` returns `Reason = "OutputExists"`, and merge conflicts return `Reason = "MergeFailed"`.

### `push`

Apply declarative sections and optionally selected triggers from a spec.

```powershell
# Apply declarative config
winspec push -Spec ./my-config.ps1

# Preview changes
winspec push -Spec ./my-config.ps1 -DryRun

# Create a restore point first
winspec push -Spec ./my-config.ps1 -Checkpoint

# Apply only selected providers
winspec push -Spec ./my-config.ps1 -Providers Registry,Feature

# Run selected triggers while pushing
winspec push -Spec ./my-config.ps1 -Triggers activation,debloat
```

Notes:

- Declarative managers are idempotent and test current state before applying.
- Triggers are non-idempotent and only execute when selected.
- Use `-DryRun`, sandbox mode, or `-Checkpoint` for safety.
- `push` reports top-level `Success = $false` when any provider or trigger returns `Status = "Error"`.
- If `-Checkpoint` is requested and checkpoint creation fails, push aborts before provider/trigger mutation and returns `Reason = "CheckpointFailed"` with the checkpoint failure details.

### `diff`

Compare desired state against live state or another spec.

```powershell
# Compare spec against live system
winspec diff -Spec ./my-config.ps1

# Compare two specs
winspec diff -Spec ./my-config.ps1 -Against ./base-config.ps1

# Compare only one provider
winspec diff -Spec ./my-config.ps1 -Providers Registry
```

Diff output groups entries into added, removed, changed, and equal items.

### `merge`

Merge two specification files.

```powershell
# Auto merge
winspec merge -Base ./base.ps1 -Incoming ./custom.ps1 -Output ./merged.ps1

# Union merge
winspec merge -Base ./base.ps1 -Incoming ./custom.ps1 -Strategy union

# Prefer base or incoming on conflicts
winspec merge -Base ./base.ps1 -Incoming ./custom.ps1 -Strategy ours
winspec merge -Base ./base.ps1 -Incoming ./custom.ps1 -Strategy theirs

# Interactive conflict resolution
winspec merge -Base ./base.ps1 -Incoming ./custom.ps1 -Interactive
```

Available strategies: `auto`, `union`, `ours`, `theirs`.

### `status`

Print current state captured by providers.

```powershell
winspec status
winspec status -Providers Registry,Feature
winspec status -Output ./current-state.ps1
```

The command prints JSON to the console. With `-Output`, it also saves captured state.

### `providers`

List discovered declarative managers and triggers.

```powershell
winspec providers
```

WinSpec lists built-in providers and providers found under the resolved config path.

### `validate`

Validate a specification without applying it.

```powershell
winspec validate -Spec ./my-config.ps1
```

Validation checks PowerShell loading and the expected top-level spec shape.

### `trigger`

Execute selected triggers directly.

```powershell
# Run one trigger
winspec trigger activation

# Run multiple triggers
winspec trigger activation,debloat

# Run all discovered triggers
winspec trigger *
```

Triggers can read values from the `Trigger` section of the spec or from command input. They are not idempotent; review trigger behavior before running.

### `sandbox`

Manage sandbox state.

```powershell
# Show sandbox status
winspec sandbox

# Enter mock sandbox
winspec sandbox -Enter -Mode Mock

# Enter dry-run sandbox
winspec sandbox -Enter -Mode DryRun

# List snapshots
winspec sandbox -List

# Exit sandbox
winspec sandbox -Exit
```

Sandbox mode lets providers simulate or report changes without modifying live state. `DryRun` reports pending changes and discards its active sandbox context at the end of `push`; `Mock` records simulated provider changes in the sandbox context and can write sandbox history on exit.

### `checkpoint` / `rollback`

`winspec push -Checkpoint` creates a Windows System Restore point before applying a spec. Checkpoint creation does not enable System Restore implicitly and requires the current process to be elevated. If System Restore is disabled, checkpoint creation returns `Success = $false`, `Reason = "SystemRestoreDisabled"`; if the process is not elevated, it returns `Reason = "RequiresAdministrator"`. A failed requested checkpoint aborts push before provider or trigger mutation.

Restore a Windows System Restore checkpoint.

```powershell
# Roll back to latest WinSpec checkpoint
winspec rollback -Last

# Roll back to a specific restore point sequence number
winspec rollback -SequenceNumber 5
```

Rollback is guarded by PowerShell `ShouldProcess`; `-WhatIf` does not call `Restore-Computer` and returns `Success = $false`, `Reason = "WhatIf"`. Other structured failure reasons include `SystemRestoreDisabled`, `NoRestorePoints`, `RollbackTargetRequired`, `RestorePointNotFound`, and `RestoreFailed`.

---

## Specification API

A spec is a PowerShell file that returns a hashtable:

```powershell
@{
    Name = "developer-workstation"
    Description = "My Windows developer setup"

    Import = @(
        "./base.ps1"
    )

    Registry = @{
        Clipboard = @{ EnableHistory = $true }
        Explorer  = @{ ShowHidden = $true; ShowFileExt = $true }
        Theme     = @{ AppTheme = "dark"; SystemTheme = "dark" }
        Desktop   = @{ MenuShowDelay = "0" }
    }

    Feature = @{
        "Microsoft-Windows-Subsystem-Linux" = "enabled"
        "VirtualMachinePlatform" = "enabled"
    }

    Service = @{
        wuauserv = @{ State = "stopped"; Startup = "disabled" }
    }

    Trigger = @("activation", "debloat", "office")

    TriggerConfig = @{
        activation = @{ Method = "KMS38" }
        debloat    = @{ Silent = $true }
        office     = @{ Path = "C:\Installers"; Cache = $true }
    }
}
```

### Top-level fields

| Field | Type | Purpose |
| --- | --- | --- |
| `Name` | string | Human-readable spec name. |
| `Description` | string | Description for maintainers/logging. |
| `Import` | array | Other specs to import before this spec. |
| `Providers` | array | Optional provider allow-list used by some operations. |
| `Registry` | hashtable | Registry category/property state. |
| `Feature` | hashtable | Windows Optional Feature state. |
| `Service` | hashtable | Windows service state and startup mode. |
| `Trigger` | string or array | Explicit non-idempotent action names to run. |
| `TriggerConfig` | hashtable | Parameter maps keyed by trigger name. |

Omit sections you do not want WinSpec to manage.

### Config path resolution

When no explicit path is supplied, WinSpec resolves specs in this order:

1. explicit `-Spec`/`-Output` argument,
2. `$env:WINSPEC_CONFIG`,
3. user config directory under `~/.config/winspec/`,
4. `.winspec.ps1` in the current directory.

### Import resolution

`Import` entries can be:

- absolute paths,
- paths relative to the current spec,
- paths relative to the config directory,
- built-in spec names where supported.

Later/importing values override or extend earlier imported values.

---

## Built-in provider sections

### `Registry`

Manages friendly registry categories.

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

Built-in categories:

| Category | Common fields | Scope | Restart hint |
| --- | --- | --- | --- |
| `Clipboard` | `EnableHistory` | `HKCU` | none |
| `Explorer` | `ShowHidden`, `ShowFileExt` | `HKCU` | Explorer restart |
| `Taskbar` | `Alignment`, `ShowTaskViewButton`, `SearchMode`, `ShowWidgets`, `ShowChat` | `HKCU` | Explorer restart |
| `Start` | `ShowRecommendations`, `ShowRecentlyAddedApps`, `ShowRecentlyOpenedItems` | `HKCU` | Explorer restart |
| `Theme` | `AppTheme`, `SystemTheme` | `HKCU` | none |
| `Desktop` | `MenuShowDelay`, `ForegroundLockTimeout` | `HKCU` | sign out |

Registry specs are validated against `winspec/registry-maps.psm1`: unknown categories/properties are rejected, mapped values must be one of their declared `AllowedValues`, and raw `DWord`/`String` properties must match their expected PowerShell value type.

See [reference.md](reference.md#registry) for concrete registry fields and translations.

### `Feature`

Manages Windows Optional Features.

```powershell
Feature = @{
    "Microsoft-Windows-Subsystem-Linux" = "enabled"
    "VirtualMachinePlatform" = "enabled"
    "Containers" = "disabled"
}
```

Values: `"enabled"`, `"disabled"`.

Safety behavior:

- Live feature export and mutation require Administrator privileges.
- Without elevation, feature export returns no feature state and logs an error; live feature apply returns `Status = "Error"`, `Reason = "RequiresAdministrator"`.
- The Feature provider no longer spawns generated elevated scripts for export/apply.

See [reference.md](reference.md#feature) for feature values and discovery commands.

### `Service`

Manages Windows services.

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

Fields:

| Field | Values |
| --- | --- |
| `State` | `"running"`, `"stopped"` |
| `Startup` | `"automatic"`, `"manual"`, `"disabled"` |

Safety behavior:

- Live service changes require Administrator privileges. Without elevation, the Service provider returns `Status = "Error"`, `Reason = "RequiresAdministrator"`, and does not call `Set-Service`, `Start-Service`, or `Stop-Service`.
- The built-in Service provider only manages a small allow-list of Windows services. Services outside that allow-list return `Reason = "ServiceNotManaged"` and are not mutated.
- Default service export and explicit `Export-ServiceState -ServiceNames ...` filter to that allow-list.

See [reference.md](reference.md#service) for the current allow-list and discovery commands.

### `Trigger` and `TriggerConfig`

`Trigger` selects explicit non-idempotent actions. `TriggerConfig` configures those actions with parameter maps keyed by trigger name.

```powershell
Trigger = @("activation", "debloat", "office")

TriggerConfig = @{
    activation = @{ Method = "KMS38" }
    debloat    = @{ Silent = $true }
    office     = @{ Path = "C:\Installers"; Cache = $true }
}
```

Built-in triggers:

| Trigger | Config parameters | Behavior |
| --- | --- | --- |
| `activation` | `Method` | Windows/Office activation helper. |
| `debloat` | `Silent` | Debloat helper. |
| `office` | `Path`, `Cache` | Office installer download/setup helper. |

Security note: remote/download triggers must stay opt-in and respect native PowerShell execution controls such as `-WhatIf`/dry-run. Runtime confirmation belongs to command execution, not to stored trigger config.

---

## Provider extension API

### Declarative manager module

Create a module under `winspec/managers/<name>.psm1` or a user config managers directory.

Required shape:

```powershell
function Get-ProviderInfo {
    return @{
        Name = "MyProvider"
        Type = "Declarative"
        Description = "Manages my subsystem"
    }
}

function Export-MyProviderState {
    return @{}
}

function Compare-MyProviderState {
    param($System, $Desired)
    return @()
}

function Test-MyProviderState {
    param([hashtable]$Desired)
    return $true
}

function Set-MyProviderState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable]$Desired)
    return @{ Status = "Applied" }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo",
    "Export-MyProviderState",
    "Compare-MyProviderState",
    "Test-MyProviderState",
    "Set-MyProviderState"
)
```

### Trigger module

Create a module under `winspec/triggers/<name>.psm1` or a user config triggers directory.

```powershell
function Get-ProviderInfo {
    return @{
        Name = "mytrigger"
        Type = "Trigger"
        Description = "Runs my explicit action"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch]$ExampleFlag,
        [string]$Mode = "default"
    )

    return @{
        Status = "Success"
        Message = "Completed"
    }
}

Export-ModuleMember -Function @("Get-ProviderInfo", "Invoke-Trigger")
```


---

## Custom behavior model

Use this model when you want to configure or extend WinSpec behavior.

### Declarative managers vs triggers

| Kind | Purpose | Spec location | Module location | Runtime behavior |
| --- | --- | --- | --- | --- |
| Declarative manager | Idempotent desired state | Provider-named sections such as `Registry`, `Feature`, `Service`, or your provider name | `managers/<name>.psm1` | Export, compare, test, then apply missing changes. |
| Trigger | Explicit non-idempotent action | `Trigger` + `TriggerConfig` | `triggers/<name>.psm1` | Runs only when selected. Parameters are splatted into typed `Invoke-Trigger` params. |

A declarative provider owns one top-level spec section:

```powershell
MyProvider = @{
    Setting = "value"
}
```

A trigger is split into selection and configuration:

```powershell
Trigger = @("mytrigger")

TriggerConfig = @{
    mytrigger = @{ Mode = "safe"; ExampleFlag = $true }
}
```

Do not put trigger parameter maps inside `Trigger`; `Trigger` only names actions to run.

### Provider discovery and config path

WinSpec discovers built-in providers from its installation and user providers from the resolved config path:

```text
<config>/managers/*.psm1
<config>/triggers/*.psm1
```

Each provider module must export `Get-ProviderInfo`. The `Name` returned by `Get-ProviderInfo` is the public spec section name for managers and the public selection name for triggers.

### Runtime controls are not stored config

Runtime controls such as `-WhatIf`, `-Confirm`, `-Verbose`, and `-ErrorAction` are command-line execution controls. They are forwarded through orchestration when supported, but they do not belong in stored spec fields.

Use:

```powershell
winspec push -Spec ./my-config.ps1 -WhatIf
winspec push -Spec ./my-config.ps1 -DryRun
```

not persistent config fields such as `ConfirmRemoteExecution`.

### State workflow mental model

For declarative managers, WinSpec follows this lifecycle:

```text
pull/status: discover managers -> Export-<Name>State -> spec-shaped state

diff:        discover managers -> Compare-<Name>State -> Added/Removed/Changed/Equal rows

push:        discover managers -> Test-<Name>State -> Set-<Name>State when needed
```

For triggers, WinSpec follows this lifecycle:

```text
selection:   CLI -Triggers overrides Spec.Trigger; otherwise Spec.Trigger selects actions

config:      TriggerConfig.<name> becomes typed Invoke-Trigger parameters

execution:   import exact trigger module -> invoke its exported Invoke-Trigger command
```

---

## Common workflows

### New machine setup

```powershell
# On a configured machine
winspec pull -Output ./my-setup.ps1

# On a new machine
winspec diff -Spec ./my-setup.ps1
winspec push -Spec ./my-setup.ps1 -Checkpoint
```

### Daily maintenance

```powershell
winspec diff -Spec ./my-config.ps1
winspec pull -Output ./current-state.ps1
winspec merge -Base ./my-config.ps1 -Incoming ./current-state.ps1 -Output ./updated.ps1
```

### Safe provider development smoke

```powershell
winspec providers
winspec validate -Spec ./my-config.ps1
winspec push -Spec ./my-config.ps1 -DryRun
```
