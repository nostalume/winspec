# push.psm1 - Push command for WinSpec
# Applies configuration to the system
# Replaces: wrapper in winspec.ps1

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "registry-maps.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "state.psm1") -Force

# =============================================================================
# PUSH COMMAND - Apply config to system
# =============================================================================

function Invoke-Push {
    <#
    .SYNOPSIS
        Pushes configuration to the system.
    .DESCRIPTION
        Applies a configuration spec to the system.
    #>

    [CmdletBinding(SupportsShouldProcess)]
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

    Import-Module (Join-Path $PSScriptRoot "sandbox.psm1") -Force

    # Detect existing sandbox
    $sandboxAlreadyActive = Test-SandboxActive
    $sandboxMode = "Live"

    if ($sandboxAlreadyActive) {
        $sandboxMode = Get-SandboxMode
        Write-LogHeader "SANDBOX MODE: $sandboxMode"
    }
    elseif ($DryRun) {
        $sandboxMode = "DryRun"
    }

    $enteredSandbox = $false

    # Enter sandbox if needed
    if (-not $sandboxAlreadyActive -and $sandboxMode -ne "Live") {
        Enter-Sandbox -Mode $sandboxMode
        $enteredSandbox = $true
        Write-LogHeader "SANDBOX MODE: $sandboxMode"
    }

    $commonParameters = Get-ForwardedCommonParameters -BoundParameters $PSBoundParameters

    # Execute spec
    $result = Invoke-WinSpec `
        -Spec $Spec `
        -ConfigPath $ConfigPath `
        -Providers $Providers `
        -Triggers $Triggers `
        -Checkpoint:$Checkpoint `
        @commonParameters

    if (-not $result.Success) {
        Write-Log -Level "ERROR" -Message "Push failed"
    }

    # Show sandbox summary
    if (Test-SandboxActive) {
        $changes = Get-SandboxChanges
        if ($changes.Count -gt 0) {
            Write-Host ""
            Write-Host "=== Sandbox Changes Summary ===" -ForegroundColor Cyan

            foreach ($change in $changes) {
                Write-Host "$($change.Provider): $($change.Details.Status)"
            }
        }
    }

    # Exit sandbox only if we created it
    if ($enteredSandbox) {
        Exit-Sandbox -DiscardChanges:($sandboxMode -eq "DryRun")
    }

    Write-Host ""
    Write-Log -Level "OK" -Message "Push completed successfully"
    return $result
}

Export-ModuleMember -Function @(
    "Invoke-Push"
)
