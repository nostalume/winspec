# Developing WinSpec

This guide is for maintainers changing WinSpec. CLI and user-spec behavior is
owned by [the API reference](api.md), the third-party extension contract by
[Building WinSpec providers](provider-development.md), and dependency direction
by [Architecture](architecture.md).

## Supported environment

Runtime changes must work in both Windows PowerShell 5.1 and PowerShell 7 on
Windows. Do not use PowerShell 7-only syntax or APIs without a guarded equivalent.
Runtime modules have no Pester or PSScriptAnalyzer dependency.

The maintained development tools are Pester 5.7.1 or newer and
PSScriptAnalyzer 1.24.0 or newer:

```powershell
Install-Module Pester -Scope CurrentUser -RequiredVersion 5.7.1
Install-Module PSScriptAnalyzer -Scope CurrentUser -RequiredVersion 1.24.0
```

## Repository layout

```text
winspec/                    CLI and runtime owners
  providers/               trusted core State adapters
  providers/bundled/       three external bundled Action packages + common.psm1
tests/                      Pester behavior and disposable integration tests
  fixtures/                 inert protocol/data helpers
examples/                   runnable specs and local scripts
docs/                       usage, API, provider guides, architecture, development, migration
tools/format.ps1            project formatter/checker
winspec.json                Scoop publication manifest
AGENTS.md                   repository contributor constraints
```

There is no public reports or decisions tree. Current rationale belongs in
architecture/API prose; history remains in version control. Each bundled package
contains only `provider.json`, `provider.ps1`, and `README.md`. Ordinary custom
automation belongs in one Script file, not a package directory.

## Canonical checks

Run daily regression on the current host:

```powershell
pwsh.exe -NoProfile -File .\tools\test.ps1 -Profile Quick
```

`Quick` selects existing `Unit` and `Quick` Pester tags, not copies of tests.
`Unit` covers in-process/Mock specification, State, adapters, checkpoint and pure
human projection, including all 28 approved HumanOutput renders from the unchanged
JSON receipts. The child/wait observation is `Boundary`, not `Unit`.
`Boundary` covers real CLI/protocol seams; `Flow` covers composed scenarios.
Lifecycle cases additionally carry `Safety`. Quick adds all twelve Help topics, top-level text/JSON Help,
the provider JSON envelope and sandbox retirement. It is not a substitute for
the full safety suite or two-host compatibility acceptance.

For complete acceptance, run the format check once and Full once on each fresh
host, serially, stopping at the first failure. Do not insert another fixed
two-host focused run or discovery-only pass. Discovery-only is useful when
changing selectors, not as a routine prerequisite. Quick supplies focused
evidence for its selected scope; add affected tests only when a change needs it.

```powershell
.\tools\format.ps1 -Check
pwsh.exe -NoProfile -File .\tools\test.ps1 -Profile Full
powershell.exe -NoProfile -File .\tools\test.ps1 -Profile Full
git diff --check
```

`Full` applies no test filter. Both profiles stop remaining Pester tests on the
first failure and return nonzero for failures, skips, empty selection or missing
execution. Optional `-ResultPath <absolute-json-path>` writes counts/selection
plus an NUnit XML sibling. Output directories must already exist. There is no
result cache, process pooling, implicit benchmark or cross-host loop inside a
suite. Keep the two-host loop in the outer invocation only.

Timing goals (not measured guarantees or per-stage kill limits): current-host
Quick <=90 seconds; full two-host acceptance including one format check <=12
minutes for this reduction stage. For time-boxed acceptance the outer runner
owns one shared 20-minute deadline across Quick, formatting and both Full runs;
on failure or total timeout stop, do not retry. No per-stage timeout is added.
The profile entry itself runs on the current host and does not enforce a
cross-invocation deadline. HumanOutput renders also run in Quick; all 28 real CLI
JSON receipts and nine representative human invocations remain in Full. Runtime
performance targets still require separate acceptance.

Run the formatter after edits, then run `-Check` again; an idempotent second pass
is the gate. Source, tests, examples, and active Markdown use UTF-8 without BOM
and LF endings. Validate JSON output by parsing it, not by visual inspection.

### CI Full entry

The Test WinSpec workflow keeps separate `powershell` and `pwsh` matrix jobs.
Each job explicitly calls the existing entry rather than duplicating Pester
configuration:

```powershell
& ./tools/test.ps1 -Profile Full -ResultPath (Join-Path $env:GITHUB_WORKSPACE 'test-results.json')
```

The explicit profile matters because the entry defaults to Quick. Selection,
count checks, and test-failure policy remain owned by `tools/test.ps1`. It writes
the JSON receipt and an NUnit3 `test-results.xml` sibling. The existing upload
step uses `always()` and includes both files in the per-host artifact. The
reporter retains its cancellation/same-repository PR protection and additionally
requires XML to exist before attempting the `dotnet-nunit` report. These
conditions do not guarantee artifact availability or external service success.

