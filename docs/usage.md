# Using WinSpec

This guide is for someone operating WinSpec from PowerShell. The normative
field, option, limit, and exit definitions are in the [API reference](api.md).

## Offline first run

Use Windows PowerShell 5.1 or PowerShell 7, from the source checkout root. No
elevation, network, default spec or machine-State changes are required. If using
Scoop, set `$winspec = 'winspec'` and use your own copies of the example files.
`<spec>` elsewhere in this guide is a placeholder, not a literal path.
When invoking the `.ps1` entry with `&`, quote the literal separator as `'--'`
so PowerShell does not consume it. With the installed native `winspec` shim,
the usual unquoted `--` is sufficient. Both forward the same separator to WinSpec.

The included [offline tour spec](../examples/offline-tour.winspec.psd1) has one
local greeting Script and a Run-only Workflow. The Script only prints text. The
direct provider example explicitly starts the bundled provider's offline preview;
it does not download or execute its upstream Script. Remote Script DryRun does
not make a request, even to the illustrative `example.test` address.

<!-- executable: offline-tour -->
```powershell
$winspec = '.\winspec\winspec.ps1'
$spec = '.\examples\offline-tour.winspec.psd1'
& $winspec help run
& $winspec validate $spec
& $winspec actions $spec
& $winspec run hello -Spec $spec -DryRun
& $winspec run .\examples\scripts\hello.ps1 -DryRun '--' configured appended
& $winspec run https://example.test/current.ps1 -DryRun
& $winspec run -Provider MicrosoftActivation -DryRun '--' /HWID
& $winspec workflow hello -Spec $spec -DryRun
& $winspec run hello -Spec $spec '--' appended
& $winspec workflow hello -Spec $spec
& $winspec rollback -Last -DryRun
```
<!-- end executable: offline-tour -->

Expected observations: the previews begin with `PLAN`; the real local Run prints
`configured|appended` under `Child stdout:` and finishes with `OK`; the Workflow
reports one successful step. All commands above exit 0. These examples prove
selection/receipt behavior, not readiness of activation or any other live task.

`winspec help` groups commands by task. `winspec help <command>` and
`winspec <command> -Help` are the same human page; use no operands or execution
options with `-Help` (`-Json` alone may accompany it). Help still works when a
default spec is missing/broken or a provider catalog cannot load. It includes
resolved paths to the packaged guides. Only a named Action/Workflow reads the
default spec for `run`/`workflow`; direct Script/provider forms do not.

## Choose and compose a spec

Pass a path explicitly while developing a configuration:

```powershell
$winspec = '.\winspec\winspec.ps1'
$spec = '.\config\workstation.winspec.psd1'
& $winspec validate $spec
```

Default validation is structural and does not start packaged provider code. Its
`results.validation.subjects` show provider-owned configurations as `NotRun`.
When you explicitly trust the configured external Action providers and want their semantic
preview checks, use:

```powershell
& $winspec validate $spec -PreviewActions -Json
```

This may start provider code and perform observations, but a conforming preview
does not modify target or durable state. External State configurations remain
unexecuted because protocol version 1 has no State validation operation.
Core Script configuration shape is structural; validate (even with PreviewActions)
does not check source-file existence or runtime dependencies. Use a local Script
run -DryRun for source existence; remote previews do not download.

For routine use, place exactly one default spec at:

```text
%USERPROFILE%\.config\winspec\.winspec.psd1
%USERPROFILE%\.config\winspec\.winspec.json
```

PSD1 is recommended for a person editing configuration. JSON is useful for
generated configuration and captured output. Both are data-only. A `.ps1` is a
program and can only be run through a Script Action.

If both default files exist, selection fails with `AmbiguousDefaultSpec`; pass a
path or keep exactly one. No parent directories are searched. `status` without a
spec instead observes core State; `capture` without an output writes the default
PSD1 path, not a JSON fallback. Relative CLI paths are based on the current
directory, while operational paths inside a spec follow the owning root spec.

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

`-Force` authorizes atomic replacement of an existing output. Without it, a file
that appears after the initial check is also protected from overwrite. Capture,
merge with `-Output`, and Workflow Capture share this publication boundary.
Concurrent changes, permissions or file locks can still prevent publication;
there is no delete-and-retry fallback. Keep the existing snapshot and resolve the
cause or choose a new path. Force does not bypass validation or grant privileges.

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
Action receipt. DryRun displays only the selector: it does not look up a restore
point or prove System Restore/privileges are available. A successful real command
means the restore request was accepted, not that recovery completed; inspect
Windows' recovery outcome separately. WinSpec does not elevate automatically.

## Run local scripts

For a one-off local file, use the direct form. No spec or provider package is
needed:

