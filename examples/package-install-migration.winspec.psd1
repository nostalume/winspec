@{
    SchemaVersion = 1
    Name = 'WinSpec Configuration'
    Description = 'Data-only replacement for the legacy PackageInstall trigger'

    Registry = @{
        Clipboard = @{ EnableHistory = $true }
        Desktop = @{ ForegroundLockTimeout = 0; MenuShowDelay = '400' }
        Explorer = @{ ShowFileExt = $true; ShowHidden = $true }
        Start = @{
            ShowRecentlyAddedApps = $false
            ShowRecommendations = $false
        }
        Taskbar = @{ ShowTaskViewButton = $true; ShowWidgets = $false }
        Theme = @{ AppTheme = 'dark'; SystemTheme = 'dark' }
    }

    Actions = @{
        installPackages = @{
            Use = 'Script'
            With = @{
                File = './scripts/install-packages.ps1'
                Args = @('-Roles', 'base,dev,backup')
            }
        }
        installDailyPackages = @{
            Use = 'Script'
            With = @{
                File = './scripts/install-packages.ps1'
                Args = @('-Roles', 'daily', '-IncludeInteractive')
                Interactive = $true
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
