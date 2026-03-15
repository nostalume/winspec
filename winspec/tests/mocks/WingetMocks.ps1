# tests/mocks/WingetMocks.ps1 - Winget mocking helpers for WinSpec tests
# Provides reusable mocks for Winget package manager operations

# =============================================================================
# Winget Detection Mocks
# =============================================================================

function Mock-WingetInstalled {
    <#
    .SYNOPSIS
        Mocks Winget as installed
    #>
    Mock Get-Command {
        return [PSCustomObject]@{
            Name = "winget"
            Source = "winget"
        }
    } -ParameterFilter { $Name -eq "winget" }
}

function Mock-WingetNotInstalled {
    <#
    .SYNOPSIS
        Mocks Winget as not installed
    #>
    Mock Get-Command {
        return $null
    } -ParameterFilter { $Name -eq "winget" }
}

# =============================================================================
# Winget List/Export Mocks
# =============================================================================

function Mock-WingetExportWithApps {
    <#
    .SYNOPSIS
        Mocks winget export with specified packages (JSON format) to file
    .PARAMETER Packages
        Array of package objects to include in export
    #>
    param([array]$Packages = @())
    
    $pkgArray = @()
    foreach ($pkg in $Packages) {
        $pkgArray += @{ PackageIdentifier = $pkg.Id }
    }
    
    $jsonObj = @{
        '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'
        CreationDate = '2024-01-15T10:30:00Z'
        Sources = @(
            @{
                Packages = $pkgArray
                SourceDetails = @{
                    Argument = 'https://cdn.winget.microsoft.com/cache'
                    Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
                    Name = 'winget'
                    Type = 'Microsoft.PreIndexed.Package'
                }
            }
        )
        WinGetVersion = '1.6.3133'
    }
    
    $jsonOutput = $jsonObj | ConvertTo-Json -Depth 10
    
    Mock Invoke-Expression {
        # Handle -o <file> parameter
        if ($_ -match 'winget export.*-o\s+(\S+)') {
            $matches[1] | Out-File -FilePath $matches[1] -Encoding utf8
        }
        return $jsonOutput
    } -ParameterFilter { $_ -match "winget export" }
}

function Mock-WingetExportEmpty {
    <#
    .SYNOPSIS
        Mocks empty winget export (no packages)
    #>
    $jsonObj = @{
        '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'
        CreationDate = '2024-01-15T10:30:00Z'
        Sources = @()
        WinGetVersion = '1.6.3133'
    }
    
    $jsonOutput = $jsonObj | ConvertTo-Json
    
    Mock Invoke-Expression {
        if ($_ -match 'winget export.*-o\s+(\S+)') {
            $matches[1] | Out-File -FilePath $matches[1] -Encoding utf8
        }
        return $jsonOutput
    } -ParameterFilter { $_ -match "winget export" }
}

function Mock-WingetExportWithGitAndVSCode {
    <#
    .SYNOPSIS
        Mocks winget export with git, vscode and other packages (JSON format)
    #>
    $jsonObj = @{
        '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'
        CreationDate = '2024-01-15T10:30:00Z'
        Sources = @(
            @{
                Packages = @(
                    @{ PackageIdentifier = 'Git.Git' },
                    @{ PackageIdentifier = 'Microsoft.VisualStudioCode' },
                    @{ PackageIdentifier = 'OpenJS.NodeJSLTS' },
                    @{ PackageIdentifier = 'Python.Python.3.11' },
                    @{ PackageIdentifier = 'Docker.DockerDesktop' }
                )
                SourceDetails = @{
                    Argument = 'https://cdn.winget.microsoft.com/cache'
                    Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
                    Name = 'winget'
                    Type = 'Microsoft.PreIndexed.Package'
                }
            }
        )
        WinGetVersion = '1.6.3133'
    }
    
    $jsonOutput = $jsonObj | ConvertTo-Json -Depth 10
    
    Mock Invoke-Expression {
        if ($_ -match 'winget export.*-o\s+(\S+)') {
            $matches[1] | Out-File -FilePath $matches[1] -Encoding utf8
        }
        return $jsonOutput
    } -ParameterFilter { $_ -match "winget export" }
}

