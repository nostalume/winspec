# WinSpec

WinSpec is a declarative Windows setup tool with a deliberately small execution
model: describe convergent machine **State**, name explicit one-shot **Actions**,
and use a **Workflow** when those operations must run in order.

Configuration is data, never code. WinSpec reads `.psd1` and `.json`; it never
loads a `.ps1` spec, imports a third-party module during discovery, searches
`PATH` for a provider, elevates itself, or turns an arbitrary command string into
an implicit workflow.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Windows for live Registry, Service, Feature, checkpoint, and rollback work.
- Whatever privileges the selected operation itself requires. Start the shell
  with those privileges when appropriate; WinSpec does not request elevation.

The source checkout can be invoked directly:

```powershell
.\winspec\winspec.ps1 help
```

If installed through Scoop, use `winspec` in the examples instead.

`winspec help` introduces every command. Use `winspec help run` or
`winspec run -Help` for a command's selection forms, effects, default, and minimal
example.

## PSD1 or JSON?

Use PSD1 for a hand-maintained spec: it supports comments and PowerShell's
compact hashtable syntax while `Import-PowerShellDataFile` keeps it data-only.
Use JSON for generated files or another tool's interchange format. Both formats
have the same schema and effect model. Neither may contain executable code.

With no explicit path, WinSpec reads
`%USERPROFILE%\.config\winspec\.winspec.psd1`, falling back to
`.winspec.json`. If both exist, selection is ambiguous and fails. WinSpec does
not search parent directories.

## Five-minute example

Create `demo\scripts\hello.ps1`:

```powershell
param([string]$Name)
"Hello, $Name"
```

Create `demo\machine.winspec.psd1` beside the `scripts` directory:

```powershell
@{
    SchemaVersion = 1
    Name = 'Example workstation'

    Registry = @{
        Explorer = @{
            ShowHidden = $true
            ShowFileExt = $true
        }
    }

    Actions = @{
        hello = @{
            Use = 'Script'
            With = @{
                File = './scripts/hello.ps1'
                Args = @('from-spec')
            }
        }
    }

    Workflows = @{
        setup = @{
            Steps = @(
                @{ Apply = @{ Providers = @('Registry') } }
                @{ Run = 'hello' }
            )
        }
    }
}
```

Use the safety ladder before changing the machine:

```powershell
$spec = '.\demo\machine.winspec.psd1'
.\winspec\winspec.ps1 validate $spec
.\winspec\winspec.ps1 actions $spec
.\winspec\winspec.ps1 status $spec -Providers Registry
.\winspec\winspec.ps1 diff $spec -Providers Registry
.\winspec\winspec.ps1 apply $spec -Providers Registry -DryRun
.\winspec\winspec.ps1 apply $spec -Providers Registry
.\winspec\winspec.ps1 run hello -Spec $spec -- from-cli
.\winspec\winspec.ps1 workflow setup -Spec $spec -DryRun
```

`validate` admits the common and core data shape without starting packaged
providers; its result reports provider-validation coverage. Add
`-PreviewActions` only when configured Action providers should execute their
non-mutating preview operation. `actions` lists the spec's named Action instances
without running them. `status` observes selected State.
`diff` exits 1 when desired and observed State differ. `apply -DryRun` computes a
plan without changing State; `apply` converges State but never runs Actions.
`run` executes exactly one Action. `workflow` is the only surface that sequences
State and Actions. In the example, `from-cli` is appended after `from-spec`.

## Capture and checkpoints

Capture publishes observed State as another data-only spec:

```powershell
.\winspec\winspec.ps1 capture .\observed.winspec.psd1 -Providers Registry
```

Existing output requires `-Force`. Publication uses a temporary sibling and an
atomic replacement. To request one Windows restore point immediately before a
changing `apply`, add `-Checkpoint`. A Workflow may set `Checkpoint = $true` to
create one checkpoint before its first effect. System Restore must already be
available and the caller must already be privileged.

## Actions and providers

Registry, Service, Feature, and Script are trusted core providers. `Script` is
the normal extension point: point it at one local `.ps1`, pass an argument array,
and choose captured or interactive execution explicitly.

MicrosoftActivation, WindowsDebloat, and OfficeDeployment are bundled external
Action packages. They are automatically discoverable but inert until an Action
selects them. Each runs in a separate provider process. Activation and Debloat
download their official current bootstrap script at run time; WinSpec does not
pin an upstream release or expected digest. The receipt records the bytes that
arrived, but that is audit identity after download—not pre-execution
verification. Those bootstraps can fetch additional content outside WinSpec's
byte-level receipt. Review the
[bundled-provider guide](docs/bundled-providers.md) before use.

`winspec providers` lists discovered implementations; `winspec actions [spec]`
lists configured Action instances. A provider with useful empty configuration can
also be selected once without editing a spec:

```powershell
winspec run -Provider MicrosoftActivation -DryRun -- /HWID
```

This is an ephemeral Action with empty `With`. Reusable/provider-configured and
Workflow operations continue to use a named `{ Use, With }` Action.

An external provider package is for advanced integrations that need their own
validation, lifecycle, or child interaction. Ordinary custom scripts do not need
a manifest or JSON envelope. The dedicated [provider author guide](docs/provider-development.md)
defines the manifest, operations, process API, and complete Action and State
examples.

## Interaction, output, and trust

Noninteractive scripts and providers have bounded stdout/stderr, a timeout, and
an exact immediate-child exit in the result. Interactive local Script Actions
inherit the terminal, cannot use `-Json` or `-DryRun`, and remain responsible for
their own prompts or visible child processes. A provider entrypoint is always a
noninteractive protocol process, but it may launch and wait for a visible child.

`-Json` reserves stdout for exactly one result document, suitable for automation:

```powershell
$result = .\winspec\winspec.ps1 providers -Json | ConvertFrom-Json
$result.results.providers.name
```

External providers and downloaded scripts are trusted programs with the caller's
OS token. Process isolation protects the WinSpec process and wire contract; it is
not a security sandbox. No provider runs merely because it was discovered.

An explicitly selected HTTPS Script may fetch current unpinned content. Add an
optional SHA-256 when exact reviewed bytes must be enforced; plain HTTP requires
that pin. Results distinguish pinned verification from an observed digest.

## Documentation

- [Usage guide](docs/usage.md): capture/apply recipes, scripts, workflows,
  bundled Actions, results, and troubleshooting.
- [API reference](docs/api.md): the normative CLI, user schema, limits, and exits.
- [Built-in State providers](docs/state-providers.md): Registry, Service, and
  Feature configuration and behavior.
- [Bundled Action providers](docs/bundled-providers.md): shipped integrations,
  trust boundaries, effects, and receipts.
- [Provider author guide](docs/provider-development.md): discovery, manifests, operations,
  process protocol, complete examples, and extension tests.
- [Architecture](docs/architecture.md): ownership, effect flow, trust,
  lifecycle, failure, and cleanup.
- [Development](docs/development.md): supported hosts, repository tests,
  fake-effect rules, and completion checks.
- [Migration](docs/migration.md): removed commands and an end-to-end conversion
  from legacy Trigger configuration.

Runnable examples are under [`examples`](examples). Tests never contact the
real activation, debloat, or Office endpoints and never perform live machine,
package, restore-point, elevation, or licensing effects.

License: MIT.
