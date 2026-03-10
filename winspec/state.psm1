# state.psm1 - Common state manipulation functions for WinSpec
# Provides shared functionality for pull, push, diff, merge, and sync commands

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

# =============================================================================
# PROVIDER RESOLUTION
# =============================================================================

function Resolve-ProviderList {
    <#
    .SYNOPSIS
        Resolves the list of providers to operate on.
    .PARAMETER Providers
        Array of provider names to filter by (optional)
    .OUTPUTS
        Array of provider names to use
    #>
    param(
        [string[]]$Providers = @()
    )
    
    # Default providers
    $defaultProviders = @("Package", "Registry", "Service", "Feature")
    
    if ($Providers.Count -gt 0) {
        # Filter to requested providers
        return $Providers
    }
    
    return $defaultProviders
}

function Get-AvailableProviders {
    <#
    .SYNOPSIS
        Gets the list of available providers from the managers directory.
    .OUTPUTS
        Array of available provider names
    #>
    $managersPath = Join-Path $PSScriptRoot "managers"
    $available = @()
    
    if (Test-Path $managersPath) {
        Get-ChildItem -Path $managersPath -Filter "*.psm1" | ForEach-Object {
            $available += $_.BaseName
        }
    }
    
    return $available
}

# =============================================================================
# STATE CAPTURE
# =============================================================================

function Get-SystemState {
    <#
    .SYNOPSIS
        Captures the current system state via providers.
    .PARAMETER Providers
        Array of provider names to capture (default: all available)
    .OUTPUTS
        Hashtable representing the system state
    #>
    [CmdletBinding()]
    param(
        [string[]]$Providers = @()
    )
    
    $providersToCapture = Resolve-ProviderList -Providers $Providers
    
    $state = @{}
    
    foreach ($provider in $providersToCapture) {
        $modulePath = Join-Path $PSScriptRoot "managers\$provider.psm1"
        if (Test-Path $modulePath) {
            try {
                Import-Module $modulePath -Force
                # Use Export- function which has no mandatory params
                $exportFunction = "Export-${provider}State"
                
                if (Get-Command $exportFunction -ErrorAction SilentlyContinue) {
                    $providerState = & $exportFunction
                    if ($providerState) {
                        $state[$provider] = $providerState
                    }
                }
            }
            catch {
                Write-Log -Level "WARN" -Message "Failed to capture $provider state: $($_.Exception.Message)"
            }
        }
    }
    
    return $state
}

# =============================================================================
# STATE COMPARISON
# =============================================================================

