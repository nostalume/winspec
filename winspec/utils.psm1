# utils.psm1 - Shared utility functions for WinSpec
# Consolidates common functionality across diff, merge, and sync modules

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -ErrorAction Stop

# =============================================================================
# HASHTABLE EXPORT - Unified hashtable-to-string conversion
# =============================================================================

function ConvertTo-HashtableString {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Hashtable,

        [int]$IndentLevel = 0
    )

    $indent = "    " * $IndentLevel
    $innerIndent = "    " * ($IndentLevel + 1)

    $lines = @()
    $lines += "$indent@{"

    foreach ($key in ($Hashtable.Keys | Sort-Object)) {

        $value = $Hashtable[$key]

        $safeKey = if ($key -match '^[a-zA-Z_][a-zA-Z0-9_]*$') {
            $key
        }
        else {
            "'" + ($key -replace "'", "''") + "'"
        }

        if ($value -is [hashtable]) {
            $lines += "$innerIndent$safeKey ="
            $nested = ConvertTo-HashtableString -Hashtable $value -IndentLevel ($IndentLevel + 1)
            $lines += $nested
        }
        else {
            $formattedValue = ConvertTo-PowerShellValue `
                -Value $value `
                -IndentLevel ($IndentLevel + 1)

            $lines += "$innerIndent$safeKey = $formattedValue"
        }
    }

    $lines += "$indent}"

    return ($lines -join "`n")
}

function ConvertTo-PowerShellValue {
    param(
        $Value,
        [int]$IndentLevel = 0
    )

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [bool]) {
        return '$' + $Value.ToString().ToLower()
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }

    if ($Value -is [string]) {
        return '"' + $Value.Replace('"', '""') + '"'
    }

    if ($Value -is [array]) {

        if ($Value.Count -eq 0) {
            return '@()'
        }

        $indent = "    " * $IndentLevel
        $innerIndent = "    " * ($IndentLevel + 1)

        $items = $Value | ForEach-Object {
            $v = ConvertTo-PowerShellValue -Value $_ -IndentLevel ($IndentLevel + 1)
            "$innerIndent$v"
        }

        return "@(`n$($items -join "`n")`n$indent)"
    }

    if ($Value -is [hashtable]) {
        return ConvertTo-HashtableString -Hashtable $Value -IndentLevel $IndentLevel
    }

    return '"' + $Value.ToString() + '"'
}

# =============================================================================
# CONFIG FILE OPERATIONS
# =============================================================================

function Save-Configuration {
    <#
    .SYNOPSIS
        Saves configuration to a file.
    .DESCRIPTION
        Unified function for saving configuration. Supports both JSON and
        PowerShell hashtable formats based on file extension.
    .PARAMETER Config
        The hashtable configuration to save.
    .PARAMETER Path
        Path to save the configuration.
    .OUTPUTS
        Boolean indicating success.
    #>
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    try {
        $extension = [System.IO.Path]::GetExtension($Path).ToLower()
        
        if ($extension -eq ".json") {
            $json = $Config | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $Path -Encoding UTF8
        }
        else {
            # PowerShell hashtable format
            $content = ConvertTo-HashtableString -Hashtable $Config -IndentLevel 0
            $content | Out-File -FilePath $Path -Encoding UTF8
        }
        
        Write-Log -Level "OK" -Message "Configuration saved to: $Path"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to save configuration: $($_.Exception.Message)"
        return $false
    }
}

function Import-Configuration {
    <#
    .SYNOPSIS
        Imports a configuration from a file.
    .DESCRIPTION
        Unified function for importing configuration specs. Executes the file
        and validates it returns a hashtable.
    .PARAMETER Path
        Path to the configuration file.
    .OUTPUTS
        Hashtable or $null on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        Write-Log -Level "ERROR" -Message "Config file not found: $Path"
        return $null
    }
    
    try {
        $config = & $Path
        
        if ($config -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Config must return a hashtable: $Path"
            return $null
        }
        
        return $config
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to parse config: $($_.Exception.Message)"
        return $null
    }
}

