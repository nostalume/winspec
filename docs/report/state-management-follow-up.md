# State Management Follow-up Plan

This development report holds review findings and implementation slices for state comparison and sandbox consistency. It is intentionally outside `docs/reference.md`; the reference remains current API/workflow surface, while this file is a development plan.

## Scope

Review targets:

- provider comparison correctness for `Registry`, `Feature`, and `Service`,
- comparison data shape consistency,
- sandbox data correctness, persistence, cache/locality, and algorithm ownership,
- small implementation slices that can be coded and verified independently.

## Provider comparison implementation review

This section records current comparison semantics and known consistency gaps.

### Registry comparison

Implementation: `winspec/managers/registry.psm1` -> `Compare-RegistryState`.

Current algorithm:

1. Iterate desired categories and properties only.
2. Read corresponding system category/property if present.
3. Emit:
   - `Added` when desired property is absent from system state.
   - `Changed` when system value differs from desired value.
4. It does not emit `Removed` or `Equal` rows.

Assessment:

- Good: sparse desired registry specs do not produce noisy removals for every unmanaged registry value.
- Good: comparison operates on friendly/spec-shaped values after export translation.
- Gap: output semantics differ from Feature and Service because it suppresses `Removed`/`Equal` entirely.
- Gap: this should be documented as sparse-spec behavior or normalized across providers.

### Feature comparison

Implementation: `winspec/managers/feature.psm1` -> `Compare-FeatureState`.

Current algorithm:

1. Iterate desired feature names.
2. Emit `Added` if feature is missing from system export.
3. Emit `Changed` if exported state differs from desired state.
4. Iterate system feature names and emit `Removed` for any feature not present in desired.

Assessment:

- Good: detects features present in captured state but absent from desired.
- Correctness gap: desired values are schema-level lowercase (`enabled`/`disabled`), while `Export-FeatureState` returns Windows casing (`Enabled`/`Disabled`). Direct string comparison can mark equal states as changed.
- Noise gap: when comparing a sparse desired spec against a broad live export, removed-feature rows can dominate the diff even though omitted features may be intentionally unmanaged.
- Recommended next slice: normalize feature state values before comparison and decide whether provider comparisons should use sparse-spec semantics by default.

### Service comparison

Implementation: `winspec/managers/service.psm1` -> `Compare-ServiceState`.

Current algorithm:

1. Iterate desired services.
2. Emit `Added` if the service is absent from system export.
3. Emit `Equal` if both `State` and `Startup` match.
4. Otherwise emit `Changed` for the whole service object.
5. Iterate system services and emit `Removed` when absent from desired.

Assessment:

- Good: can report `Equal`, `Changed`, `Added`, and `Removed` rows.
- Correctness gap: desired spec uses lowercase values (`running`, `stopped`, `automatic`, `manual`, `disabled`), while service export uses PowerShell/.NET casing (`Running`, `Stopped`, `Automatic`, etc.). Direct comparison can mark equal states as changed.
- Granularity gap: state and startup differences are collapsed into one service-level row. That is usable, but less precise than registry property-level rows.
- Scope gap: default provider list is currently `Registry`, `Feature`; `Service` is built in and schema-valid but not part of the default capture/compare provider list unless selected.

### Cross-provider comparison consistency

Current diff row shape is conceptually shared:

```powershell
[pscustomobject]@{
    Type        = "Added" # or Removed/Changed/Equal
    Path        = "Provider.Path"
    SystemValue = <current>
    ConfigValue = <desired>
}
```

Consistency issues to resolve later:

1. Normalize provider exported values to spec-level values before comparison.
2. Decide sparse-spec semantics: omitted desired keys may mean unmanaged, not removed.
3. Decide row granularity: provider-level object rows vs leaf/property rows.
4. Include `Service` in default providers or document why it is explicit-only.

---

## Sandbox consistency review

`sandbox.psm1` currently provides a persistent marker file, snapshots, history, and in-memory mock state. The orchestration layer checks sandbox state through `Test-WinSpecSandboxActive` and `Get-WinSpecSandboxMode` wrappers.

### Current sandbox data model

Files:

```text
~/.config/winspec/sandbox/sandbox.json
~/.config/winspec/sandbox/snapshots/<name>.json
~/.config/winspec/sandbox/history/<timestamp>.json
```

In-memory context shape:

```powershell
@{
    Mode      = "DryRun" | "Mock" | "Live"
    Snapshot  = "default"
    StartTime = <date>
    Changes   = @()
    State     = <provider state map>
    Original  = <initial state clone>
}
```

### Correctness gaps

