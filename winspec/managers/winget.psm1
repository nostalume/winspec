# managers/winget.psm1 - Declarative WinGet package management provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\utils.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Winget"
        Type = "Declarative"
    }
}

function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Verifies Winget is installed and available.
    .DESCRIPTION
        Checks if Winget command is available. Throws an error if not installed.
    #>
    [CmdletBinding()]
    param()
    
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    
    if ($null -eq $wingetCmd) {
        throw @"
WinGet is not installed. Please install it from the Microsoft Store:
  https://apps.microsoft.com/store/detail/app-installer/9NBLGGH4NNS1

Or enable it via Settings > Apps > Optional features.
"@
    }
    
    return $true
}

function Invoke-WingetCommand {
    <#
    .SYNOPSIS
        Internal wrapper to invoke winget commands.
    .DESCRIPTION
        Wraps winget command calls for testability. Uses Start-Process for
        secure command execution instead of Invoke-Expression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Command,
        
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    
    # Build command arguments
    $cmdArgs = @($Command)
    if ($Arguments) {
        $cmdArgs += $Arguments
    }
    
    # Debug output
    Write-Debug "Invoking: winget $($cmdArgs -join ' ')"
    
    # Use Start-Process for secure execution
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'winget'
    $psi.Arguments = $cmdArgs -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    # Read output with async to avoid potential deadlock
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    
    # Debug output
    Write-Debug "Exit code: $($process.ExitCode)"
    if ($stdout) { Write-Debug "STDOUT: $stdout" }
    if ($stderr) { Write-Debug "STDERR: $stderr" }
    
    # Log any errors or non-zero exit codes
    if ($process.ExitCode -ne 0) {
        Write-Debug "Winget command exited with non-zero code: $($process.ExitCode)"
        if ($stderr) {
            Write-Log -Level "WARNING" -Message "Winget command exited with code $($process.ExitCode): $stderr"
        }
    }
    
    return $stdout
}

# Helper function to extract packages from winget export
function Parse-WingetExportJson {
    <#
    .SYNOPSIS
        Parses winget export JSON and extracts packages and sources.
    .PARAMETER JsonContent
        Raw JSON content from winget export
    .OUTPUTS
        Hashtable with Packages and Sources arrays
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonContent
    )
    
    Write-Debug "Parse-WingetExportJson called with content length: $($JsonContent.Length)"
    
    if ([string]::IsNullOrWhiteSpace($JsonContent)) {
        Write-Debug "JsonContent is null or whitespace, returning empty"
        return @{
            Packages = @()
            Sources = @()
        }
    }
    
    $export = $JsonContent | ConvertFrom-Json -ErrorAction Stop
    Write-Debug "JSON parsed successfully. WinGetVersion: $($export.WinGetVersion), CreationDate: $($export.CreationDate)"
    
    # Use ArrayList for O(1) append performance
    $packages = [System.Collections.ArrayList]::new()
    $sources = [System.Collections.ArrayList]::new()
    
    # Early return if no sources
    if (-not $export.Sources -or $export.Sources.Count -eq 0) {
        Write-Debug "No sources found in export, returning empty packages"
        return @{
            Packages = @()
            Sources = @()
            WinGetVersion = $export.WinGetVersion
            CreationDate = $export.CreationDate
        }
    }
    
    Write-Debug "Found $($export.Sources.Count) sources in export"
    
    # Process sources - flat loop, no nesting
    foreach ($source in $export.Sources) {
        $sourceName = $source.SourceDetails.Name
        $sourceArg = $source.SourceDetails.Argument
        
        Write-Debug "Processing source: $sourceName"
        
        [void]$sources.Add(@{
            Name = $sourceName
            Argument = $sourceArg
        })
        
        # Extract packages from this source
        if ($source.Packages -and $source.Packages.Count -gt 0) {
            Write-Debug "Source $sourceName has $($source.Packages.Count) packages"
            foreach ($pkg in $source.Packages) {
                [void]$packages.Add(@{
                    Name = $pkg.PackageIdentifier
                    Source = $sourceName
                })
            }
        }
        else {
            Write-Debug "Source $sourceName has NO packages"
        }
    }
    
    Write-Debug "Final result: $($packages.Count) packages, $($sources.Count) sources"
    
    return @{
        Packages = $packages.ToArray()
        Sources = $sources.ToArray()
        WinGetVersion = $export.WinGetVersion
        CreationDate = $export.CreationDate
    }
}

