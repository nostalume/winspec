# Bundled Action providers

This is the normative operator contract for the three packaged Action providers
shipped with WinSpec: `MicrosoftActivation`, `WindowsDebloat`, and
`OfficeDeployment`.

They are automatically discovered from the bundle but remain inert until a named
Action, a direct `run -Provider` call, or a Workflow `Run` step selects one. Each
is a normal protocol-version-1 packaged provider running outside the WinSpec
process.
Bundling changes installation and discovery only; it does not grant extra
privilege or create a security sandbox.

`winspec providers` lists these implementations. `winspec actions [spec]` lists
the named instances configured in one spec. A one-off call can select a bundled
implementation directly with `winspec run -Provider <name>`; this creates an
ephemeral Action with empty `With`. Reusable or non-default `With` values remain a
named Action.

## Shared execution contract

Dry-run uses the provider's `preview` operation. It validates the provider's
small `With` map and reports the planned endpoint, destination or arguments
without network access, target mutation, directory creation, or child execution.

Real execution uses the caller's existing OS token. WinSpec never prompts for
elevation. Downloads follow at most five redirects, stream into a unique
invocation directory, and are hashed incrementally. The provider process and its
immediate child are subject to `-TimeoutSeconds` (default 300, range 1–3600).
Temporary outer downloads are removed after success or failure.

Noninteractive immediate-child stdout and stderr are each retained up to 1 MiB
and report truncation. An immediate nonzero child exit makes the Action
`Failed`. Detached or separately elevated descendants may outlive that receipt.

## MicrosoftActivation

This provider launches the current Microsoft Activation Scripts bootstrap:

```text
https://get.activated.win/
```

Configure it as:

```powershell
Actions = @{
    activateWindows = @{
        Use = 'MicrosoftActivation'
        With = @{
            Args = @('/HWID')
            Interactive = $false
        }
    }
}
```

`With` accepts only:

| Field | Type and default | Meaning |
| --- | --- | --- |
| `Args` | string array, default empty | Passed literally to the current bootstrap. |
| `Interactive` | Boolean, default false | Lets the bootstrap child own a visible UI/terminal. |

