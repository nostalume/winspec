# Built-in State providers

This is the normative user contract for WinSpec's core `Registry`, `Service`,
and `Feature` State providers. It applies to specification schema version 1 on
Windows PowerShell 5.1 and PowerShell 7.

These providers are trusted WinSpec code and run in process. They appear in
`winspec providers` with catalog protocol version `0`, meaning that no provider
wire protocol is involved. The JSON protocol is only for
[packaged providers](provider-development.md).

## Selection and effect model

State configuration is sparse: WinSpec observes and compares only the selected
providers, and each provider converges only resources named in the desired spec.
Omitting a category, service, feature, or property never requests its removal.

Selection follows one rule:

| Operation | `-Providers` supplied | `-Providers` omitted |
| --- | --- | --- |
| `capture` | Exactly the named State providers | Core Registry, Service, and Feature |
| `status` without a spec | Exactly the named State providers | Core Registry, Service, and Feature |
| `status`, `diff`, or `apply` with a spec | Exactly the named State providers | Only same-named State sections present in the spec |
| Workflow `Apply` or `Capture` | Exactly `Providers` when present | Only same-named State sections present in the Workflow's spec |

Discovery alone never selects or starts a provider. A discovered external State
package is selected implicitly only when its same-named root section is present
in the active spec.

`apply` captures and compares before mutation. It returns `Unchanged` without
changing the machine when the selected desired State is already satisfied.
`-DryRun` stops after observation and comparison. WinSpec never elevates,
retries an uncertain mutation, or rolls back successful siblings after a partial
failure.

## Registry

Registry configuration is a map of maintained categories and properties:

```powershell
Registry = @{
    Explorer = @{
        ShowHidden = $true
        ShowFileExt = $true
    }
    Taskbar = @{
        Alignment = 'left'
        SearchMode = 'icon'
    }
}
```

All current categories are per-user HKCU settings and do not require
Administrator privileges. The table is derived from the maintained Registry
metadata; schema validation rejects unknown categories, properties, wrong types,
and values outside these domains before observation.

| Category | Property | Accepted value | Restart hint |
| --- | --- | --- | --- |
| Clipboard | `EnableHistory` | Boolean | None |
| Explorer | `ShowHidden` | Boolean | Restart Explorer |
| Explorer | `ShowFileExt` | Boolean | Restart Explorer |
| Taskbar | `Alignment` | `left`, `center` | Restart Explorer |
| Taskbar | `ShowTaskViewButton` | Boolean | Restart Explorer |
| Taskbar | `SearchMode` | `hidden`, `icon`, `box` | Restart Explorer |
| Taskbar | `ShowWidgets` | Boolean | Restart Explorer |
| Taskbar | `ShowChat` | Boolean | Restart Explorer |
| Start | `ShowRecommendations` | Boolean | Restart Explorer |
| Start | `ShowRecentlyAddedApps` | Boolean | Restart Explorer |
| Start | `ShowRecentlyOpenedItems` | Boolean | Restart Explorer |
| Theme | `AppTheme` | `light`, `dark` | None |
| Theme | `SystemTheme` | `light`, `dark` | None |
| Desktop | `MenuShowDelay` | String | Sign out |
| Desktop | `ForegroundLockTimeout` | Integer 0–4294967295 | Sign out |

String enumeration values are case-insensitive. Boolean values must be actual
PSD1/JSON Booleans, not the strings `"true"` or `"false"`.
`MenuShowDelay` remains a Windows string value; WinSpec validates its type but
does not invent a range beyond the platform's contract.

`capture` publishes only maintained values that currently exist. A missing
value is not materialized from the metadata default. Applying one property does
not rewrite sibling properties.

Explorer and sign-out hints describe when Windows may visibly consume a changed
value. WinSpec records the mutation but does not restart Explorer, sign the user
out, or reboot.

## Service

Each service entry may specify runtime `State`, startup policy `Startup`, or
both:

```powershell
Service = @{
    WSearch = @{
        State = 'running'
        Startup = 'automatic'
    }
    Spooler = @{
        State = 'stopped'
        Startup = 'disabled'
    }
}
```

Accepted values are case-insensitive:

- `State`: `running` or `stopped`;
- `Startup`: `automatic`, `manual`, or `disabled`.

Only this safety allow-list is admitted:

```text
WinDefend  WdNisSvc  SecurityHealthService
DiagTrack  dmwappushservice  WSearch
wuauserv  UsoSvc  BITS
Dnscache  Dhcp  NlaSvc
RemoteRegistry  TermService  WinRM
SysMain  WerSvc  Spooler
```

The match is case-insensitive. A name outside the list fails schema validation;
WinSpec does not wait until mutation to reject it. The allow-list limits accidental
scope—it does not imply that every listed service exists or is safe to disable on
every machine.

Observation returns allow-listed services that exist. Applying Service State
requires an already-elevated process. A selected service missing on the machine,
an insufficient privilege, or a failed startup/state change produces a failed
provider receipt. Successfully changed sibling services remain changed and are
reported in the same output.

Changing or stopping a service can disrupt networking, updates, security,
printing, remote access, or dependent applications. WinSpec does not calculate
service dependencies, restart applications, elevate, or synthesize recovery.

## Feature

Feature configuration maps Windows optional-feature names to one
case-insensitive value:

```powershell
Feature = @{
    Microsoft-Windows-Subsystem-Linux = 'enabled'
    TelnetClient = 'disabled'
}
```

The accepted values are `enabled` and `disabled`. Feature names must be
nonempty, but they are machine-dependent and therefore are not checked for
existence during data-only validation.

Capture enumerates nonremoved online optional features. Windows requires the
process to be already elevated for Feature observation and mutation. Without
that privilege, unconstrained capture/status omits Feature data; a requested
Feature apply fails with `RequiresAdministrator`. A desired feature missing
from the machine also fails its apply receipt.

Enable/disable uses Windows' online optional-feature commands with restart
suppressed. A successful change includes a `RestartMayBeRequired` diagnostic;
WinSpec never reboots automatically.

## Capture, compare, and apply results

`capture` writes a normal schema-version-1 PSD1 or JSON document. `status`
returns the selected observed maps under `results.state`. `diff` reports only
desired resources that are missing or different; omitted machine resources are
not removals.

Each selected apply provider returns:

```text
Name         provider catalog name
Status       Succeeded | Unchanged | Planned | Failed
Output       provider-specific per-resource receipt
Diagnostics array of structured code/message/resource items
```

Any failed resource makes its provider and the command `Failed` and produces
exit 3. Successful sibling receipts remain in `Output`; there is no implicit
rollback. Dry-run returns `Planned` without invoking mutation.

Use `-Json` for automation and inspect the status before relying on individual
resource output:

```powershell
$result = winspec apply .\machine.winspec.psd1 -DryRun -Json |
    ConvertFrom-Json
$result.status
$result.results.providers
```

See the [API reference](api.md) for the command envelope and exit codes, and
[Using WinSpec](usage.md#observe-and-converge-state) for the shortest operating
workflow.