Pester stops remaining tests after the first failure within a host; the matrix
retains `fail-fast: false`, so another host is not cancelled on that account.
The unchanged CI timeout is 30 minutes per job, distinct from the local shared
20-minute acceptance budget. Triggers, action pins, permissions, dependency
versions, and the formatting step are unchanged by entry alignment.

Local acceptance of this alignment covered YAML structure and four synthetic
success/failure calls across both hosts, including exit and result-path
propagation. It did not run real Pester or validate real NUnit3 output.
Hosted workflow execution, artifact upload/download, and Checks presentation
remain unverified; local orchestration checks are not evidence of remote CI
success or required-check wiring.

For a local PS5 AuthorizationManager startup refusal in a restricted execution
context, establish the actual cause before changing policy. In this incident,
read-only execution-policy queries failed on registry access in the restricted
context, while the same script launch worked in an approved outside-sandbox
context with the existing RemoteSigned policy. The local verification driver
now detects that refusal early; it does not elevate itself. Request an approved
execution context where authorized, rather than using policy bypass, changing
global policy/ACLs, or executing file contents to avoid authorization. This is
local verification setup, not a WinSpec or hosted-workflow requirement.

### Formatter diagnostics

The formatter prunes `.git`, `.agents`, and `docs/report` directories before
entering them and does not descend into directory links on the supported hosts.
It retains the original extension/name and hidden-file selection behavior,
including eligible untracked files. PowerShell files still pass through
`Invoke-Formatter`; other eligible text receives newline/trailing-space
normalization, not language-specific formatting. Rules are unchanged. The tool
still selects the highest discoverable PSScriptAnalyzer version >=1.24.0; a local
cache does not pin that version.

When investigating a normal check, use its existing common `-Verbose` parameter
for that invocation rather than adding another timing-only run:

```powershell
.\tools\format.ps1 -Check -Verbose
```

`FormatTiming` reports `discoveryMs` (initial setup and module discovery),
`importMs`, `enumerationMs`, `fileOtherMs` (file handling excluding formatter
calls), `formatterMs` (cumulative `Invoke-Formatter`), `totalMs`, `files`, and
`formatterCalls`. `FormatModule` reports the selected version and path. Internal
`totalMs` excludes host startup and outer-runner/output-drain overhead. Timing
messages are opt-in; `-Verbose` also enables the analyzer's own diagnostics and
can produce substantial logs, whose cost is included in the observation.

Record file counts, module version, host, verbosity, and timing boundaries when
comparing runs. A single historical total cannot identify which phase changed
or establish stable speedup, p95, or cold-start performance. File-set equality
checks on both hosts do not substitute for Full on both hosts; if a scoped
acceptance omits PS5 Full, report that omission explicitly. The full-acceptance
procedure above is unchanged.

A standalone PS5 verification worker may need to import its native
`$PSHOME/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1`
explicitly when `Get-FileHash` cannot be discovered through inherited module
paths. On PS5 the hash command is an exported function of that native module.
This is verification-worker setup, not a formatter module-selection change or
a WinSpec runtime dependency.

### Focused suites

- `Spec.Tests.ps1`: data admission, duplicate keys, Includes, paths, and atomic
  publication.
- `State.Tests.ps1`: root State schema, provider selection, and merge truth.
- `Provider.Tests.ps1`: core Windows adapters with mocked host effects.
- `Checkpoint.Tests.ps1`: checkpoint/rollback owner with mocked System Restore.
- `CommandBehavior.Tests.ps1`: CLI grammar, results, exits, and direct Script.
- `CliAdmission.Tests.ps1`: cross-process option/operand admission, retirement,
  literal forwarding, static Help JSON, and rejection before effects.
- `HumanOutput.Tests.ps1` and `golden/`: 28 in-process rendering cases reuse the
  unchanged JSON snapshots as input and compare the original stdout/stderr text.
  One sequential boundary check retains every real CLI JSON receipt and nine human
  wiring cases (actions, diff, run-failed, run-warning, run-timeout, provider-plan,
  workflow-failed, capture, missing-value). Failures identify the receipt; stop at
  the first failure. Context is explicit fixture data, not a second parser. No
  render fixture starts an operation or imports an external provider. Normalize
  only temporary paths, host interpreter, request IDs, timings and alignment, not
  claims or statuses. Keep snapshots unchanged during a test-organization change.
- `HumanProjection.Tests.ps1`: pure projection limits, privacy, terminal escaping,
  diagnostic ownership, result immutability, and optional wait observations.
- `ActionWorkflow.Tests.ps1`: common Action envelopes and Workflow semantics.
- `ProviderProtocol.Tests.ps1`: manifest discovery, process protocol, bundled
  localhost acquisition, output, timeout, and cleanup.
