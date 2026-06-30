# WinSpec Agent Guide

This guide is for coding agents and maintainers operating inside the WinSpec repository. It intentionally covers only toolchain, stack, and project principles. User-facing APIs belong in [api.md](api.md); architecture concepts belong in [architecture.md](architecture.md); contribution workflow belongs in [development.md](development.md); ephemeral file/module references belong in [reference.md](reference.md).

---

## Stack

- **Language**: PowerShell scripts and modules.
- **Runtime target**: Windows 10/11 with Windows PowerShell 5.1 or PowerShell 7+; prefer PowerShell 7+ syntax when changing code unless compatibility is explicitly required.
- **Configuration language**: native PowerShell `.ps1` files returning hashtables.
- **Provider modules**: `.psm1` files under `winspec/managers/` and `winspec/triggers/`.
- **Tests**: Pester 5+ under `tests/`.
- **CI**: GitHub Actions on `windows-latest`, running Pester.
- **Release packaging**: tag-triggered GitHub release plus Scoop manifest update in `winspec.json`.

---

## Toolchain

### Local commands

Run commands from the repository root in PowerShell:

```powershell
# Run all tests
Invoke-Pester -Path ./tests

# Run one test file
Invoke-Pester -Path ./tests/Integration.Tests.ps1

# Detailed output
Invoke-Pester -Path ./tests -Output Detailed

# Validate a specification
./winspec/winspec.ps1 validate -Spec ./my-config.ps1

# Show CLI help
./winspec/winspec.ps1 help
./winspec/winspec.ps1 push -Help
```

Install Pester if needed:

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser -MinimumVersion 5.0
```

### Safety commands

Prefer non-mutating checks before live system changes:

```powershell
./winspec/winspec.ps1 diff -Spec ./my-config.ps1
./winspec/winspec.ps1 push -Spec ./my-config.ps1 -DryRun
./winspec/winspec.ps1 sandbox -Enter -Mode Mock
./winspec/winspec.ps1 sandbox -Exit
```

Use checkpoints for live pushes that may affect system state:

```powershell
./winspec/winspec.ps1 push -Spec ./my-config.ps1 -Checkpoint
```

---

## Principles for changes

1. **Inspect before editing**: read the owning module and tests before changing behavior.
2. **Keep semantics separated**: declarative managers are idempotent; triggers are explicit and non-idempotent.
3. **Preserve native config**: do not introduce YAML/JSON as the primary specification format.
4. **Keep providers independent**: new manager/trigger behavior should be discoverable by module convention, not central registration.
5. **Support dry runs**: mutating operations must respect `ShouldProcess`, `-WhatIf`, `-DryRun`, or sandbox semantics where applicable.
6. **Use shared logging**: user-visible provider output should go through `logging.psm1` helpers.
7. **Return simple results**: provider functions should return status hashtables with clear `Status` and optional `Message` fields.
8. **Mock system changes in tests**: Pester tests should not modify registry, services, optional features, packages, or activation state.
9. **Document API changes**: if a command, spec field, provider contract, or workflow changes, update `docs/api.md` and `docs/development.md` as appropriate.
10. **Prefer small provider-owned changes**: do not spread subsystem logic across the CLI, state engine, and provider at the same time unless the contract itself changes.

---

## PowerShell style

- Functions use PascalCase: `Invoke-WinSpec`, `Get-SystemState`.
- Variables use camelCase where practical: `$currentState`, `$desiredValue`.
- Use `[CmdletBinding()]`; use `SupportsShouldProcess = $true` for functions that can mutate state.
- Prefer splatting or line continuation for long command calls.
- Use `$null -eq $value` for null checks.
- Use `try`/`catch` around external commands and Windows APIs.
- Use `Write-Verbose`/`Write-Debug` for diagnostic detail and `Write-Log*` helpers for user-facing output.

---

## Provider implementation rules

### Declarative managers

A manager in `winspec/managers/<name>.psm1` owns one idempotent state section. It should expose:

```powershell
Get-ProviderInfo
Export-<Name>State
Compare-<Name>State
Test-<Name>State
Set-<Name>State
```

Optional sandbox support uses an `Invoke-<Name>Sandbox...` function consumed by the state engine.

### Triggers

A trigger in `winspec/triggers/<name>.psm1` owns one explicit action. It should expose:

```powershell
Get-ProviderInfo
Invoke-Trigger
```

Triggers must stay opt-in. Do not run remote scripts or destructive actions from declarative managers.

---

## Verification expectations

For documentation-only changes:

```powershell
git diff --check -- docs
```

For code changes:

```powershell
Invoke-Pester -Path ./tests
./winspec/winspec.ps1 validate -Spec ./my-config.ps1
```

When the change touches a live-system provider, add or update mocked Pester tests first, then run the relevant test file before the full suite.
