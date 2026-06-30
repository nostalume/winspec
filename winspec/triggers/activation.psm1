# providers/activation.psm1 - Trigger provider for Windows/Office activation

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Activation"
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

    Write-Log -Level "INFO" -Message "Triggering Windows/Office activation..."

    # Build arguments based on option type
    $arguments = @()

    if ($Option -is [hashtable]) {
        # Complex options
        if ($Option.Method) {
            $arguments += "-$($Option.Method)"
        }
    }
    elseif ($Option -is [string] -and $Option -ne "default") {
        # String option like "KMS38"
        $arguments += "-$Option"
    }

    if ($PSCmdlet.ShouldProcess("Windows/Office", "Activate")) {
        if (-not (Test-RemoteExecutionConfirmed -Option $Option)) {
            return New-RemoteExecutionBlockedResult -Action "Activation"
        }

        try {
            Write-Log -Level "WARN" -Message "Downloading and executing activation script from get.activated.win"
            Write-Log -Level "WARN" -Message "This script requires administrator privileges"

            $script = Invoke-RestMethod -Uri "https://get.activated.win" -ErrorAction Stop

            if ($arguments.Count -gt 0) {
                & ([scriptblock]::Create($script)) @arguments
            }
            else {
                & ([scriptblock]::Create($script))
            }

            Write-Log -Level "APPLIED" -Message "Activation script executed"

            return @{
                Status  = "Success"
                Message = "Activation script executed successfully"
            }
        }
        catch {
            Write-Log -Level "ERROR" -Message "Activation failed: $($_.Exception.Message)"
            return @{
                Status  = "Error"
                Message = $_.Exception.Message
            }
        }
    }
    else {
        Write-Log -Level "INFO" -Message "Would trigger Windows/Office activation (dry run)"
        return @{
            Status = "DryRun"
            Message = "Would execute activation script"
        }
    }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
