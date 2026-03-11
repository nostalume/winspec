# sandbox.psm1 - Sandbox engine for WinSpec: mock state management

# Import dependent modules
$ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $ModuleRoot "logging.psm1") -Global

# Constants
$Script:SandboxDir = Join-Path $env:USERPROFILE ".config\winspec\sandbox"
$Script:SandboxStateDir = Join-Path $Script:SandboxDir "state"
$Script:SandboxProfilesDir = Join-Path $Script:SandboxStateDir "profiles"
$Script:SandboxHistoryDir = Join-Path $Script:SandboxDir "history"

# Sandbox context (module-level state)
$Script:SandboxContext = $null

# Default sandbox state templates
$Script:DefaultState = @{
    Scoop = @{
        apps = @()
        buckets = @(
            @{ name = "main"; source = "https://github.com/ScoopInstaller/Main" }
        )
    }
    Winget = @{
        packages = @()
    }
    Registry = @{
        Explorer = @{
            ShowHidden = $false
            HideFileExt = $true
        }
        Clipboard = @{}
        Theme = @{}
        Desktop = @{}
    }
    Service = @{}
    Feature = @{}
}

function Get-SandboxContext {
    <#
    .SYNOPSIS
        Returns the current sandbox context.
    
    .DESCRIPTION
        Returns the current sandbox context if in sandbox mode, or $null if not.
    
    .OUTPUTS
        hashtable or $null
    #>
    return $Script:SandboxContext
}

function Test-SandboxActive {
    <#
    .SYNOPSIS
        Checks if sandbox mode is currently active.
    
    .DESCRIPTION
        Returns $true if sandbox mode is active, $false otherwise.
    
    .OUTPUTS
        bool
    #>
    return $null -ne $Script:SandboxContext
}

function Get-SandboxMode {
    <#
    .SYNOPSIS
        Returns the current sandbox mode.
    
    .DESCRIPTION
        Returns the current sandbox mode ("DryRun", "Mock", "Live") or "Live" if not in sandbox.
    
    .OUTPUTS
        string
    #>
    if ($null -eq $Script:SandboxContext) {
        return "Live"
    }
    return $Script:SandboxContext.Mode
}

function Initialize-SandboxDirectory {
    <#
    .SYNOPSIS
        Initializes the sandbox directory structure.
    
    .DESCRIPTION
        Creates the sandbox directories if they don't exist.
    #>
    [CmdletBinding()]
    param()
    
    $dirs = @($Script:SandboxDir, $Script:SandboxStateDir, $Script:SandboxProfilesDir, $Script:SandboxHistoryDir)
    
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-SandboxStatePath {
    <#
    .SYNOPSIS
        Gets the path to a sandbox state file.
    
    .DESCRIPTION
        Returns the path to a sandbox state file for the specified provider.
    
    .PARAMETER Provider
        The provider name (Scoop, Winget, Registry, Service, Feature).
    
    .PARAMETER Profile
        The sandbox profile name (default: "default").
    
    .OUTPUTS
        string
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Scoop", "Winget", "Registry", "Service", "Feature")]
        [string]$Provider,
        
        [Parameter(Mandatory = $false)]
        [string]$Profile = "default"
    )
    
    $profilePath = Join-Path $Script:SandboxProfilesDir "$Profile.json"
    
    if (Test-Path $profilePath) {
        $stateData = Get-Content $profilePath | ConvertFrom-Json
        return $stateData.$Provider
    }
    
    return $Script:DefaultState.$Provider
}

function Import-SandboxState {
    <#
    .SYNOPSIS
        Imports a sandbox state profile.
    
    .DESCRIPTION
        Loads a sandbox state profile from disk.
    
    .PARAMETER Profile
        The sandbox profile name (default: "default").
    
    .OUTPUTS
        hashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Profile = "default"
    )
    
    $profilePath = Join-Path $Script:SandboxProfilesDir "$Profile.json"
    
    if (Test-Path $profilePath) {
        try {
            $content = Get-Content $profilePath -Raw | ConvertFrom-Json
            Write-Log -Level "OK" -Message "Loaded sandbox profile: $Profile"
            return @{
                Package = if ($content.Package) { $content.Package } else { $Script:DefaultState.Package }
                Registry = if ($content.Registry) { $content.Registry } else { $Script:DefaultState.Registry }
                Service = if ($content.Service) { $content.Service } else { $Script:DefaultState.Service }
                Feature = if ($content.Feature) { $content.Feature } else { $Script:DefaultState.Feature }
            }
        }
        catch {
            Write-Log -Level "ERROR" -Message "Failed to load sandbox profile: $_"
            return $Script:DefaultState.Clone()
        }
    }
    
    Write-Log -Level "INFO" -Message "Using default sandbox state"
    return $Script:DefaultState.Clone()
}

