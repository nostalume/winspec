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
        Mocks winget list with specified packages
    .PARAMETER Packages
        Array of package objects to include in list
    #>
    param(
        [array]$Packages = @()
    )
    
    # Build the output format that winget list returns
    # Header: Name                          Id                           Version      Available
    # Line:  Package Name                   package.id                   1.0.0       
    $output = @"
Name                          Id                           Version      Available
----                          --                           -------      ---------
"@
    
    foreach ($pkg in $Packages) {
        $name = $pkg.Name
        $id = $pkg.Id
        $version = if ($pkg.Version) { $pkg.Version } else { "1.0.0" }
        
        # Format: name (left-padded to 28 chars) + id (left-padded to 30) + version
        $output += "`n$($name.PadRight(28))$($id.PadRight(30))$version"
    }
    
    Mock Invoke-Expression {
        return $output
    } -ParameterFilter { $_ -match "^winget list" -or $_ -match "winget list" }
}

function Mock-WingetExportEmpty {
    <#
    .SYNOPSIS
        Mocks empty winget list (no packages)
    #>
    Mock Invoke-Expression {
        return @"
Name                          Id                           Version      Available
----                          --                           -------      ---------
"@
    } -ParameterFilter { $_ -match "^winget list" -or $_ -match "winget list" }
}

function Mock-WingetExportWithGitAndVSCode {
    <#
    .SYNOPSIS
        Mocks winget list with git and vscode installed
    #>
    Mock Invoke-Expression {
        return @"
Name                          Id                           Version      Available
----                          --                           -------      ---------
Git                           Git.Git                       2.42.0       
Visual Studio Code            Microsoft.VisualStudioCode    1.85.0       
Node.js LTS                   OpenJS.NodeJSLTS              20.10.0      
Python                        Python.Python.3.11            3.11.7       
Docker Desktop                Docker.DockerDesktop          4.26.0       
"@
    } -ParameterFilter { $_ -match "^winget list" -or $_ -match "winget list" }
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