function Mock-WingetExportWithSources {
    <#
    .SYNOPSIS
        Mocks winget export with multiple sources
    .PARAMETER Packages
        Hashtable with source names as keys and package arrays as values
    #>
    param([hashtable]$PackagesBySource = @{})
    
    $sources = @()
    
    foreach ($sourceName in $PackagesBySource.Keys) {
        $pkgs = $PackagesBySource[$sourceName]
        $pkgArray = @()
        foreach ($pkgId in $pkgs) {
            $pkgArray += @{ PackageIdentifier = $pkgId }
        }
        
        $sourceUrl = switch ($sourceName) {
            'winget' { 'https://cdn.winget.microsoft.com/cache' }
            'ustc' { 'https://mirrors.ustc.edu.cn/winget-source' }
            'msstore' { 'https://storeedgefd.dsx.mp.microsoft.com/v9.0' }
            default { 'https://example.com/source' }
        }
        
        $sources += @{
            Packages = $pkgArray
            SourceDetails = @{
                Argument = $sourceUrl
                Identifier = "Microsoft.Winget.Source_$sourceName"
                Name = $sourceName
                Type = 'Microsoft.PreIndexed.Package'
            }
        }
    }
    
    $jsonObj = @{
        '$schema' = 'https://aka.ms/winget-packages.schema.2.0.json'
        CreationDate = '2024-01-15T10:30:00Z'
        Sources = $sources
        WinGetVersion = '1.6.3133'
    }
    
    $jsonOutput = $jsonObj | ConvertTo-Json -Depth 10
    
    Mock Invoke-Expression {
        if ($_ -match 'winget export.*-o\s+(\S+)') {
            $matches[1] | Out-File -FilePath $matches[1] -Encoding utf8
        }
        return $jsonOutput
    } -ParameterFilter { $_ -match "winget export" }
}

# =============================================================================
# Winget Install Mocks
# =============================================================================

function Mock-WingetInstallSuccess {
    <#
    .SYNOPSIS
        Mocks successful winget install
    #>
    Mock Invoke-Expression {
        return "Found [$($args[0])] Version [1.0.0]
Downloading url
Installing package..."
    } -ParameterFilter { $_ -match "^winget install" -and $_ -notmatch "uninstall" }
}

function Mock-WingetInstallFailure {
    <#
    .SYNOPSIS
        Mocks failed winget install
    .PARAMETER ErrorMessage
        Custom error message
    #>
    param(
        [string]$ErrorMessage = "No package found matching input criteria"
    )
    
    Mock Invoke-Expression {
        throw $ErrorMessage
    } -ParameterFilter { $_ -match "^winget install" -and $_ -notmatch "uninstall" }
}

function Mock-WingetInstallAlreadyInstalled {
    <#
    .SYNOPSIS
        Mocks winget install when package already installed
    #>
    Mock Invoke-Expression {
        return "No applicable upgrade found"
    } -ParameterFilter { $_ -match "^winget install" }
}

# =============================================================================
# Winget Uninstall Mocks
# =============================================================================

function Mock-WingetUninstallSuccess {
    <#
    .SYNOPSIS
        Mocks successful winget uninstall
    #>
    Mock Invoke-Expression {
        return "Uninstalling package..."
    } -ParameterFilter { $_ -match "winget uninstall" }
}

function Mock-WingetUninstallFailure {
    <#
    .SYNOPSIS
        Mocks failed winget uninstall
    #>
    Mock Invoke-Expression {
        throw "Failed to uninstall package"
    } -ParameterFilter { $_ -match "winget uninstall" }
}

# =============================================================================
# Winget Update Mocks
# =============================================================================

