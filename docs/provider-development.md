# Building WinSpec providers

This is the normative contract for external provider manifest schema version 1
and process protocol version 1. It is written for people extending WinSpec, not
only for repository maintainers. The [API reference](api.md) separately owns the
CLI, user specification, and command-result schemas.

WinSpec has one provider catalog with two execution backends:

- **core providers** are trusted, hard-coded, and run in process;
- **packaged providers** are discovered from a static `provider.json` and run
  out of process through protocol version 1.

`Registry`, `Service`, `Feature`, and `Script` are core providers.
`MicrosoftActivation`, `WindowsDebloat`, and `OfficeDeployment` are packaged
providers bundled with WinSpec. “Bundled” describes distribution and discovery,
not another protocol or an in-process privilege. Catalog `protocolVersion: 0`
means a core provider has no wire protocol.

This guide specifies only packaged-provider development. Use
[Built-in State providers](state-providers.md) for core declarative
configuration and [Bundled Action providers](bundled-providers.md) for the
shipped packages. Core and packaged providers share operation names and logical
result semantics, but process timeout, message-size, stderr, and cleanup bounds
apply only to packaged execution.

An external provider is a trusted program that WinSpec discovers from static
metadata and starts only when an operation selects it. The manifest is
declarative data; the provider program itself is an imperative adapter. A
**State** provider exposes declarative desired/current convergence. An **Action**
provider exposes one explicit effect.

## Choose the smallest extension

Use the core `Script` Action when one script already owns the work. It needs no
manifest, package, installation step, or JSON protocol:

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

Use an external **Action provider** when an integration needs its own stable
configuration schema, semantic preview, dependency checks, structured receipt,
or child-interaction policy. Use an external **State provider** when users should
declare desired state and WinSpec must capture, compare, and converge it.

Legacy “custom trigger” code normally becomes a Script Action. Build an Action
provider only when the additional provider-owned contract earns the package and
protocol boundary. WinSpec has no event, schedule, logon, or boot trigger type;
an external scheduler may invoke a named Action or Workflow.

## Package and discovery

A package is one immediate child directory under a provider root:

```text
my-providers/
  AcmeAction/
    provider.json
    provider.ps1
    README.md
```

WinSpec searches these roots in order:

1. packaged `winspec/providers/bundled`;
2. `%USERPROFILE%\.config\winspec\providers`;
3. each root passed with `-ProviderPath`.

Discovery is nonrecursive. `-ProviderPath` names the parent containing packages,
not an individual package. Discovery reads `provider.json` and checks that the
contained entrypoint exists. It never starts the entrypoint, imports its module,
searches `PATH`, installs dependencies, or probes capabilities.

Names are unique case-insensitively across core, bundled, user, and explicit
roots. A collision fails catalog construction rather than selecting by search
order. Confirm discovery without execution:

```powershell
winspec providers -ProviderPath .\my-providers -Json
```

The result identifies each provider's `name`, `kind`, `protocolVersion`,
`operations`, `entryPointType`, and `origin`.

Discovery is not configuration. After a spec names the provider through
`Actions.<name>.Use`, `winspec actions <spec> -ProviderPath .\my-providers`
lists that durable binding without executing the entrypoint.

## Manifest schema

An Action provider with semantic preview uses:

```json
{
  "schemaVersion": 1,
  "name": "AcmeAction",
  "kind": "Action",
  "protocolVersion": 1,
  "script": "provider.ps1",
  "operations": ["run", "preview"]
}
```

Manifest fields are:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Required integer `1`. |
| `name` | Required nonempty, case-insensitively unique string. |
| `kind` | Required `Action` or `State`. |
| `protocolVersion` | Required integer `1`. |
| `script` | Relative contained PowerShell entrypoint; mutually exclusive with `executable`. |
| `executable` | Relative contained native entrypoint; mutually exclusive with `script`. |
| `operations` | Required capability array governed by `kind`. |

Absolute, escaping, or missing entrypoints fail discovery. PowerShell
entrypoints run in the current PowerShell edition with `-NoProfile
-NonInteractive -File`. Native entrypoints run at their exact admitted path. The
package directory is the provider process working directory.

An Action must declare `run` and may declare `preview`. A State provider must
declare all of `capture`, `compare`, and `apply`. Unknown, duplicate, or
kind-incompatible operation names fail discovery.

## What `operation` means

The manifest's plural `operations` declares capabilities. The request's singular
`operation` tells one entrypoint which declared behavior WinSpec selected. It is
part of the provider-author API, not an end-user configuration field.

