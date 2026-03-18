# diff.psm1 - System state diff functionality for WinSpec
# Compares system state with a configuration specification
# Implements the 'diff' command as part of Git-like command structure

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "state.psm1") -Force

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
        [switch]$ShowEqual
    )
    
    Write-Log -Level "INFO" -Message "Starting diff operation..."
    
    $differences = Compare-SystemState -Spec $Spec -Against $Against -Providers $Providers
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
    "Invoke-Diff"
)
