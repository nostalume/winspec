# Migrating to schema version 1

This guide is for configurations created before the data-only State/Action/
Workflow model. Migration is an explicit cutover: there is no command alias,
executable-config loader, legacy provider importer, or automatic translation.

## Removed surfaces

| Removed surface | Current replacement |
| --- | --- |
| `pull` | `capture` |
| `push` | `apply` for State, or a named Workflow for ordered State and Actions |
| `trigger` | one named Action through `run` |
| `run -All` | one ordered named Workflow |
| `-ConfigPath` | `-ProviderPath` for external package roots |
| root `Providers` | command `-Providers` or `Apply.Providers` / `Capture.Providers` |
| `Import` | data-only `Include` |
| `Trigger` + `TriggerConfig` | `Actions` + optional `Workflows` |
| flat Script fields | `Use = 'Script'; With = @{ ... }` |
| executable `.ps1` configuration | data-only `.winspec.psd1` or `.winspec.json` |
| third-party `.psm1` trigger discovery | ordinary Script Action, or an advanced static provider package |
| activation `Method` | `MicrosoftActivation.With.Args` passed to the current upstream bootstrap |
| debloat `Profile` / `Options` | `WindowsDebloat.With.Args` passed unchanged |
| Office `Mode` / `ConfigurationFile` / `ToolPath` | `OfficeDeployment.With.Path` and `Cache` online-installer behavior |

Stale input fails with an admission diagnostic. This is intentional: silently
guessing old command or field meaning would hide effects.

## Convert an executable spec

A literal hashtable can often move to `.winspec.psd1` after adding
`SchemaVersion = 1`. Review every interpolation, command, type construction,
function call, imported module, and computed value. PSD1 must remain acceptable
to `Import-PowerShellDataFile`. Move intentional program behavior to a Script
Action.

Before:

```powershell
@{
    Providers = @('Registry')
    Trigger = @('PackageInstall')
    TriggerConfig = @{
        PackageInstall = @{ Roles = @('base', 'dev') }
    }
    Registry = @{ Explorer = @{ ShowHidden = $true } }
}
```

After:

```powershell
@{
    SchemaVersion = 1
    Registry = @{ Explorer = @{ ShowHidden = $true } }
    Actions = @{
        installPackages = @{
            Use = 'Script'
            With = @{
                File = './scripts/install.ps1'
                Args = @('-Roles', 'base,dev')
            }
        }
    }
    Workflows = @{
        setup = @{
            Steps = @(
                @{ Apply = @{ Providers = @('Registry') } }
                @{ Run = 'installPackages' }
            )
        }
    }
}
```

Provider selection moved out of the root. `apply` still never runs the Action;
the Workflow makes the order visible.

## Inspected user-config mapping

The inspected legacy configuration at
`%USERPROFILE%\.config\winspec\.winspec.ps1` contains desired Registry State,
selects Registry and Feature, and selects a `PackageInstall` trigger. Its package
module defines `base`, `daily`, `dev`, and `backup`, while both its default list
and Trigger configuration also name `utils`.

The migration is:

- retain the existing Registry categories and values;
- omit Feature because the legacy spec contains no desired Feature state;
- remove root `Providers` and select Registry in the Workflow;
- replace Trigger/TriggerConfig with `installPackages` and
  `installDailyPackages` Script Actions;
- preserve `base,dev,backup` in the noninteractive default;
- keep `daily` separate and explicitly interactive;
- omit and reject `utils`, because no role definition exists—do not invent a
  package list;
- keep the role table and Scoop/WinGet behavior in one `scripts\install.ps1`.

The repository records the complete proposed result as:

- [`examples/package-install-migration.winspec.psd1`](../examples/package-install-migration.winspec.psd1)
- [`examples/scripts/install-packages.ps1`](../examples/scripts/install-packages.ps1)

Copy and rename the script to `scripts\install.ps1` if using the exact target
layout below. Review its package catalog before any real run.

## Why Roles is one string

Windows PowerShell 5.1 `powershell.exe -File` cannot reliably bind an array-valued
script parameter from native command-line tokens. Use one comma-separated string
and split inside the script:

