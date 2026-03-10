# push.psm1 - Push command for WinSpec
# Applies configuration to the system
# Replaces: wrapper in winspec.ps1

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "registry-maps.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "exec.psm1") -Force

# =============================================================================
# PUSH COMMAND - Apply config to system
# =============================================================================

function Invoke-Push {
    <#
    .SYNOPSIS
        Pushes configuration to the system.
    .DESCRIPTION
        Applies a configuration spec to the system.
        Integrates with exec.psm1 for actual execution.
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
        [string]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$DryRun,
        
        [Parameter(Mandatory = $false)]
        [switch]$Checkpoint,
        
        [Parameter(Mandatory = $false)]
        [switch]$WithTriggers,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers
    )
    
    Write-LogHeader -Title "WinSpec Push"
    
    # Resolve spec path
    if (-not $Spec) {
        $Spec = Resolve-SpecPath -Spec $Spec -ConfigPath $ConfigPath
        if (-not $Spec) {
            Write-Log -Level "ERROR" -Message "No spec file specified or found. Use -Spec to specify a config file."
            return @{ Success = $false; Error = "No spec file" }
        }
    }
    
    Write-Log -Level "INFO" -Message "Using spec: $Spec"
    
    # Handle sandbox mode
    Import-Module (Join-Path $PSScriptRoot "sandbox.psm1") -Force
    $sandboxModeValue = "Live"
    $isSandbox = $false
    
    $isSandbox = Test-SandboxActive
    if ($isSandbox) {
        $sandboxModeValue = Get-SandboxMode
        Write-Log -Level "INFO" -Message "=== SANDBOX MODE: $sandboxModeValue ==="
    }
    elseif ($DryRun) {
        $sandboxModeValue = "DryRun"
    }
    
    # Enter sandbox if needed
    if ($sandboxModeValue -ne "Live") {
        Enter-Sandbox -Mode $sandboxModeValue
    }
    
    # Execute using exec.psm1
    $result = Invoke-WinSpec -Spec $Spec -ConfigPath $ConfigPath -Checkpoint:$Checkpoint -WithTriggers:$WithTriggers
    
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
    
    Write-Log -Level "OK" -Message "Push completed successfully"
    return $result
}

# Alias for backward compatibility
Set-Alias -Name "Apply-Configuration" -Value "Invoke-Push" -Scope Global

Export-ModuleMember -Function @(
    "Invoke-Push"
)