```powershell
& $winspec run .\scripts\hello.ps1 '--' first 'two words'
& $winspec run .\scripts\wizard.ps1 -Interactive '--' -Mode guided
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
& $winspec run hello -Spec $spec '--' appended
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

Keep WinSpec options before `--`: afterwards even `-Json` and `-Help` are child
arguments. Only `run` accepts this separator (including an empty one). A target
with a path separator or `.ps1` suffix is a direct Script; an absolute HTTP(S) URI
is remote; a plain name is always a configured Action, never an inferred provider.
Use `./-Json` for a file named like a WinSpec option.

`-Spec` belongs to named Actions/Workflows only. Direct provider selection cannot
also have a target, Spec, Interactive or Sha256. Use the named Action's `With` for
configuration; `-Providers` selects State, not an Action. CLI `-Interactive` is
local direct Script only and `-Sha256` is remote direct Script only; named Scripts
declare `With.Interactive` / `With.Sha256`, not CLI overrides.

Noninteractive scripts run under the current PowerShell host with `-NoProfile
-NonInteractive`. Stdout and stderr are each retained up to 1 MiB, truncation is
reported, the immediate exit is exact, and timeout defaults to 300 seconds.
Interactive scripts must be local, inherit the terminal, and wait for their
immediate child. They cannot be combined with JSON or dry-run because WinSpec
cannot simultaneously own machine-readable stdout or preview an opaque prompt.

`-TimeoutSeconds` accepts integers 1..3600 (default 300). It budgets each managed
operation, not an entire Workflow or every synchronous Windows API. On validate
it requires `-PreviewActions`. A timeout can leave external effects: inspect them
before retrying. It is not automatic cancellation of arbitrary descendants or an
automatic undo.

For a managed Script/provider call, startup, input transfer, download, execution,
output draining and response parsing consume the same monotonic budget; phases
do not each receive a new timeout. Output continues to drain after the capture
limit. Failure cleanup has separately bounded waits, so a timeout is not an exact
wall-clock return promise for every OS/filesystem call. If cleanup also fails,
the original failure remains first and additional diagnostics identify cleanup.

These are operation safeguards, not measured speed or whole-process memory
guarantees. See the [performance model](architecture.md#performance-model) for
the remaining acceptance limits; a green regression suite is not a latency SLA.

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

Before executing the steps, WinSpec admits the entire workflow: names, provider
capabilities, step shapes, capture destinations, overwrite conflicts, and
checkpoint capability. Preflight may start trusted Action-provider preview code,
including for a normal run; providers without preview are reported as opaque.
Script previews check source/selection but do not predict the Script's changes.

During execution, one requested checkpoint is created before the first effect,
steps run sequentially, and the first failure stops the workflow. Every remaining
step receives a `Skipped` receipt. Capture publication occurs only when its step
is reached, never feeds later steps, and cannot overwrite the root spec or an
included source even with `Force`.

There is no nested workflow, retry, parallel step, command-string step, implicit
rollback, or Action execution inside `apply`.

## Use bundled Actions

Bundled packages appear in `winspec providers` without installation. Discovery
does not execute them. The catalog and configured instances are different views:

```powershell
& $winspec providers -Json       # discovered implementations
& $winspec actions $spec -Json   # named Actions in this spec
```

For a one-off provider that accepts empty configuration, run an ephemeral Action
without editing a spec:

```powershell
& $winspec run -Provider MicrosoftActivation -DryRun '--' /HWID
& $winspec run -Provider WindowsDebloat -DryRun '--' -RunDefaultsLite -Silent
```

`-Provider` is singular and belongs only to direct `run`; plural `-Providers`
selects declarative State providers. Direct provider execution sends an empty
`With` map and any literal values after `--`. When options must live in `With`,
when the operation is reusable, or when a Workflow references it, define a named
Action:

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

The explicit Office `Path` matters: when it is omitted, OfficeDeployment uses the
owning spec directory rather than creating a dedicated cache directory.

Read [Bundled Action providers](bundled-providers.md) for the exact fields,
endpoints, argument order, interaction, privileges, download bounds, trust
boundary, and receipts. That guide—not these recipes or the package-local
READMEs—is the normative bundled-provider contract.

## Read results and exits

Human output is for decisions, not parsing:

| Header | What it establishes |
| --- | --- |
| `OK` | Success in the stated scope; not verified convergence or completed recovery |
| `PARTIAL` | Structure/checks passed with incomplete provider-validation coverage |
| `PLAN` | No actual apply/run/restore requested; trusted provider previews may have run |
| `DIFF` | Differences found; exit 1 is not command failure |
| `NO-WORK` | Empty selection, not observed compliance |
| `FAIL` | Read the failed identity, reason and recovery boundary before retrying |
| `WAIT` | Terminal-only stage/elapsed feedback, not a final receipt |

For a live diff, `Observed` is the machine and `Desired` is the spec; with
`-Against`, the columns are `Against` and `Spec`. `(absent)` is not `null`.
Validation `NotRun`/`Unavailable` does not mean validated; even `Valid` preview
does not prove actual execution will succeed. Apply reports provider receipts,
not a fresh post-apply verification. Workflow tables are numbered from 1 for
humans; JSON step `Index` remains zero-based. Earlier completed steps are not
undone when later ones fail.

Success/list/plan and labeled child stdout use stdout. Failures, diagnostics and
labeled child stderr use stderr. Exit 0 with child stderr is still success;
stderr content alone is not a failure signal. A failed Workflow may have earlier
child stdout in stdout and its final table in stderr, without a duplicate table.

Human display limits are 8 KiB of child text per stream, 100 result rows, 256
characters per cell, and 100 diagnostics per command with 4 KiB per message.
Labels/indentation are outside those text budgets. Explicit omission notices
distinguish display omission from runtime capture loss; `-Json` exposes retained
data, but cannot recover discarded capture bytes. Retained-text UTF-8 omission
counts are not raw total process-output measurements. Control sequences are
escaped. Default metadata omits arguments/With and URI credentials/query/fragment;
arbitrary Script/provider payloads may still contain secrets. Review before sharing.

`WAIT` is disabled for JSON, redirected streams and interactive children. Managed
captured processes report elapsed time after one second and at least two seconds
apart thereafter. Synchronous HTTP/core calls only report entry into their stage;
silence inside a blocking API is not proof of a hang.

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
| 4 | Cancellation or timeout at the command boundary |

Inside results, `Succeeded`, `Unchanged`, `Different`, `Planned`, `Skipped`, and
`Failed` retain operation-level meaning. A bundled provider can return a valid
structured `Failed` response while its protocol process exits 0; that is a
provider failure, not malformed JSON.

A Workflow's completed `Failed` receipt exits 3, including a timeout captured as
a failed step; timeout escaping at the command boundary exits 4. Child exits are
reported separately, not returned as WinSpec exit codes. Exception classification
is bounded: an unclassified command-boundary error can exit 2, including the known
capture overwrite publication defect. Do not infer that exit 2 proves no earlier
external effect. JSON fields and statuses remain schema version 1.

`merge` without `-Output` writes no file. Human mode summarizes the merge; use
`-Json` to inspect its merged document. Default strategy `auto` reports conflicts;
`ours`/`theirs` choose a side; `union` combines arrays and otherwise chooses the
incoming value. `-Force` does not resolve conflicts. Review both inputs before
choosing a resolution strategy.

## Troubleshooting

| Symptom | Cause and safe response |
| --- | --- |
| `UnsupportedSpecFormat: '.ps1'` | Rename only after making the content data-only; move commands/functions into Script Actions. |
| `AmbiguousDefaultSpec` | Keep only one default PSD1 or JSON file, or pass a path explicitly. |
| `UnknownAction` | Use `winspec actions [spec] -Json` to inspect configured names, then validate the owning spec. |
| `UnknownProvider` | Use `winspec providers -Json` (plus the same `-ProviderPath`, if any) to inspect discovered implementations. |
| `ProviderValidationUnavailable` from an older WinSpec | Version 0.6.0 emitted one warning for every packaged Action. Current `validate` reports coverage in `results.validation`; use `-PreviewActions` when explicit provider execution is wanted. |
| `UnknownConfigurationField` | Remove a retired or misspelled provider field; the provider-author or bundled-provider guide owns its schema. |
| `InsecureRemoteScript` | Change the source to HTTPS, or supply an independently obtained SHA-256 for HTTP. |
| `InteractiveOutputConflict` | Remove `-Json`/`-DryRun`, or make the script noninteractive. |
| `ProviderTimeout` / `ChildTimeout` | Increase `-TimeoutSeconds` only after deciding the operation is expected to take longer; inspect possible external side effects first. |
| `OutputExists` | Inspect the existing file. For capture, prefer a new path while the known overwrite defect remains; for merge use `-Force` only when replacement is intended. |
| Output publication fails | Capture, merge output and Workflow Capture use the same boundary. Without Force, an existing or concurrently created file is not replaced. With Force, check locks/permissions and retain the old snapshot; do not delete it merely to retry. |
| `RetiredCommand` / `RetiredOption` | `sandbox`, its five options, and ineffective `-Verbose`/`-Debug` are removed. Use command-specific Help/preview; existing sandbox files are not changed. |
| `DuplicateOption` / `UnexpectedOperand` | Remove duplicate scalar/switch or extra operand. Only `-Providers`/`-ProviderPath` repeat; list items are trimmed/deduplicated and empty items fail. |
| `CheckpointUnavailable` | Enable and configure System Restore separately and start an already-elevated shell, or omit the checkpoint. |
| Exit 1 from `diff` | Differences were found successfully; inspect `results` rather than treating it as a parser failure. |

When diagnosing automation, repeat with `-Json`, retain stderr separately, and
inspect `diagnostics[].code` before matching free-form messages.

Run `winspec help` for the command inventory. `winspec help <command>` and
`winspec <command> -Help` show that command's selection forms, effects, default,
and a minimal example without loading configuration or discovering providers.
