# WinSpec API

This document is the normative public contract for specification schema version
1, command result schema version 1, and the CLI. The external manifest and
process protocol version 1 are specified in
[Building WinSpec providers](provider-development.md).
Files and functions under `winspec/` are implementation details unless a public
document names their command, data, package, or wire behavior.

## Command grammar

```text
winspec capture [output] [-Providers names] [-ProviderPath roots] [-Force] [-Json]
winspec status [spec] [-Providers names] [-ProviderPath roots] [-Json]
winspec validate [spec] [-ProviderPath roots] [-Json]
winspec diff [spec] [-Against spec] [-Providers names] [-ProviderPath roots] [-Json]
winspec apply [spec] [-Providers names] [-ProviderPath roots] [-DryRun] [-Checkpoint] [-Json]
winspec run <name> [-Spec spec] [options] [-- arguments]
winspec run <path|http(s)-uri> [-Interactive] [-Sha256 hex] [options] [-- arguments]
winspec workflow <name> [-Spec spec] [-DryRun] [-Json]
winspec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]
winspec providers [-ProviderPath roots] [-Json]
winspec sandbox [-Enter|-Exit|-List] [-Mode Mock|DryRun] [-Snapshot name]
winspec rollback (-Last|-SequenceNumber n) [-DryRun]
winspec help [command]
```

Commands and options are case-insensitive. `-Providers` and `-ProviderPath`
accept comma-separated values and may be repeated. Empty provider names are
invalid. `--` ends WinSpec parsing and is valid only for `run`; every following
token is forwarded as one literal argument. Unknown commands, options,
combinations, and extra operands fail before effects.

`-TimeoutSeconds` defaults to 300 and accepts 1–3600. `-Json` reserves stdout for
one result document. It is incompatible with interactive execution. `-Verbose`
and `-Debug` are accepted common switches; their diagnostic streams are not part
of the JSON document.

| Command | Operand and selection | Options and defaults |
| --- | --- | --- |
| `capture` | optional output; default user `.winspec.psd1` | `-Providers`; `-ProviderPath`; without names, observes core State; existing output needs `-Force` |
| `status` | optional spec | `-Providers`; `-ProviderPath`; defaults to spec sections, or core State without a spec |
| `validate` | optional spec | `-ProviderPath`; validates the common external envelope |
| `diff` | optional desired spec | `-Against`; `-Providers`; `-ProviderPath`; otherwise compares with the machine |
| `apply` | optional desired spec | `-Providers`; `-ProviderPath`; `-DryRun`; `-Checkpoint` |
| `run` | exactly one Action name, local path, or HTTP(S) URI | name uses `-Spec`; local may use `-Interactive`; remote may use `-Sha256`; accepts `--` |
| `workflow` | exactly one Workflow name | optional `-Spec`; `-DryRun` |
| `merge` | base and incoming specs | `-Output` defaults to stdout; strategy defaults `auto`; existing output needs `-Force` |
| `providers` | no operand | `-ProviderPath` adds discovery roots |
| `sandbox` | no operand | exactly one of `-Enter`, `-Exit`, `-List`; mode defaults `Mock`; snapshot defaults `default` |
| `rollback` | no operand | exactly one of `-Last` or positive `-SequenceNumber`; optional `-DryRun` |

`-Spec` is valid only for a named Action or Workflow. `-Sha256` is valid only for
a direct remote Script; a named remote Script stores it in `With`. `-Interactive`
is valid only for a direct local Script; a named local Script stores it in
`With`. `-Providers` applies only to State commands. `-ProviderPath` applies to
`capture`, `status`, `validate`, `diff`, `apply`, `run`, `workflow`, and
`providers`. `-Checkpoint` applies only to `apply`; a Workflow stores its
checkpoint request in the spec.

An omitted spec resolves to
`%USERPROFILE%\.config\winspec\.winspec.psd1`, then `.winspec.json`. If both
exist, WinSpec returns `AmbiguousDefaultSpec`. It does not walk parent
directories. An omitted capture output is the PSD1 default path.

