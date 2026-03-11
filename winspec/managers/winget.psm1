# managers/winget.psm1 - Declarative Winget package management provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Winget"
        Type = "Declarative"
    }
}

function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Verifies winget (Windows Package Manager) is installed and available.
    .DESCRIPTION
        Checks if winget command is available. Throws an error if not installed.
    #>
    [CmdletBinding()]
    param()
    
    if ($null -eq (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw @"
Winget is not installed. Please install Windows Package Manager first:

  https://github.com/microsoft/winget-cli#installing-the-cli

Or update your Windows 10/11 to the latest version which includes winget.
"@
    }
    
    return $true
}

function Invoke-WingetCommand {
    <#
    .SYNOPSIS
        Internal wrapper to invoke winget commands for testability.
    .DESCRIPTION
        Wraps winget command calls to allow for mocking in tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Command,
        
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    
    $argString = if ($Arguments) { $Arguments -join ' ' } else { '' }
    $fullCommand = if ($argString) { "winget $Command $argString" } else { "winget $Command" }
    
    return Invoke-Expression $fullCommand 2>$null
}

function Get-WingetExport {
    <#
    .SYNOPSIS
        Gets the current Winget state by querying installed packages.
    .DESCRIPTION
        Runs 'winget list' and parses the output to get installed packages.
    .OUTPUTS
        Hashtable with 'packages' array
    #>
    [CmdletBinding()]
    param()
    
    # Ensure Winget is installed first
    Test-WingetInstalled | Out-Null
    
    try {
        # winget list --accept-source-agreements to avoid prompts
        $listOutput = Invoke-WingetCommand -Command "list" -Arguments "--accept-source-agreements"
        
        if ([string]::IsNullOrWhiteSpace($listOutput)) {
            return @{
                packages = @()
            }
        }
        
        # Parse winget list output - it returns a table format
        # Header line starts with "Name"
        $lines = $listOutput -split "`n" | Where-Object { $_.Trim() -ne "" }
        
        $packages = @()
        
        # Find the header line and parse from there
        $startIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*Name\s+Id") {
                $startIndex = $i + 1
                break
            }
        }
        
        if ($startIndex -ge 0 -and $startIndex -lt $lines.Count) {
            for ($i = $startIndex; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Skip separator lines (----)
                if ($line -match "^-+\s+-+\s+-") {
                    continue
                }
                
                # Parse line: Name                    Id                           Version      Available
                # We need to extract the package name and id
                if ($line -match "^\s*(.+?)\s+([^\s]+)\s+([^\s]+)") {
                    $name = $matches[1].Trim()
                    $id = $matches[2].Trim()
                    $version = $matches[3].Trim()
                    
                    # Skip header-like entries
                    if ($name -eq "Name" -or $id -eq "Id") {
                        continue
                    }
                    
                    $packages += @{
                        Name = $name
                        Id = $id
                        Version = $version
                    }
                }
            }
        }
        
        return @{
            packages = $packages
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to get Winget packages: $($_.Exception.Message)"
        return @{
            packages = @()
        }
    }
}

function Get-InstalledWingetPackages {
    <#
    .SYNOPSIS
        Gets the list of installed package IDs.
    .DESCRIPTION
        Uses winget list to return just the package IDs.
    #>
    [CmdletBinding()]
    param()
    
    $export = Get-WingetExport
    return @($export.packages | Select-Object -ExpandProperty Id -ErrorAction SilentlyContinue)
}

function Get-WingetPackageInfo {
    <#
    .SYNOPSIS
        Gets detailed information about an installed package.
    .DESCRIPTION
        Returns metadata about a package from the winget list.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )
    
    $export = Get-WingetExport
    return $export.packages | Where-Object { $_.Id -eq $PackageId }
}

function Get-PackageName {
    <#
    .SYNOPSIS
        Extracts package name/id from various input formats.
    .DESCRIPTION
        Handles both simple string format and extended hashtable format with flags.
    .PARAMETER Package
        Package id (string) or package object with Name and optional Flags
    .OUTPUTS
        Package id string
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package
    )
    
    if ($Package -is [hashtable]) {
        return $Package.Name  # Using Name field as the package id for winget
    }
    return $Package
}

function Get-PackageFlags {
    <#
    .SYNOPSIS
        Extracts installation flags from package object.
    .DESCRIPTION
        Returns flags string if package is hashtable with Flags property, otherwise empty string.
    .PARAMETER Package
        Package id (string) or package object with Name and optional Flags
    .OUTPUTS
        Flags string (may be empty)
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package
    )
    
    if ($Package -is [hashtable] -and $Package.Flags) {
        return $Package.Flags
    }
    return ""
}

