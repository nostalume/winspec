# Architecture

WinSpec separates three domain concepts:

- **State** is observable and convergent: capture, compare, then apply.
- **Action** is an explicit one-shot effect: run or preview one configured or
  ephemeral operation.
- **Workflow** is the sole owner of ordered multi-step execution.

This separation is public behavior, not directory style. `apply` cannot start an
Action, an Action cannot smuggle a sequence into the State engine, and only a
Workflow can coordinate State, Actions, checkpoint timing, and capture
publication.

```text
CLI grammar and result envelope
              |
    data-only spec composition ----- static provider manifests
              |                               |
       complete core admission                |
          /              \                     |
   State operation     Action operation -------+
 capture/compare/apply  Script or provider process
          \              /
           Workflow owner
  preflight -> checkpoint -> ordered effects -> receipts
```

## Owners and dependency direction

`winspec.ps1` owns command parsing, option compatibility, one public result
document, and process exit. It admits raw CLI data, then delegates one terminal
operation. It also projects the static catalog as `providers`, projects named
spec instances as `actions`, and constructs the empty-configuration ephemeral
Action selected by `run -Provider`. It does not contain provider policy.

`spec.psm1` owns data-only PSD1/JSON admission, Include composition, default path
resolution, safe serialization, and atomic publication. `schema.psm1` owns the
common version-1 root, State, Action, and Workflow shapes. A provider owns only
the semantic fields inside its admitted configuration.

`provider-runtime.psm1` owns static provider discovery and the external process
boundary: manifest validation, collision refusal, request identity, bounded
stdin/stdout/stderr, timeout/tree termination, and a per-invocation temporary
directory. It never imports provider code during discovery.

`state.psm1` routes capture/compare/apply to Registry, Service, Feature, or an
external State process. `comparison.psm1` owns general data comparison.
`windows.psm1` owns Windows capability checks. Individual core provider modules
own their Windows adapters. The State adapter normalizes both backends to logical
`Status`, `Output`, and `Diagnostics` receipts.

`actions.psm1` owns the core Script Action and delegates external Actions through
the process runtime. It decides local versus remote acquisition, digest policy,
argument order, interaction, output bounds, timeout, and temporary cleanup.

`workflow.psm1` owns total preflight, step order, one checkpoint boundary,
fail-fast behavior, `Skipped` receipts, and Capture publication. It consumes
State and Action owners; neither depends on Workflow.

`checkpoint.psm1` owns System Restore capability, creation, history, and rollback.
`sandbox.psm1` owns the legacy Mock/DryRun sandbox context; sandbox profiles are
not specification input.

## State flow

```text
spec + provider selection
  -> admit complete schema and capabilities
  -> capture selected current State
  -> compare desired/current
  -> Unchanged | Different
  -> optional checkpoint when change is needed
  -> apply each selected State owner
  -> aggregate provider receipts
```

Capture is read-only until publication. Publication writes a temporary sibling,
then atomically moves or replaces the admitted destination. Apply performs no
Action work. External State is captured again immediately before apply so its
provider owns the freshest semantic comparison.

Explicit provider names select exactly those State owners. Without names, a
spec-scoped operation selects only same-named State sections; unconstrained
capture/status selects core State only. Catalog construction alone therefore
cannot start an external State process. Any core resource failure makes the
provider receipt fail while preserving successful sibling output; there is no
pretend rollback.

No implicit elevation occurs. A checkpoint is neither automatic nor a universal
undo log; it is a separately admitted Windows restore effect.

## Script Action flow

A local Script path is resolved once from its owner. Dry-run checks existence and
returns an opaque plan. Run starts the current PowerShell host with argument-array
semantics. Noninteractive streams are drained concurrently into bounded buffers;
interactive execution transfers the terminal to the immediate child and waits.

A remote core Script accepts explicitly selected current HTTPS content and an
optional exact SHA-256 pin. HTTP requires a pin, and every unpinned redirect must
remain HTTPS. Acquisition streams through an 80 KiB buffer, is bounded to 16 MiB
and five redirects, hashes received bytes, never evaluates downloaded text in the
WinSpec process, and removes the temporary file.

An ordinary custom script stays one program plus one `Use = 'Script'` data
entry. It does not need a provider manifest or a second JSON envelope. This keeps
the most common extension path readable and debuggable from a normal shell.

## Packaged provider flow

```text
provider.json --read only--> catalog
configured Action or explicit run -Provider selection
  -> admit one { Use, With } Action (direct With is empty)
  -> select one provider operation
  -> create invocation temp directory
  -> start admitted entrypoint out of process
  -> write one bounded JSON request; close stdin
  -> drain bounded stdout/stderr under timeout
  -> validate one operation-specific JSON response and request identity
  -> terminate tree on timeout
  -> remove invocation temp directory
  -> return provider receipt
```

A package boundary earns its cost when the integration needs independent
configuration semantics, dependencies, protocol validation, resource lifecycle,
or its own visible child interaction. External providers are fully trusted code
with the caller's token. The process boundary is fault and protocol isolation,
not privilege isolation.