function Export-SandboxState {
    <#
    .SYNOPSIS
        Exports the current sandbox state to a profile.
    
    .DESCRIPTION
        Saves the current sandbox state to a profile file.
    
    .PARAMETER Profile
        The sandbox profile name.
    
    .PARAMETER State
        The state hashtable to export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    Initialize-SandboxDirectory
    
    $profilePath = Join-Path $Script:SandboxProfilesDir "$Profile.json"
    $State | ConvertTo-Json -Depth 10 | Set-Content $profilePath -Encoding UTF8
    
    Write-Log -Level "OK" -Message "Exported sandbox profile: $Profile"
}

function Enter-Sandbox {
    <#
    .SYNOPSIS
        Enters sandbox mode.
    
    .DESCRIPTION
        Initializes the sandbox context with the specified mode and profile.
    
    .PARAMETER Mode
        The sandbox mode: "DryRun", "Mock", or "Live".
    
    .PARAMETER Profile
        The sandbox profile name to use for mock state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("DryRun", "Mock", "Live")]
        [string]$Mode = "Mock",
        
        [Parameter(Mandatory = $false)]
        [string]$Profile = "default"
    )
    
    if ($null -ne $Script:SandboxContext) {
        Write-Log -Level "WARN" -Message "Already in sandbox mode. Exiting current sandbox first."
        Exit-Sandbox
    }
    
    Initialize-SandboxDirectory
    
    $Script:SandboxContext = @{
        Mode = $Mode
        Profile = $Profile
        OriginalState = @{}
        CurrentState = @{}
        Changes = @()
        StartTime = Get-Date
    }
    
    if ($Mode -eq "Mock") {
        $Script:SandboxContext.CurrentState = Import-SandboxState -Profile $Profile
        $Script:SandboxContext.OriginalState = $Script:SandboxContext.CurrentState.Clone()
    }
    else {
        # For DryRun, use default state
        $Script:SandboxContext.CurrentState = $Script:DefaultState.Clone()
        $Script:SandboxContext.OriginalState = $Script:SandboxContext.CurrentState.Clone()
    }
    
    Write-Log -Level "OK" -Message "Entered sandbox mode: $Mode (Profile: $Profile)"
    
    return $Script:SandboxContext
}

function Exit-Sandbox {
    <#
    .SYNOPSIS
        Exits sandbox mode.
    
    .DESCRIPTION
        Exits sandbox mode and optionally exports changes.
    
    .PARAMETER DiscardChanges
        If specified, changes are discarded instead of exported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$DiscardChanges
    )
    
    if ($null -eq $Script:SandboxContext) {
        Write-Log -Level "WARN" -Message "Not in sandbox mode"
        return
    }
    
    $mode = $Script:SandboxContext.Mode
    $changesCount = $Script:SandboxContext.Changes.Count
    
    if ($DiscardChanges) {
        Write-Log -Level "INFO" -Message "Sandbox changes discarded"
    }
    elseif ($changesCount -gt 0) {
        Export-SandboxHistory -Context $Script:SandboxContext
    }
    
    $Script:SandboxContext = $null
    
    Write-Log -Level "OK" -Message "Exited sandbox mode ($mode). Changes: $changesCount"
}

function Export-SandboxHistory {
    <#
    .SYNOPSIS
        Exports sandbox history to a file.
    
    .DESCRIPTION
        Saves the sandbox session history to a timestamped file.
    
    .PARAMETER Context
        The sandbox context to export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    Initialize-SandboxDirectory
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
    $historyPath = Join-Path $Script:SandboxHistoryDir "$timestamp.json"
    
    $history = @{
        timestamp = (Get-Date).ToString("o")
        mode = $Context.Mode
        profile = $Context.Profile
        startTime = $Context.StartTime.ToString("o")
        changes = $Context.Changes
        finalState = $Context.CurrentState
    }
    
    $history | ConvertTo-Json -Depth 10 | Set-Content $historyPath -Encoding UTF8
    
    Write-Log -Level "OK" -Message "Sandbox history saved: $historyPath"
}

