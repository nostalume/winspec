# providers/feature.psm1 - Declarative Windows features provider

Import-Module (Join-Path $PSScriptRoot "..\logging.psm1")
Import-Module (Join-Path $PSScriptRoot "..\utils.psm1") 
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -ErrorAction SilentlyContinue

function Get-ProviderInfo {
    return @{
        Name = "Feature"
        Type = "Declarative"
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
    
    return (ConvertTo-FeatureSpecState $DesiredState) -eq (ConvertTo-FeatureSpecState $CurrentState)
}

function ConvertTo-FeatureSpecState {
    param($State)

    if ($null -eq $State) { return $null }
    switch ($State.ToString().ToLowerInvariant()) {
        "enabled" { return "enabled" }
        "disabled" { return "disabled" }
        default { return $State }
    }
}

function Test-FeatureState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $allInDesiredState = $true
    $features = Export-FeatureState
    
    foreach ($featureName in $Desired.Keys) {
        $desiredState = $Desired[$featureName]
        $currentState = $features["$featureName"]
        
        if ($null -eq $currentState) {
            Write-Log -Level "WARN" -Message "Feature not found: $featureName"
            $allInDesiredState = $false
            continue
        }

        $isDesired = Test-FeatureInDesiredState -DesiredState $desiredState -CurrentState $currentState
        if (-not $isDesired) {
            $allInDesiredState = $false
        }
    }
    
    return $allInDesiredState
}

function Get-FeatureState {
    <#
    .SYNOPSIS
        Gets the state of a single Windows optional feature.
    .PARAMETER FeatureName
        The name of the Windows optional feature.
    .OUTPUTS
        String state ("Enabled", "Disabled") or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureName
    )

    $features = Export-FeatureState -FeatureNames @($FeatureName)
    return $features[$FeatureName]
}

function Set-FeatureState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )

    if (-not (Test-IsAdmin)) {
        Write-Log -Level "ERROR" -Message "Windows feature changes require Administrator privileges"
        return @{ Status = "Error"; Reason = "RequiresAdministrator"; Message = "Windows feature changes require Administrator privileges" }
    }
    
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
                    Enable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -All -ErrorAction Stop | Out-Null
                }
                else {
                    Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
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
    [CmdletBinding()]
    param(
        [string[]]$FeatureNames = @()
    )

    $result = @{}
    if (-not (Test-IsAdmin)) {
        Write-Log -Level "ERROR" -Message "Windows feature export requires Administrator privileges"
        return $result
    }
    try {
        $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop |
            Where-Object { $_.State -ne 'Removed' -and $_.State -ne "DisabledWithPayloadRemoved" } |
            Select-Object FeatureName, @{ Name = 'State'; Expression = { $_.State.ToString() } }

        if ($FeatureNames.Count -gt 0) {
            $features = $features | Where-Object {
                $FeatureNames -contains $_.FeatureName
            }
        }

        Write-Debug "Export Features:`n$($features | Out-String)"
        foreach ($f in $features) { $result[$f.FeatureName] = $f.State }
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
        $desiredState = ConvertTo-FeatureSpecState $Desired[$featureName]
        $systemState = if ($System.ContainsKey($featureName)) { $System[$featureName] } else { $null }
        $systemSpecState = ConvertTo-FeatureSpecState $systemState
        
        $path = "Feature.$featureName"
        
        if ($null -eq $systemState) {
            # Feature not in system
            $differences += @{
                Type        = "Added"
                Path        = $path
                SystemValue = $null
                ConfigValue = $desiredState
            }
        }
        elseif ($systemSpecState -ne $desiredState) {
            # State changed
            $differences += @{
                Type        = "Changed"
                Path        = $path
                SystemValue = $systemState
                ConfigValue = $desiredState
            }
        }
        # Skip "Equal" entries - only Added, Changed, Removed for cleaner diffs
    }
    return $differences
}

function Invoke-FeatureSandbox {
    <#
    .SYNOPSIS
        Applies feature state changes in sandbox mode.

    .DESCRIPTION
        Simulates feature changes in the sandbox context without touching
        the real system feature configuration.

    .PARAMETER Desired
        Desired feature state hashtable.

    .OUTPUTS
        Hashtable with Status and Changed arrays.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )

    if (-not (Test-SandboxActive)) {
        throw "Sandbox not active"
    }

    $providerName = "Feature"

    $results = @{
        Status  = "Success"
        Changed = @()
    }

    Update-SandboxState $providerName {
        param($state)

        if (-not $state) {
            $state = @{}
        }
        foreach ($feature in $Desired.Keys) {

            $currentValue = $state[$feature]
            $desiredValue = $Desired[$feature]

            if ($currentValue -ne $desiredValue) {

                $results.Changed += @{
                    Name     = $feature
                    OldValue = $currentValue
                    NewValue = $desiredValue
                }

                $state[$feature] = $desiredValue
            }
        }

        return $state
    }
    # record change in sandbox history
    Update-SandboxChanges "Feature" "Apply" $results

    return $results
}

function Invoke-FeatureSandboxApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )

    return Invoke-FeatureSandbox -Desired $Desired
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Get-FeatureState"
    "ConvertTo-FeatureSpecState"
    "Test-FeatureInDesiredState"
    "Test-FeatureState"
    "Set-FeatureState"
    "Export-FeatureState"
    "Compare-FeatureState"
    "Invoke-FeatureSandbox"
    "Invoke-FeatureSandboxApply"
)