| User intent | Provider operation | Effect rule | Legal statuses |
| --- | --- | --- | --- |
| Action dry-run | `preview` | Admit the same configuration as `run`; do not mutate the target or durable state. Observation needed for a truthful plan is allowed. | `Planned`, `Failed` |
| Action execution | `run` | Perform the one explicitly selected effect. | `Succeeded`, `Failed` |
| State observation | `capture` | Observe complete provider-owned current state; do not mutate the target. | `Succeeded`, `Failed` |
| State comparison | `compare` | Compare desired configuration with supplied observation; do not mutate the target. | `Unchanged`, `Different`, `Failed` |
| State convergence | `apply` | Re-observe as needed and converge toward desired configuration. | `Succeeded`, `Unchanged`, `Failed` |

`Skipped` belongs to Workflow after an earlier step fails; providers cannot
return it. State dry-run invokes `capture` and `compare` but never `apply`.
Consequently the request has no separate mode field.

If an Action omits `preview`, WinSpec dry-run returns an opaque `Planned` result
without starting the provider. A provider therefore cannot use missing preview
as a request to run or validate through side effects.

## Process protocol

WinSpec starts one fresh process per operation. It writes exactly one UTF-8 JSON
request to stdin, closes stdin, drains bounded stdout and stderr, waits under the
operation timeout, and validates exactly one JSON response from stdout. Progress
and child logs belong on stderr. Additional stdout corrupts the response.

Every request has this envelope:

```json
{
  "protocolVersion": 1,
  "requestId": "2a4c0f59-1bb9-4ce4-8b52-cf40849ddb31",
  "operation": "run",
  "input": {}
}
```

`protocolVersion` is `1`. `requestId` is a fresh UUID that the response must
preserve exactly. `operation` is selected by WinSpec. `input` is an
operation-specific object.

Each input contains `executionPolicy`:

```json
{
  "timeoutSeconds": 300,
  "temporaryDirectory": "C:\\...\\winspec-provider-uuid"
}
```

Action input also supplies `workingDirectory`, the absolute directory of the
root specification that owns the Action, inside `executionPolicy`. The provider
process itself still starts in its package directory. `temporaryDirectory` is a
unique existing directory for disposable files. WinSpec removes it after a
valid response, process failure, malformed response, or timeout. A provider must
not place durable requested output there.

### Action requests

`run` and `preview` receive the same shape:

```json
{
  "configuration": {},
  "arguments": ["literal", "values"],
  "executionPolicy": {
    "timeoutSeconds": 300,
    "workingDirectory": "C:\\spec",
    "temporaryDirectory": "C:\\...\\winspec-provider-uuid"
  }
}
```

`configuration` is the Action's data-only `With` map, forwarded without
provider-specific interpretation. `arguments` contains CLI values after `--`,
in order and without shell-string evaluation. The provider owns admission,
defaults, relative-path meaning, effect behavior, and receipt fields for its
configuration. It should reject unknown configuration fields.

### State requests

`capture` receives desired provider configuration when a spec supplied it, or an
empty object when observation was requested without desired state:

```json
{
  "configuration": {},
  "executionPolicy": {
    "timeoutSeconds": 300,
    "temporaryDirectory": "C:\\...\\winspec-provider-uuid"
  }
}
```

It returns the complete observed representation in `output`. That output can be
published under the provider name and later supplied to `compare` as `observed`:

```json
{
  "configuration": { "desired": "values" },
  "observed": { "current": "values" },
  "executionPolicy": {
    "timeoutSeconds": 300,
    "temporaryDirectory": "C:\\...\\winspec-provider-uuid"
  }
}
```

`compare` owns semantic equality. On `Different`, its output convention is:

```json
{
  "differences": [
    { "path": "setting", "kind": "Changed", "desired": "on", "observed": "off" }
  ]
}
```

Difference item contents are provider-owned, but `differences` must be an array
because WinSpec aggregates it. `apply` receives `configuration` plus
`executionPolicy`, like `capture`. The earlier observation can become stale, so
`apply` must check current state again before mutation. Return `Unchanged` when
the target already converged. Do not assume WinSpec retries or rolls back an
uncertain partial effect.

## Response and diagnostics

Every successful protocol exchange returns exactly five fields:

```json
{
  "protocolVersion": 1,
  "requestId": "same-request-uuid",
  "status": "Succeeded",
  "output": {},
  "diagnostics": []
}
```

`output` must be an object. `diagnostics` must be an array; every item requires a
nonempty string `code` and `message` and may include provider-owned detail.
Unknown top-level response fields, invalid operation statuses, an identity or
protocol mismatch, malformed JSON, or oversized stdout are protocol failures.

An admitted provider failure uses `status: "Failed"`, returns useful diagnostics,
and exits the protocol process with code 0. A nonzero process exit means the
provider crashed or could not speak the protocol. WinSpec reports the bounded
stderr with that process failure. It does not reinterpret either failure as
success.