function Get-SandboxChanges {
    <#
    .SYNOPSIS
        Returns the changes made in the current sandbox session.
    
    .DESCRIPTION
        Returns an array of changes made in the current sandbox session.
    
    .OUTPUTS
        array
    #>
    if ($null -eq $Script:SandboxContext) {
        return @()
    }
    return $Script:SandboxContext.Changes
}

function Add-SandboxChange {
    <#
    .SYNOPSIS
        Records a change in the sandbox.
    
    .DESCRIPTION
        Adds a change record to the sandbox history.
    
    .PARAMETER Provider
        The provider name.
    
    .PARAMETER Change
        The change details hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Provider,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Change
    )
    
    if ($null -eq $Script:SandboxContext) {
        return
    }
    
    $Script:SandboxContext.Changes += @{
        Provider = $Provider
        Details = $Change
        Timestamp = Get-Date
    }
}

function Get-SandboxState {
    <#
    .SYNOPSIS
        Gets the current sandbox state for a provider.
    
    .DESCRIPTION
        Returns the current sandbox state for a provider, depending on sandbox mode.
    
    .PARAMETER Provider
        The provider name.
    
    .OUTPUTS
        hashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Scoop", "Winget", "Registry", "Service", "Feature")]
        [string]$Provider
    )
    
    if ($null -eq $Script:SandboxContext) {
        throw "Not in sandbox mode"
    }
    
    if ($Script:SandboxContext.Mode -eq "Live") {
        throw "Cannot get sandbox state in Live mode"
    }
    
    $state = $Script:SandboxContext.CurrentState[$Provider]
    
    # Return default state if null
    if ($null -eq $state) {
        return $Script:DefaultState[$Provider].Clone()
    }
    
    return $state
}

function Set-SandboxState {
    <#
    .SYNOPSIS
        Sets the current sandbox state for a provider.
    
    .DESCRIPTION
        Updates the current sandbox state for a provider.
    
    .PARAMETER Provider
        The provider name.
    
    .PARAMETER State
        The new state hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Scoop", "Winget", "Registry", "Service", "Feature")]
        [string]$Provider,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    if ($null -eq $Script:SandboxContext) {
        throw "Not in sandbox mode"
    }
    
    $Script:SandboxContext.CurrentState[$Provider] = $State
}

function Reset-SandboxState {
    <#
    .SYNOPSIS
        Resets the sandbox state to the original state.
    
    .DESCRIPTION
        Resets the current sandbox state to the original state at sandbox entry.
    #>
    [CmdletBinding()]
    param()
    
    if ($null -eq $Script:SandboxContext) {
        Write-Log -Level "WARN" -Message "Not in sandbox mode"
        return
    }
    
    $Script:SandboxContext.CurrentState = $Script:SandboxContext.OriginalState.Clone()
    $Script:SandboxContext.Changes = @()
    
    Write-Log -Level "INFO" -Message "Sandbox state reset to original"
}

function Get-SandboxProfiles {
    <#
    .SYNOPSIS
        Lists available sandbox profiles.
    
    .DESCRIPTION
        Returns an array of available sandbox profile names.
    
    .OUTPUTS
        array
    #>
    [CmdletBinding()]
    param()
    
    Initialize-SandboxDirectory
    
    $profiles = @()
    
    try {
        if (Test-Path $Script:SandboxProfilesDir) {
            $files = @(Get-ChildItem -Path $Script:SandboxProfilesDir -Filter "*.json" -ErrorAction SilentlyContinue)
            if ($files.Count -gt 0) {
                # Force array output by using explicit array construction
                $result = @()
                foreach ($file in $files) {
                    $result += $file.BaseName
                }
                $profiles = $result
            }
        }
    }
    catch {
        # Return empty array on error
    }
    
    # Ensure we return an array
    if ($null -eq $profiles) {
        return ,@()
    }
    # Use comma prefix to preserve array on return
    return ,$profiles
}

