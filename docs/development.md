# WinSpec Development Guide

This guide is the contributor workflow for WinSpec. It replaces the short contributing notes with the full development process: setup, repository map, provider contracts, testing, CI, release, and documentation expectations.

---

## Prerequisites

- Windows 10/11 for live provider behavior.
- PowerShell 7+ recommended; Windows PowerShell 5.1 compatibility should be considered when touching runtime code.
- Git.
- Pester 5+ for tests.
- Administrator privileges for live system operations that modify registry, services, optional features, packages, restore points, activation, debloat, or Office setup.

Install Pester:

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser -MinimumVersion 5.0
```

---

## Setup

```powershell
git clone https://github.com/lvyuemeng/winspec.git
cd winspec

# Verify the CLI loads
./winspec/winspec.ps1 help

# Run tests
Invoke-Pester -Path ./tests
```

If you installed WinSpec through Scoop or added it to PATH, `winspec` can replace `./winspec/winspec.ps1` in examples.

---

## Repository layout

```text
winspec/
  winspec.ps1          CLI entry point
  state.psm1           provider discovery, state capture, compare, apply, triggers
  utils.psm1           spec loading, imports, serialization, merge helpers, admin helpers
  schema.psm1          spec validation
  logging.psm1         logging helpers
  checkpoint.psm1      System Restore checkpoints and rollback
  sandbox.psm1         sandbox contexts and simulated changes
  pull.psm1            pull command implementation
  push.psm1            push command implementation
  diff.psm1            diff command implementation
  merge.psm1           merge engine
  registry-maps.psm1   registry category map
  managers/            declarative idempotent providers
  triggers/            explicit non-idempotent providers

tests/
  Integration.Tests.ps1
  Provider.Tests.ps1
  Trigger.Tests.ps1
  State.Tests.ps1
  fixtures/sample-config.ps1

docs/
  architecture.md
  api.md
  development.md
  AGENT.md
  reference.md
```

---

## Development principles

1. **Native PowerShell first**: specs are `.ps1` hashtables; do not replace the primary config language with YAML or JSON.
2. **Managers are idempotent**: declarative providers must test state before applying changes.
3. **Triggers are explicit**: non-idempotent actions belong in triggers and must be selected by the user.
4. **Provider ownership**: subsystem details belong in provider modules, not the CLI dispatcher.
5. **Convention-based extension**: new providers should be discovered by module metadata, not by editing a central provider list.
6. **Safety before mutation**: support dry-run, `ShouldProcess`, sandbox, and checkpoint workflows.
7. **Tests must not alter the machine**: use Pester mocks for registry/service/feature/package/remote-script operations.
8. **Docs follow behavior**: update API/development/reference docs with any user-visible command, spec, provider, or workflow change.

---

## Branch and change workflow

1. Create a focused branch.
2. Read the owner module and relevant tests before editing.
3. Add or update tests for behavior changes.
4. Implement the smallest provider-owned or command-owned slice.
5. Run focused tests.
6. Run the full Pester suite.
7. Run docs whitespace checks if docs changed.
8. Review `git diff` for accidental live-system commands, secrets, generated files, or stale documentation.

Recommended pre-PR commands:

```powershell
Invoke-Pester -Path ./tests
./winspec/winspec.ps1 validate -Spec ./my-config.ps1
git diff --check
```

For live-system provider changes, also run safe CLI smokes:

```powershell
./winspec/winspec.ps1 providers
./winspec/winspec.ps1 push -Spec ./my-config.ps1 -DryRun
```

---

## Creating a declarative manager

Create `winspec/managers/<name>.psm1`. A manager owns one idempotent spec section.

### Required functions

```powershell
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "MyProvider"
        Type = "Declarative"
        Description = "Manages my subsystem"
    }
}

function Export-MyProviderState {
    # Capture live state into spec-shaped data.
    return @{}
}

function Compare-MyProviderState {
    param(
        [hashtable]$System,
        [hashtable]$Desired
    )
    # Return diff rows with Type/Path/SystemValue/ConfigValue where practical.
    return @()
}

function Test-MyProviderState {
    param([hashtable]$Desired)
    # Return $true only if live state already matches desired state.
    return $true
}

function Set-MyProviderState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable]$Desired)

    if ($PSCmdlet.ShouldProcess("MyProvider", "Apply desired state")) {
        return @{ Status = "Applied" }
    }

    return @{ Status = "DryRun" }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo",
    "Export-MyProviderState",
    "Compare-MyProviderState",
    "Test-MyProviderState",
    "Set-MyProviderState"
)
```

### Manager expectations

- `Get-ProviderInfo.Name` must match the function stem used by `Test-<Name>State` and `Set-<Name>State`.
- `Test-<Name>State` must not mutate live state.
- `Set-<Name>State` should do nothing if state already matches; keep the test-before-set pattern even inside provider helpers.
- External commands and Windows APIs must use `try`/`catch` with clear error results.
- User-visible output should use `logging.psm1` helpers.
- Add mocked tests for export, compare, test, and set paths.

### Optional sandbox support

If the provider needs custom sandbox behavior, add an `Invoke-<Name>Sandbox...` function and tests for it. The state engine detects sandbox mode and routes simulated changes there when available.

---

## Creating a trigger provider

Create `winspec/triggers/<name>.psm1`. A trigger owns one explicit, non-idempotent action.

```powershell
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "mytrigger"
        Type = "Trigger"
        Description = "Runs my explicit action"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Option = $true)

    if (-not $PSCmdlet.ShouldProcess("mytrigger", "Execute trigger")) {
        return @{ Status = "DryRun"; Message = "Would execute" }
    }

    try {
        return @{ Status = "Success"; Message = "Completed" }
    }
    catch {
        return @{ Status = "Error"; Message = $_.Exception.Message }
    }
}