Catalog identity and Action identity are intentionally distinct. A provider is
an installed/discovered implementation; a named Action is durable spec data and
can be referenced by a Workflow; a direct provider Action lives for one command.
`providers` and `actions` observe the first two identities without execution.
Both configured and direct Actions converge at `actions.psm1`, so `run` remains
the only single-Action effect owner.

Default validation stops before the process boundary and reports packaged
configuration subjects as `NotRun`. Explicit `-PreviewActions` crosses that
boundary only for configured Action providers declaring `preview`; it never
substitutes preview for the absent external State validation operation.

Core providers use the same catalog names, operation vocabulary, and logical
result laws but not this process envelope. Their catalog protocol version is
`0`, meaning no wire protocol. Consequently process timeout, message-size,
stderr, and process-tree cleanup bounds do not apply to in-process core calls.
The public extension API remains protocol version 1.

The provider entrypoint is always noninteractive so stdout can remain a single
JSON response. A provider that needs prompts or UI starts and waits for a separate
visible child. A noninteractive child must have its streams captured or redirected
so it cannot corrupt the provider response.

## Why bundled launchers remain packages

MicrosoftActivation, WindowsDebloat, and OfficeDeployment remain external
packages because automatic static discovery and process isolation are valuable
for downloaded or installer code. Each package has one manifest, one entrypoint,
and a short pointer to the central
[bundled-provider guide](bundled-providers.md). Shared `common.psm1` owns only bounded download, common
argument/interaction validation, child execution, signature verification, and
protocol rendering.

The packages do not own upstream releases:

- no `sources.json`, GitHub release lookup, cache, version translation, or
  expected content digest;
- no copied activation-method or debloat-option catalog;
- no Office Deployment Tool XML wrapper.

Activation and Debloat point at upstream-owned current bootstrap URLs. The outer
download is streamed to the invocation directory, hashed for observed identity,
started as a child, and removed. The hash cannot prove the code was expected;
`digestVerified` is false. A bootstrap may fetch more code after it starts, which
is transitively trusted and outside the receipt.

Office preserves a different narrow goal: acquire the current Microsoft online
installer, require a Microsoft Authenticode publisher, save it to the admitted
`Path`, and optionally start it. The destination is durable user-requested output;
the invocation copy remains temporary.

## Workflow flow and failure ownership

Workflow first constructs the entire plan. It validates every tag, name, provider
kind, capability, capture output, source-overwrite conflict, preview, and
checkpoint requirement before the first effect. This prevents a late structural
error from following an earlier successful mutation.

If dry-run is selected, State steps only observe/compare, preview-capable Actions
return plans, opaque Actions remain explicitly opaque, and neither checkpoint nor
capture publication occurs.

During a real run, a requested checkpoint occurs once before the first effect.
Steps execute sequentially. A provider `Failed` result or thrown failure becomes
the failed step; later steps are recorded `Skipped`. WinSpec does not retry or
implicitly roll back because it cannot assume external Actions are idempotent or
reversible.

Each boundary adds context only where it owns translation:

- provider code returns provider diagnostics;
- process runtime translates malformed wire/process/timeout failures;
- Workflow attaches step identity and skip state;
- CLI renders the public diagnostic and exit.

Cleanup is lexical where possible. Download helpers remove partial files on
read/size/hash errors. Provider entrypoints remove downloaded children in
`finally`. The process runtime removes the whole invocation directory after
normal response, provider failure, or timeout, using a bounded retry for released
handles. Durable outputs such as Capture files and cached Office installers are
never confused with disposable artifacts.

## Trust, authority, and limits

Safety mechanisms are data-only configuration, complete common admission,
explicit selection, collision-free names, contained entrypoints, bounded
messages/downloads/output/time, atomic publication, and no implicit elevation.

They do not make arbitrary code safe. A local Script, external provider, fetched
bootstrap, or installer may change anything allowed by the caller's token. A
visible child may create detached or elevated descendants that outlive the
immediate receipt. Bootstrap-owned nested downloads are not measured by the outer
receipt. Operators must decide trust before selecting the Action.

## Performance model

Startup is intentionally module-based and single-process until an Action or
external State operation is selected. Discovery reads small static manifests and
does not start providers. Workflows run sequentially; no hidden concurrency or
retry multiplies effects.

Core remote Script and bundled downloads stream with an 80 KiB buffer and an
incremental SHA-256, so memory does not grow with the admitted file size. Protocol
and child output remain bounded in memory. There is no bundle metadata request or
release cache: a run performs one current-endpoint acquisition plus redirects and
whatever opaque work the selected upstream child itself performs.

## Reopening the architecture

Revisit these boundaries only when a concrete consumer needs a capability they
cannot express: resumable/cached acquisition with explicit freshness semantics,
interactive protocol messages rather than a child UI, parallel workflows with
effect conflict rules, or compatibility with a released schema/protocol version.
Historical decision records are intentionally absent; this document and the
normative API describe the current architecture.