function Remove-SandboxProfile {
    <#
    .SYNOPSIS
        Removes a sandbox profile.
    
    .DESCRIPTION
        Deletes a sandbox profile file.
    
    .PARAMETER Profile
        The profile name to remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile
    )
    
    $profilePath = Join-Path $Script:SandboxProfilesDir "$Profile.json"
    
    if (Test-Path $profilePath) {
        Remove-Item $profilePath -Force
        Write-Log -Level "OK" -Message "Removed sandbox profile: $Profile"
    }
    else {
        Write-Log -Level "WARN" -Message "Profile not found: $Profile"
    }
}

function Invoke-SandboxDryRun {
    <#
    .SYNOPSIS
        Performs a dry-run comparison.
    
    .DESCRIPTION
        Compares desired state against current (mock or real) state without applying changes.
    
    .PARAMETER Spec
        The desired state specification.
    
    .PARAMETER SystemStateProvider
        Function to get real system state for comparison.
    
    .OUTPUTS
        hashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Spec,
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$SystemStateProvider
    )
    
    $results = @{
        Mode = "DryRun"
        Comparison = @{}
    }
    
    $providers = @("Scoop", "Winget", "Registry", "Service", "Feature")
    
    foreach ($provider in $providers) {
        if (-not $Spec.ContainsKey($provider)) {
            continue
        }
        
        $desired = $Spec[$provider]
        
        # Get current state
        if ($null -ne $Script:SandboxContext -and $Script:SandboxContext.Mode -eq "Mock") {
            $current = $Script:SandboxContext.CurrentState[$provider]
        }
        elseif ($SystemStateProvider) {
            $current = & $SystemStateProvider
        }
        else {
            continue
        }
        
        # Compare
        $comparison = Compare-ProviderState -Provider $provider -Current $current -Desired $desired
        
        $results.Comparison[$provider] = $comparison
    }
    
    return $results
}