function Merge-Hashtables {
    <#
    .SYNOPSIS
        Recursively merges two hashtables, with Override taking precedence.
    .DESCRIPTION
        Merges two hashtables recursively. When both values are hashtables, they are
        merged recursively. When both values are arrays, they are merged with unique
        values. Otherwise, the Override value replaces the Base value.
    .PARAMETER Base
        The base hashtable to merge into.
    .PARAMETER Override
        The hashtable containing values that override Base.
    .PARAMETER MaxDepth
        Maximum recursion depth to prevent circular reference issues. Default is 10.
    .OUTPUTS
        [hashtable] The merged hashtable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Base,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Override,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 10,
        
        [Parameter(Mandatory = $false)]
        [int]$CurrentDepth = 0
    )
    
    # Prevent circular reference infinite loop
    if ($CurrentDepth -gt $MaxDepth) {
        Write-Warning "Merge-Hashtables: Maximum recursion depth ($MaxDepth) exceeded."
        return $Base.Clone()
    }
    
    $result = $Base.Clone()
    
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            # Recursively merge nested hashtables
            $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key] -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1)
        }
        elseif ($result.ContainsKey($key) -and $result[$key] -is [array] -and $Override[$key] -is [array]) {
            # Merge arrays (unique values)
            $result[$key] = @($result[$key] + $Override[$key] | Select-Object -Unique)
        }
        else {
            # Override with new value
            $result[$key] = $Override[$key]
        }
    }
    
    return $result
}

# =============================================================================
# PATH RESOLUTION - Config/spec path resolution utilities
# =============================================================================

$DefaultConfigFilename = ".winspec.ps1"
$UserConfigDir = Join-Path $env:USERPROFILE ".config\winspec"

function Resolve-Candidate {
    param(
        [string]$candidate
    )
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    if (Test-Path $candidate -PathType Container) {
        $candidate = Join-Path $candidate $DefaultConfigFilename
    }

    if (Test-Path $candidate) {
        return (Resolve-Path $candidate).Path
    }

    return $null
}

function Resolve-SpecPath {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $candidates = @(
        $Path
        $env:WINSPEC_CONFIG
        (Join-Path $UserConfigDir $DefaultConfigFilename)
        (Join-Path (Get-Location) $DefaultConfigFilename)
    )

    foreach ($c in $candidates) {
        $resolved = Resolve-Candidate $c
        if ($resolved) { return $resolved }
    }

    $defaultPath = Join-Path $UserConfigDir $DefaultConfigFilename
    Write-Log -Level "WARN" -Message "No existing spec file found. Falling back to default user config path: $defaultPath"
    return $defaultPath
}


function Resolve-Spec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$BasePath = $PWD
    )

    $result = @{}

    foreach ($import in ($Config.Import ?? @())) {
        $path = if ([System.IO.Path]::IsPathRooted($import)) {
            $import
        }
        else {
            Join-Path $BasePath $import
        }

        $importConfig = Import-Configuration $path

        if ($importConfig) {
            $resolvedImport = Resolve-Spec `
                -Config $importConfig `
                -BasePath (Split-Path $path -Parent)

            $result = Merge-Hashtables $result $resolvedImport
        }
    }

    $result = Merge-Hashtables $result $Config
    $result.Remove("Import")

    return $result
}

function Get-Spec {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $specPath = Resolve-SpecPath $Path
    if (-not $specPath) { return $null }

    Write-Log -Level "INFO" -Message "Loading configuration: $specPath"

    $config = Import-Configuration $specPath
    if ($null -eq $config -or $config.Count -eq 0) {
        Write-Log -Level "ERROR" -Message "Configuration is empty"
        return $null
    }

    return Resolve-Spec `
        -Config $config `
        -BasePath (Split-Path $specPath -Parent)
}

# =============================================================================
# PRIVILEGE ELEVATION
# =============================================================================
function Test-IsAdmin {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-AdminCommand {
    param(
        [scriptblock]$Script
    )

    if (Test-IsAdmin) {
        return & $Script
    }

    $scriptFile = [System.IO.Path]::GetTempFileName() + ".ps1"
    $outputFile = [System.IO.Path]::GetTempFileName()

    try {
        $scriptContent = @"
`$result = & {
$($Script.ToString())
}

`$result | ConvertTo-Json -Depth 5 | Set-Content "$outputFile" -Encoding UTF8
"@

        Set-Content -Path $scriptFile -Value $scriptContent -Encoding UTF8
        Start-Process powershell `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`"" `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait

        if (Test-Path $outputFile) {
            $json = Get-Content $outputFile -Raw
            if ($json) {
                return $json | ConvertFrom-Json
            }
        }
    }
    finally {
        Remove-Item $scriptFile -ErrorAction SilentlyContinue
        Remove-Item $outputFile -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# EXPORT
# =============================================================================

Export-ModuleMember -Function @(
    # config
    "Save-Configuration"
    "Import-Configuration"
    "Resolve-Candidate"
    "Resolve-SpecPath"
    "Get-Spec"
    # display
    "ConvertTo-HashtableString"
    "ConvertTo-PowerShellValue"
    # data
    "Test-ValuesEqual"
    "Merge-Hashtables"
    # admin
    "Test-IsAdmin"
    "Invoke-AdminCommand"
)
