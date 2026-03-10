# registry-maps.ps1 - Registry configuration maps
# Project-defined registry categories and properties

$Script:RegistryMaps = @{
    Clipboard = @{
        Path = "HKCU:\Software\Microsoft\Clipboard"
        Properties = @{
            EnableHistory = @{
                Name = "EnableClipboardHistory"
                Type = "DWord"
            }
        }
    }
    
    Explorer = @{
        Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Properties = @{
            ShowHidden = @{
                Name    = "Hidden"
                Type    = "DWord"
                Map     = @{ $true = 1; $false = 2 }
            }
            ShowFileExt = @{
                Name    = "HideFileExt"
                Type    = "DWord"
                Map     = @{ $true = 0; $false = 1 }
            }
        }
    }
    
    Theme = @{
        Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Properties = @{
            AppTheme = @{
                Name    = "AppsUseLightTheme"
                Type    = "DWord"
                Map     = @{ "light" = 1; "dark" = 0 }
            }
            SystemTheme = @{
                Name    = "SystemUsesLightTheme"
                Type    = "DWord"
                Map     = @{ "light" = 1; "dark" = 0 }
            }
        }
    }
    
    Desktop = @{
        Path = "HKCU:\Control Panel\Desktop"
        Properties = @{
            MenuShowDelay = @{
                Name = "MenuShowDelay"
                Type = "String"
            }
            ForegroundLockTimeout = @{
                Name = "ForegroundLockTimeout"
                Type = "DWord"
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
