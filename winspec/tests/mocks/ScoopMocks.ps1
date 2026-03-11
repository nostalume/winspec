# tests/mocks/ScoopMocks.ps1 - Scoop mocking helpers for WinSpec tests
# Provides reusable mocks for Scoop package manager operations

# =============================================================================
# Scoop Detection Mocks
# =============================================================================

function Mock-ScoopInstalled {
    <#
    .SYNOPSIS
        Mocks Scoop as installed
    #>
    Mock Get-Command {
        return [PSCustomObject]@{
            Name = "scoop"
            Source = "scoop"
        }
    } -ParameterFilter { $Name -eq "scoop" }
}

function Mock-ScoopNotInstalled {
    <#
    .SYNOPSIS
        Mocks Scoop as not installed
    #>
    Mock Get-Command {
        return $null
    } -ParameterFilter { $Name -eq "scoop" }
}

# =============================================================================
# Scoop Export Mocks
# =============================================================================

function Mock-ScoopExportWithApps {
    <#
    .SYNOPSIS
        Mocks scoop export with specified apps
    .PARAMETER Apps
        Array of app objects to include in export
    .PARAMETER Buckets
        Array of bucket objects to include
    #>
    param(
        [array]$Apps = @(),
        [array]$Buckets = @()
    )
    
    $export = @{
        apps = $Apps
        buckets = $Buckets
    }
    
    Mock Invoke-Expression {
        return $export | ConvertTo-Json -Depth 10
    } -ParameterFilter { $_ -match "^scoop export" -or $_ -match "scoop export" }
}

function Mock-ScoopExportEmpty {
    <#
    .SYNOPSIS
        Mocks empty scoop export (no apps, no buckets)
    #>
    Mock Invoke-Expression {
        return '{"apps":[],"buckets":[]}'
    } -ParameterFilter { $_ -match "^scoop export" -or $_ -match "scoop export" }
}

function Mock-ScoopExportWithGitAndNode {
    <#
    .SYNOPSIS
        Mocks scoop export with git and nodejs installed
    #>
    Mock Invoke-Expression {
        return @'
{
    "buckets": [
        {"name": "main", "source": "https://github.com/ScoopInstaller/Main"}
    ],
    "apps": [
        {"name": "git", "version": "2.42.0", "bucket": "main", "architecture": "64bit"},
        {"name": "nodejs", "version": "20.0.0", "bucket": "main", "architecture": "64bit"}
    ]
}
'@
    } -ParameterFilter { $_ -match "^scoop export" -or $_ -match "scoop export" }
}

# =============================================================================
# Scoop Install Mocks
# =============================================================================

function Mock-ScoopInstallSuccess {
    <#
    .SYNOPSIS
        Mocks successful scoop install
    #>
    Mock Invoke-Expression {
        return "Installing app..."
    } -ParameterFilter { $_ -match "^scoop install" -and $_ -notmatch "uninstall" }
}

function Mock-ScoopInstallFailure {
    <#
    .SYNOPSIS
        Mocks failed scoop install
    .PARAMETER ErrorMessage
        Custom error message
    #>
    param(
        [string]$ErrorMessage = "Could not find app"
    )
    
    Mock Invoke-Expression {
        throw $ErrorMessage
    } -ParameterFilter { $_ -match "^scoop install" -and $_ -notmatch "uninstall" }
}

function Mock-ScoopInstallAlreadyInstalled {
    <#
    .SYNOPSIS
        Mocks scoop install when app already installed
    #>
    Mock Invoke-Expression {
        return "'app' is already installed"
    } -ParameterFilter { $_ -match "^scoop install" }
}

# =============================================================================
# Scoop Uninstall Mocks
# =============================================================================

function Mock-ScoopUninstallSuccess {
    <#
    .SYNOPSIS
        uninstall
    # Mocks successful scoop>
    Mock Invoke-Expression {
        return "Uninstalling app..."
    } -ParameterFilter { $_ -match "scoop uninstall" }
}

function Mock-ScoopUninstallFailure {
    <#
    .SYNOPSIS
        Mocks failed scoop uninstall
    #>
    Mock Invoke-Expression {
        throw "Could not uninstall app"
    } -ParameterFilter { $_ -match "scoop uninstall" }
}

# =============================================================================
# Scoop Bucket Mocks
# =============================================================================

function Mock-ScoopBucketList {
    <#
    .SYNOPSIS
        Mocks scoop bucket list
    #>
    Mock Invoke-Expression {
        return @'
[
    {"name": "main", "source": "https://github.com/ScoopInstaller/Main"},
    {"name": "extras", "source": "https://github.com/ScoopInstaller/extras"}
]
'@
    } -ParameterFilter { $_ -match "scoop bucket list" }
}

