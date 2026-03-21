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