function Get-WingetExport {
    <#
    .SYNOPSIS
        Gets the current Winget state as a hashtable from JSON export.
    .DESCRIPTION
        Runs 'winget export' and parses the JSON output to get installed
        packages and their sources.
    .OUTPUTS
        Hashtable with 'Packages' and 'Sources' arrays
    #>
    [CmdletBinding()]
    param()
    
    # Ensure Winget is installed first
    Test-WingetInstalled | Out-Null
    
    # Use a temp file for winget export output
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    Write-Debug "Temp file: $tempFile"
    
    try {
        # Run winget export with accept-source-agreements to avoid prompts
        # Fixed: Remove incorrect backtick escaping around temp file path
        $null = Invoke-WingetCommand -Command "export" -Arguments @("-o", $tempFile, "--accept-source-agreements")
        
        # Debug: Check if file was created
        Write-Debug "Checking for temp file existence..."
        
        # Guard clause: check if file was created
        if (-not (Test-Path $tempFile)) {
            Write-Debug "Temp file was NOT created - winget export may have failed silently"
            return @{
                Packages = @()
                Sources = @()
            }
        }
        
        Write-Debug "Temp file exists, reading content..."
        
        # Read and parse the JSON using helper function
        $jsonContent = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
        Write-Debug "JSON content length: $($jsonContent.Length)"
        Write-Debug "JSON content preview: $($jsonContent.Substring(0, [Math]::Min(200, $jsonContent.Length)))"
        
        return Parse-WingetExportJson -JsonContent $jsonContent
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to get Winget export: $($_.Exception.Message)"
        Write-Debug "Exception details: $($_.Exception.Message)"
        return @{
            Packages = @()
            Sources = @()
        }
    }
    finally {
        # Clean up temp file
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InstalledWingetPackages {
    <#
    .SYNOPSIS
        Gets the list of installed package names.
    .DESCRIPTION
        Uses Winget export to return just the package names.
    #>
    [CmdletBinding()]
    param()
    
    $export = Get-WingetExport
    return @($export.Packages | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)
}

function Get-WingetPackageInfo {
    <#
    .SYNOPSIS
        Gets detailed information about an installed package.
    .DESCRIPTION
        Returns metadata about a package from the Winget export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageName
    )
    
    $export = Get-WingetExport
    return $export.Packages | Where-Object { $_.Name -eq $PackageName }
}

function Get-PackageIdentifier {
    <#
    .SYNOPSIS
        Extracts package identifier from various input formats.
    .DESCRIPTION
        Handles both simple string format and extended hashtable format with flags.
    .PARAMETER Package
        Package name (string) or package object with Name and optional Version/Source
    .OUTPUTS
        Package identifier string
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

function Get-PackageVersion {
    <#
    .SYNOPSIS
        Extracts version from package object.
    .DESCRIPTION
        Returns version string if package is hashtable with Version property.
    .PARAMETER Package
        Package name (string) or package object with Name and optional Version
    .OUTPUTS
        Version string (may be empty)
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package
    )
    
    if ($Package -is [hashtable] -and $Package.Version) {
        return $Package.Version
    }
    return ""
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

function Test-WingetState {
    <#
    .SYNOPSIS
        Tests if all desired packages are installed.
    .DESCRIPTION
        Compares the desired package list against Winget's exported state.
        Supports both simple strings and extended hashtables with Version/Source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    if (-not $Desired.Installed) {
        return $true
    }
    
    $installed = Get-InstalledWingetPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgName = Get-PackageIdentifier -Package $package
        if ($pkgName -notin $installed) {
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
        Uses Winget export to determine current state and installs
        only the packages that are missing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    # Verify Winget is installed
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
    
    # Get current state once from winget export
    $installed = Get-InstalledWingetPackages
    
    foreach ($package in $Desired.Installed) {
        $pkgName = Get-PackageIdentifier -Package $package
        $pkgVersion = Get-PackageVersion -Package $package
        $pkgFlags = Get-PackageFlags -Package $package
        
        if ($pkgName -in $installed) {
            Write-LogOk -Name $pkgName -DesiredValue "installed"
            $results[$pkgName] = @{ Status = "AlreadyInstalled"; Version = $pkgVersion }
            continue
        }
        
        Write-LogChange -Name $pkgName -CurrentValue "not installed" -DesiredValue "installed"
        
        if ($PSCmdlet.ShouldProcess($pkgName, "Install package")) {
            try {
                # Build install arguments - use ID directly (winget accepts full ID like Git.Git)
                $inputs = @("install", "--id", $pkgName, "--accept-source-agreements", "--accept-package-agreements")
                
                # Add version if specified
                if ($pkgVersion) {
                    $inputs += @("--version", $pkgVersion)
                }
                
                # Add custom flags if specified
                if ($pkgFlags) {
                    $inputs += $pkgFlags -split ' '
                }
                
                Invoke-WingetCommand -Command $inputs[0] -Arguments $inputs[1..($inputs.Length - 1)] | Out-Null
                
                Write-LogApplied -Name $pkgName -DesiredValue "installed"
                $results[$pkgName] = @{ Status = "Installed"; Version = $pkgVersion; Flags = $pkgFlags }
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

function Export-WingetState {
    <#
    .SYNOPSIS
        Exports the current package state for bidirectional sync.
    .DESCRIPTION
        Captures the current Winget state in a format suitable for WinSpec configuration.
    .OUTPUTS
        Hashtable with Installed array
    #>
    [CmdletBinding()]
    param()
    
    Write-Debug "Export-WingetState: Starting export..."
    
    # Ensure Winget is installed
    try {
        Test-WingetInstalled | Out-Null
    }
    catch {
        Write-Log -Level "ERROR" -Message "Cannot export: Winget is not installed"
        Write-Debug "Export-WingetState: Winget not installed error"
        return $null
    }
    
    Write-Debug "Export-WingetState: Getting winget export..."
    $export = Get-WingetExport
    
    Write-Debug "Export-WingetState: Got export with $($export.Packages.Count) packages, $($export.Sources.Count) sources"
    
    # Build packages array using ArrayList for O(1) append
    $packages = [System.Collections.ArrayList]::new()
    foreach ($pkg in $export.Packages) {
        $pkgEntry = @{
            Name = $pkg.Name
        }
        
        # Add source if available (for tracking where package came from)
        if ($pkg.Source) {
            $pkgEntry.Source = $pkg.Source
        }
        
        # Add version if available
        if ($pkg.Version) {
            $pkgEntry.Version = $pkg.Version
        }
        
        [void]$packages.Add($pkgEntry)
    }
    
    # Build result
    $result = @{}
    
    # Include sources if available
    if ($export.Sources -and $export.Sources.Count -gt 0) {
        $result.Sources = $export.Sources
    }
    
    if ($packages.Count -gt 0) {
        # Always include Packages for consistency
        $result.Installed = $packages | ForEach-Object { $_.Name }
        $result.Packages = $packages.ToArray()
    }
    
    Write-Debug "Export-WingetState: Returning result with $($result.Count) keys"
    Write-Debug "Export-WingetState: Result keys = $($result.Keys -join ', ')"
    
    return $result
}

function Compare-WingetState {
    <#
    .SYNOPSIS
        Compares system package state with desired configuration.
    .DESCRIPTION
        Compares current Winget state with a desired configuration and
        returns differences.
    .PARAMETER System
        Current system state (from Export-WingetState)
    .PARAMETER Desired
        Desired configuration state
    .OUTPUTS
        Array of difference objects
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
        $System.Installed | ForEach-Object { Get-PackageIdentifier -Package $_ }
    } else { @() }
    
    $desiredPackages = if ($Desired.Installed) { 
        $Desired.Installed | ForEach-Object { Get-PackageIdentifier -Package $_ }
    } else { @() }
    
    # Find added packages (in desired, not in system)
    foreach ($package in $desiredPackages) {
        if ($package -notin $systemPackages) {
            [void]$differences.Add(@{
                Type = "Added"
                Path = "Winget.$package"
                SystemValue = $null
                ConfigValue = $package
            })
        }
    }
    
    # Find removed packages (in system, not in desired)
    foreach ($package in $systemPackages) {
        if ($package -notin $desiredPackages) {
            [void]$differences.Add(@{
                Type = "Removed"
                Path = "Winget.$package"
                SystemValue = $package
                ConfigValue = $null
            })
        }
    }
    
    # Check sources
    $systemSources = if ($System.Sources) { $System.Sources } else { @() }
    $desiredSources = if ($Desired.Sources) { $Desired.Sources } else { @() }
    
    foreach ($source in $desiredSources) {
        $systemSource = $systemSources | Where-Object { $_.Name -eq $source.Name }
        if (-not $systemSource) {
            [void]$differences.Add(@{
                Type = "Added"
                Path = "Winget.Sources.$($source.Name)"
                SystemValue = $null
                ConfigValue = $source
            })
        }
    }
    
    return $differences.ToArray()
}

function Merge-WingetState {
    <#
    .SYNOPSIS
        Merges system Winget state with existing config.
    .DESCRIPTION
        Uses shared merge utilities for efficiency. Prefers existing config
        for sources to preserve user customizations.
    .PARAMETER SystemState
        Hashtable with Installed, Packages, and/or Sources arrays from system
    .PARAMETER ExistingConfig
        Hashtable with Installed, Packages, and/or Sources arrays from config
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
    
    # Use generic source merge
    $mergedSources = Merge-SourceCollection `
        -SystemSources $SystemState.Sources `
        -ExistingSources $ExistingConfig.Sources `
        -NameKey "Name"
    
    if ($mergedSources.Count -gt 0) {
        $result.Sources = $mergedSources
    }
    
    return $result
}

# Export module members
Export-ModuleMember -Function @(
    'Get-ProviderInfo',
    'Test-WingetInstalled',
    'Get-WingetExport',
    'Get-InstalledWingetPackages',
    'Get-WingetPackageInfo',
    'Get-PackageIdentifier',
    'Get-PackageVersion',
    'Get-PackageFlags',
    'Test-WingetState',
    'Set-WingetState',
    'Export-WingetState',
    'Compare-WingetState',
    'Merge-WingetState'
)
