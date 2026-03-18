# managers/scoop.psm1 - Declarative Scoop package management provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\utils.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue

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
    Internal wrapper to invoke scoop commands.

.DESCRIPTION
    Executes scoop in a separate PowerShell process for isolation
    and improved testability.

.PARAMETER Command
    Scoop command (install, list, update, etc).

.PARAMETER Arguments
    Additional arguments passed to scoop.

.OUTPUTS
    Command stdout as string.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    $cmdArgs = @($Command)
    if ($Arguments) {
        $cmdArgs += $Arguments
    }

    # Proper argument quoting
    $escaped = $cmdArgs | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "powershell"
    $psi.Arguments = "-NoProfile -Command scoop $($escaped -join ' ')"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        Write-Log -Level WARNING -Message "Scoop exited with code $($process.ExitCode): $stderr"
    }

    return $stdout
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
                apps    = @()
                buckets = @()
            }
        }
        
        $export = $exportJson | ConvertFrom-Json -ErrorAction Stop
        
        # Handle case where apps or buckets might be null
        $apps = if ($export.apps) { @($export.apps) } else { @() }
        $buckets = if ($export.buckets) { @($export.buckets) } else { @() }
        
        return @{
            apps    = $apps
            buckets = $buckets
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to parse Scoop export: $($_.Exception.Message)"
        return @{
            apps    = @()
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
    
    $buckets = [System.Collections.ArrayList]::new()
    foreach ($bucket in $export.buckets) {
        [void]$buckets.Add(@{
                Name   = $bucket.name
                Source = $bucket.source
            })
    }
    
    $apps = [System.Collections.ArrayList]::new()
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
        
        [void]$apps.Add($appEntry)
    }
    
    # Build result - unified format
    $result = @{}
    
    if ($buckets.Count -gt 0) {
        $result.Buckets = $buckets.ToArray()
    }
    
    if ($apps.Count -gt 0) {
        # Always include Packages for consistency
        # $result.Installed = $apps | ForEach-Object { $_.Name }
        $result.Packages = $apps.ToArray()
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
    
    $differences = [System.Collections.ArrayList]::new()
    
    # Get package lists (handle both simple and extended format)
    $systemPackages = if ($System.Installed) { 
        $System.Installed | ForEach-Object { Get-PackageName -Package $_ }
    }
    else { @() }
    
    $desiredPackages = if ($Desired.Installed) { 
        $Desired.Installed | ForEach-Object { Get-PackageName -Package $_ }
    }
    else { @() }
    
    # Find added packages (in desired, not in system)
    foreach ($package in $desiredPackages) {
        if ($package -notin $systemPackages) {
            [void]$differences.Add(@{
                    Type        = "Added"
                    Path        = "Scoop.$package"
                    SystemValue = $null
                    ConfigValue = $package
                })
        }
    }
    
    # Find removed packages (in system, not in desired)
    foreach ($package in $systemPackages) {
        if ($package -notin $desiredPackages) {
            [void]$differences.Add(@{
                    Type        = "Removed"
                    Path        = "Scoop.$package"
                    SystemValue = $package
                    ConfigValue = $null
                })
        }
    }
    
    # Find existing packages (for version comparison if Packages data available)
    $systemPackages = if ($System.Packages) { $System.Packages } else { @() }
    $desiredPackages = if ($Desired.Packages) { $Desired.Packages } else { @() }
    
    foreach ($desiredPkg in $desiredPackages) {
        $systemPkg = $systemPackages | Where-Object { $_.Name -eq $desiredPkg.Name }
        if (-Not $systemPkg) {
            continue
        }
        # Check for version mismatch
        if ($desiredPkg.Version -and $systemPkg.Version -ne $desiredPkg.Version) {
            [void]$differences.Add(@{
                    Type        = "Changed"
                    Path        = "Scoop.$($desiredPkg.Name)"
                    SystemValue = @{ Version = $systemPkg.Version }
                    ConfigValue = @{ Version = $desiredPkg.Version }
                })
        }
        else {
            [void]$differences.Add(@{
                    Type        = "Equal"
                    Path        = "Scoop.$($desiredPkg.Name)"
                    SystemValue = $systemPkg
                    ConfigValue = $desiredPkg
                })
        }
    }
    
    # Check buckets
    $systemBuckets = if ($System.Buckets) { $System.Buckets } else { @() }
    $desiredBuckets = if ($Desired.Buckets) { $Desired.Buckets } else { @() }
    
    foreach ($bucket in $desiredBuckets) {
        $systemBucket = $systemBuckets | Where-Object { $_.Name -eq $bucket.Name }
        if (-not $systemBucket) {
            [void]$differences.Add(@{
                    Type        = "Added"
                    Path        = "Scoop.Buckets.$($bucket.Name)"
                    SystemValue = $null
                    ConfigValue = $bucket
                })
        }
    }
    
    return $differences.ToArray()
}

function Merge-ScoopState {
    <#
    .SYNOPSIS
        Merges system Scoop state with existing config.
    .DESCRIPTION
        Uses shared merge utilities for efficiency. Prefers existing config
        for buckets to preserve user customizations.
    .PARAMETER SystemState
        Hashtable with Installed, Packages, and/or Buckets arrays from system
    .PARAMETER ExistingConfig
        Hashtable with Installed, Packages, and/or Buckets arrays from config
    .OUTPUTS
        Hashtable with merged state
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SystemState,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$ExistingConfig
    )
    
    # Use generic package merge
    $result = Merge-PackageState -SystemState $SystemState -SpecState $ExistingConfig
    
    # Use generic bucket merge
    $mergedBuckets = Merge-SourceCollection `
        -SystemSources $SystemState.Buckets `
        -ExistingSources $ExistingConfig.Buckets `
        -NameKey "Name"
    
    if ($mergedBuckets.Count -gt 0) {
        $result.Buckets = $mergedBuckets
    }
    
    return $result
}

function Invoke-ScoopSandbox {
    <#
.SYNOPSIS
Simulates Scoop package changes inside sandbox.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    if (!Test-SandboxActive) {
        throw "Sandbox not active"
    }

    $results = @{
        Status           = "Success"
        Installed        = @()
        Removed          = @()
        AlreadyInstalled = @()
    }

    Update-SandboxState "Scoop" {
        param($state)
        $currentApps = @($state.apps.name)

        # -----------------------------
        # normalize desired packages
        # -----------------------------

        $desiredApps = @()
        if ($Desired.Installed) {
            foreach ($pkg in $Desired.Installed) {
                $desiredApps += Get-PackageName -Package $pkg
            }
        }

        # -----------------------------
        # simulate install
        # -----------------------------

        foreach ($pkg in $desiredApps) {
            if ($pkg -notin $currentApps) {
                $state.apps += @{
                    name    = $pkg
                    version = "latest"
                    bucket  = "main"
                }
                $results.Installed += $pkg
            }
            else {
                $results.AlreadyInstalled += $pkg
            }
        }

        # -----------------------------
        # simulate removal
        # -----------------------------

        if ($Desired.Removed) {

            foreach ($pkg in $Desired.Removed) {

                if ($pkg -in $currentApps) {

                    $state.apps =
                    @($state.apps | Where-Object { $_.name -ne $pkg })

                    $results.Removed += $pkg
                }
            }
        }

    }
    # record change in sandbox history
    Update-SandboxChanges "Scoop" "Apply" $results

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
    "Merge-ScoopState"
    "Invoke-ScoopSandBox"
)
