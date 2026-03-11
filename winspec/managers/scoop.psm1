# managers/scoop.psm1 - Declarative Scoop package management provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Scoop"
        Type = "Declarative"
    }
}

function Test-ScoopInstalled {
    <#
    .SYNOPSIS
        Verifies Scoop is installed and available.
    .DESCRIPTION
        Checks if Scoop command is available. Throws an error if not installed,
        directing the user to install Scoop manually.
    #>
    [CmdletBinding()]
    param()
    
    if ($null -eq (Get-Command scoop -ErrorAction SilentlyContinue)) {
        throw @"
Scoop is not installed. Please install Scoop first:

  irm get.scoop.sh | iex

Or with proxy (for China users):
  irm https://gh-proxy.org/https://raw.githubusercontent.com/ScoopInstaller/Install/master/install.ps1 | iex

For more information: https://scoop.sh
"@
    }
    
    return $true
}

function Invoke-ScoopCommand {
    <#
    .SYNOPSIS
        Internal wrapper to invoke scoop commands for testability.
    .DESCRIPTION
        Wraps scoop command calls to allow for mocking in tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Command,
        
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    
    $argString = if ($Arguments) { $Arguments -join ' ' } else { '' }
    $fullCommand = if ($argString) { "scoop $Command $argString" } else { "scoop $Command" }
    
    return Invoke-Expression $fullCommand 2>$null
}

function Get-ScoopExport {
    <#
    .SYNOPSIS
        Gets the current Scoop state as a hashtable from JSON export.
    .DESCRIPTION
        Runs 'scoop export' and parses the JSON output to get installed
        packages, buckets, and their metadata.
    .OUTPUTS
        Hashtable with 'apps' and 'buckets' arrays
    #>
    [CmdletBinding()]
    param()
    
    # Ensure Scoop is installed first
    Test-ScoopInstalled | Out-Null
    
    try {
        $exportJson = Invoke-ScoopCommand -Command "export"
        
        if ([string]::IsNullOrWhiteSpace($exportJson)) {
            return @{
                apps = @()
                buckets = @()
            }
        }
        
        $export = $exportJson | ConvertFrom-Json -ErrorAction Stop
        
        # Handle case where apps or buckets might be null
        $apps = if ($export.apps) { @($export.apps) } else { @() }
        $buckets = if ($export.buckets) { @($export.buckets) } else { @() }
        
        return @{
            apps = $apps
            buckets = $buckets
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to parse Scoop export: $($_.Exception.Message)"
        return @{
            apps = @()
            buckets = @()
        }
    }
}

function Get-InstalledScoopPackages {
    <#
    .SYNOPSIS
        Gets the list of installed package names.
    .DESCRIPTION
        Uses cached Scoop export to return just the package names.
    #>
    [CmdletBinding()]
    param()
    
    $export = Get-ScoopExport
    return @($export.apps | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)
}

function Get-ScoopPackageInfo {
    <#
    .SYNOPSIS
        Gets detailed information about an installed package.
    .DESCRIPTION
        Returns metadata about a package from the Scoop export.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageName
    )
    
    $export = Get-ScoopExport
    return $export.apps | Where-Object { $_.Name -eq $PackageName }
}

function Get-PackageName {
    <#
    .SYNOPSIS
        Extracts package name from various input formats.
    .DESCRIPTION
        Handles both simple string format and extended hashtable format with flags.
    .PARAMETER Package
        Package name (string) or package object with Name and optional Flags
    .OUTPUTS
        Package name string
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package
    )
    
    if ($Package -is [hashtable]) {
        return $Package.Name
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
        Package name (string) or package object with Name and optional Flags
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

function Test-ScoopState {
    <#
    .SYNOPSIS
        Tests if all desired packages are installed.
    .DESCRIPTION
        Compares the desired package list against Scoop's exported state.
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
    
    $installed = Get-InstalledScoopPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgName = Get-PackageName -Package $package
        if ($pkgName -notin $installed) {
            return $false
        }
    }
    
    return $true
}

