# providers/debloat.psm1 - Trigger provider for system debloating

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Debloat"
        Type = "Trigger"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [switch]$Silent,
        [switch]$RemoveApps,
        [switch]$CreateRestorePoint,
        [switch]$DisableBing,
        [switch]$RemoveCopilot
    )

    Write-Log -Level "INFO" -Message "Triggering system debloat..."

    $scriptOptions = @()
    if ($Silent) { $scriptOptions += "-Silent" }
    if ($RemoveApps) { $scriptOptions += "-RemoveApps" }
    if ($CreateRestorePoint) { $scriptOptions += "-CreateRestorePoint" }
    if ($DisableBing) { $scriptOptions += "-DisableBingSearch" }
    if ($RemoveCopilot) { $scriptOptions += "-RemoveCopilot" }

    if (-not $PSCmdlet.ShouldProcess("Windows System", "Debloat")) {
        Write-Log -Level "INFO" -Message "Would trigger system debloat (dry run)"
        return @{
            Status = "DryRun"
            Message = "Would execute debloat script"
            Options = $scriptOptions
        }
    }

    try {
        Write-Log -Level "WARN" -Message "Downloading and executing debloat script from debloat.raphi.re"
        Write-Log -Level "WARN" -Message "This script requires administrator privileges"

        $script = Invoke-RestMethod -Uri "https://debloat.raphi.re/" -ErrorAction Stop

        if ($scriptOptions.Count -gt 0) {
            & ([scriptblock]::Create($script)) @scriptOptions
        }
        else {
            & ([scriptblock]::Create($script))
        }

        Write-Log -Level "APPLIED" -Message "Debloat script executed"

        return @{
            Status  = "Success"
            Message = "Debloat script executed successfully"
            Options = $scriptOptions
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Debloat failed: $($_.Exception.Message)"
        return @{
            Status  = "Error"
            Message = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