## Specification data model

PSD1 and JSON admit maps, arrays, strings, Booleans, signed 64-bit integers,
finite numbers, and null. A source file is limited to 4 MiB and nesting depth 64.
Map keys are strings and duplicates are rejected case-insensitively. The root must
be a map. A `.ps1` file is never configuration.

PSD1 is loaded only through `Import-PowerShellDataFile`. JSON receives a duplicate
key scan before conversion. Both normalize to the same data model.

### Composition and paths

`Include` is a string or array of strings. Each path resolves from its including
file. Included documents compose first-to-last; the local document composes last.
Maps merge recursively. Arrays and scalar values replace. Cycles and invalid
included files fail the complete load.

The root spec passed to a named `run` or `workflow` owns operational relative
paths. Local Script `File`, Office `Path`, and Workflow Capture `Output` resolve
from that root spec's directory. A Capture step cannot overwrite the root or any
loaded include, even with `Force`.

### Root fields

After composition, schema version 1 accepts:

- required integer `SchemaVersion = 1`;
- optional string `Name` and `Description`;
- `Registry`, `Service`, and `Feature` core State maps;
- one same-named map for each discovered external State provider;
- optional `Actions` map;
- optional `Workflows` map.

Unknown root fields fail. Root `Providers`, `Trigger`, `TriggerConfig`, and
`Import` have no compatibility meaning. Provider selection belongs to the CLI or
a Workflow step.

The complete normative Registry, Service, and Feature configuration tables,
permissions, selection defaults, and restart behavior are in
[Built-in State providers](state-providers.md). Unknown core State fields or
deterministically invalid values fail validation. External State maps are passed
to their selected package.

## Action schema

Every named Action uses one common envelope:

```powershell
Actions = @{
    actionName = @{
        Use = 'ActionProviderName'
        With = @{ }
    }
}
```

`Use` is a required nonempty string selecting one discovered Action provider.
`With` is an optional map and defaults empty. No flat provider fields are valid.
For an external provider, WinSpec forwards `With` unchanged as
`input.configuration`; the provider package owns its field meanings.

### Core Script Action

Script `With` accepts only:

- exactly one of `File` or `Uri`, each a nonempty string;
- optional `Args`, an array of strings, default empty;
- optional `Sha256`, exactly 64 hexadecimal characters and valid only with
  `Uri`;
- optional Boolean `Interactive`, default false; true is valid only with `File`.

Configured arguments precede CLI `--` arguments. No shell command string is
constructed or evaluated. `File` resolves from the owning spec. Direct paths
resolve from the caller's current directory.

An unpinned remote Script requires HTTPS. Supplying `Sha256` verifies exact bytes
and also permits HTTP. Every unpinned redirect must remain HTTPS. Remote content
is streamed to a temporary file while hashing, limited to 16 MiB and five
redirects, run only out of process, and deleted afterward. Remote Scripts cannot
be interactive.

Dry-run is offline and reports `Integrity` as `Unpinned` or `Pinned`. Run also
reports requested and final URI, received byte count and SHA-256, and
`DigestVerified`. An unpinned received digest is audit identity after acquisition,
not proof that the content matched an earlier review.

Dry-run never starts Script code. A local noninteractive dry-run requires the
file to exist and returns an opaque plan. Noninteractive run uses the current
PowerShell host with `-NoProfile -NonInteractive`, captures stdout and stderr up
to 1 MiB each, reports truncation, waits for the immediate child, and returns its
exit. Interactive run inherits the terminal and captures neither stream; it
cannot use JSON or dry-run. Detached descendants are outside the receipt.