function Compare-ProviderState {
    <#
    .SYNOPSIS
        Compares desired state vs current system state for a provider.
    .PARAMETER Provider
        Provider name (e.g., "Registry", "Service")
    .PARAMETER Desired
        Desired state hashtable
    .PARAMETER Current
        Current system state hashtable
    .OUTPUTS
        Array of difference objects with Type, Path, CurrentValue, DesiredValue
    #>
    param(
        [string]$Provider,
        [hashtable]$Desired,
        [hashtable]$Current
    )
    
    $differences = @()
    
    $modulePath = Join-Path $PSScriptRoot "managers\$Provider.psm1"
    if (Test-Path $modulePath) {
        try {
            Import-Module $modulePath -Force
            $compareFunction = "Compare-${Provider}State"
            
            if (Get-Command $compareFunction -ErrorAction SilentlyContinue) {
                $differences = & $compareFunction -System $Current -Desired $Desired
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Failed to compare $Provider state: $($_.Exception.Message)"
        }
    }
    
    return $differences
}

function Compare-SystemState {
    <#
    .SYNOPSIS
        Compares system state with a configuration specification.
    .PARAMETER SpecPath
        Path to the desired configuration spec file
    .PARAMETER Against
        Optional path to compare against (instead of live system)
    .PARAMETER Providers
        Array of provider names to compare (default: all)
    .OUTPUTS
        Hashtable with differences per provider
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SpecPath,
        
        [string]$Against,
        
        [string[]]$Providers = @()
    )
    
    Write-Log -Level "INFO" -Message "Starting system state comparison..."
    
    # Import the desired config
    $desiredConfig = $null
    try {
        $desiredConfig = & $SpecPath
        if ($desiredConfig -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Spec must return a hashtable: $SpecPath"
            return $null
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to load spec: $($_.Exception.Message)"
        return $null
    }
    
    # Get system state (either live or from file)
    $systemConfig = $null
    if ($Against) {
        try {
            $systemConfig = & $Against
            Write-Log -Level "INFO" -Message "Comparing against: $Against"
        }
        catch {
            Write-Log -Level "ERROR" -Message "Failed to load comparison file: $($_.Exception.Message)"
            return $null
        }
    }
    else {
        Write-Log -Level "INFO" -Message "Comparing against live system state..."
        $systemConfig = Get-SystemState -Providers $Providers
    }
    
    # Determine which providers to compare
    $providersToCompare = Resolve-ProviderList -Providers $Providers | Where-Object {
        $desiredConfig.ContainsKey($_) -or $systemConfig.ContainsKey($_)
    }
    
    $allDifferences = @{
        Added = @()
        Removed = @()
        Changed = @()
        Equal = @()
    }
    
    # Compare each provider
    foreach ($providerName in $providersToCompare) {
        $systemState = if ($systemConfig.ContainsKey($providerName)) { $systemConfig[$providerName] } else { @{} }
        $desiredState = if ($desiredConfig.ContainsKey($providerName)) { $desiredConfig[$providerName] } else { @{} }
        
        # Skip if neither has data
        if ($systemState.Count -eq 0 -and $desiredState.Count -eq 0) {
            continue
        }
        
        Write-Log -Level "INFO" -Message "Comparing $providerName state..."
        
        $differences = Compare-ProviderState -Provider $providerName -Desired $desiredState -Current $systemState
        
        foreach ($diff in $differences) {
            switch ($diff.Type) {
                "Added" { $allDifferences.Added += $diff }
                "Removed" { $allDifferences.Removed += $diff }
                "Changed" { $allDifferences.Changed += $diff }
                "Equal" { $allDifferences.Equal += $diff }
            }
        }
        
        $count = $differences.Count
        Write-Log -Level "OK" -Message "Found $count differences in $providerName"
    }
    
    return $allDifferences
}

# =============================================================================
# CONFIG FILE OPERATIONS (use utils.psm1 implementations)
# =============================================================================

# Note: Export-ConfigFile and Import-ConfigFile are provided by utils.psm1
# Aliases for backward compatibility with modules expecting them here

# =============================================================================
# DIFF OUTPUT FORMATTING
# =============================================================================

function Format-DiffOutput {
    <#
    .SYNOPSIS
        Formats differences for human-readable display.
    .PARAMETER Differences
        The differences hashtable from Compare-SystemState
    .OUTPUTS
        String formatted for display
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Differences
    )
    
    $output = @()
    $output += "`n=== STATE DIFFERENCES ===`n"
    
    # Added items
    if ($Differences.Added.Count -gt 0) {
        $output += "`n[+] ADDED (in config, not in system):"
        foreach ($item in $Differences.Added) {
            $output += "    $($item.Path)"
            if ($item.DesiredValue -is [hashtable]) {
                $details = ($item.DesiredValue.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                $output += "       Value: { $details }"
            }
            elseif ($item.DesiredValue -is [array]) {
                $output += "       Value: @($($item.DesiredValue -join ', '))"
            }
            else {
                $output += "       Value: $($item.DesiredValue)"
            }
        }
    }
    
    # Removed items
    if ($Differences.Removed.Count -gt 0) {
        $output += "`n[-] REMOVED (in system, not in config):"
        foreach ($item in $Differences.Removed) {
            $output += "    $($item.Path)"
            if ($item.CurrentValue -is [hashtable]) {
                $details = ($item.CurrentValue.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                $output += "       Current: { $details }"
            }
            elseif ($item.CurrentValue -is [array]) {
                $output += "       Current: @($($item.CurrentValue -join ', '))"
            }
            else {
                $output += "       Current: $($item.CurrentValue)"
            }
        }
    }
    
    # Changed items
    if ($Differences.Changed.Count -gt 0) {
        $output += "`n[~] CHANGED (different values):"
        foreach ($item in $Differences.Changed) {
            $output += "    $($item.Path)"
            $output += "       System:  $(ConvertTo-DisplayValue $item.CurrentValue)"
            $output += "       Config:  $(ConvertTo-DisplayValue $item.DesiredValue)"
        }
    }
    
    # Equal items
    $equalCount = if ($Differences.Equal) { $Differences.Equal.Count } else { 0 }
    if ($equalCount -gt 0) {
        $output += "`n[=] EQUAL (matched): $equalCount items"
    }
    
    # Summary
    $totalChanges = $Differences.Added.Count + $Differences.Removed.Count + $Differences.Changed.Count
    $output += "`n---"
    $output += "Summary: $($Differences.Added.Count) added, $($Differences.Removed.Count) removed, $($Differences.Changed.Count) changed, $equalCount equal"
    $output += "Total differences: $totalChanges"
    
    return $output -join "`n"
}

# =============================================================================
# EXPORTS
# =============================================================================

# Note: Export-ConfigFile and Import-ConfigFile are now re-exported from utils.psm1
# for backward compatibility

Export-ModuleMember -Function @(
    "Resolve-ProviderList"
    "Get-AvailableProviders"
    "Get-SystemState"
    "Compare-ProviderState"
    "Compare-SystemState"
    "Export-ConfigFile"
    "Import-ConfigFile"
    "Format-DiffOutput"
)
