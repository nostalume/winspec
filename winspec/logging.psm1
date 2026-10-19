# logging.psm1 - Unified logging module for WinSpec

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "OK", "APPLIED", "CHANGE", "ERROR", "WARN")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $colors = @{
        "OK" = "Green"
        "APPLIED" = "Green"
        "WARN" = "Yellow"
        "ERROR" = "Red"
    }

    $prefix = switch ($Level) {
        "INFO" { "[INFO]" }
        "OK" { "[OK]" }
        "APPLIED" { "[APPLIED]" }
        "CHANGE" { "[CHANGE]" }
        "WARN" { "[WARN]" }
        "ERROR" { "[ERROR]" }
    }

    if ($colors.ContainsKey($Level)) {
        Write-Host "$prefix $Message" -ForegroundColor $colors[$Level]
    } elseif ($Level -eq "CHANGE") {
        Write-Warning "$prefix $Message"
    } elseif ($Level -eq "ERROR") {
        Write-Error "$prefix $Message"
    } else {
        Write-Host "$prefix $Message"
    }
}

Export-ModuleMember -Function 'Write-Log'