function Compare-ProviderState {
    <#
    .SYNOPSIS
        Compares current and desired state for a provider.
    
    .DESCRIPTION
        Returns a comparison of current vs desired state for a specific provider.
    
    .PARAMETER Provider
        The provider name.
    
    .PARAMETER Current
        The current state.
    
    .PARAMETER Desired
        The desired state.
    
    .OUTPUTS
        hashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Provider,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Current,
        
        [parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $comparison = @{
        Added = @()
        Removed = @()
        Changed = @()
        Unchanged = @()
    }
    
    switch ($Provider) {
        "Scoop" {
            $currentApps = @($Current.apps | ForEach-Object { $_.name })
            $desiredApps = @($Desired.Installed)
            
            foreach ($app in $desiredApps) {
                $appName = $app
                if ($app -is [hashtable]) { $appName = $app.Name }
                
                if ($appName -notin $currentApps) {
                    $comparison.Added += $appName
                }
                else {
                    $comparison.Unchanged += $appName
                }
            }
            
            foreach ($app in $currentApps) {
                if ($app -notin $desiredApps) {
                    $comparison.Removed += $app
                }
            }
        }
        
        "Winget" {
            $currentPackages = @($Current.packages | ForEach-Object { $_.Id })
            $desiredPackages = @($Desired.Installed)
            
            foreach ($pkg in $desiredPackages) {
                $pkgId = $pkg
                if ($pkg -is [hashtable]) { $pkgId = $pkg.Name }
                
                if ($pkgId -notin $currentPackages) {
                    $comparison.Added += $pkgId
                }
                else {
                    $comparison.Unchanged += $pkgId
                }
            }
            
            foreach ($pkg in $currentPackages) {
                if ($pkg -notin $desiredPackages) {
                    $comparison.Removed += $pkg
                }
            }
        }
        
        "Registry" {
            foreach ($category in $Desired.Keys) {
                if (-not $Current.ContainsKey($category)) {
                    $Current[$category] = @{}
                }
                
                foreach ($key in $Desired[$category].Keys) {
                    $currentValue = $Current[$category][$key]
                    $desiredValue = $Desired[$category][$key]
                    
                    if ($null -eq $currentValue) {
                        $comparison.Added += @{ Category = $category; Key = $key; Value = $desiredValue }
                    }
                    elseif ($currentValue -ne $desiredValue) {
                        $comparison.Changed += @{ Category = $category; Key = $key; OldValue = $currentValue; NewValue = $desiredValue }
                    }
                    else {
                        $comparison.Unchanged += @{ Category = $category; Key = $key; Value = $desiredValue }
                    }
                }
            }
        }
        
        "Service" {
            foreach ($service in $Desired.Keys) {
                $currentValue = $Current[$service]
                $desiredValue = $Desired[$service].Startup
                
                if ($null -eq $currentValue) {
                    $comparison.Added += @{ Name = $service; Startup = $desiredValue }
                }
                elseif ($currentValue.Startup -ne $desiredValue) {
                    $comparison.Changed += @{ Name = $service; OldStartup = $currentValue.Startup; NewStartup = $desiredValue }
                }
                else {
                    $comparison.Unchanged += @{ Name = $service; Startup = $desiredValue }
                }
            }
        }
        
        "Feature" {
            foreach ($feature in $Desired.Keys) {
                $currentValue = $Current[$feature]
                $desiredValue = $Desired[$feature]
                
                if ($null -eq $currentValue -or $currentValue -ne $desiredValue) {
                    if ($desiredValue -eq "Enabled") {
                        $comparison.Added += @{ Name = $feature }
                    }
                    else {
                        $comparison.Changed += @{ Name = $feature; OldValue = $currentValue; NewValue = $desiredValue }
                    }
                }
                else {
                    $comparison.Unchanged += @{ Name = $feature }
                }
            }
        }
    }
    
    return $comparison
}

function Format-SandboxDiff {
    <#
    .SYNOPSIS
        Formats sandbox comparison results as a readable diff.
    
    .DESCRIPTION
        Converts comparison results to a human-readable string format.
    
    .PARAMETER Comparison
        The comparison hashtable from Invoke-SandboxDryRun.
    
    .OUTPUTS
        string
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Comparison
    )
    
    $output = @()
    
    foreach ($provider in $Comparison.Keys) {
        $comp = $Comparison[$provider]
        
        $output += "=== $provider ==="
        
        if ($comp.Added.Count -gt 0) {
            foreach ($item in $comp.Added) {
                if ($item -is [string]) {
                    $output += "[+] $item"
                }
                elseif ($item.Category) {
                    $output += "[+] $($item.Category).$($item.Key) = $($item.Value)"
                }
                elseif ($item.Name) {
                    $output += "[+] $($item.Name)"
                }
            }
        }
        
        if ($comp.Removed.Count -gt 0) {
            foreach ($item in $comp.Removed) {
                $output += "[-] $item"
            }
        }
        
        if ($comp.Changed.Count -gt 0) {
            foreach ($item in $comp.Changed) {
                if ($item.OldValue -and $item.NewValue) {
                    $output += "[~] $($item.Category).$($item.Key): $($item.OldValue) -> $($item.NewValue)"
                    $output += "[~] $($item.Name): $($item.OldStartup) -> $($item.NewStartup)"
                }
            }
        }
        
        if ($comp.Unchanged.Count -gt 0) {
            foreach ($item in $comp.Unchanged) {
                if ($item -is [string]) {
                    $output += "[=] $item"
                }
                elseif ($item.Name) {
                    $output += "[=] $($item.Name)"
                }
            }
        }
        
        $output += ""
    }
    
    return $output -join "`n"
}

# Export module members
Export-ModuleMember -Function @(
    'Get-SandboxContext'
    'Test-SandboxActive'
    'Get-SandboxMode'
    'Initialize-SandboxDirectory'
    'Get-SandboxStatePath'
    'Import-SandboxState'
    'Export-SandboxState'
    'Enter-Sandbox'
    'Exit-Sandbox'
    'Export-SandboxHistory'
    'Get-SandboxChanges'
    'Add-SandboxChange'
    'Get-SandboxState'
    'Set-SandboxState'
    'Reset-SandboxState'
    'Get-SandboxProfiles'
    'Remove-SandboxProfile'
    'Invoke-SandboxDryRun'
    'Compare-ProviderState'
    'Format-SandboxDiff'
)