1. **Persisted active sandbox vs process-local context**

   `Test-SandboxActive` checks whether `sandbox.json` exists, but `Get-SandboxMode` returns `Live` when `$Script:SandboxContext` is not populated. A new PowerShell process can see sandbox active while reporting mode as `Live`.

   Target fix: make `Get-SandboxMode` load `Get-SandboxContext` when process-local context is null.

2. **Mutation persistence**

   `Update-SandboxState` mutates only `$Script:SandboxContext.State`. It does not rewrite `sandbox.json`. `Exit-Sandbox` reloads context from disk via `Get-SandboxContext`, so in-memory changes may be absent from saved history.

   Target fix: after state/change mutation, persist the updated context atomically to `sandbox.json`.

3. **JSON type locality**

   `Import-SandboxState` returns `ConvertFrom-Json` objects without `-AsHashtable`, but provider sandbox mutation code often treats state as a hashtable with indexers and `.ContainsKey()`.

   Target fix: use `ConvertFrom-Json -AsHashtable` consistently for sandbox state files, or normalize state objects at load boundaries.

4. **Initial sandbox state shape mismatch**

   `New-SandboxState` uses `Registry.Explorer.HideFileExt`, but the public spec field is `ShowFileExt`. This makes mock state diverge from registry provider spec shape.

   Target fix: seed mock state with spec-shaped keys only.

5. **Service sandbox is incomplete**

   `Invoke-ServiceSandbox` currently tracks startup changes but does not fully model service `State` changes.

   Target fix: simulate both `State` and `Startup` using the same spec shape as `Service` config.

6. **Dead comparator path**

   `sandbox.psm1` has `Register-ProviderComparator`, `Compare-ProviderState`, and `Invoke-SandboxDryRun`, but no built-in comparators are registered and the dry-run function is not exported. The active path is provider-specific `Invoke-<Name>SandboxApply`, not this comparator engine.

   Target fix: either delete the unused comparator engine or wire it into the same module-scoped provider comparison path used by `state.psm1`. Ponytail default: delete unless a caller needs it.

7. **Provider locality**

   `$Script:Providers = @("Registry", "Service", "Feature")` is hard-coded in sandbox dry-run. It does not reflect user providers discovered via `ConfigPath`.

   Target fix: do not keep a separate sandbox provider list. Reuse `Get-Managers -ConfigPath` if sandbox dry-run remains.

8. **Cache/locality model**

   Normal state cache has been removed from `state.psm1`, but sandbox persists globally under the user profile, not per config path or repo. Snapshot names are global.

   Target fix: include config/workspace identity in sandbox scope or document that sandbox state is a user-global WinSpec context.

### Recommended sandbox cleanup order

1. Fix process-local context loading: `Get-SandboxMode` and state access should hydrate from `sandbox.json`.
2. Persist mutations after `Update-SandboxState` and `Update-SandboxChanges`.
3. Normalize JSON state as hashtables at load/save boundaries.
4. Fix seeded state keys to match public spec shape.
5. Complete Service state simulation.
6. Delete or wire the unused comparator/dry-run engine.
7. Decide whether sandbox root is user-global or config/workspace-local, then document/enforce it.

---

## Target improvement design

### Comparison policy

Adopt one explicit comparison policy before changing providers:

1. **Spec-shaped values at compare boundary**: every provider compare function should compare values in public spec terms, not raw Windows terms.
   - `Feature`: compare `enabled`/`disabled`, not `Enabled`/`Disabled`.
   - `Service`: compare `running`/`stopped` and `automatic`/`manual`/`disabled`, not PowerShell enum casing.
   - `Registry`: already compares friendly/spec values after map translation.
2. **Sparse desired specs are unmanaged-by-omission by default**: omitted keys should not become `Removed` unless a future explicit full-state diff mode asks for removals.
3. **Diff rows should be leaf-oriented where possible**: row paths should identify the smallest changed setting, e.g. `Service.wuauserv.Startup`, not only `Service.wuauserv`.
4. **Equal rows are optional for display but must not be required for correctness**: providers may emit `Equal` for full/status views, but normal diff display can suppress them.

### Sandbox policy

Adopt one sandbox locality model:

1. Active sandbox state is a persisted context, not process-local memory only.
2. Every process that sees `sandbox.json` must be able to hydrate mode, state, and changes from it.
3. Mutations must be written back atomically after state or change updates.
4. Sandbox state shape must match public spec shape.
5. Sandbox provider execution should either use the active module-scoped provider path or have the unused parallel comparator engine deleted.
6. Sandbox scope must be explicit: user-global context now, config/workspace-local only if we add a scoped root later.