function Mock-WingetUpdateSuccess {
    <#
    .SYNOPSIS
        Mocks successful winget update
    #>
    Mock Invoke-Expression {
        return "Updating package..."
    } -ParameterFilter { $_ -match "^winget upgrade" }
}

function Mock-WingetUpdateFailure {
    <#
    .SYNOPSIS
        Mocks failed winget update
    #>
    Mock Invoke-Expression {
        throw "Update failed"
    } -ParameterFilter { $_ -match "^winget upgrade" }
}

function Mock-WingetUpdateAll {
    <#
    .SYNOPSIS
        Mocks winget upgrade for all packages
    #>
    Mock Invoke-Expression {
        return "Upgrading all packages..."
    } -ParameterFilter { $_ -match "winget upgrade --all" -or $_ -match "winget upgrade\s+$" }
}

# =============================================================================
# Winget Search Mocks
# =============================================================================

function Mock-WingetSearchFound {
    <#
    .SYNOPSIS
        Mocks winget search with results found
    #>
    param(
        [string]$PackageId = "TestPackage"
    )
    
    Mock Invoke-Expression {
        return @"
Name                          Id                           Version      Available
----                          --                           -------      ---------
Test Package                  $PackageId                    1.0.0       
"@
    } -ParameterFilter { $_ -match "^winget search" }
}

function Mock-WingetSearchNotFound {
    <#
    .SYNOPSIS
        Mocks winget search with no results
    #>
    Mock Invoke-Expression {
        return "No packages found"
    } -ParameterFilter { $_ -match "^winget search" }
}

# =============================================================================
# Winget Source Mocks
# =============================================================================

function Mock-WingetSourceList {
    <#
    .SYNOPSIS
        Mocks winget source list
    #>
    Mock Invoke-Expression {
        return @"
Sources
------
winget
msstore

"@
    } -ParameterFilter { $_ -match "^winget source list" }
}

function Mock-WingetSourceAdd {
    <#
    .SYNOPSIS
        Mocks winget source add
    #>
    Mock Invoke-Expression {
        return "Adding source..."
    } -ParameterFilter { $_ -match "^winget source add" }
}

# =============================================================================
# Winget Info Mocks
# =============================================================================

function Mock-WingetShow {
    <#
    .SYNOPSIS
        Mocks winget show command
    #>
    param(
        [string]$PackageId = "TestPackage"
    )
    
    Mock Invoke-Expression {
        return @"
Found $PackageId [winget]
Version:    1.0.0
Publisher: Test Publisher
Description: Test package description
"@
    } -ParameterFilter { $_ -match "^winget show" }
}

# =============================================================================
# Winget List Versions Mocks
# =============================================================================

function Mock-WingetListVersions {
    <#
    .SYNOPSIS
        Mocks winget list-versions command
    #>
    param(
        [string]$PackageId = "TestPackage"
    )
    
    Mock Invoke-Expression {
        return @"
Versions
-------
1.0.0
1.1.0
1.2.0
"@
    } -ParameterFilter { $_ -match "^winget list-versions" }
}

# Export functions
Export-ModuleMember -Function @(
    'Mock-WingetInstalled',
    'Mock-WingetNotInstalled',
    'Mock-WingetExportWithApps',
    'Mock-WingetExportEmpty',
    'Mock-WingetExportWithGitAndVSCode',
    'Mock-WingetExportWithSources',
    'Mock-WingetInstallSuccess',
    'Mock-WingetInstallFailure',
    'Mock-WingetInstallAlreadyInstalled',
    'Mock-WingetUninstallSuccess',
    'Mock-WingetUninstallFailure',
    'Mock-WingetUpdateSuccess',
    'Mock-WingetUpdateFailure',
    'Mock-WingetUpdateAll',
    'Mock-WingetSearchFound',
    'Mock-WingetSearchNotFound',
    'Mock-WingetSourceList',
    'Mock-WingetSourceAdd',
    'Mock-WingetShow',
    'Mock-WingetListVersions'
)
