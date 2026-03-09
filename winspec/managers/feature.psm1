# providers/feature.psm1 - Declarative Windows features provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

# Import sandbox module once at module load time (consistent with service.psm1)
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue

function Get-ProviderInfo {
    return @{
        Name = "Feature"
        Type = "Declarative"
    }
}

function Get-FeatureState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FeatureName
    )
    
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
        if ($feature) {
            return $feature.State
        }
        return $null
    }
    catch {
        return $null
    }
}

# Helper function to check if feature is in desired state (eliminates duplicate logic)
function Test-FeatureInDesiredState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DesiredState,
        
        [Parameter(Mandatory = $true)]
        [string]$CurrentState
    )
    
    return ($DesiredState -eq "enabled" -and $CurrentState -eq "Enabled") -or
           ($DesiredState -eq "disabled" -and $CurrentState -eq "Disabled")
}

function Test-FeatureState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $allInDesiredState = $true
    
    foreach ($featureName in $Desired.Keys) {
        $desiredState = $Desired[$featureName]
        $currentState = Get-FeatureState -FeatureName $featureName
        
        if ($null -eq $currentState) {
            Write-Log -Level "WARN" -Message "Feature not found: $featureName"
            continue
        }
        
        $isDesired = Test-FeatureInDesiredState -DesiredState $desiredState -CurrentState $currentState
        
        if (-not $isDesired) {
            $allInDesiredState = $false
        }
    }
    
    return $allInDesiredState
}

function Set-FeatureState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    foreach ($featureName in $Desired.Keys) {
        $desiredState = $Desired[$featureName]
        $currentState = Get-FeatureState -FeatureName $featureName
        
        if ($null -eq $currentState) {
            Write-Log -Level "ERROR" -Message "Feature not found: $featureName"
            $results[$featureName] = @{ Status = "Error"; Message = "Feature not found" }
            continue
        }
        
        $isDesired = Test-FeatureInDesiredState -DesiredState $desiredState -CurrentState $currentState
        
        if ($isDesired) {
            Write-LogOk -Name $featureName -DesiredValue $desiredState
            $results[$featureName] = @{ Status = "AlreadySet"; State = $currentState }
            continue
        }
        
        Write-LogChange -Name $featureName -CurrentValue $currentState -DesiredValue $desiredState
        
        if ($PSCmdlet.ShouldProcess($featureName, "Set state to '$desiredState'")) {
            try {
                if ($desiredState -eq "enabled") {
                    Enable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -All -ErrorAction Stop
                }
                else {
                    Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop
                }
                
                Write-LogApplied -Name $featureName -DesiredValue $desiredState
                Write-Log -Level "WARN" -Message "A REBOOT may be required for this change to fully apply."
                $results[$featureName] = @{ Status = "Applied"; State = $desiredState }
            }
            catch {
                Write-LogError -Name $featureName -Details $_.Exception.Message
                $results[$featureName] = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }
    }
    
    return $results
}

function Export-FeatureState {
    <#
    .SYNOPSIS
        Exports the current Windows features state for bidirectional sync.
    .DESCRIPTION
        Captures currently enabled Windows optional features.
        Exports features that are Enabled or Disabled (not Removed).
    .PARAMETER FeatureNames
        Optional array of specific feature names to export.
    .OUTPUTS
        Hashtable with feature names and their states
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$FeatureNames = @()
    )
    
    $result = @{}
    
    try {
        if ($FeatureNames.Count -eq 0) {
            # Get all enabled features
            $features = Get-WindowsOptionalFeature -Online | Where-Object { 
                $_.State -eq 'Enabled' 
            } | Select-Object -ExpandProperty FeatureName
            $FeatureNames = $features
        }
        
        foreach ($featureName in $FeatureNames) {
            $state = Get-FeatureState -FeatureName $featureName
            if ($state) {
                # Convert to lowercase for consistency
                $result[$featureName] = $state.ToString().ToLower()
            }
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to export feature state: $($_.Exception.Message)"
    }
    
    return $result
}

function Compare-FeatureState {
    <#
    .SYNOPSIS
        Compares system feature state with desired configuration.
    .DESCRIPTION
        Compares current Windows features state with desired and
        returns differences (added, removed, changed features).
    .PARAMETER System
        Current system state (from Export-FeatureState)
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
    
    foreach ($featureName in $Desired.Keys) {
        $desiredState = $Desired[$featureName]
        $systemState = if ($System.ContainsKey($featureName)) { $System[$featureName] } else { $null }
        
        $path = "Feature.$featureName"
        
        if ($null -eq $systemState) {
            # Feature not in system
            $differences += @{
                Type = "Added"
                Path = $path
                SystemValue = $null
                ConfigValue = $desiredState
            }
        }
        elseif ($systemState -ne $desiredState) {
            # State changed
            $differences += @{
                Type = "Changed"
                Path = $path
                SystemValue = $systemState
                ConfigValue = $desiredState
            }
        }
        # Skip "Equal" entries - only Added, Changed, Removed for cleaner diffs
    }
    
    # Check for removed features (in system but not in desired)
    foreach ($featureName in $System.Keys) {
        if (-not $Desired.ContainsKey($featureName)) {
            $differences += @{
                Type = "Removed"
                Path = "Feature.$featureName"
                SystemValue = $System[$featureName]
                ConfigValue = $null
            }
        }
    }
    
    return $differences
}

function Get-FeatureMockState {
    <#
    .SYNOPSIS
        Gets the feature mock state from sandbox.
    .DESCRIPTION
        Returns the current feature state from the sandbox context.
    .OUTPUTS
        Hashtable with feature names and states
    #>
    [CmdletBinding()]
    param()
    
    # Module already imported at module scope - no need to import again
    
    if (Test-SandboxActive) {
        return Get-SandboxState -Provider "Feature"
    }
    
    return @{}
}

function Set-FeatureMockState {
    <#
    .SYNOPSIS
        Sets the feature mock state in sandbox.
    .DESCRIPTION
        Updates the current feature state in the sandbox context.
    .PARAMETER State
        Hashtable with feature names and states
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    # Module already imported at module scope
    
    if (Test-SandboxActive) {
        Set-SandboxState -Provider "Feature" -State $State
    }
}

function Invoke-FeatureSandboxApply {
    <#
    .SYNOPSIS
        Applies feature state changes in sandbox mode.
    .DESCRIPTION
        Simulates feature changes in the sandbox context.
    .PARAMETER Desired
        Desired feature state hashtable
    .OUTPUTS
        Hashtable with Status and Changed arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    # Module already imported at module scope
    
    if (-not (Test-SandboxActive)) {
        throw "Not in sandbox mode"
    }
    
    $currentState = Get-SandboxState -Provider "Feature"
    
    $results = @{
        Status = "Success"
        Changed = @()
    }
    
    foreach ($feature in $Desired.Keys) {
        $currentValue = $currentState[$feature]
        $desiredValue = $Desired[$feature]
        
        if ($currentValue -ne $desiredValue) {
            $results.Changed += @{
                Name = $feature
                OldValue = $currentValue
                NewValue = $desiredValue
            }
            $currentState[$feature] = $desiredValue
        }
    }
    
    Set-SandboxState -Provider "Feature" -State $currentState
    Add-SandboxChange -Provider "Feature" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Get-FeatureState"
    "Test-FeatureInDesiredState"
    "Test-FeatureState"
    "Set-FeatureState"
    "Export-FeatureState"
    "Compare-FeatureState"
    "Get-FeatureMockState"
    "Set-FeatureMockState"
    "Invoke-FeatureSandboxApply"
)
