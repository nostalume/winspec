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

From the repository root:

```powershell
.\tools\format.ps1
.\tools\format.ps1 -Check
pwsh.exe -NoProfile -Command "Invoke-Pester -Path .\tests"
powershell.exe -NoProfile -Command "Invoke-Pester -Path .\tests"
pwsh.exe -NoProfile -File .\winspec\winspec.ps1 providers -Json
powershell.exe -NoProfile -File .\winspec\winspec.ps1 providers -Json
git diff --check
```

Run the formatter after edits, then run `-Check` again; an idempotent second pass
is the gate. Source, tests, examples, and active Markdown use UTF-8 without BOM
and LF endings. Validate JSON output by parsing it, not by visual inspection.

Focused suites:

- `Spec.Tests.ps1`: data admission, duplicate keys, Includes, paths, and atomic
  publication.
- `State.Tests.ps1`: root State schema, provider selection, and merge truth.
- `Provider.Tests.ps1`: core Windows adapters with mocked host effects.
- `Checkpoint.Tests.ps1`: checkpoint/rollback owner with mocked System Restore.
- `CommandBehavior.Tests.ps1`: CLI grammar, results, exits, and direct Script.
- `ActionWorkflow.Tests.ps1`: common Action envelopes and Workflow semantics.
- `ProviderProtocol.Tests.ps1`: manifest discovery, process protocol, bundled
  localhost acquisition, output, timeout, and cleanup.
- `PackageInstallMigration.Tests.ps1`: the one-file migration on both hosts with
  fake package executables.
- `Integration.Tests.ps1`: external State routing through disposable packages.

Every command or protocol change must exercise the public executable in fresh
Windows PowerShell 5.1 and PowerShell 7 processes. Capture stdout and stderr as
separate streams. For `-Json`, parse stdout and assert it contains exactly one
JSON document; diagnostics belong on stderr and must not corrupt that document.
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

After the last edit, inspect the actual diff and search retired names/paths.
Exercise every changed claim through a stable public or durable boundary on both
hosts. Run focused tests, formatting/static analysis, full Pester, CLI help,
provider listing, spec/example validation, JSON parsing, link/stale scans, and
`git diff --check`.

Report exactly what ran, any skipped live acceptance, and remaining external
trust limitations. Package publication, tagging, and registry updates are a
separate release operation; ordinary development does not authorize them.
