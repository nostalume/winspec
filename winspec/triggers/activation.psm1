# providers/activation.psm1 - Trigger provider for Windows/Office activation

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Activation"
        Type = "Trigger"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet("HWID", "KMS38", "Office", "Windows")]
        [string]$Method = "HWID"
    )

    Write-Log -Level "INFO" -Message "Triggering Windows/Office activation..."

    $arguments = @()
    if ($Method -and $Method -ne "default") {
        $arguments += "-$Method"
    }

    if (-not $PSCmdlet.ShouldProcess("Windows/Office", "Activate")) {
        Write-Log -Level "INFO" -Message "Would trigger Windows/Office activation (dry run)"
        return @{
            Status = "DryRun"
            Message = "Would execute activation script"
            Method  = $Method
        }
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
            Method  = $Method
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

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