- `ProcessLifecycle.Tests.ps1`: observed child entry, blocked input, inherited
  pipes, EOF before exit, duplex messages, spent budgets and cleanup failures.
  Its disposable native fixture uses the Windows .NET Framework compiler; it is
  not a runtime dependency.
- `PackageInstallMigration.Tests.ps1`: the one-file migration on both hosts with
  fake package executables.
- `Integration.Tests.ps1`: external State routing through disposable packages.

Every command or protocol change must exercise the public executable in fresh
Windows PowerShell 5.1 and PowerShell 7 processes. Capture stdout and stderr as
separate streams. For `-Json`, parse stdout and assert it contains exactly one
JSON document; controlled diagnostics belong inside that document and stderr
must remain empty on CLI success and failure paths.
For human output, assert the complete diagnostic line so a code such as
`InvalidRegistryValue` cannot accidentally be rendered twice.

Catalog/configuration changes must test both projections: `providers` remains a
static implementation inventory when no spec configures a provider, and
`actions [spec]` remains a static list of configured Action names. Direct
`run -Provider` tests must cover preview, execution, invalid kind, process
failure, and timeout without contacting a real upstream.

## Effect policy for tests

Tests must never contact the real activation, debloat, Office, or other upstream
URL. They must never install a package, mutate Registry/Service/Feature State,
change licensing, create a real restore point, request elevation, or write the
user profile.

Use a unique `$TestDrive` root, localhost byte server, copied package, fake
executable, and sentinel. Observe the exact request, result, filesystem residue,
and cleanup. A copied bundle may replace its fixed URI only inside that disposable
fixture; production packages expose no source override. A Microsoft-signed inert
Windows executable is suitable for testing Office signature-and-cache behavior
without running it as an installer.

Keep test effects bounded: explicit byte counts, expected request counts, one
timeout owner, killed process trees, and cleanup in `AfterEach`. Do not hide a
live effect behind `Mock` when a deterministic disposable integration can verify
the actual process/wire seam.

CLI suites share `tests/TestSupport.ps1` for independent stdout/stderr capture,
an outer timeout and teardown. The default child is the current test host, not
hard-coded `pwsh`, so a PS5 run actually exercises PS5. Keep fixture policy and
semantic assertions in the owning suite. Do not increase a product timeout to
hide a slow drain or treat absence of an entry marker as proof of child cleanup.

Failure cleanup lazily builds its fixed native ancestry reader using PowerShell's
built-in `Add-Type`. Keep ABI, birth identity and handle-retention checks covered
on both hosts after Windows/runtime updates. The process-isolation contract does
not authorize compiling configuration or importing external provider code.

The EOF-before-exit branch uses empty streams around an independently live
process. It is a deterministic deadline/cleanup seam, not proof that a native
Windows close-pipes fixture works on every host. The CLI cleanup-error test
also uses a disposable source copy for fault injection; keep that coupling
visible rather than adding a production fault flag.

Let the outer two-host run own the compatibility matrix; a CLI or migration
case should use the current host, not launch both hosts again inside each suite.
Keep fresh processes for CLI/protocol boundaries rather than caching receipts
from effectful commands. Two Workflow steps can verify ordered preview/run counts
and distinct process identities; they do not establish 20-step scalability.
For display limits, cross the count boundary with short records and use a long
record to cross the length boundary, rather than multiplying oversized payloads.

Pester 5.7.1 `TotalCount` includes discovered tests excluded by a filter. Record
discovered, selected (`ShouldRun`), executed and not-run counts separately; a
filtered run is not a full run. `Filter.FullName` matches the unexpanded template,
so a name containing `<Topic>` does not match the expanded word `run`. Discover
without execution to check parameter rows before a time-boxed verification run.
All Help topics retain JSON goldens; the common alternate Help dispatcher is
exercised on `run` without repeating every spelling for every topic.

## T4 validation checkpoint (2026-10-18)

This is a historical local uncommitted-worktree checkpoint based on
`8995dc0e64d649c8d0e48b1c7238f95a0bb3910d`, not a released version. Final validation
used Pester 5.7.1 on Windows x64 10.0.26300. Each host discovered 289 tests and
selected all 12 Help-topic rows in the 45-test focused subset.

| Host | Focused | Full suite | Full worker wall time |
| --- | --- | --- | --- |
| PowerShell 7.6.7 | 45/45 | 289/289 | 347.467 s |
| Windows PowerShell 5.1.26100.9711 | 45/45 | 289/289 | 338.258 s |

Both full runs had zero failures, skips or unexecuted tests. Focused runs left
100 discovered cases outside their filter; those were covered by the full runs.
The original 97 golden files, including 28 command JSON and 13 Help JSON
snapshots, were unchanged. Format checking, generated Help-reference checking and
`git diff --check` passed. The serial run took 821.338 s under one 1200 s total
deadline, with no separate stage deadline, benchmark execution or automatic retry.
This documents that run, not a new product timeout or permanent test-time SLA.