---

## Implementation slices

### Slice 1 — RED tests for comparison normalization

Add focused Pester tests before implementation:

- `Compare-FeatureState` treats `Enabled` system state as equal to desired `enabled`.
- `Compare-FeatureState` treats `Disabled` system state as equal to desired `disabled`.
- `Compare-ServiceState` treats `Running`/`Stopped` as equal to desired `running`/`stopped`.
- `Compare-ServiceState` treats `Automatic`/`Manual`/`Disabled` as equal to desired `automatic`/`manual`/`disabled`.

Expected initial state: tests fail on current direct string comparison.

Verification:

```powershell
Invoke-Pester -Path ./tests/State.Tests.ps1 -FullName "*comparison normalization*"
```

### Slice 2 — normalize Feature comparison

Implementation target:

- Add a small provider-local normalizer, e.g. `ConvertTo-FeatureSpecState`.
- Use it inside `Compare-FeatureState` for both system and desired values.
- Keep invalid/unknown values visible rather than silently coercing to success.

Acceptance:

- enabled/disabled equal cases no longer emit `Changed`.
- actual mismatch still emits `Changed`.
- missing desired feature still emits `Added` or chosen sparse policy behavior.

### Slice 3 — normalize Service comparison and row granularity

Implementation target:

- Add provider-local normalizers for service state and startup.
- Compare normalized values.
- Prefer leaf rows:
  - `Service.<name>.State`
  - `Service.<name>.Startup`
- Preserve whole-service `Added` for missing service.

Acceptance:

- casing-only differences do not emit `Changed`.
- actual state/startup differences emit precise leaf rows.
- tests cover both `State` and `Startup` differences.

### Slice 4 — choose and enforce sparse diff policy

Implementation target:

- Treat omitted desired keys as unmanaged by default for normal provider diff.
- Remove broad `Removed` emission from Feature/Service default compare, or gate it behind an explicit future full-state mode.
- Document the policy in `docs/reference.md` after implementation lands.

Acceptance:

- sparse desired Feature spec does not report every other exported feature as removed.
- sparse desired Service spec does not report every other managed service as removed.
- Registry, Feature, and Service use consistent omission semantics.

### Slice 5 — default provider list consistency

Implementation target:

- Decide whether `Service` should be included in the default provider list.
- If yes, update `Resolve-ProviderList` default and tests.
- If no, document `Service` as explicit-only in user/API docs.

Acceptance:

- default capture/compare behavior is intentional and documented.
- tests assert the expected default provider set.

### Slice 6 — sandbox context hydration

Implementation target:

- Change `Get-SandboxMode`, `Get-SandboxState`, `Update-SandboxState`, and `Update-SandboxChanges` to hydrate `$Script:SandboxContext` from `sandbox.json` when process-local context is null.
- Ensure `Test-SandboxActive` and `Get-SandboxMode` agree across new PowerShell processes.

Acceptance:

- entering sandbox in one process and reading mode in another returns the active mode, not `Live`.
- missing or corrupt context fails loudly or resets through one documented path.

### Slice 7 — sandbox mutation persistence and JSON shape

Implementation target:

- Add a single `Save-SandboxContext` helper.
- Persist after state/change mutation.
- Load JSON with `-AsHashtable` or normalize to hashtable at the boundary.
- Fix `New-SandboxState` to use spec-shaped keys (`ShowFileExt`, not `HideFileExt`).

Acceptance:

- sandbox apply changes are present in `sandbox.json` immediately after mutation.
- `Exit-Sandbox` history includes mutations made before exit.
- mock registry state uses only public spec keys.

### Slice 8 — sandbox provider algorithm cleanup

Implementation target:

- Delete unused comparator/dry-run engine from `sandbox.psm1`, unless a real caller is found.
- If dry-run comparison remains needed, wire it through `state.psm1` module-scoped provider comparison instead of a second registry.
- Remove hard-coded `$Script:Providers` from sandbox if not needed.

Acceptance:

- no dead exported/unexported comparator API remains.
- sandbox behavior depends on the same provider discovery/command lookup model as normal state management, or intentionally only provider-local `Invoke-<Name>SandboxApply` hooks.

---

## Suggested coding order

1. Slices 1-4: comparison correctness and sparse semantics.
2. Slice 5: provider default choice.
3. Slices 6-8: sandbox persistence and algorithm cleanup.

Do not mix comparison fixes and sandbox persistence in one commit. The failure modes are different: comparison is pure data normalization; sandbox is process/file-state correctness.