Export-ModuleMember -Function @("Get-ProviderInfo", "Invoke-Trigger")
```

Trigger rules:

- Keep triggers opt-in. Do not run them as side effects of declarative provider application.
- If a trigger downloads or executes remote scripts, document that behavior in API/reference docs.
- Support dry-run or `ShouldProcess` semantics where possible.
- Return `Status` plus `Message` for operator feedback.

---

## Code style

- Use PascalCase function names.
- Use camelCase variable names where practical.
- Use `[CmdletBinding()]` for functions with parameters or common PowerShell behavior.
- Use `SupportsShouldProcess = $true` for functions that can mutate system state.
- Use `$null -eq $value` for null checks.
- Prefer `Write-Verbose`/`Write-Debug` for diagnostics and shared `Write-Log*` helpers for normal output.
- Keep provider modules focused on one subsystem.
- Avoid central registration for providers; rely on discovery and `Get-ProviderInfo`.

---

## Testing

### Run tests

```powershell
# Full suite
Invoke-Pester -Path ./tests

# Focused files
Invoke-Pester -Path ./tests/Integration.Tests.ps1
Invoke-Pester -Path ./tests/Provider.Tests.ps1
Invoke-Pester -Path ./tests/Trigger.Tests.ps1
Invoke-Pester -Path ./tests/State.Tests.ps1

# Detailed output
Invoke-Pester -Path ./tests -Output Detailed
```

### Coverage output

```powershell
$config = New-PesterConfiguration
$config.Run.Path = "./tests"
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = "./winspec"
$config.CodeCoverage.OutputFormat = "JaCoCo"
$config.CodeCoverage.OutputPath = "./coverage.xml"
Invoke-Pester -Configuration $config
```

### Test design rules

- Use `Describe`, `Context`, and `It` blocks.
- Use `BeforeAll`/`AfterAll` for setup and cleanup.
- Mock system-changing commands: registry writes, service changes, optional feature changes, package installs, restore point operations, downloads, and trigger execution.
- Test one behavior per `It` block.
- Keep fixtures under `tests/fixtures/`.
- Prefer asserting result hashtables and provider calls over checking console color/output.

Example:

```powershell
Describe "MyProvider" {
    BeforeAll {
        Import-Module "$PSScriptRoot/../winspec/managers/myprovider.psm1" -Force
    }

    Context "Test-MyProviderState" {
        It "returns true when desired state already matches" {
            Mock -CommandName Get-SomeState -MockWith { "enabled" }
            Test-MyProviderState -Desired @{ Item = "enabled" } | Should -BeTrue
        }
    }
}
```

---

## Documentation workflow

Update docs in the same change when behavior changes:

| Change type | Docs to update |
| --- | --- |
| CLI command or option | `docs/api.md` |
| Spec field/provider section | `docs/api.md` and `docs/reference.md` |
| Provider contract or architecture boundary | `docs/architecture.md`, `docs/development.md`, `docs/reference.md` |
| Contributor workflow/tooling | `docs/development.md`, `docs/AGENT.md` |
| Safety/security behavior | `docs/api.md` and `docs/reference.md` |

Documentation-only verification:

```powershell
git diff --check -- docs
```

---

## CI

GitHub Actions runs tests on Windows for:

- pushes to `main` and `develop`,
- pull requests to `main` and `develop`,
- a weekly scheduled run.

The test workflow installs Pester, runs `Invoke-Pester -Configuration $config`, saves `test-results.xml`, uploads it as an artifact, and publishes test results.

Keep local test commands aligned with CI unless the workflow is intentionally changed.

---

## Release workflow

Releases are tag-driven.

1. Ensure tests pass locally.
2. Update docs and manifest data if the release changes user-facing behavior.
3. Commit changes.
4. Tag with a `v*` tag, for example `v0.5.2`.
5. Push the tag.

The release workflow:

- creates a GitHub Release,
- derives version from the tag,
- updates `winspec.json` for Scoop with the tag archive URL and extract directory,
- commits the manifest update back to `main`.

Check the generated release and the manifest update after the workflow completes.

---

## Pre-merge checklist

- [ ] The owner module and tests were inspected before editing.
- [ ] Declarative behavior remains idempotent.
- [ ] Non-idempotent behavior is isolated in triggers.
- [ ] Live-system operations are mocked in tests.
- [ ] `Invoke-Pester -Path ./tests` passes.
- [ ] `./winspec/winspec.ps1 validate -Spec ./my-config.ps1` passes or any platform blocker is documented.
- [ ] `git diff --check` passes.
- [ ] API/development/reference docs are updated for user-visible changes.
- [ ] No secrets, generated artifacts, or local sandbox state are committed.
