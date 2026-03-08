# providers/package.psm1 - Declarative package management provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Package"
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

function Get-InstalledPackages {
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

function Get-PackageInfo {
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

function Test-PackageState {
    <#
    .SYNOPSIS
        Tests if all desired packages are installed.
    .DESCRIPTION
        Compares the desired package list against Scoop's exported state.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    if (-not $Desired.Installed) {
        return $true
    }
    
    $installed = Get-InstalledPackages
    
    foreach ($package in $Desired.Installed) {
        if ($package -notin $installed) {
            return $false
        }
    }
    
    return $true
}

function Set-PackageState {
    <#
    .SYNOPSIS
        Installs packages that are not already present.
    .DESCRIPTION
        Uses Scoop export to determine current state and installs
        only the packages that are missing. Requires Scoop to be
        pre-installed.
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
    $installed = Get-InstalledPackages
    
    foreach ($package in $Desired.Installed) {
        if ($package -in $installed) {
            Write-LogOk -Name $package -DesiredValue "installed"
            $results[$package] = @{ Status = "AlreadyInstalled" }
            continue
        }
        
        Write-LogChange -Name $package -CurrentValue "not installed" -DesiredValue "installed"
        
        if ($PSCmdlet.ShouldProcess($package, "Install package")) {
            try {
                Invoke-ScoopCommand -Command "install" -Arguments $package | Out-Null
                Write-LogApplied -Name $package -DesiredValue "installed"
                $results[$package] = @{ Status = "Installed" }
            }
            catch {
                Write-LogError -Name $package -Details $_.Exception.Message
                $results[$package] = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }
        else {
            $results[$package] = @{ Status = "DryRun" }
        }
    }
    
    return $results
}

function Export-PackageState {
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

function Compare-PackageState {
    <#
    .SYNOPSIS
        Compares system package state with desired configuration.
    .DESCRIPTION
        Compares current Scoop state with a desired configuration and
        returns differences (added, removed, changed packages).
    .PARAMETER System
        Current system state (from Export-PackageState)
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
    
    # Get package lists
    $systemPackages = if ($System.Installed) { $System.Installed } else { @() }
    $desiredPackages = if ($Desired.Installed) { $Desired.Installed } else { @() }
    
    # Find added packages (in desired, not in system)
    foreach ($package in $desiredPackages) {
        if ($package -notin $systemPackages) {
            $differences += @{
                Type = "Added"
                Path = "Package.$package"
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
                Path = "Package.$package"
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
                    Path = "Package.$($desiredApp.Name)"
                    SystemValue = @{ Version = $systemApp.Version }
                    ConfigValue = @{ Version = $desiredApp.Version }
                }
            }
            else {
                $differences += @{
                    Type = "Equal"
                    Path = "Package.$($desiredApp.Name)"
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
                Path = "Package.Buckets.$($bucket.Name)"
                SystemValue = $null
                ConfigValue = $bucket
            }
        }
    }
    
    return $differences
}

function Get-PackageMockState {
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
        $state = Get-SandboxState -Provider "Package"
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

function Set-PackageMockState {
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
        Set-SandboxState -Provider "Package" -State $State
    }
}

function Invoke-PackageSandboxApply {
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
    
    $currentState = Get-SandboxState -Provider "Package"
    $currentApps = @($currentState.apps | ForEach-Object { $_.name })
    $desiredApps = @($Desired.Installed)
    
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
    Set-SandboxState -Provider "Package" -State $currentState
    
    # Record change
    Add-SandboxChange -Provider "Package" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Test-ScoopInstalled"
    "Invoke-ScoopCommand"
    "Get-ScoopExport"
    "Get-InstalledPackages"
    "Get-PackageInfo"
    "Test-PackageState"
    "Set-PackageState"
    "Export-PackageState"
    "Compare-PackageState"
    "Get-PackageMockState"
    "Set-PackageMockState"
    "Invoke-PackageSandboxApply"
)
