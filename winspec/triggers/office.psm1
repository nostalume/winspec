# providers/office.psm1 - Trigger provider for Office deployment

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Office"
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

    Write-Log -Level "WARN" -Message "$Action blocked: set ConfirmRemoteExecution = `$true in the trigger option to allow live remote download/execution."
    return @{
        Status  = "Blocked"
        Message = "Live remote download/execution requires ConfirmRemoteExecution = `$true"
    }
}

function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        $Option = $true
    )

    Write-Log -Level "INFO" -Message "Triggering Office deployment..."

    # Determine target directory
    $targetDir = if ($Option -is [string]) {
        $Option
    }
    elseif ($Option -is [hashtable] -and $Option.Path) {
        $Option.Path
    }
    else {
        $PWD
    }

    $target = Join-Path $targetDir "Officesetup.exe"

    if (-not $PSCmdlet.ShouldProcess($target, "Download Office installer")) {
        Write-Log -Level "INFO" -Message "Would download Office installer to: $target (dry run)"
        return @{
            Status = "DryRun"
            Message = "Would download Office installer"
            Path    = $target
        }
    }

    if (-not (Test-RemoteExecutionConfirmed -Option $Option)) {
        return New-RemoteExecutionBlockedResult -Action "Office deployment"
    }

    $url = 'https://c2rsetup.officeapps.live.com/c2r/download.aspx?ProductreleaseID=O365ProPlusRetail&platform=x64&language=en-us&version=O16GA'

    if ($PSCmdlet.ShouldProcess($target, "Download Office installer")) {
        try {
            Write-Log -Level "INFO" -Message "Downloading Office installer from Microsoft CDN..."

            # Create directory if needed
            if (-not (Test-Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }

            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -ErrorAction Stop

            Write-Log -Level "APPLIED" -Message "Office installer downloaded to: $target"

            # Check if we should run the installer
            $runInstaller = $true
            if ($Option -is [hashtable]) {
                $runInstaller = -not $Option.Cache
            }

            if ($runInstaller) {
                Write-Log -Level "INFO" -Message "Launching Office installer..."
                Start-Process -FilePath $target -Wait
            }
            else {
                Write-Log -Level "INFO" -Message "Installer cached (not executed)"
            }

            return @{
                Status  = "Success"
                Message = "Office installer downloaded successfully"
                Path    = $target
                Run     = $runInstaller
            }
        }
        catch {
            Write-Log -Level "ERROR" -Message "Office deployment failed: $($_.Exception.Message)"
            return @{
                Status  = "Error"
                Message = $_.Exception.Message
            }
        }
    }

    return @{
        Status = "Skipped"
        Message = "User declined Office deployment"
    }
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Invoke-Trigger"
)