function Test-WingetState {
    <#
    .SYNOPSIS
        Tests if all desired packages are installed.
    .DESCRIPTION
        Compares the desired package list against winget's exported state.
        Supports both simple strings and extended hashtables with flags.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    if (-not $Desired.Installed) {
        return $true
    }
    
    $installed = Get-InstalledWingetPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgId = Get-PackageName -Package $package
        if ($pkgId -notin $installed) {
            return $false
        }
    }
    
    return $true
}

function Set-WingetState {
    <#
    .SYNOPSIS
        Installs packages that are not already present.
    .DESCRIPTION
        Uses winget list to determine current state and installs
        only the packages that are missing. Supports per-package flags.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    # Verify Winget is installed - this will throw if not
    try {
        Test-WingetInstalled | Out-Null
    }
    catch {
        Write-Log -Level "ERROR" -Message $_.Exception.Message
        $results["Winget"] = @{ Status = "Error"; Message = "Winget not installed" }
        return $results
    }
    
    if (-not $Desired.Installed) {
        return $results
    }
    
    # Get current state once from winget list
    $installed = Get-InstalledWingetPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgId = Get-PackageName -Package $package
        $pkgFlags = Get-PackageFlags -Package $package
        
        if ($pkgId -in $installed) {
            Write-LogOk -Name $pkgId -DesiredValue "installed"
            $results[$pkgId] = @{ Status = "AlreadyInstalled" }
            continue
        }
        
        Write-LogChange -Name $pkgId -CurrentValue "not installed" -DesiredValue "installed"
        
        if ($PSCmdlet.ShouldProcess($pkgId, "Install package")) {
            try {
                # Build arguments: package id followed by any flags
                $args = @($pkgId)
                if ($pkgFlags) {
                    # Parse flags string into separate arguments
                    $args += $pkgFlags -split '\s+'
                }
                
                Invoke-WingetCommand -Command "install" -Arguments $args | Out-Null
                Write-LogApplied -Name $pkgId -DesiredValue "installed"
                $results[$pkgId] = @{ Status = "Installed"; Flags = $pkgFlags }
            }
            catch {
                Write-LogError -Name $pkgId -Details $_.Exception.Message
                $results[$pkgId] = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }
        else {
            $results[$pkgId] = @{ Status = "DryRun" }
        }
    }
    
    return $results
}

function Export-WingetState {
    <#
    .SYNOPSIS
        Exports the current package state for bidirectional sync.
    .DESCRIPTION
        Captures the current Winget state (packages) in a format
        suitable for WinSpec configuration.
    .OUTPUTS
        Hashtable with Installed array
    #>
    [CmdletBinding()]
    param()
    
    # Ensure Winget is installed
    try {
        Test-WingetInstalled | Out-Null
    }
    catch {
        Write-Log -Level "ERROR" -Message "Cannot export: Winget is not installed"
        return $null
    }
    
    $export = Get-WingetExport
    
    # Build packages array
    $packages = @()
    foreach ($pkg in $export.packages) {
        $pkgEntry = @{
            Name = $pkg.Id  # Use Id as the primary identifier for winget
        }
        
        # Add optional fields if present
        if ($pkg.Version) {
            $pkgEntry.Version = $pkg.Version
        }
        
        $packages += $pkgEntry
    }
    
    # Build result - use simple array format with just package IDs
    $result = @{}
    
    if ($packages.Count -gt 0) {
        # Use simple array format if no version info needed
        $simpleIds = $packages | ForEach-Object { $_.Name }
        $result.Installed = $simpleIds
        
        # Also include detailed format if any package has extra metadata
        $hasDetailedInfo = $packages | Where-Object { $_.Count -gt 1 }
        if ($hasDetailedInfo) {
            $result.Packages = $packages
        }
    }
    
    return $result
}

