# WinSpec Architecture

WinSpec is a PowerShell-native Windows configuration engine. It treats a machine configuration as a composable PowerShell specification and routes each specification section to a provider that knows how to observe, compare, and apply one Windows subsystem.

This document describes abstractions and concepts only. User-facing commands and configuration fields belong in [api.md](api.md). Tooling and contributor workflow belong in [development.md](development.md). Agent operating rules belong in [AGENT.md](AGENT.md).

---

## Core abstractions

### Specification

A specification is a PowerShell `.ps1` file that returns a hashtable. It is the user-facing declaration of desired Windows state and requested one-time actions.

Conceptually, a specification contains:

- identity metadata (`Name`, `Description`),
- composition edges (`Import`),
- declarative provider sections (`Registry`, `Feature`, `Service`),
- trigger requests (`Trigger`),
- optional provider selection hints (`Providers`).

Specifications are native PowerShell data, not YAML/JSON schemas. This keeps config editable with the normal PowerShell language and avoids parser dependencies.

### Provider

A provider is a PowerShell module discovered at runtime. Providers are the ownership boundary for a Windows subsystem.

There are two provider families:

| Family | Directory | Semantics |
| --- | --- | --- |
| Declarative manager | `winspec/managers/` | Owns an idempotent state section. It can export current state, compare desired/current state, test whether desired state already holds, and apply changes. |
| Trigger | `winspec/triggers/` | Owns a non-idempotent action. It executes only when explicitly requested. |

Provider discovery is convention-based: WinSpec scans provider directories, imports modules, and reads `Get-ProviderInfo` metadata. No central registry is required.

### State

State is the observed or desired provider-shaped hashtable. WinSpec uses state for four operations:

1. **Capture** current machine state from providers.
2. **Compare** desired state against current or another spec.
3. **Apply** missing declarative state through managers.
4. **Merge** multiple specs into one composed target.

State capture is fresh by default. The previous process-local provider cache and `-NoCache` API were removed to avoid stale or partial state across provider filters and config paths. Command-local provider runtime objects may reuse an imported module and exported-command map inside one command invocation, but no global provider cache is kept.

### Diff

A diff is a provider-level comparison between desired and observed state. Diff entries are categorized as added, removed, changed, or equal. Diff is diagnostic by default; it does not mutate the system.

### Sandbox

Sandbox mode is a safety boundary for trying provider behavior without touching live state.

- `DryRun` reports pending changes and discards the active sandbox context after a dry-run push.
- `Mock` records simulated state changes and trigger executions.

Providers can supply sandbox-specific apply functions, but the core execution layer owns sandbox detection and routing. Sandbox state is file-backed so provider modules can hydrate the same context across module boundaries; integration tests must isolate the sandbox root under `TestDrive`.

### Checkpoint

A checkpoint is a Windows System Restore point created before risky system changes when requested. Checkpoint creation is explicit: WinSpec does not enable System Restore implicitly, and creating a restore point requires Administrator privileges. If a push requested a checkpoint and checkpoint creation fails, push stops before provider/trigger mutation. Rollback restores a previous checkpoint by sequence number or the latest WinSpec checkpoint, is guarded by `ShouldProcess`, and returns structured success/failure metadata rather than a bare boolean.

---

## Execution model

### Command entry

`winspec/winspec.ps1` is the CLI entry point. It resolves the spec path, imports core modules, parses command options, and dispatches to command modules.

High-level command ownership:

| Command | Conceptual operation | Owner module |
| --- | --- | --- |
| `pull` | Capture live state into a spec | `pull.psm1` + `state.psm1` |
| `push` | Apply a spec to the machine | `push.psm1` + `state.psm1` |
| `diff` | Compare spec vs live state or another spec | `diff.psm1` + `state.psm1` |
| `merge` | Compose two specs | `merge.psm1` + `utils.psm1` |
| `status` | Print live provider state | `winspec.ps1` + `state.psm1` |
| `providers` | List discovered managers and triggers | `winspec.ps1` + `state.psm1` |
| `validate` | Check spec shape | `schema.psm1` |
| `trigger` | Execute selected triggers | `state.psm1` |
| `sandbox` | Manage sandbox context | `sandbox.psm1` |
| `rollback` | Restore a checkpoint | `checkpoint.psm1` |

### Declarative manager flow

The declarative path is intentionally test-before-set:

```text
spec section
  -> provider discovery
  -> Test-<Provider>State
  -> if already desired: report OK
  -> if sandbox/dry-run: report pending/simulated change
  -> Set-<Provider>State
  -> result hashtable
```

Managers own subsystem details. The core engine owns ordering, logging, sandbox routing, and result aggregation. Top-level push success is derived from nested provider/trigger results, so any `Status = "Error"` marks the command unsuccessful.

### Trigger flow

The trigger path is explicit and non-idempotent:

```text
trigger selection
  -> trigger provider discovery
  -> resolve trigger value from spec/user input
  -> if sandbox: record simulated trigger
  -> Invoke-Trigger -Option <value>
  -> result hashtable
```

Triggers are not run just because they exist in a spec. They run when the user invokes `trigger` or passes trigger selection to `push`.

### Composition flow

Specs can import other specs. Composition is handled by resolving imports, loading PowerShell hashtables, and recursively merging them. Later/importing values override or extend earlier values according to the merge semantics for each value shape.

---

## Provider contracts

### Declarative manager contract

A declarative manager module must expose provider metadata and state functions using the provider name as the command stem:

```powershell
function Get-ProviderInfo { ... }
function Export-<Name>State { ... }
function Compare-<Name>State { param($System, $Desired) ... }
function Test-<Name>State { param([hashtable]$Desired) ... }
function Set-<Name>State { param([hashtable]$Desired) ... }
```

The core can tolerate a missing export/compare in some contexts, but a manager must provide `Test-<Name>State` and `Set-<Name>State` to participate in `push`.

### Trigger contract

A trigger module must expose:

```powershell
function Get-ProviderInfo { ... }
function Invoke-Trigger { param(<typed trigger parameters>) ... }
```

`Invoke-Trigger` receives typed parameters from `TriggerConfig.<name>` and returns a status hashtable.

### Result contract

Providers return small hashtables with a `Status` key plus optional diagnostic fields. Common statuses include:

- declarative: `AlreadyInDesiredState`, `Applied`, `DryRun`, `Error`,
- trigger: `Success`, `DryRun`, `Skipped`, `Error`,
- sandbox: `Simulated`.

The result shape is intentionally simple because provider modules are independent PowerShell modules rather than classes in a shared runtime.

---

## Built-in provider concepts

### Registry

The registry manager maps friendly categories and properties to concrete registry paths, value names, types, and value translations. Category definitions live in `registry-maps.psm1`; `registry.psm1` owns read, compare, write, export, and sandbox behavior.

### Feature

The feature manager maps simple `enabled`/`disabled` config values to Windows Optional Feature states. It owns calls to `Get-WindowsOptionalFeature`, `Enable-WindowsOptionalFeature`, and `Disable-WindowsOptionalFeature`.

### Service

The service manager maps desired service `State` and `Startup` fields to Windows service status and start mode. It owns service lookup, comparison, startup-type changes, and start/stop behavior.

### Activation, Debloat, Office

Triggers wrap explicitly requested setup actions. They are separated from managers because repeated execution is not guaranteed to be harmless or convergent.

---

## Dependency boundaries

- `winspec.ps1` is the CLI and dispatch boundary.
- `state.psm1` owns provider discovery, state capture, comparison dispatch, declarative execution, trigger execution, and shared diff formatting.
- `utils.psm1` owns spec path resolution, spec import/loading, hashtable serialization, merge helpers, and admin helpers.
- `schema.psm1` owns specification shape validation.
- `logging.psm1` owns user-visible log formatting.
- Provider modules own subsystem-specific APIs and must not require central edits to be discovered.
- Trigger modules own non-idempotent actions and must remain opt-in.

Forbidden conceptually:

- Do not hide non-idempotent behavior inside declarative managers.
- Do not make provider discovery depend on hardcoded provider lists.
- Do not put user-facing spec examples into architecture; keep them in API docs.
- Do not require external config formats for the core spec language.

---

## Design principles

1. **Native**: use PowerShell `.ps1` hashtables as the configuration language.
2. **Composable**: let specs import and merge other specs.
3. **Idempotent where possible**: declarative managers test before changing state.
4. **Explicit where not idempotent**: triggers are named actions, not hidden side effects.
5. **Safe by default**: support `-DryRun`, sandbox mode, and optional checkpoints.
6. **Provider-local ownership**: subsystem logic belongs in provider modules.
7. **Convention over registration**: new providers are discovered by directory and metadata contract.