The checkpoint establishes regression results, not performance acceptance. No
claim is made for Help/catalog/list p95, 4 MiB admission speed, large-output memory
scaling or throughput, 20-step Workflow cost, or a universal two-second cleanup
return. Those targets remain unaccepted. Real State writes, restore, interactive
UI, package installation and live bundled-provider upstreams were not exercised.
This table predates the subsequent test consolidation and formatter changes.
The 2026-10-19 tool-only acceptance verified file selection/hashes on both hosts
but ran formatting and Full only on PS7. PS5 Full was not rerun; the historical
table above is not evidence for that omitted run or the updated formatter.
Later documentation-only closeout does not constitute another Pester run or
format check, and no stable performance gain follows from a single timing.

## Choose Script before a provider

Most custom Actions should be one local script:

```powershell
Actions = @{
    configureTool = @{
        Use = 'Script'
        With = @{
            File = './scripts/configure-tool.ps1'
            Args = @('-Profile', 'developer')
        }
    }
}
```

This already provides relative path ownership, literal argument arrays, timeout,
exact exit, bounded noninteractive streams, interactive child support, and opaque
dry-run. It is easier to run and debug directly. Do not create a manifest merely
to wrap a script.

Use an external provider only when it must own provider-specific validation,
capture/compare/apply semantics, dependencies, a distinct protocol lifecycle, or
a child UI policy that should be exposed as one named integration.

## Build an external provider

External provider packages are a public third-party extension surface, not merely
an internal repository convention.
[Building WinSpec providers](provider-development.md) is
the normative author guide. It explains when a Script Action is sufficient,
package discovery, manifest and process schemas, every Action and State operation,
legal statuses, complete examples, child interaction, trust, cleanup, testing, and
compatibility.

Repository maintainers should change the runtime and that guide atomically. Do not
copy its protocol examples here; this document owns WinSpec repository procedure,
while the provider guide owns the versioned peer contract.

## Bundled launcher conventions

A bundled launcher has a fixed official current endpoint in `provider.ps1`, a
small stable `With` schema, offline preview, bounded streaming acquisition, an
out-of-process child, truthful identity/exit/output receipt, and one normative
[bundled-provider guide](bundled-providers.md). Shared mechanism belongs in
`bundled/common.psm1`; provider meaning stays in its entrypoint and each package
README is only a local pointer.

Do not add:

- a real-upstream test;
- `sources.json`, source version/hash pins, GitHub release lookup, or cache policy;
- a copied catalog of upstream switches, profiles, or modes;
- in-process `Invoke-Expression`, `ScriptBlock::Create`, dot-sourcing, or module
  import of downloaded code;
- an ODT or other upstream schema wrapper without a separately approved public
  contract;
- implicit elevation, retry, or detached child ownership.

Current-script receipts must say that the digest is observed rather than verified
and that bootstrap-owned nested downloads are outside the receipt. Office keeps
Microsoft publisher validation because it authenticates the signer without
pinning a fetched version.

## Completion review

CLI Help is maintained with its admission inventory in `winspec/winspec.ps1`.
Each command owns presentation-only human paragraphs alongside its existing JSON
Help fields; each option owns type/repetition, display label and explanation.
Do not add a second legality table or serialize human-only metadata. Existing
Help JSON prose/shape is frozen by `tests/golden/help` (captured before the human
Help expansion); changing it requires an explicit compatibility decision, not
regenerating the expected result from the candidate.

After changing command/option records, regenerate the marked API option table,
then check it without executing the CLI:

```powershell
.\tools\update-help-reference.ps1
.\tools\update-help-reference.ps1 -Check
Invoke-Pester -Path .\tests\Help.Tests.ps1, .\tests\Documentation.Tests.ps1
```

Help tests use fresh processes, match semantics rather than page whitespace,
compare every existing JSON value, and prove early Help works with poisoned
runtime modules. Documentation tests execute only the marked offline tour in
the usage guide and statically check repository links/reference generation.
Live Registry/Service/Feature, restore, interactive UI, package installation and
remote real-execution recipes are not offline acceptance. Keep them clearly
separate from the no-effect introductory path.

After the last edit, inspect the actual diff and search retired names/paths.
Exercise every changed claim through a stable public or durable boundary on both
hosts. Run focused tests, formatting/static analysis, full Pester, CLI help,
provider listing, spec/example validation, JSON parsing, link/stale scans, and
`git diff --check`.

Report exactly what ran, any skipped live acceptance, and remaining external
trust limitations. Package publication, tagging, and registry updates are a
separate release operation; ordinary development does not authorize them.