Protocol request and response stdout are limited to 4 MiB. Provider stderr is
limited to 1 MiB. WinSpec terminates the provider process tree when the timeout
expires. A detached or separately elevated descendant can escape that immediate
receipt and remains the provider's responsibility.

## Minimal Action provider

Create `AcmeAction/provider.json` with the Action manifest above, then create
`AcmeAction/provider.ps1`:

```powershell
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

function Write-Response(
    [string]$Status,
    [hashtable]$Output,
    [object[]]$Diagnostics
) {
    [ordered]@{
        protocolVersion = 1
        requestId = $request.requestId
        status = $Status
        output = $Output
        diagnostics = @($Diagnostics)
    } | ConvertTo-Json -Depth 20 -Compress
}

try {
    $configuration = $request.input.configuration
    foreach ($name in @($configuration.PSObject.Properties.Name)) {
        if ($name -notin @('Message')) {
            throw "UnknownConfigurationField: '$name'"
        }
    }
    $message = if ($configuration.Message) {
        [string]$configuration.Message
    }
    else {
        'hello'
    }

    if ($request.operation -eq 'preview') {
        Write-Response 'Planned' @{
            message = $message
            writesMessage = $true
        } @()
        return
    }
    if ($request.operation -ne 'run') {
        throw "UnsupportedOperation: '$($request.operation)'"
    }

    [Console]::Error.WriteLine("AcmeAction: $message")
    Write-Response 'Succeeded' @{ message = $message } @()
}
catch {
    $text = $_.Exception.Message
    Write-Response 'Failed' @{} @(@{
            code = ($text -split ':')[0]
            message = $text
        })
}
```

Select it from a data-only spec:

```powershell
@{
    SchemaVersion = 1
    Actions = @{
        greet = @{
            Use = 'AcmeAction'
            With = @{ Message = 'hello from the provider' }
        }
    }
}
```

```powershell
winspec run greet -Spec .\demo.winspec.psd1 `
    -ProviderPath .\my-providers -DryRun -Json
winspec run greet -Spec .\demo.winspec.psd1 `
    -ProviderPath .\my-providers -Json
```

Because this example provider has a useful empty configuration, it can also be
invoked as an ephemeral Action:

```powershell
winspec run -Provider AcmeAction -ProviderPath .\my-providers -DryRun
winspec run -Provider AcmeAction -ProviderPath .\my-providers -- from-cli
```

The direct form sends an empty `configuration` object and forwards values after
`--` as `arguments`. It is not an alternate provider protocol. Providers that
require structured `With` data should direct users to a named Action; WinSpec does
not define inline nested provider configuration on the command line.

Default `validate` keeps the entrypoint inert and reports configured packaged
Actions as `NotRun` under `results.validation`. Provider authors can test their
`preview` admission through explicit Action validation:

```powershell
winspec validate .\demo.winspec.psd1 -ProviderPath .\my-providers `
    -PreviewActions -Json
```

This starts trusted provider code. A conforming preview may observe dependencies
but must not mutate target or durable state. Missing `preview` is reported as
`Unavailable`; it is never translated into `run`.

## Minimal State provider

A State provider manifest changes `kind` and operations:

```json
{
  "schemaVersion": 1,
  "name": "FileContent",
  "kind": "State",
  "protocolVersion": 1,
  "script": "provider.ps1",
  "operations": ["capture", "compare", "apply"]
}
```

The provider below converges one fixed demonstration file beside its own
entrypoint. This keeps the example self-contained in the package being developed.
Its captured output uses the same `{ Content }` shape as desired configuration,
so a captured spec can be used again. Production providers should choose and
admit a real, enumerable resource domain rather than copying this path:

```powershell
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
$desired = $request.input.configuration
$path = Join-Path $PSScriptRoot 'example-state.txt'

function Observe-File {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return @{ Content = [IO.File]::ReadAllText($path) }
    }
    return @{ Content = $null }
}

function Write-Response(
    [string]$Status,
    [hashtable]$Output,
    [object[]]$Diagnostics
) {
    [ordered]@{
        protocolVersion = 1
        requestId = $request.requestId
        status = $Status
        output = $Output
        diagnostics = @($Diagnostics)
    } | ConvertTo-Json -Depth 20 -Compress
}

