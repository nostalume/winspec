# Using WinSpec

This guide is for someone operating WinSpec from PowerShell. The normative
field, option, limit, and exit definitions are in the [API reference](api.md).

## Choose and compose a spec

Pass a path explicitly while developing a configuration:

```powershell
$winspec = '.\winspec\winspec.ps1'
$spec = '.\config\workstation.winspec.psd1'
& $winspec validate $spec
```

For routine use, place exactly one default spec at:

```text
%USERPROFILE%\.config\winspec\.winspec.psd1
%USERPROFILE%\.config\winspec\.winspec.json
```

PSD1 is recommended for a person editing configuration. JSON is useful for
generated configuration and captured output. Both are data-only. A `.ps1` is a
program and can only be run through a Script Action.

`Include` composes shared data first and the local document last:

```powershell
@{
    SchemaVersion = 1
    Include = @('./base.winspec.psd1', './team.winspec.json')
    Registry = @{ Explorer = @{ ShowHidden = $true } }
}
```

Include paths resolve from the including file. Maps merge recursively; a later
scalar or array replaces the earlier value. Cycles, missing files, invalid data,
and duplicate keys fail before effects. Relative Script paths and Workflow
capture paths resolve from the root spec that owns the operation.

## Observe and converge State

State providers are Registry, Service, Feature, plus any discovered external
State package. If `-Providers` is omitted, WinSpec selects the State sections
present in the spec (or all core providers for unconstrained `capture` and
`status`). A comma-separated value and repeated options are both accepted.
The complete built-in fields, allow-list, privileges, and restart behavior are in
[Built-in State providers](state-providers.md).

### Capture

```powershell
& $winspec capture .\observed.winspec.psd1 -Providers Registry,Service
& $winspec capture .\observed.winspec.json -Providers Feature -Force -Json
```

Capture reads the machine, then atomically publishes a data-only file. It does
not apply desired state or run Actions. Existing output is refused unless
`-Force` is explicit.

### Status and diff

```powershell
& $winspec status $spec -Providers Registry
& $winspec diff $spec -Providers Registry,Service
& $winspec diff $spec -Against .\baseline.winspec.psd1
```

`status` reports observed State. `diff` compares the desired spec with current
State, or with another spec supplied by `-Against`. Exit 1 means comparison
completed successfully and found differences; it is not an admission failure.

### Apply safely

```powershell
& $winspec apply $spec -Providers Registry -DryRun
& $winspec apply $spec -Providers Registry -Checkpoint
```

Apply always captures and compares first. If nothing differs, it returns
`Unchanged` and creates no checkpoint. `-DryRun` stops after the read-only plan.
`-Checkpoint` asks the checkpoint owner to create one restore point immediately
before the first change. WinSpec does not enable System Restore or elevate.

To roll back a checkpoint already recorded by WinSpec:

```powershell
& $winspec rollback -Last -DryRun
& $winspec rollback -SequenceNumber 123
```

Rollback is a Windows restore operation, not a reversal synthesized from an
Action receipt. Inspect the dry-run before executing it.

## Run local scripts

For a one-off local file, use the direct form. No spec or provider package is
needed:

```powershell
& $winspec run .\scripts\hello.ps1 -- first 'two words'
& $winspec run .\scripts\wizard.ps1 -Interactive -- -Mode guided
```

For repeatable automation, name the same file in a spec:

```powershell
@{
    SchemaVersion = 1
    Actions = @{
        hello = @{
            Use = 'Script'
            With = @{
                File = './scripts/hello.ps1'
                Args = @('configured')
            }
        }
        wizard = @{
            Use = 'Script'
            With = @{
                File = './scripts/wizard.ps1'
                Interactive = $true
            }
        }
    }
}
```

```powershell
& $winspec run hello -Spec $spec -- appended
& $winspec run hello -Spec $spec -DryRun -Json
& $winspec run wizard -Spec $spec
```

Configured `With.Args` come first; strings after `--` are appended without
shell-string evaluation. Use a single comma-separated parameter value when a
script must work through Windows PowerShell 5.1 `powershell.exe -File` and the
logical parameter is a list:

```powershell
param([string]$Roles = 'base,dev')
$selectedRoles = @($Roles -split ',' | ForEach-Object { $_.Trim() })
```

Noninteractive scripts run under the current PowerShell host with `-NoProfile
-NonInteractive`. Stdout and stderr are each retained up to 1 MiB, truncation is
reported, the immediate exit is exact, and timeout defaults to 300 seconds.
Interactive scripts must be local, inherit the terminal, and wait for their
immediate child. They cannot be combined with JSON or dry-run because WinSpec
cannot simultaneously own machine-readable stdout or preview an opaque prompt.

The complete package-install migration example uses one ordinary script:

- [`package-install-migration.winspec.psd1`](../examples/package-install-migration.winspec.psd1)
- [`install-packages.ps1`](../examples/scripts/install-packages.ps1)

Edit its package catalog before using it. `installPackages` is safe to include in
a Workflow; `installDailyPackages` is explicitly interactive and is intentionally
separate.

## Remote Script Actions

An explicitly selected HTTPS Script may use the source's current content:

```powershell
& $winspec run https://example.test/current.ps1 -DryRun
& $winspec run https://example.test/current.ps1
& $winspec run https://example.test/setup.ps1 -Sha256 '<64 hex>'
```

