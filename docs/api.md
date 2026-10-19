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
winspec validate [spec] [-ProviderPath roots] [-PreviewActions] [-Json]
winspec diff [spec] [-Against spec] [-Providers names] [-ProviderPath roots] [-Json]
winspec apply [spec] [-Providers names] [-ProviderPath roots] [-DryRun] [-Checkpoint] [-Json]
winspec run <name> [-Spec spec] [options] [-- arguments]
winspec run -Provider name [-ProviderPath roots] [-DryRun] [-Json] [-- arguments]
winspec run <path|http(s)-uri> [-Interactive] [-Sha256 hex] [options] [-- arguments]
winspec workflow <name> [-Spec spec] [-DryRun] [-Json]
winspec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]
winspec providers [-ProviderPath roots] [-Json]
winspec actions [spec] [-ProviderPath roots] [-Json]
winspec rollback (-Last|-SequenceNumber n) [-DryRun]
winspec help [command]
```

Commands and options are case-insensitive. `-Providers` and `-ProviderPath`
accept comma-separated values and may be repeated. Items are trimmed and
deduplicated case-insensitively; empty items are invalid. All other options,
including switches, may occur only once. Explicit empty path/name values fail;
they do not select a default. A missing value before another known option is
reported as `MissingOptionValue`. Use a path prefix such as `./-Json` for a
file whose name is also an option.
`--` ends WinSpec parsing and is valid only for `run`; every following
token is forwarded as one literal argument and cannot enable WinSpec output or
help modes. Even an empty `--` is rejected on commands other than `run`.
Unknown commands, options,
combinations, and extra operands fail before effects.

`-TimeoutSeconds` defaults to 300 and accepts integers 1–3600. It is valid on
`capture`, `status`, `diff`, `apply`, `run`, and `workflow`, and on `validate`
only with `-PreviewActions`. It bounds supported process/remote operations,
not an entire Workflow or every synchronous core Windows API.
`-Json` reserves stdout for one result document, including Help, and is
incompatible with interactive execution. Controlled diagnostics are included in
the JSON document; stderr is empty on these CLI success and failure paths.

`sandbox` and its `-Enter`, `-Exit`, `-List`, `-Mode`, and `-Snapshot` options
are retired. The ineffective `-Verbose` and `-Debug` options are also retired.
They fail with exit 2 rather than executing or forwarding to another command.
Existing sandbox files are not read as execution policy, modified, or deleted
by the CLI. Use explicit command preview contracts instead of a global
simulation mode.

| Command | Operand and selection | Options and defaults |
| --- | --- | --- |
| `capture` | optional output; default user `.winspec.psd1` | `-Providers`; `-ProviderPath`; without names, observes core State; existing output needs `-Force` |
| `status` | optional spec | `-Providers`; `-ProviderPath`; defaults to spec sections, or core State without a spec |
| `validate` | optional spec | `-ProviderPath`; structural by default; `-PreviewActions` explicitly starts preview-capable configured Action providers |
| `diff` | optional desired spec | `-Against`; `-Providers`; `-ProviderPath`; otherwise compares with the machine |
| `apply` | optional desired spec | `-Providers`; `-ProviderPath`; `-DryRun`; `-Checkpoint` |
| `run` | exactly one Action name, `-Provider` name, local path, or HTTP(S) URI | configured name uses `-Spec`; direct provider uses empty `With`; local may use `-Interactive`; remote may use `-Sha256`; accepts `--` |
| `workflow` | exactly one Workflow name | optional `-Spec`; `-DryRun` |
| `merge` | base and incoming specs | no `-Output` means no file is written (human summary or JSON result); strategy defaults `auto`; existing output needs `-Force` |
| `providers` | no operand | `-ProviderPath` adds discovery roots |
| `actions` | optional spec | `-ProviderPath`; lists configured Action bindings without returning `With` or executing providers |
| `rollback` | no operand | exactly one of `-Last` or positive `-SequenceNumber`; optional `-DryRun` |

`-Spec` is valid only for a named Action or Workflow. Singular `-Provider` is
valid only for direct provider execution through `run`; plural `-Providers`
selects State providers on State commands. `-Sha256` is valid only for
a direct remote Script; a named remote Script stores it in `With`. `-Interactive`
is valid only for a direct local Script; a named local Script stores it in
`With`. `-Providers` applies only to State commands. `-ProviderPath` applies to
`capture`, `status`, `validate`, `diff`, `apply`, `run`, `workflow`, `providers`,
and `actions`. `-Checkpoint` applies only to `apply`; a Workflow stores its
checkpoint request in the spec. Option applicability is checked by presence,
even when its explicit value equals a default (for example `-Strategy auto`).

`run -Provider` cannot be combined with a positional target, `-Spec`,
`-Interactive`, or `-Sha256`. It accepts only an Action provider. A provider name
is never inferred from the positional Action namespace, so a configured Action
may safely have the same name as a provider.

An omitted spec resolves to
`%USERPROFILE%\.config\winspec\.winspec.psd1`, then `.winspec.json`. If both
exist, WinSpec returns `AmbiguousDefaultSpec`. It does not walk parent
directories. An omitted capture output is the PSD1 default path.

## Option reference

`[options]` in command Help means only that command's listed options. Angle
brackets name required values; square brackets mark optional forms. All options
are checked by presence, not truthiness or whether a value differs from a default.
The `validate` timeout additionally requires `-PreviewActions`.

<!-- BEGIN GENERATED CLI OPTIONS: tools/update-help-reference.ps1 -->
The following inventory is generated from the CLI option/command records.
Only listed commands accept each option; `-Help` is the separate help-only form.

| Option | Value / repetition | Commands | Meaning and default |
| --- | --- | --- | --- |
| `-Json` | Switch; once | capture, status, validate, diff, apply, run, workflow, merge, providers, actions, rollback, help | Return one result document on stdout; no progress/log lines are added. Default: human-readable output. Incompatible with Interactive. |
| `-Help` | Switch; once | all commands (help-only) | Show command help without reading a specification or starting a provider. Use without operands or execution options; Json is allowed. |
| `-DryRun` | Switch; once | apply, run, workflow, rollback | Do not request the actual apply/run/restore operation. Provider previews may execute trusted code; Script previews are opaque. Default: actual operation. |
| `-PreviewActions` | Switch; once | validate | Explicitly run declared external Action-provider previews and report coverage. Default: structural validation only. |
| `-Spec <path>` | String; once | run, workflow | Select the specification for a named Action or Workflow. Default: user specification; not valid for a direct provider or Script. |
| `-Provider <name>` | String; once | run | Select one Action implementation with empty With configuration. Cannot be combined with a target, Spec, Interactive or Sha256. |
| `-Providers <names>` | List; repeatable | capture, status, diff, apply | Select State providers by name; comma-separated/repeatable. Empty items fail and duplicates are removed. This does not select Actions. |
| `-ProviderPath <roots>` | List; repeatable | capture, status, validate, diff, apply, run, workflow, providers, actions | Add static package discovery roots; comma-separated/repeatable. Relative roots resolve from the current directory. Does not execute or install a provider. |
| `-Against <path>` | String; once | diff | Compare the desired spec with this observed/reference spec instead of the current machine. Default: live comparison. |
| `-Output <path>` | String; once | merge | Publish the merged data-only specification at this path. Default: return a merge result without writing a file. |
| `-Strategy <name>` | String; once | merge | auto, union, ours or theirs; default auto. auto reports scalar/array conflicts, ours/theirs choose a side, union combines arrays and otherwise chooses incoming values. |
| `-Force` | Switch; once | capture, merge | Allow replacing the selected capture/merge output file. Does not bypass validation, trust, privileges or unresolved merge conflicts. Default: refuse existing output. |
| `-Checkpoint` | Switch; once | apply | Request one Windows restore point before a changing apply. Default: no checkpoint. Requires already-available System Restore and privileges. |
| `-Interactive` | Switch; once | run | Direct local Script only; inherit its terminal. Cannot use Json or DryRun. Named Scripts declare With.Interactive instead. Default: captured noninteractive execution. |
| `-Sha256 <64 hex chars>` | String; once | run | Direct remote Script only; exactly 64 hexadecimal characters. Verify received bytes against this independently obtained pin. Named Scripts declare With.Sha256. Required for HTTP; optional for HTTPS. |
| `-TimeoutSeconds <int>` | Integer; once | capture, status, validate, diff, apply, run, workflow | 1..3600, default 300; per managed operation, not a whole Workflow or every synchronous Windows API. |
| `-Last` | Switch; once | rollback | Choose the latest available Windows restore point during actual rollback. Exactly one of Last or SequenceNumber is required; no default target. |
| `-SequenceNumber <positive-int>` | Integer; once | rollback | Choose this positive Windows restore-point sequence. Exactly one of Last or SequenceNumber is required; no default target. |
<!-- END GENERATED CLI OPTIONS -->

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

A provider is a discovered implementation. A configured Action is a durable,
named use of one provider. `providers` lists implementations; `actions` lists the
configured instances in a spec. Both operations are static and inert.

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

For a one-off invocation whose provider accepts empty configuration, use:

```powershell
winspec run -Provider MicrosoftActivation -DryRun -- /HWID
```

This constructs an ephemeral `{ Use = 'MicrosoftActivation'; With = @{} }`
Action. Values after `--` become `input.arguments`. The current directory becomes
the Action working directory. Providers with required or reusable configuration
use a named Action instead; WinSpec does not define an inline nested `With`
syntax.

`actions [spec]` returns items sorted case-insensitively by Action name. Each item
contains `name`, `provider`, `origin`, and `operations`; it intentionally omits
the provider-owned `With` map.

### Validation coverage

Default `validate` is structural and never starts provider code. It preserves
`results.valid` and reports configurations whose provider-owned semantics were
not executed:

```json
{
  "valid": true,
  "validation": {
    "mode": "Structural",
    "subjects": [
      {
        "path": "Actions.cacheOffice",
        "provider": "OfficeDeployment",
        "status": "NotRun"
      }
    ]
  }
}
```

`-PreviewActions` changes `mode` to `ActionPreview` and selects configured external Action
providers that declare `preview`, in case-insensitive Action-name order. A
successful `Planned` response maps to `Valid`; a provider response of `Failed`
maps to `Invalid`, makes `valid` false, and exits 2. A provider without preview is
`Unavailable` and is not started. A provider process/protocol failure or timeout
fails the command with exit 3 or 4 and preserves the subject and diagnostic.

Core Script configuration shape is checked structurally, but source-file existence
and runtime dependencies are not checked by validate, including with PreviewActions.
Use local Script run -DryRun for source existence; remote preview stays offline.

The complete subject vocabulary is `NotRun`, `Valid`, `Unavailable`, and
`Invalid`. External State configuration remains `NotRun`; protocol version 1 has
no State validation operation. `-PreviewActions` starts trusted provider code and
may perform observations allowed by the preview contract. A conforming preview
does not mutate target or durable state, but process isolation is not a security
sandbox.

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

Capture, merge with `-Output`, and Workflow Capture share one file-publication
boundary. They write a temporary sibling, then atomically move it to a new path
or, with explicit Force, replace an existing file. Without Force, a destination
created concurrently is not replaced. No delete-and-retry fallback is used;
permissions, locks or concurrent changes can still cause failure. Force is an
overwrite authorization, not a validation bypass or a durability guarantee.

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

Without `-Json`, WinSpec renders a human projection rather than an internal JSON
dump. Final headers use `OK`, `PARTIAL`, `PLAN`, `DIFF`, `NO-WORK`, or `FAIL`.
`PARTIAL` describes incomplete provider-validation coverage, not runtime success;
`NO-WORK` distinguishes an empty selection from a comparison that found no drift.
These tokens do not extend the machine status vocabulary or change exit codes.

Successful summaries, lists, plans and labeled child stdout use stdout. Failure
summaries and diagnostics, labeled child/provider stderr, and terminal-only
`WAIT` events use stderr. Child stderr alone does not turn exit 0 into failure.
Workflow failures show one final step table on stderr; skipped identities are
projected from the already-loaded steps, without adding fields to JSON receipts.

Human child display retains at most 8 KiB per stream (head/tail halves), result
tables at most 100 rows, and value cells at most 256 characters. Diagnostics are
limited to 100 items per command and 4 KiB per message. Explicit notices identify
display omissions separately from capture loss. `-Json` retains the existing
captured data; it cannot recover bytes already discarded by the runtime. Terminal
control characters are escaped. URI credentials, query and fragment, argument
vectors and `With` configuration are not displayed as default metadata; arbitrary
child/provider payloads should still be treated as potentially sensitive.

For noninteractive captured processes, `WAIT` reports the actual stage, then
elapsed time after one second and at most every two seconds. It is disabled for
JSON, redirected streams and interactive Script children. Synchronous HTTP/core
Windows calls report entry into their stage, not periodic elapsed events while
blocked; no new scheduler, deadline or progress percentage is implied.

Apply success means providers reported success; no post-apply verification is
performed. Rollback success means Windows accepted the request, not that system
recovery completed. DryRun rollback does not resolve a restore point.

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

Human diagnostics render their code once. If a message already begins with its
same `code:` prefix, WinSpec does not prepend it again. JSON preserves the
separate provider/command `code` and `message` values.

A direct provider run returns its selection and nested provider result:

```json
{
  "actions": [
    {
      "provider": "MicrosoftActivation",
      "result": { "status": "Planned" }
    }
  ]
}
```

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
provider code and reports that coverage in `results.validation`. Explicit
`-PreviewActions` invokes configured Action previews; it does not validate
external State semantics. Process isolation contains WinSpec process and wire
failures; it is not a security sandbox.

## Command Help

`winspec help` groups all twelve commands into Inspect, Change, Files, Recovery
and Help, then shows safe starting commands and the default-spec rule. Both
`winspec help <command>` and `winspec <command> -Help` show the same human page:
Usage, Selection, typed Options with meaning/defaults/conflicts, Effects and
limits, Examples, Exit, and resolved packaged documentation paths. `run` also
explains literal argument forwarding. Help performs no spec load, provider
discovery or execution, even when a default spec or catalog is broken/missing.
Use `-Help` without operands or execution options; `-Json` may accompany it.

`help [command] -Json` and `<command> -Help -Json` return a schema-version-1
command result with `results.help`. It contains `topic` (empty string for the inventory),
`summary`, `usage` (array), `options` (array of `name`, `valueType`, `repeatable`),
`defaults.selection`, `effects`, `examples` (array), and `related` (array of
repository documentation references). The top-level inventory additionally
contains `commands`, an array of `name` and `summary`. The option value types
are `Switch`, `String`, `Integer`, and `List`. These fields describe the static
command contract, not provider-owned configuration or runtime readiness.
Unknown/retired topics return one Failed result with exit 2. Existing Help JSON
fields and prose values are retained for compatibility; expanded human prose
does not add fields to that document. Option legality, type, repetition and
human descriptions belong to the same command/option inventory as admission.
Strategy/timeout defaults are read from their option records. The option table
above is generated from those literal records without executing the CLI; its
maintenance command is documented in [Development](development.md).

## Bundled Action providers

`MicrosoftActivation`, `WindowsDebloat`, and `OfficeDeployment` are packaged
protocol-version-1 Action providers shipped and automatically discovered with
WinSpec. They remain inert until selected. Their exact `With` fields, endpoints,
preview/run behavior, interaction, privileges, acquisition limits, nested-content
boundary, and receipts are owned by
[Bundled Action providers](bundled-providers.md).
