# diff.psm1 - System state diff functionality for WinSpec
# Compares system state with a configuration specification
# Implements the 'diff' command as part of Git-like command structure

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "state.psm1") -Force

function ConvertTo-DisplayValue {
    param($Value)
    if ($null -eq $Value) { return '(null)' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    return $Value.ToString()
}

function Format-DiffOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Differences)

    $output = @()
    $output += "`n=== STATE DIFFERENCES ===`n"

    $addedItems = if ($Differences.Added) { $Differences.Added } else { @() }
    if ($addedItems.Count -gt 0) {
        $output += "`n[+] ADDED (in config, not in system):"
        foreach ($item in $addedItems) {
            $output += "    $($item.Path)"
            $output += "       Value: $(ConvertTo-DisplayValue $item.ConfigValue)"
        }
    }

    $removedItems = if ($Differences.Removed) { $Differences.Removed } else { @() }
    if ($removedItems.Count -gt 0) {
        $output += "`n[-] REMOVED (in system, not in config):"
        foreach ($item in $removedItems) {
            $output += "    $($item.Path)"
            $output += "       Current: $(ConvertTo-DisplayValue $item.SystemValue)"
        }
    }

    $changedItems = if ($Differences.Changed) { $Differences.Changed } else { @() }
    if ($changedItems.Count -gt 0) {
        $output += "`n[~] CHANGED (different values):"
        foreach ($item in $changedItems) {
            $output += "    $($item.Path)"
            $output += "       System:  $(ConvertTo-DisplayValue $item.SystemValue)"
            $output += "       Config:  $(ConvertTo-DisplayValue $item.ConfigValue)"
        }
    }

    $equalCount = if ($Differences.Equal) { $Differences.Equal.Count } else { 0 }
    if ($equalCount -gt 0) {
        $output += "`n[=] EQUAL (matched): $equalCount items"
    }

    $totalChanges = $addedItems.Count + $removedItems.Count + $changedItems.Count
    $output += "`n---"
    $output += "Summary: $($addedItems.Count) added, $($removedItems.Count) removed, $($changedItems.Count) changed, $equalCount equal"
    $output += "`nTotal differences: $totalChanges"

    return $output -join "`n"
}

function Invoke-Diff {
    <#
    .SYNOPSIS
        Compares system state with a configuration specification.
    .DESCRIPTION
        Compares current system state (or exported state) with a desired
        configuration and returns differences across all providers.
        Implements the 'diff' command for Git-like workflow.
    .PARAMETER Spec
        Path to the desired configuration spec file.
    .PARAMETER Against
        Optional path to compare against (instead of live system).
        Can be another config file or exported state file.
    .PARAMETER Providers
        Array of provider names to compare (default: all).
    .PARAMETER OutputFormat
        Output format: text, json, or simple (default: text).
    .PARAMETER ShowEqual
        Include equal items in output (default: false).
    .OUTPUTS
        Hashtable with differences per provider
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Spec,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Against,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers = @(),
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("text", "json", "simple")]
        [string]$OutputFormat = "text",
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowEqual,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    Write-Log -Level "INFO" -Message "Starting diff operation..."
    
    $differences = Compare-SystemState -Spec $Spec -Against $Against -Providers $Providers -ConfigPath $ConfigPath
    if ($null -eq $differences) {
        Write-Log -Level "ERROR" -Message "Failed to compare system state"
        return $null
    }
    
    # Filter out equal items if not requested
    if (-not $ShowEqual -and $differences.ContainsKey("Equal")) {
        $differences.Remove("Equal")
    }
    
    # Format output based on preference
    switch ($OutputFormat) {
        "json" {
            $output = $differences | ConvertTo-Json -Depth 10
            Write-Output $output
        }
        "simple" {
            # Simple format: just list differences
            foreach ($type in @("Added", "Removed", "Changed")) {
                if ($differences.ContainsKey($type)) {
                    foreach ($item in $differences[$type]) {
                        $symbol = switch ($type) { "Added" { "+" } "Removed" { "-" } "Changed" { "~" } }
                        Write-Output "$symbol $($item.Path)"
                    }
                }
            }
        }
        default {
            # Text format (default)
            $formatted = Format-DiffOutput -Differences $differences
            Write-Output $formatted
        }
    }
    
    # Return summary for scripting
    $summary = @{
        Added = if ($differences.Added) { $differences.Added.Count } else { 0 }
        Removed = if ($differences.Removed) { $differences.Removed.Count } else { 0 }
        Changed = if ($differences.Changed) { $differences.Changed.Count } else { 0 }
        Total = 0
    }
    $summary.Total = $summary.Added + $summary.Removed + $summary.Changed
    
    Write-Log -Level "INFO" -Message "Diff complete: $($summary.Total) differences found"
    
    return $summary
}

Export-ModuleMember -Function @(
    "Invoke-Diff",
    "ConvertTo-DisplayValue",
    "Format-DiffOutput"
)