function Set-ScoopState {
    <#
    .SYNOPSIS
        Installs packages that are not already present.
    .DESCRIPTION
        Uses Scoop export to determine current state and installs
        only the packages that are missing. Supports per-package flags.
        Requires Scoop to be pre-installed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    # Verify Scoop is installed - this will throw if not
    try {
        Test-ScoopInstalled | Out-Null
    }
    catch {
        Write-Log -Level "ERROR" -Message $_.Exception.Message
        $results["Scoop"] = @{ Status = "Error"; Message = "Scoop not installed" }
        return $results
    }
    
    if (-not $Desired.Installed) {
        return $results
    }
    
    # Get current state once from scoop export
    $installed = Get-InstalledScoopPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgName = Get-PackageName -Package $package
        $pkgFlags = Get-PackageFlags -Package $package
        
        if ($pkgName -in $installed) {
            Write-LogOk -Name $pkgName -DesiredValue "installed"
            $results[$pkgName] = @{ Status = "AlreadyInstalled" }
            continue
        }
        
        Write-LogChange -Name $pkgName -CurrentValue "not installed" -DesiredValue "installed"
        
        if ($PSCmdlet.ShouldProcess($pkgName, "Install package")) {
            try {
                if ($pkgFlags) {
                    Invoke-ScoopCommand -Command "install" -Arguments "$pkgFlags $pkgName" | Out-Null
                }
                else {
                    Invoke-ScoopCommand -Command "install" -Arguments $pkgName | Out-Null
                }
                Write-LogApplied -Name $pkgName -DesiredValue "installed"
                $results[$pkgName] = @{ Status = "Installed"; Flags = $pkgFlags }
            }
            catch {
                Write-LogError -Name $pkgName -Details $_.Exception.Message
                $results[$pkgName] = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }
        else {
            $results[$pkgName] = @{ Status = "DryRun" }
        }
    }
    
    return $results
}

function Export-ScoopState {
    <#
    .SYNOPSIS
        Exports the current package state for bidirectional sync.
    .DESCRIPTION
        Captures the current Scoop state (buckets and packages) in a format
        suitable for WinSpec configuration. Filters out ephemeral fields
        like 'Updated' timestamps, keeping only persistent data.
    .OUTPUTS
        Hashtable with Buckets and Installed arrays
    #>
    [CmdletBinding()]
    param()
    
    # Ensure Scoop is installed
    try {
        Test-ScoopInstalled | Out-Null
    }
    catch {
        Write-Log -Level "ERROR" -Message "Cannot export: Scoop is not installed"
        return $null
    }
    
    $export = Get-ScoopExport
    
    # Build buckets array (persistent fields only)
    $buckets = @()
    foreach ($bucket in $export.buckets) {
        $buckets += @{
            Name = $bucket.name
            Source = $bucket.source
        }
    }
    
    # Build apps array (persistent fields only)
    $apps = @()
    foreach ($app in $export.apps) {
        $appEntry = @{
            Name = $app.name
        }
        
        # Add optional fields if present
        if ($app.version) {
            $appEntry.Version = $app.version
        }
        if ($app.bucket) {
            $appEntry.Bucket = $app.bucket
        }
        if ($app.architecture) {
            $appEntry.Architecture = $app.architecture
        }
        
        $apps += $appEntry
    }
    
    # Build result - support both simple and extended formats
    $result = @{}
    
    if ($buckets.Count -gt 0) {
        $result.Buckets = $buckets
    }
    
    if ($apps.Count -gt 0) {
        # Use simple array format if no version/bucket info needed
        $simpleNames = $apps | ForEach-Object { $_.Name }
        $result.Installed = $simpleNames
        
        # Also include detailed format if any app has extra metadata
        $hasDetailedInfo = $apps | Where-Object { $_.Count -gt 1 }
        if ($hasDetailedInfo) {
            $result.Apps = $apps
        }
    }
    
    return $result
}

