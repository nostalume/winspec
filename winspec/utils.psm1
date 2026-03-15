# utils.psm1 - Shared utility functions for WinSpec
# Consolidates common functionality across diff, merge, and sync modules

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force

# =============================================================================
# HASHTABLE EXPORT - Unified hashtable-to-string conversion
# =============================================================================

function ConvertTo-HashtableString {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Hashtable,

        [int]$IndentLevel = 0
    )

    $indent      = "    " * $IndentLevel
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

        $indent      = "    " * $IndentLevel
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


# =============================================================================
# VALUE EQUALITY TESTING
# =============================================================================

function Test-ValuesEqual {
    <#
    .SYNOPSIS
        Tests if two values are equal, handling complex types.
    .DESCRIPTION
        Recursively compares hashtables, arrays, and primitive values.
    .PARAMETER Value1
        First value to compare.
    .PARAMETER Value2
        Second value to compare.
    .PARAMETER MaxDepth
        Maximum recursion depth to prevent stack overflow on circular refs.
        Default is 10.
    .PARAMETER CurrentDepth
        Internal parameter tracking current recursion depth.
    .OUTPUTS
        Boolean indicating equality.
    #>
    param(
        $Value1,
        $Value2,
        [int]$MaxDepth = 10,
        [int]$CurrentDepth = 0
    )
    
    # Check recursion depth
    if ($CurrentDepth -gt $MaxDepth) {
        Write-Verbose "Test-ValuesEqual: Max depth ($MaxDepth) exceeded"
        return $false
    }
    
    if (-not $Value1 -and -not $Value2) {
        return $true
    }
    
    if (-not $Value1 -or -not $Value2) {
        return $false
    }
    
    $type1 = $Value1.GetType()
    $type2 = $Value2.GetType()
    
    if ($type1 -ne $type2) {
        return $false
    }
    
    if ($Value1 -is [hashtable]) {
        if ($Value1.Count -ne $Value2.Count) {
            return $false
        }
        foreach ($key in $Value1.Keys) {
            if (-not $Value2.ContainsKey($key)) {
                return $false
            }
            if (-not (Test-ValuesEqual -Value1 $Value1[$key] -Value2 $Value2[$key] -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1))) {
                return $false
            }
        }
        return $true
    }
    
    if ($Value1 -is [array]) {
        if ($Value1.Count -ne $Value2.Count) {
            return $false
        }
        for ($i = 0; $i -lt $Value1.Count; $i++) {
            if (-not (Test-ValuesEqual -Value1 $Value1[$i] -Value2 $Value2[$i] -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1))) {
                return $false
            }
        }
        return $true
    }
    
    return $Value1 -eq $Value2
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

    Write-Log "INFO" "Loading configuration: $specPath"

    $config = Import-Configuration $specPath
    if (-not $config) {
        Write-Log "ERROR" "Failed to load specification"
        return $null
    }

    return Resolve-Spec `
        -Config $config `
        -BasePath (Split-Path $specPath -Parent)
}

# =============================================================================
# PACKAGE STATE MERGE - Shared utilities for package managers
# =============================================================================

function Merge-PackageState {
    <#
    .SYNOPSIS
        Generic package state merge for package managers.
    .DESCRIPTION
        Merges system package state with existing config, preserving user metadata
        like flags, versions, and other per-package settings. Uses ArrayList for
        efficient O(n) performance instead of O(n²) array concatenation.
    .PARAMETER SystemState
        Hashtable with Installed and/or Packages arrays from system
    .PARAMETER ExistingConfig
        Hashtable with Installed and/or Packages arrays from config
    .OUTPUTS
        Hashtable with Installed and Packages arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SystemState,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$ExistingConfig
    )
    
    # Build lookup from existing packages (preserves user metadata)
    $existingPkgs = @{}
    if ($ExistingConfig.Packages) {
        foreach ($p in $ExistingConfig.Packages) {
            if ($p.Name) {
                $existingPkgs[$p.Name] = $p
            }
        }
    }
    elseif ($ExistingConfig.Installed) {
        foreach ($p in $ExistingConfig.Installed) {
            $id = if ($p -is [hashtable] -and $p.Name) { $p.Name } else { $p }
            $existingPkgs[$id] = if ($p -is [hashtable]) { $p } else { @{ Name = $id } }
        }
    }
    
    # Build lookup from system packages
    $systemPkgs = @{}
    if ($SystemState.Packages) {
        foreach ($p in $SystemState.Packages) {
            if ($p.Name) {
                $systemPkgs[$p.Name] = $p
            }
        }
    }
    elseif ($SystemState.Installed) {
        foreach ($p in $SystemState.Installed) {
            $id = if ($p -is [hashtable] -and $p.Name) { $p.Name } else { $p }
            $systemPkgs[$id] = if ($p -is [hashtable]) { $p } else { @{ Name = $id } }
        }
    }
    
    # Merge: prefer existing (preserves flags), add new from system
    # Use ArrayList for O(1) amortized append
    $mergedList = [System.Collections.ArrayList]::new()
    $allIds = @($existingPkgs.Keys) + @($systemPkgs.Keys) | Select-Object -Unique
    
    foreach ($id in $allIds) {
        if ($existingPkgs.ContainsKey($id)) {
            [void]$mergedList.Add($existingPkgs[$id])
        }
        elseif ($systemPkgs.ContainsKey($id)) {
            [void]$mergedList.Add($systemPkgs[$id])
        }
    }
    
    $result = @{}
    if ($mergedList.Count -gt 0) {
        $result.Installed = $mergedList | ForEach-Object { 
            if ($_ -is [string]) { $_ } else { $_.Name } 
        }
        $result.Packages = $mergedList.ToArray()
    }
    
    return $result
}

function Merge-SourceCollection {
    <#
    .SYNOPSIS
        Generic source/bucket merge for package managers.
    .DESCRIPTION
        Merges system sources with existing config. Existing sources take precedence
        to preserve user customizations (e.g., custom bucket URLs).
    .PARAMETER SystemSources
        Array of source objects from system
    .PARAMETER ExistingSources
        Array of source objects from config
    .PARAMETER NameKey
        Property name to use as key (default: "Name")
    .OUTPUTS
        Array of merged source objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [array]$SystemSources,
        
        [Parameter(Mandatory = $false)]
        [array]$ExistingSources,
        
        [Parameter(Mandatory = $false)]
        [string]$NameKey = "Name"
    )
    
    # Use hashtable for O(1) lookup
    $merged = @{}
    
    # Add system sources first
    if ($SystemSources) {
        foreach ($s in $SystemSources) {
            if ($s.$NameKey) {
                $merged[$s.$NameKey] = $s
            }
        }
    }
    
    # Add existing sources (skip if already exists - existing takes precedence)
    if ($ExistingSources) {
        foreach ($s in $ExistingSources) {
            if ($s.$NameKey -and -not $merged.ContainsKey($s.$NameKey)) {
                $merged[$s.$NameKey] = $s
            }
        }
    }
    
    if ($merged.Count -gt 0) {
        return $merged.Values
    }
    return @()
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

    try {
        $Script.ToString() | Set-Content $scriptFile -Encoding UTF8

        Start-Process powershell `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`"" `
            -Verb RunAs `
            -Wait
    }
    finally {
        Remove-Item $scriptFile -ErrorAction SilentlyContinue
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
    "Merge-PackageState"
    "Merge-SourceCollection"
    # admin
    "Test-IsAdmin"
    "Invoke-AdminCommand"
)