A named remote Script uses the same rule. `Sha256` is optional for HTTPS and
pins exact bytes when supplied:

```powershell
remoteSetup = @{
    Use = 'Script'
    With = @{
        Uri = 'https://example.test/setup.ps1'
        Sha256 = '<64 hex>'
        Args = @('-Quiet')
    }
}
```

Remote Script content is limited to 16 MiB and five redirects. It is downloaded,
streamed to a temporary file while hashing, run out of process, and deleted. An
unpinned redirect must remain HTTPS; HTTP requires `Sha256`. It cannot be
interactive. Dry-run is offline. Run results report requested/final URI, received
bytes and SHA-256, and whether the digest was verified. An unpinned digest records
what arrived but cannot prove it matched earlier reviewed content.

## Build a Workflow

A Workflow is a nonempty ordered list. Every step has exactly one of `Apply`,
`Run`, or `Capture`:

```powershell
Workflows = @{
    setup = @{
        Checkpoint = $true
        Steps = @(
            @{ Apply = @{ Providers = @('Registry', 'Service') } }
            @{ Run = 'installPackages' }
            @{ Capture = @{
                Output = './observed.winspec.psd1'
                Providers = @('Registry', 'Service')
                Force = $true
            } }
        )
    }
}
```

```powershell
& $winspec workflow setup -Spec $spec -DryRun -Json
& $winspec workflow setup -Spec $spec
```

Before any effect, WinSpec admits the entire workflow: names, provider
capabilities, step shapes, capture destinations, overwrite conflicts, and
checkpoint capability. Action providers with `preview` validate their own small
configuration during dry-run; providers without it are reported as opaque.

During execution, one requested checkpoint is created before the first effect,
steps run sequentially, and the first failure stops the workflow. Every remaining
step receives a `Skipped` receipt. Capture publication occurs only when its step
is reached, never feeds later steps, and cannot overwrite the root spec or an
included source even with `Force`.

There is no nested workflow, retry, parallel step, command-string step, implicit
rollback, or Action execution inside `apply`.

## Use bundled Actions

Bundled packages appear in `winspec providers` without installation. Discovery
does not execute them. Naming one in `Actions` is still inert until `run` or a
Workflow step selects that Action.

```powershell
activate = @{
    Use = 'MicrosoftActivation'
    With = @{ Args = @('/HWID') }
}
debloat = @{
    Use = 'WindowsDebloat'
    With = @{ Args = @('-RunDefaultsLite', '-Silent') }
}
cacheOffice = @{
    Use = 'OfficeDeployment'
    With = @{ Path = './downloads/office'; Cache = $true }
}
```

Preview before accepting network, licensing, debloat, installer, or nested
upstream effects:

```powershell
& $winspec run activate -Spec $spec -DryRun -Json
& $winspec run cacheOffice -Spec $spec -DryRun -Json
```

Read [Bundled Action providers](bundled-providers.md) for the exact fields,
endpoints, argument order, interaction, privileges, download bounds, trust
boundary, and receipts. That guide—not these recipes or the package-local
READMEs—is the normative bundled-provider contract.

## Read results and exits

Use `-Json` for automation. Stdout is exactly one document:

```json
{
  "schemaVersion": 1,
  "command": "workflow",
  "status": "Planned",
  "results": { "steps": [] },
  "diagnostics": []
}
```

Exit meanings:

| Exit | Interpretation |
| ---: | --- |
| 0 | Success, unchanged, or a valid plan |
| 1 | `diff` found differences |
| 2 | CLI, path, data, schema, selection, or protocol admission failed |
| 3 | A provider, Action, checkpoint, publication, or rollback failed |
| 4 | Cancellation or timeout |

Inside results, `Succeeded`, `Unchanged`, `Different`, `Planned`, `Skipped`, and
`Failed` retain operation-level meaning. A bundled provider can return a valid
structured `Failed` response while its protocol process exits 0; that is a
provider failure, not malformed JSON.

## Troubleshooting

| Symptom | Cause and safe response |
| --- | --- |
| `UnsupportedSpecFormat: '.ps1'` | Rename only after making the content data-only; move commands/functions into Script Actions. |
| `AmbiguousDefaultSpec` | Keep only one default PSD1 or JSON file, or pass a path explicitly. |
| `UnknownAction` / `UnknownProvider` | Check names with `winspec providers -Json` and validate the owning spec. |
| `UnknownConfigurationField` | Remove a retired or misspelled provider field; the provider-author or bundled-provider guide owns its schema. |
| `InsecureRemoteScript` | Change the source to HTTPS, or supply an independently obtained SHA-256 for HTTP. |
| `InteractiveOutputConflict` | Remove `-Json`/`-DryRun`, or make the script noninteractive. |
| `ProviderTimeout` / `ChildTimeout` | Increase `-TimeoutSeconds` only after deciding the operation is expected to take longer; inspect possible external side effects first. |
| `OutputExists` | Inspect the existing file, then repeat capture/merge with `-Force` only when replacement is intended. |
| `CheckpointUnavailable` | Enable and configure System Restore separately and start an already-elevated shell, or omit the checkpoint. |
| Exit 1 from `diff` | Differences were found successfully; inspect `results` rather than treating it as a parser failure. |

When diagnosing automation, repeat with `-Json`, retain stderr separately, and
inspect `diagnostics[].code` before matching free-form messages.