CLI values after `--` append after `With.Args`. WinSpec does not define
activation methods or copy the upstream switch catalog; consult the
[Microsoft Activation Scripts project](https://github.com/massgravel/Microsoft-Activation-Scripts)
for the behavior of current arguments.

Preview reports `requestedUri`, final argument order, `interactive`,
`downloadsCurrentCode = true`, and `opaque = true`.

Run downloads at most 16 MiB, calculates the received SHA-256, and starts the
downloaded `.ps1` through the current PowerShell host. Downloaded text is never
evaluated, dot-sourced, or imported in the provider process. Interactive mode
returns no captured child streams.

Activation changes licensing state. Use it only when licenses and machine policy
permit and begin from a shell with any privilege the upstream operation needs.

## WindowsDebloat

This provider launches the current Win11Debloat bootstrap:

```text
https://debloat.raphi.re/
```

Configure it as:

```powershell
Actions = @{
    debloat = @{
        Use = 'WindowsDebloat'
        With = @{
            Args = @('-RunDefaultsLite', '-Silent')
            Interactive = $false
        }
    }
}
```

Its fields, defaults, argument ordering, 16 MiB bound, child execution, and
interaction behavior are identical to `MicrosoftActivation`. WinSpec defines no
profile, mode, or switch mapping. Consult the
[Win11Debloat project](https://github.com/Raphire/Win11Debloat) for current
arguments and effects.

Debloating can remove applications and change policies. Review the current
upstream behavior and consider a Workflow checkpoint when one Windows restore
point should precede a larger ordered setup. Neither this provider nor WinSpec
implicitly creates a second checkpoint or rolls back.

## Current-script receipt and trust boundary

MicrosoftActivation and WindowsDebloat intentionally do not pin an upstream
release, fetched version, or expected digest: selecting them means selecting the
newest content served by their fixed current endpoint.

Their run output includes:

- requested and final URI;
- received byte count and SHA-256;
- `digestVerified = false`;
- argument order and interaction choice;
- `captureMode`, duration, immediate exit, stdout/stderr, and truncation flags.

`receivedSha256` identifies what arrived after download; it does not prove that
the bytes matched an earlier review. These bootstrap scripts can download and
execute further content. Nested bytes, repositories, archives, processes, and
their cleanup are outside WinSpec's byte-level receipt and acquisition bounds.

## OfficeDeployment

OfficeDeployment preserves a narrower goal: download Microsoft's current online
installer to an explicit directory, verify its Microsoft publisher, then save it
or start it. It is not an Office Deployment Tool XML wrapper.

The current endpoint is:

```text
https://c2rsetup.officeapps.live.com/c2r/download.aspx?ProductreleaseID=O365ProPlusRetail&platform=x64&language=en-us&version=O16GA
```

The query selects O365ProPlusRetail, x64, en-us, and the Office 16 generation. It
is not a WinSpec release pin or fetched-file version promise.

```powershell
Actions = @{
    cacheOffice = @{
        Use = 'OfficeDeployment'
        With = @{
            Path = './downloads/office'
            Cache = $true
        }
    }
}
```

`With` accepts only:

| Field | Type and default | Meaning |
| --- | --- | --- |
| `Path` | nonempty directory string; owning spec directory | Relative paths resolve from the root spec. |
| `Cache` | Boolean, default false | True saves only; false saves, starts, and waits. |

CLI `--` arguments are invalid. The durable destination is always
`Path\OfficeSetup.exe`. Existing content is overwritten only after the new
download passes signature validation.

Preview reports the requested URI, resolved directory/file, cache choice,
`downloadsCurrentInstaller = true`, `verifiesMicrosoftPublisher = true`, and
`opaque = true`.

Run streams at most 64 MiB, calculates SHA-256, and requires Authenticode status
`Valid` with a signer subject containing `O=Microsoft Corporation`. The
temporary copy is removed after it is copied to the admitted destination.
`Cache = true` stops there. The default starts `OfficeSetup.exe`
noninteractively and waits for its immediate exit.

The receipt includes requested/final URI, received bytes/SHA-256,
`digestVerified = false`, `publisherVerified = true`, destination, and cache
choice. When started it also includes duration, immediate exit, streams, and
truncation. Publisher validation authenticates the signer but does not pin an
installer version.

The installer may create UI, download Office payloads, create descendants, and
change installed products beyond WinSpec's receipt. `Cache = true` is the
inspectable acquisition path. WinSpec does not expose product/language/version
configuration, elevate, retry, or uninstall.

## Run and Workflow examples

```powershell
winspec run -Provider MicrosoftActivation -DryRun -- /HWID
winspec run -Provider WindowsDebloat -DryRun -- -RunDefaultsLite -Silent
winspec run activateWindows -Spec .\machine.winspec.psd1 -DryRun -Json
winspec run debloat -Spec .\machine.winspec.psd1
winspec run cacheOffice -Spec .\machine.winspec.psd1 -Json
```

Default `validate` reports these named provider configurations as `NotRun`
without starting them. `validate -PreviewActions` explicitly starts each
preview-capable configured Action, validates its `With` map without network
access, and reports `Valid` or `Invalid`. An opaque provider would be
`Unavailable`; all three maintained bundled providers currently declare preview.

A Workflow can make checkpoint and ordering explicit:

```powershell
Workflows = @{
    setup = @{
        Checkpoint = $true
        Steps = @(
            @{ Apply = @{ Providers = @('Registry') } }
            @{ Run = 'debloat' }
        )
    }
}
```

Review preview output, upstream behavior, privileges, and recovery before a real
run. Tests and examples must use disposable copies and local fixtures; they must
never contact these production endpoints.

See [Using WinSpec](usage.md#use-bundled-actions) for short recipes and
[Building WinSpec providers](provider-development.md) only when developing a
different packaged integration.
