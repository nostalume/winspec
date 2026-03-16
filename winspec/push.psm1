# push.psm1 - Push command for WinSpec
# Applies configuration to the system
# Replaces: wrapper in winspec.ps1

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "registry-maps.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

# =============================================================================
# PUSH COMMAND - Apply config to system
# =============================================================================

function Invoke-Push {
    <#
    .SYNOPSIS
        Pushes configuration to the system.
    .DESCRIPTION
        Applies a configuration spec to the system.
    .PARAMETER Spec
        Path to the configuration spec file.
    .PARAMETER ConfigPath
        Configuration directory path.
    .PARAMETER DryRun
        Preview changes without applying.
    .PARAMETER Checkpoint
        Create restore point before applying.
    .PARAMETER WithTriggers
        Include trigger execution.
    .PARAMETER Providers
        Apply only specific providers.
    .OUTPUTS
        Hashtable with execution results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers,

        [Parameter(Mandatory = $false)]
        $Triggers,
        
        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Checkpoint
    )
    
    Write-LogHeader -Title "WinSpec Push"
    
    # Handle sandbox mode
    Import-Module (Join-Path $PSScriptRoot "sandbox.psm1") -Force
    $sandboxModeValue = "Live"
    $isSandbox = $false
    
    $isSandbox = Test-SandboxActive
    if ($isSandbox) {
        $sandboxModeValue = Get-SandboxMode
        Write-LogHeader "SANDBOX MODE: $sandboxModeValue"
    }
    elseif ($DryRun) {
        $sandboxModeValue = "DryRun"
    }
    
    # Enter sandbox if needed
    if ($sandboxModeValue -ne "Live") {
        Enter-Sandbox -Mode $sandboxModeValue
    }
    
    $result = Invoke-WinSpec -Spec $Spec -ConfigPath $ConfigPath -Providers $Providers -Triggers $Triggers -Checkpoint:$Checkpoint 
    
    # Handle results
    if (-not $result.Success) {
        Write-Log -Level "ERROR" -Message "Push failed"
        return $result
    }
    
    # Exit sandbox if entered
    if ($isSandbox) {
        $changes = Get-SandboxChanges
        if ($changes.Count -gt 0) {
            Write-Host ""
            Write-Host "=== Sandbox Changes Summary ===" -ForegroundColor Cyan
            foreach ($change in $changes) {
                Write-Host "$($change.Provider): $($change.Details.Status)"
            }
        }
        Exit-Sandbox -DiscardChanges:($sandboxModeValue -eq "DryRun")
    }
    
    Write-Host ""
    Write-Log -Level "OK" -Message "Push completed successfully"
    return $result
}

Export-ModuleMember -Function @(
    "Invoke-Push"
)
