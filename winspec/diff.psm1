# diff.psm1 - System state diff functionality for bidirectional sync

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "export.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

function Compare-SystemState {
    <#
    .SYNOPSIS
        Compares system state with a configuration specification.
    .DESCRIPTION
        Compares current system state (or exported state) with a desired
        configuration and returns differences across all providers.
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
        
        [Parameter(Mandatory = $false)]
        [string]$Against,
        
        [Parameter(Mandatory = $false)]
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
        $systemConfig = Export-SystemState -Providers $Providers
    }
    
    # Determine which providers to compare
    $providersToCompare = if ($Providers.Count -gt 0) { 
        $Providers 
    } else { 
        @("Package", "Registry", "Service", "Feature") | Where-Object { 
            $desiredConfig.ContainsKey($_) -or $systemConfig.ContainsKey($_) 
        }
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
        
        # Load the provider module and call its Compare function
        $modulePath = Join-Path $PSScriptRoot "managers\$($providerName.ToLower()).psm1"
        if (Test-Path $modulePath) {
            try {
                Import-Module $modulePath -Force
                $compareFunction = "Compare-${providerName}State"
                
                if (Get-Command $compareFunction -ErrorAction SilentlyContinue) {
                    $differences = & $compareFunction -System $systemState -Desired $desiredState
                    
                    foreach ($diff in $differences) {
                        switch ($diff.Type) {
                            "Added" { $allDifferences.Added += $diff }
                            "Removed" { $allDifferences.Removed += $diff }
                            "Changed" { $allDifferences.Changed += $diff }
                            "Equal" { $allDifferences.Equal += $diff }
                            # Handle case where Equal entries might not be returned (optimization)
                        }
                    }
                    
                    $count = $differences.Count
                    Write-Log -Level "OK" -Message "Found $count differences in $providerName"
                }
                else {
                    Write-Log -Level "WARN" -Message "Compare function not found: $compareFunction"
                }
            }
            catch {
                Write-Log -Level "ERROR" -Message "Failed to compare $providerName state: $($_.Exception.Message)"
            }
        }
        else {
            Write-Log -Level "WARN" -Message "Provider module not found: $modulePath"
        }
    }
    
    return $allDifferences
}

function Format-DiffOutput {
    <#
    .SYNOPSIS
        Formats differences for human-readable display.
    .DESCRIPTION
        Takes the output from Compare-SystemState and formats it
        as a readable diff output.
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
            if ($item.ConfigValue -is [hashtable]) {
                $details = ($item.ConfigValue.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                $output += "       Value: { $details }"
            }
            elseif ($item.ConfigValue -is [array]) {
                $output += "       Value: @($($item.ConfigValue -join ', '))"
            }
            else {
                $output += "       Value: $($item.ConfigValue)"
            }
        }
    }
    
    # Removed items
    if ($Differences.Removed.Count -gt 0) {
        $output += "`n[-] REMOVED (in system, not in config):"
        foreach ($item in $Differences.Removed) {
            $output += "    $($item.Path)"
            if ($item.SystemValue -is [hashtable]) {
                $details = ($item.SystemValue.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                $output += "       Current: { $details }"
            }
            elseif ($item.SystemValue -is [array]) {
                $output += "       Current: @($($item.SystemValue -join ', '))"
            }
            else {
                $output += "       Current: $($item.SystemValue)"
            }
        }
    }
    
    # Changed items
    if ($Differences.Changed.Count -gt 0) {
        $output += "`n[~] CHANGED (different values):"
        foreach ($item in $Differences.Changed) {
            $output += "    $($item.Path)"
            $output += "       System:  $(ConvertTo-DisplayValue $item.SystemValue)"
            $output += "       Config:  $(ConvertTo-DisplayValue $item.ConfigValue)"
        }
    }
    
    # Equal items (only show count) - handle case where Equal might not exist in custom hashtables
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

Export-ModuleMember -Function @(
    "Compare-SystemState"
    "Format-DiffOutput"
)