```powershell
param([string]$Roles = 'base,dev,backup')

$selectedRoles = @($Roles -split ',' | ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
```

Reject an empty selection and every unknown role before invoking a package tool.
`Force` and `IncludeInteractive` remain switch parameters and can be supplied in
`With.Args` or after CLI `--`.

Target Actions:

```powershell
Actions = @{
    installPackages = @{
        Use = 'Script'
        With = @{
            File = './scripts/install.ps1'
            Args = @('-Roles', 'base,dev,backup')
        }
    }
    installDailyPackages = @{
        Use = 'Script'
        With = @{
            File = './scripts/install.ps1'
            Args = @('-Roles', 'daily', '-IncludeInteractive')
            Interactive = $true
        }
    }
}
```

The ordinary Action can participate in Workflow dry-run as an opaque step and
returns bounded stdout/stderr plus exact script exit. The daily Action is excluded
from the default Workflow: an interactive Script inherits its terminal and cannot
be dry-run or rendered as JSON.

This simpler model intentionally gives up provider-owned semantic preview and a
structured package-by-package wire receipt. The script may still print per-package
objects; WinSpec treats them as captured text.

## Sandbox-file classification

The inspected legacy directory also contains:

```text
sandbox/profiles/.json
sandbox/profiles/default.json
sandbox/snapshots/default.json
```

The current spec loader does not read sandbox profile files. The inspected
snapshot contains null state and is not desired configuration. Back these files
up with the legacy config, but do not merge them into the version-1 spec. Remove
them only during a separately reviewed cutover after confirming no older WinSpec
installation still consumes them.

## Recoverable cutover checklist

The repository work does not modify the live user directory. When you later
authorize a cutover, use this sequence:

1. Record hashes and copy `.winspec.ps1`, `triggers\install.psm1`, and the
   sandbox files to a dated backup outside the directory being changed.
2. Create sibling candidates `.winspec.psd1` and `scripts\install.ps1`; do not
   overwrite the old files yet.
3. Compare the candidate Registry values and package role table with the backup.
4. Validate from both hosts:

   ```powershell
   pwsh.exe -NoProfile -File .\winspec\winspec.ps1 validate <candidate> -Json
   powershell.exe -NoProfile -File .\winspec\winspec.ps1 validate <candidate> -Json
   ```

5. Preview only the noninteractive Action and Workflow:

   ```powershell
   winspec run installPackages -Spec <candidate> -DryRun -Json
   winspec workflow setup -Spec <candidate> -DryRun -Json
   ```

6. Test `install.ps1` against fake `scoop` and `winget` commands, including an
   unknown role and one nonzero package-manager exit.
7. Rename the candidate into the default `.winspec.psd1` location. Keep the old
   `.winspec.ps1` and trigger module only in the backup; the current runtime will
   not load them.
8. Run `validate`, `status`, and `workflow setup -DryRun` from the default path.
9. Only then decide whether to execute a real package or State operation.

Rollback before a real effect means removing the new candidates and restoring
the exact hashed legacy files. That restores bytes for an older WinSpec version;
it does not make the current runtime accept executable configuration. After a
real package/State effect, file rollback alone cannot uninstall packages or undo
machine changes—use the responsible package/provider recovery procedure.

## Bundled trigger migration

The three former trigger goals remain built in as discoverable external Actions,
but their old option wrappers are removed:

```powershell
Actions = @{
    activate = @{
        Use = 'MicrosoftActivation'
        With = @{ Args = @('/HWID') }
    }
    debloat = @{
        Use = 'WindowsDebloat'
        With = @{ Args = @('-RunDefaultsLite', '-Silent') }
    }
    cacheOffice = @{
        Use = 'OfficeDeployment'
        With = @{ Path = './downloads/office'; Cache = $true }
    }
}
```

Activation/Debloat switch meaning belongs to the current upstream script. The
bundles do not pin its release or expected digest. Office downloads Microsoft's
online installer, checks the Microsoft publisher, and saves or starts it; it is
not an ODT XML configuration wrapper. See
[Bundled Action providers](bundled-providers.md) for the complete current
contracts.
