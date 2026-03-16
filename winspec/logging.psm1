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
        "OK"      = "Green"
        "APPLIED" = "Green"
        "WARN"    = "Yellow"
        "ERROR"   = "Red"
    }

    $prefix = switch ($Level) {
        "INFO"    { "[INFO]" }
        "OK"      { "[OK]" }
        "APPLIED" { "[APPLIED]" }
        "CHANGE"  { "[CHANGE]" }
        "WARN"    { "[WARN]" }
        "ERROR"   { "[ERROR]" }
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

# Shorthand alias functions for log levels
function global:INFO {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "INFO" -Message $Message
}
function global:OK {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "OK" -Message $Message
}
function global:APPLIED {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "APPLIED" -Message $Message
}
function global:WARN {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "WARN" -Message $Message
}
function global:ERROR {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "ERROR" -Message $Message
}
function global:CHANGE {
    [CmdletBinding()] param([string]$Message)
    Write-Log -Level "CHANGE" -Message $Message
}

function Write-LogProcess {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "OK", "APPLIED", "CHANGE", "ERROR", "WARN")]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $colors = @{
        "OK"      = "Green"
        "APPLIED" = "Green"
        "WARN"    = "Yellow"
        "ERROR"   = "Red"
    }

    $prefix = switch ($Level) {
        "INFO"    { "[INFO]" }
        "OK"      { "[OK]" }
        "APPLIED" { "[APPLIED]" }
        "CHANGE"  { "[CHANGE]" }
        "WARN"    { "[WARN]" }
        "ERROR"   { "[ERROR]" }
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

function Write-LogProcess {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    Write-Log -Level "INFO" -Message "Processing '$Name'..."
}

function Write-LogOk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$DesiredValue
    )
    Write-Log -Level "OK" -Message "'$Name' is already set to '$DesiredValue'."
}

function Write-LogApplied {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$DesiredValue
    )
    Write-Log -Level "APPLIED" -Message "'$Name' set to '$DesiredValue'."
}

function Write-LogChange {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$CurrentValue,
        
        [Parameter(Mandatory = $true)]
        [string]$DesiredValue
    )
    Write-Log -Level "CHANGE" -Message "'$Name' needs update from '$CurrentValue' to '$DesiredValue'."
}

function Write-LogError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [string]$Details = ""
    )
    $msg = "Failed to set '$Name'."
    if ($Details) { $msg += " $Details" }
    Write-Log -Level "ERROR" -Message $msg
}

function Write-LogHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-LogSection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    Write-Host ""
    Write-Host "[$Name]" -ForegroundColor Yellow
}

Export-ModuleMember -Function @(
    "Write-Log"
    "Write-LogProcess"
    "Write-LogOk"
    "Write-LogApplied"
    "Write-LogChange"
    "Write-LogError"
    "Write-LogHeader"
    "Write-LogSection"
)