See [Using WinSpec](usage.md#run-local-scripts) for examples.

## Workflow schema and semantics

A Workflow contains a nonempty ordered `Steps` array and optional Boolean
`Checkpoint` (default false). Each step has exactly one tag:

```powershell
Workflows = @{
    setup = @{
        Checkpoint = $false
        Steps = @(
            @{ Apply = @{ Providers = @('Registry', 'Service') } }
            @{ Run = 'actionName' }
            @{ Capture = @{
                Output = './observed.winspec.psd1'
                Providers = @('Registry')
                Force = $false
            } }
        )
    }
}
```

`Apply.Providers` is optional; `Run` is one Action name; Capture requires an
`Output` string and accepts optional provider names and Boolean `Force`. Unknown
fields and empty provider names fail.

Before any effect, WinSpec admits every step, name, provider kind/capability,
output conflict, and checkpoint capability. Provider-specific semantic
validation occurs through `preview` where available or immediately before that
provider's run. One requested checkpoint is created before the first effect.
Steps then run sequentially. The first failure stops execution and all remaining
steps receive `Skipped` receipts.

Dry-run creates no checkpoint or output. State steps capture and compare only.
Action providers use `preview` where declared; otherwise the plan is opaque.
Capture output never feeds a later step. Workflow nesting, retries, parallel
steps, arbitrary commands, and implicit rollback are invalid.

## State operations

`capture` observes selected State and atomically publishes a data-only spec.
`status` observes without publication. `diff` compares desired State with the
machine or `-Against`; it returns exit 1 when different. `apply` captures and
compares first, then converges only selected providers. If already equal it
returns `Unchanged` without a checkpoint. External State providers are rechecked
immediately before their apply operation.

Explicit `-Providers` selects exactly those State providers. When omitted from
a spec-scoped command or Workflow State step, selection is the State sections
present in that spec. Unconstrained `capture` and `status` select only core
Registry, Service, and Feature; discovering an external package never starts it.
See [Built-in State providers](state-providers.md) for core configuration and
per-resource failure behavior.

`apply` never executes Actions. `run` executes exactly one Action. `workflow` is
the only multi-step surface. No command elevates, enables System Restore, retries
an uncertain effect, or automatically rolls back.

## Result document and exits

With `-Json`, stdout is exactly one UTF-8 JSON object:

```json
{
  "schemaVersion": 1,
  "command": "run",
  "status": "Succeeded",
  "results": {},
  "diagnostics": []
}
```

`diagnostics` items contain at least `severity`, `code`, and `message` at the
command boundary. Provider diagnostics contain `code` and `message` and are
nested in that provider result. Status vocabulary is `Succeeded`, `Unchanged`,
`Different`, `Planned`, `Skipped`, and `Failed`.

| Exit | Meaning |
| ---: | --- |
| 0 | Successful operation, unchanged State, or successful plan |
| 1 | Comparison succeeded and found differences |
| 2 | Command, option, path, data, schema, selection, manifest, or wire admission failed |
| 3 | Provider, Action, checkpoint, publication, or rollback failed |
| 4 | Cancellation or timeout at the command boundary |

## External provider packages

External providers are trusted programs discovered from static manifests and run
through a bounded, versioned process protocol. The complete contract—including
package layout, discovery, manifest fields, operation-specific inputs and legal
statuses, response validation, interaction, cleanup, and complete Action and
State examples—is
[Building WinSpec providers](provider-development.md).

Public `validate` checks the common Action/State envelope without starting
provider code. It reports `ProviderValidationUnavailable` where provider-owned
semantic validation cannot run through Action preview. Process isolation contains
WinSpec process and wire failures; it is not a security sandbox.

## Bundled Action providers

`MicrosoftActivation`, `WindowsDebloat`, and `OfficeDeployment` are packaged
protocol-version-1 Action providers shipped and automatically discovered with
WinSpec. They remain inert until selected. Their exact `With` fields, endpoints,
preview/run behavior, interaction, privileges, acquisition limits, nested-content
boundary, and receipts are owned by
[Bundled Action providers](bundled-providers.md).
