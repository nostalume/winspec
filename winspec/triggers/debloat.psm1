# providers/debloat.psm1 - Trigger provider for system debloating

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Debloat"
        Type = "Trigger"
    }
}

function Test-RemoteExecutionConfirmed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Option
    )

    return ($Option -is [hashtable] -and $Option.ConfirmRemoteExecution -eq $true)
}

function New-RemoteExecutionBlockedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action
    )

    Write-Log -Level "WARN" -Message "$Action blocked: set ConfirmRemoteExecution = `$true in the trigger option to allow live remote execution."
    return @{
        Status  = "Blocked"
        Message = "Live remote execution requires ConfirmRemoteExecution = `$true"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        $Option = $true
    )

    Write-Log -Level "INFO" -Message "Triggering system debloat..."

    if (-not $PSCmdlet.ShouldProcess("System", "Debloat (Dry Run)")) {
        Write-Log -Level "INFO" -Message "Would trigger system debloat (dry run)"
        return @{
            Status = "DryRun"
            Message = "Would execute debloat script"
        }
    }

    # Build options based on $Option type
    $scriptOptions = @()

    if ($Option -is [string]) {
        # Simple string option like "silent"
        if ($Option -ne "default") {
            $scriptOptions += "-$Option"
        }
    }
    elseif ($Option -is [hashtable]) {
        # Complex options
        if ($Option.Silent) { $scriptOptions += "-Silent" }
        if ($Option.RemoveApps) { $scriptOptions += "-RemoveApps" }
        if ($Option.CreateRestorePoint) { $scriptOptions += "-CreateRestorePoint" }
        if ($Option.DisableBing) { $scriptOptions += "-DisableBingSearch" }
        if ($Option.RemoveCopilot) { $scriptOptions += "-RemoveCopilot" }
    }
    elseif ($Option -eq $true) {
        # Default options for $true
        $scriptOptions = @()
    }

    if ($PSCmdlet.ShouldProcess("Windows System", "Debloat")) {
        if (-not (Test-RemoteExecutionConfirmed -Option $Option)) {
            return New-RemoteExecutionBlockedResult -Action "Debloat"
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

    return @{
        Status = "Skipped"
        Message = "User declined debloat"
    }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
