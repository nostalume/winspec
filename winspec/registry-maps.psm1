# registry-maps.ps1 - Registry configuration maps
# Project-defined registry categories and properties

$Script:RegistryMaps = @{
    Clipboard = @{
        Path          = "HKCU:\Software\Microsoft\Clipboard"
        Scope         = "HKCU"
        Description   = "Clipboard history preferences."
        RequiresAdmin = $false
        RestartHint   = "None"
        Properties    = @{
            EnableHistory = @{
                Name          = "EnableClipboardHistory"
                Type          = "DWord"
                Description   = "Enable Windows clipboard history."
                Default       = 0
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
        }
    }

    Explorer = @{
        Path          = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Scope         = "HKCU"
        Description   = "File Explorer advanced preferences."
        RequiresAdmin = $false
        RestartHint   = "Explorer"
        Properties    = @{
            ShowHidden = @{
                Name          = "Hidden"
                Type          = "DWord"
                Description   = "Show hidden files and folders."
                Default       = 2
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 2 }
            }
            ShowFileExt = @{
                Name          = "HideFileExt"
                Type          = "DWord"
                Description   = "Show known file extensions."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 0; $false = 1 }
            }
        }
    }

    Taskbar = @{
        Path          = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Scope         = "HKCU"
        Description   = "Windows taskbar user preferences."
        RequiresAdmin = $false
        RestartHint   = "Explorer"
        Properties    = @{
            Alignment = @{
                Name          = "TaskbarAl"
                Type          = "DWord"
                Description   = "Taskbar alignment on supported Windows versions."
                Default       = 1
                AllowedValues = @("left", "center")
                Map           = @{ "left" = 0; "center" = 1 }
            }
            ShowTaskViewButton = @{
                Name          = "ShowTaskViewButton"
                Type          = "DWord"
                Description   = "Show the Task View button."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
            SearchMode = @{
                Name          = "SearchboxTaskbarMode"
                Type          = "DWord"
                Description   = "Taskbar search presentation."
                Default       = 1
                AllowedValues = @("hidden", "icon", "box")
                Map           = @{ "hidden" = 0; "icon" = 1; "box" = 2 }
            }
            ShowWidgets = @{
                Name          = "TaskbarDa"
                Type          = "DWord"
                Description   = "Show the Widgets taskbar button."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
            ShowChat = @{
                Name          = "TaskbarMn"
                Type          = "DWord"
                Description   = "Show the Chat taskbar button where supported."
                Default       = 0
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
        }
    }

    Start = @{
        Path          = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Scope         = "HKCU"
        Description   = "Start menu user preferences."
        RequiresAdmin = $false
        RestartHint   = "Explorer"
        Properties    = @{
            ShowRecommendations = @{
                Name          = "Start_IrisRecommendations"
                Type          = "DWord"
                Description   = "Show recommendations in Start where supported."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
            ShowRecentlyAddedApps = @{
                Name          = "Start_TrackProgs"
                Type          = "DWord"
                Description   = "Show recently added apps in Start."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
            ShowRecentlyOpenedItems = @{
                Name          = "Start_TrackDocs"
                Type          = "DWord"
                Description   = "Show recently opened items in Start, Jump Lists, and File Explorer."
                Default       = 1
                AllowedValues = @($true, $false)
                Map           = @{ $true = 1; $false = 0 }
            }
        }
    }

    Theme = @{
        Path          = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Scope         = "HKCU"
        Description   = "Windows light/dark theme preferences."
        RequiresAdmin = $false
        RestartHint   = "None"
        Properties    = @{
            AppTheme = @{
                Name          = "AppsUseLightTheme"
                Type          = "DWord"
                Description   = "Default app theme."
                Default       = 1
                AllowedValues = @("light", "dark")
                Map           = @{ "light" = 1; "dark" = 0 }
            }
            SystemTheme = @{
                Name          = "SystemUsesLightTheme"
                Type          = "DWord"
                Description   = "Default system theme."
                Default       = 1
                AllowedValues = @("light", "dark")
                Map           = @{ "light" = 1; "dark" = 0 }
            }
        }
    }

    Desktop = @{
        Path          = "HKCU:\Control Panel\Desktop"
        Scope         = "HKCU"
        Description   = "Desktop and shell interaction timings."
        RequiresAdmin = $false
        RestartHint   = "SignOut"
        Properties    = @{
            MenuShowDelay = @{
                Name        = "MenuShowDelay"
                Type        = "String"
                Description = "Delay before menus are shown, in milliseconds."
                Default     = "400"
            }
            ForegroundLockTimeout = @{
                Name        = "ForegroundLockTimeout"
                Type        = "DWord"
                Description = "Foreground lock timeout in milliseconds."
                Default     = 200000
            }
        }
    }
}

function Get-RegistryMaps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category
    )

    if ($Category) {
        return $Script:RegistryMaps[$Category]
    }
    return $Script:RegistryMaps
}

Export-ModuleMember -Function Get-RegistryMaps