function Compare-ScoopState {
    <#
    .SYNOPSIS
        Compares system package state with desired configuration.
    .DESCRIPTION
        Compares current Scoop state with a desired configuration and
        returns differences (added, removed, changed packages).
    .PARAMETER System
        Current system state (from Export-ScoopState)
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
                Path = "Scoop.$package"
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
                Path = "Scoop.$package"
                SystemValue = $package
                ConfigValue = $null
            }
        }
    }
    
    # Find existing packages (for version comparison if Apps data available)
    $systemApps = if ($System.Apps) { $System.Apps } else { @() }
    $desiredApps = if ($Desired.Apps) { $Desired.Apps } else { @() }
    
    foreach ($desiredApp in $desiredApps) {
        $systemApp = $systemApps | Where-Object { $_.Name -eq $desiredApp.Name }
        if ($systemApp) {
            # Check for version mismatch
            if ($desiredApp.Version -and $systemApp.Version -ne $desiredApp.Version) {
                $differences += @{
                    Type = "Changed"
                    Path = "Scoop.$($desiredApp.Name)"
                    SystemValue = @{ Version = $systemApp.Version }
                    ConfigValue = @{ Version = $desiredApp.Version }
                }
            }
            else {
                $differences += @{
                    Type = "Equal"
                    Path = "Scoop.$($desiredApp.Name)"
                    SystemValue = $systemApp
                    ConfigValue = $desiredApp
                }
            }
        }
    }
    
    # Check buckets
    $systemBuckets = if ($System.Buckets) { $System.Buckets } else { @() }
    $desiredBuckets = if ($Desired.Buckets) { $Desired.Buckets } else { @() }
    
    foreach ($bucket in $desiredBuckets) {
        $systemBucket = $systemBuckets | Where-Object { $_.Name -eq $bucket.Name }
        if (-not $systemBucket) {
            $differences += @{
                Type = "Added"
                Path = "Scoop.Buckets.$($bucket.Name)"
                SystemValue = $null
                ConfigValue = $bucket
            }
        }
    }
    
    return $differences
}

function Get-ScoopMockState {
    <#
    .SYNOPSIS
        Gets the package mock state from sandbox.
    .DESCRIPTION
        Returns the current package state from the sandbox context.
    .OUTPUTS
        Hashtable with apps and buckets arrays
    #>
    [CmdletBinding()]
    param()
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
    if (Test-SandboxActive) {
        $state = Get-SandboxState -Provider "Scoop"
        return @{
            apps = $state.apps
            buckets = $state.buckets
        }
    }
    
    # Not in sandbox - return empty default
    return @{
        apps = @()
        buckets = @()
    }
}

function Set-ScoopMockState {
    <#
    .SYNOPSIS
        Sets the package mock state in sandbox.
    .DESCRIPTION
        Updates the current package state in the sandbox context.
    .PARAMETER State
        Hashtable with apps and buckets arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
    if (Test-SandboxActive) {
        Set-SandboxState -Provider "Scoop" -State $State
    }
}

function Invoke-ScoopSandboxApply {
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
    
    $currentState = Get-SandboxState -Provider "Scoop"
    $currentApps = @($currentState.apps | ForEach-Object { $_.name })
    
    # Handle both simple and extended format for Installed
    $desiredApps = @()
    if ($Desired.Installed) {
        foreach ($pkg in $Desired.Installed) {
            $desiredApps += Get-PackageName -Package $pkg
        }
    }
    
    $results = @{
        Status = "Success"
        Installed = @()
        Removed = @()
        AlreadyInstalled = @()
    }
    
    # Simulate installations
    foreach ($package in $desiredApps) {
        if ($package -notin $currentApps) {
            $currentState.apps += @{
                name = $package
                version = "latest"
                bucket = "main"
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
            if ($package -in $currentApps) {
                $currentState.apps = @($currentState.apps | Where-Object { $_.name -ne $package })
                $results.Removed += $package
            }
        }
    }
    
    # Update sandbox state
    Set-SandboxState -Provider "Scoop" -State $currentState
    
    # Record change
    Add-SandboxChange -Provider "Scoop" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Test-ScoopInstalled"
    "Invoke-ScoopCommand"
    "Get-ScoopExport"
    "Get-InstalledScoopPackages"
    "Get-ScoopPackageInfo"
    "Get-PackageName"
    "Get-PackageFlags"
    "Test-ScoopState"
    "Set-ScoopState"
    "Export-ScoopState"
    "Compare-ScoopState"
    "Get-ScoopMockState"
    "Set-ScoopMockState"
    "Invoke-ScoopSandboxApply"
)