try {
    if ($desired.PSObject.Properties.Name -contains 'Content' -and
        $null -ne $desired.Content -and $desired.Content -isnot [string]) {
        throw 'InvalidContent: Content must be a string or null'
    }

    if ($request.operation -eq 'capture') {
        Write-Response 'Succeeded' (Observe-File) @()
        return
    }

    $observed = if ($request.operation -eq 'compare') {
        $request.input.observed
    }
    else {
        Observe-File
    }
    $equal = $observed.Content -ceq $desired.Content

    if ($request.operation -eq 'compare') {
        $status = if ($equal) { 'Unchanged' } else { 'Different' }
        $differences = if ($equal) {
            @()
        }
        else {
            @(@{
                    path = 'content'
                    kind = 'Changed'
                    desired = $desired.Content
                    observed = $observed.Content
                })
        }
        Write-Response $status @{ differences = $differences } @()
        return
    }
    if ($request.operation -ne 'apply') {
        throw "UnsupportedOperation: '$($request.operation)'"
    }
    if ($equal) {
        Write-Response 'Unchanged' @{} @()
        return
    }

    if ($null -eq $desired.Content) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    else {
        [IO.File]::WriteAllText($path, $desired.Content)
    }
    Write-Response 'Succeeded' @{ path = $path } @()
}
catch {
    $text = $_.Exception.Message
    Write-Response 'Failed' @{} @(@{
            code = ($text -split ':')[0]
            message = $text
        })
}
```

The user configuration is a root field named for the State provider:

```powershell
@{
    SchemaVersion = 1
    FileContent = @{
        Content = 'desired text'
    }
}
```

Use `status`, `diff`, `apply -DryRun`, then `apply`, selecting the package root
and provider explicitly while developing it. Outside development, a same-named
root section selects the State provider automatically when `-Providers` is
omitted. Merely installing or discovering the package never selects it.
`validate` admits only the common external State envelope without starting
provider code and reports its subject as `NotRun`. `-PreviewActions` does not
change that State result because protocol version 1 has no State validation
operation. Semantic State configuration errors therefore surface when the State
provider is selected for an operation.

```powershell
winspec status .\state.winspec.psd1 -Providers FileContent `
    -ProviderPath .\my-providers -Json
winspec diff .\state.winspec.psd1 -Providers FileContent `
    -ProviderPath .\my-providers -Json
winspec apply .\state.winspec.psd1 -Providers FileContent `
    -ProviderPath .\my-providers -DryRun -Json
winspec apply .\state.winspec.psd1 -Providers FileContent `
    -ProviderPath .\my-providers -Json
```

## Child interaction

The provider protocol entrypoint cannot prompt through WinSpec's terminal:
stdin is one JSON request, stdout is one JSON response, and stderr is bounded
diagnostic text. When an integration requires prompts, a GUI, or a separate
console, the provider may start and wait for its own visible child process. It
must keep that child's stdout away from provider stdout and describe completion
or detached descendants honestly in its output.

For a script that should directly inherit the current terminal, prefer a local
core Script Action with `Interactive = $true`. That path cannot use `-Json` or
dry-run.

## Remote scripts and trust

Core Script accepts an explicitly selected unpinned HTTPS URI. This trusts the
current content served by that source; it does not verify that the bytes match a
previous review:

```powershell
winspec run https://example.test/current.ps1 -DryRun
winspec run https://example.test/current.ps1
```

Add `-Sha256` for a direct immutable script, or `With.Sha256` for a named Script
Action. HTTP is accepted only with a digest. Unpinned redirects must remain
HTTPS. Remote Script acquisition follows at most five redirects, streams at most
16 MiB while hashing, executes out of process, and removes its temporary file.

Run receipts distinguish `Integrity = Unpinned` from `Pinned` and report the
requested/final URI, byte count, received SHA-256, and whether the digest was
verified. A hash observed only after download is audit identity, not proof that
the code was expected. External providers and their own downloads define their
separate trust policy; the process boundary is not a security sandbox.

## Test and release checklist

Test a provider through its packaged process boundary on Windows PowerShell 5.1
and PowerShell 7. Use a disposable package root, fake executable or localhost
server, bounded timeout, and sentinel output. Cover:

- discovery without entrypoint execution;
- every declared operation and legal status;
- unknown configuration and operation refusal;
- preview without target mutation;
- malformed request/response identity and fields;
- child failure, timeout, output bounds, and cleanup;
- stale State between `compare` and `apply`;
- partial effects without automatic retry or rollback; and
- zero residue outside admitted durable output.

Do not test against a live machine, package manager, licensing service, or
bundled-provider upstream. Reserve provider stdout for the response and verify it
parses as exactly one JSON document.

Manifest schema and protocol version are compatibility promises. Change a
provider-owned `configuration` or `output` schema with its own documented
migration. A future incompatible WinSpec envelope requires a new protocol version
rather than guessing peer behavior. Installing or publishing providers is outside
the current CLI; copy a reviewed package into the user root or supply its parent
with `-ProviderPath`.