function Compare-WingetState {
    <#
    .SYNOPSIS
        Compares system package state with desired configuration.
    .DESCRIPTION
        Compares current Winget state with a desired configuration and
        returns differences (added, removed, changed packages).
    .PARAMETER System
        Current system state (from Export-WingetState)
    .PARAMETER Desired
        Desired configuration state
    .OUTPUTS
        Array of difference objects with Type, Path, SystemValue, ConfigValue
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$System,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $differences = @()
    
    # Get package lists (handle both simple and extended format)
    $systemPackages = if ($System.Installed) { 
        $System.Installed | ForEach-Object { Get-PackageName -Package $_ }
    } else { @() }
    
    $desiredPackages = if ($Desired.Installed) { 
        $Desired.Installed | ForEach-Object { Get-PackageName -Package $_ }
    } else { @() }
    
    # Find added packages (in desired, not in system)
    foreach ($package in $desiredPackages) {
        if ($package -notin $systemPackages) {
            $differences += @{
                Type = "Added"
                Path = "Winget.$package"
                SystemValue = $null
                ConfigValue = $package
            }
        }
    }
    
    # Find removed packages (in system, not in desired)
    foreach ($package in $systemPackages) {
        if ($package -notin $desiredPackages) {
            $differences += @{
                Type = "Removed"
                Path = "Winget.$package"
                SystemValue = $package
                ConfigValue = $null
            }
        }
    }
    
    # Find existing packages (for version comparison if Packages data available)
    $systemPkgs = if ($System.Packages) { $System.Packages } else { @() }
    $desiredPkgs = if ($Desired.Packages) { $Desired.Packages } else { @() }
    
    foreach ($desiredPkg in $desiredPkgs) {
        $systemPkg = $systemPkgs | Where-Object { $_.Name -eq $desiredPkg.Name }
        if ($systemPkg) {
            # Check for version mismatch
            if ($desiredPkg.Version -and $systemPkg.Version -ne $desiredPkg.Version) {
                $differences += @{
                    Type = "Changed"
                    Path = "Winget.$($desiredPkg.Name)"
                    SystemValue = @{ Version = $systemPkg.Version }
                    ConfigValue = @{ Version = $desiredPkg.Version }
                }
            }
            else {
                $differences += @{
                    Type = "Equal"
                    Path = "Winget.$($desiredPkg.Name)"
                    SystemValue = $systemPkg
                    ConfigValue = $desiredPkg
                }
            }
        }
    }
    
    return $differences
}

function Get-WingetMockState {
    <#
    .SYNOPSIS
        Gets the package mock state from sandbox.
    .DESCRIPTION
        Returns the current package state from the sandbox context.
    .OUTPUTS
        Hashtable with packages array
    #>
    [CmdletBinding()]
    param()
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
    if (Test-SandboxActive) {
        $state = Get-SandboxState -Provider "Winget"
        return @{
            packages = $state.packages
        }
    }
    
    # Not in sandbox - return empty default
    return @{
        packages = @()
    }
}

function Set-WingetMockState {
    <#
    .SYNOPSIS
        Sets the package mock state in sandbox.
    .DESCRIPTION
        Updates the current package state in the sandbox context.
    .PARAMETER State
        Hashtable with packages array
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
    if (Test-SandboxActive) {
        Set-SandboxState -Provider "Winget" -State $State
    }
}

function Invoke-WingetSandboxApply {
    <#
    .SYNOPSIS
        Applies package state changes in sandbox mode.
    .DESCRIPTION
        Simulates package installation/removal in the sandbox context.
    .PARAMETER Desired
        Desired package state hashtable
    .OUTPUTS
        Hashtable with Status, Installed, Removed arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
    if (-not (Test-SandboxActive)) {
        throw "Not in sandbox mode"
    }
    
    $currentState = Get-SandboxState -Provider "Winget"
    $currentPackages = @($currentState.packages | ForEach-Object { $_.Id })
    
    # Handle both simple and extended format for Installed
    $desiredPackages = @()
    if ($Desired.Installed) {
        foreach ($pkg in $Desired.Installed) {
            $desiredPackages += Get-PackageName -Package $pkg
        }
    }
    
    $results = @{
        Status = "Success"
        Installed = @()
        Removed = @()
        AlreadyInstalled = @()
    }
    
    # Simulate installations
    foreach ($package in $desiredPackages) {
        if ($package -notin $currentPackages) {
            $currentState.packages += @{
                Name = $package
                Id = $package
                Version = "latest"
            }
            $results.Installed += $package
        }
        else {
            $results.AlreadyInstalled += $package
        }
    }
    
    # Track removal if specified
    if ($Desired.Removed) {
        foreach ($package in $Desired.Removed) {
            if ($package -in $currentPackages) {
                $currentState.packages = @($currentState.packages | Where-Object { $_.Id -ne $package })
                $results.Removed += $package
            }
        }
    }
    
    # Update sandbox state
    Set-SandboxState -Provider "Winget" -State $currentState
    
    # Record change
    Add-SandboxChange -Provider "Winget" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Test-WingetInstalled"
    "Invoke-WingetCommand"
    "Get-WingetExport"
    "Get-InstalledWingetPackages"
    "Get-WingetPackageInfo"
    "Get-PackageName"
    "Get-PackageFlags"
    "Test-WingetState"
    "Set-WingetState"
    "Export-WingetState"
    "Compare-WingetState"
    "Get-WingetMockState"
    "Set-WingetMockState"
    "Invoke-WingetSandboxApply"
)