function Mock-ScoopBucketAdd {
    <#
    .SYNOPSIS
        Mocks scoop bucket add
    #>
    Mock Invoke-Expression {
        return "Adding bucket..."
    } -ParameterFilter { $_ -match "scoop bucket add" }
}

# =============================================================================
# Scoop Update Mocks
# =============================================================================

function Mock-ScoopUpdateSuccess {
    <#
    .SYNOPSIS
        Mocks successful scoop update
    #>
    Mock Invoke-Expression {
        return "Updating app..."
    } -ParameterFilter { $_ -match "scoop update" }
}

function Mock-ScoopUpdateFailure {
    <#
    .SYNOPSIS
        Mocks failed scoop update
    #>
    Mock Invoke-Expression {
        throw "Update failed"
    } -ParameterFilter { $_ -match "scoop update" }
}

function Mock-ScoopUpdateAll {
    <#
    .SYNOPSIS
        Mocks scoop update for all apps
    #>
    Mock Invoke-Expression {
        return "Updating all apps..."
    } -ParameterFilter { $_ -match "scoop update \*" -or $_ -match "scoop update --all" }
}

# =============================================================================
# Scoop Status/Info Mocks
# =============================================================================

function Mock-ScoopHome {
    <#
    .SYNOPSIS
        Mocks scoop home command
    #>
    Mock Invoke-Expression {
        return "C:\Users\test\scoop\apps\app"
    } -ParameterFilter { $_ -match "^scoop home" }
}

function Mock-ScoopInfo {
    <#
    .SYNOPSIS
        Mocks scoop info command
    #>
    param(
        [string]$Version = "1.0.0"
    )
    
    Mock Invoke-Expression {
        return @"
Name: test-app
Version: $Version
Description: Test application
"@
    } -ParameterFilter { $_ -match "^scoop info" }
}

# =============================================================================
# Scoop Cache Mocks
# =============================================================================

function Mock-ScoopCacheClean {
    <#
    .SYNOPSIS
        Mocks scoop cache clean
    #>
    Mock Invoke-Expression {
        return "Cleaning cache..."
    } -ParameterFilter { $_ -match "scoop cache" }
}

# =============================================================================
# Scoop Alias Mocks
# =============================================================================

function Mock-ScoopAliasList {
    <#
    .SYNOPSIS
        Mocks scoop alias list
    #>
    Mock Invoke-Expression {
        return @"
g  - scoop grep
c  - scoop cache
"@
    } -ParameterFilter { $_ -match "scoop alias list" }
}

# =============================================================================
# Scoop Hold/Unhold Mocks
# =============================================================================

function Mock-ScoopHold {
    <#
    .SYNOPSIS
        Mocks scoop hold
    #>
    Mock Invoke-Expression {
        return "Holding app..."
    } -ParameterFilter { $_ -match "scoop hold" }
}

function Mock-ScoopUnhold {
    <#
    .SYNOPSIS
        Mocks scoop unhold
    #>
    Mock Invoke-Expression {
        return "Unholding app..."
    } -ParameterFilter { $_ -match "scoop unhold" }
}

# =============================================================================
# Scoop Reset Mocks
# =============================================================================

function Mock-ScoopReset {
    <#
    .SYNOPSIS
        Mocks scoop reset
    #>
    Mock Invoke-Expression {
        return "Resetting app..."
    } -ParameterFilter { $_ -match "scoop reset" }
}

# Export functions
Export-ModuleMember -Function @(
    'Mock-ScoopInstalled',
    'Mock-ScoopNotInstalled',
    'Mock-ScoopExportWithApps',
    'Mock-ScoopExportEmpty',
    'Mock-ScoopExportWithGitAndNode',
    'Mock-ScoopInstallSuccess',
    'Mock-ScoopInstallFailure',
    'Mock-ScoopInstallAlreadyInstalled',
    'Mock-ScoopUninstallSuccess',
    'Mock-ScoopUninstallFailure',
    'Mock-ScoopBucketList',
    'Mock-ScoopBucketAdd',
    'Mock-ScoopUpdateSuccess',
    'Mock-ScoopUpdateFailure',
    'Mock-ScoopUpdateAll',
    'Mock-ScoopHome',
    'Mock-ScoopInfo',
    'Mock-ScoopCacheClean',
    'Mock-ScoopAliasList',
    'Mock-ScoopHold',
    'Mock-ScoopUnhold',
    'Mock-ScoopReset'
)
