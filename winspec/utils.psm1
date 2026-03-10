# utils.psm1 - Shared utility functions for WinSpec
# Consolidates common functionality across diff, merge, and sync modules

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force

# =============================================================================
# VALUE FORMATTING - Unified value formatting for display
# =============================================================================

function ConvertTo-DisplayValue {
    <#
    .SYNOPSIS
        Converts a value to a human-readable display format.
    .DESCRIPTION
        Unified function for formatting values in diff, merge, and sync displays.
        Handles null, hashtables, arrays, and primitive types.
    .PARAMETER Value
        The value to format.
    .PARAMETER Compact
        If specified, uses compact format for arrays (truncates long arrays).
    #>
    param(
        $Value,
        [switch]$Compact
    )
    
    if ($null -eq $Value) {
        return "<null>"
    }
    
    if ($Value -is [hashtable]) {
        $entries = $Value.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        return "{ $($entries -join ', ') }"
    }
    
    if ($Value -is [array]) {
        if ($Compact -and $Value.Count -gt 5) {
            return "@($($Value[0..4] -join ', ')... and $($Value.Count - 5) more)"
        }
        return "@($($Value -join ', '))"
    }
    
    if ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    
    return $Value.ToString()
}

function ConvertTo-DetailedDisplayValue {
    <#
    .SYNOPSIS
        Converts a value to detailed display format with nested structure.
    .DESCRIPTION
        Used for conflict resolution displays where nested structure matters.
        Handles hashtables with proper indentation and recursion.
    .PARAMETER Value
        The value to format.
    #>
    param($Value)
    
    if ($null -eq $Value) {
        return "<null>"
    }
    
    if ($Value -is [hashtable]) {
        if ($Value.Count -eq 0) {
            return "@{}"
        }
        $lines = @()
        foreach ($key in $Value.Keys) {
            $lines += "  $key = $(ConvertTo-DetailedDisplayValue -Value $Value[$key])"
        }
        return "@{`n$($lines -join "`n")`n}"
    }
    
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "@()"
        }
        $items = $Value | ForEach-Object { ConvertTo-DetailedDisplayValue -Value $_ }
        return "@($($items -join ', '))"
    }
    
    if ($Value -is [string]) {
        return '"' + $Value + '"'
    }
    
    if ($Value -is [bool]) {
        return '$' + $Value.ToString().ToLower()
    }
    
    return $Value.ToString()
}

# =============================================================================
# HASHTABLE EXPORT - Unified hashtable-to-string conversion
# =============================================================================

function ConvertTo-HashtableString {
    <#
    .SYNOPSIS
        Converts a hashtable to PowerShell code string representation.
    .DESCRIPTION
        Unified function for exporting hashtables as PowerShell code.
        Used by both merge and sync modules.
    .PARAMETER Hashtable
        The hashtable to convert.
    .PARAMETER IndentLevel
        Current indentation level for nested structures.
    #>
    param(
        [hashtable]$Hashtable,
        [int]$IndentLevel = 0
    )
    
    $indent = "    " * $IndentLevel
    $lines = @()
    
    if ($IndentLevel -eq 0) {
        $lines += "@{"
    }
    
    foreach ($key in $Hashtable.Keys) {
        $value = $Hashtable[$key]
        $formattedValue = ConvertTo-PowerShellValue -Value $value -IndentLevel ($IndentLevel + 1)
        $lines += "$indent    $key = $formattedValue"
    }
    
    if ($IndentLevel -eq 0) {
        $lines += "}"
    }
    
    return $lines -join "`n"
}

function ConvertTo-PowerShellValue {
    <#
    .SYNOPSIS
        Converts a value to PowerShell code string for export.
    .DESCRIPTION
        Handles all PowerShell types including null, bool, numbers, strings,
        arrays, and nested hashtables with proper escaping.
    .PARAMETER Value
        The value to convert.
    .PARAMETER IndentLevel
        Current indentation level for nested structures.
    #>
    param(
        $Value,
        [int]$IndentLevel = 0
    )
    
    $indent = "    " * $IndentLevel
    
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
        $items = $Value | ForEach-Object { ConvertTo-PowerShellValue -Value $_ -IndentLevel $IndentLevel }
        return "@($($items -join ', '))"
    }
    
    if ($Value -is [hashtable]) {
        $lines = @("@{`n")
        foreach ($key in $Value.Keys) {
            $formattedValue = ConvertTo-PowerShellValue -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
            $lines += "$indent    $key = $formattedValue`n"
        }
        $lines += "$indent}"
        return $lines -join ""
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

# Alias for backward compatibility with core.psm1
function Import-Spec {
    <#
    .SYNOPSIS
        Alias for Import-Configuration for backward compatibility.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    return Import-Configuration -Path $Path
}

# =============================================================================
# HASHTABLE UTILITIES
# =============================================================================

function Copy-Hashtable {
    <#
    .SYNOPSIS
        Creates a deep copy of a hashtable.
    .DESCRIPTION
        Recursively copies all nested hashtables and arrays.
    .PARAMETER Source
        The source hashtable to copy.
    .OUTPUTS
        A deep copy of the hashtable.
    #>
    param([hashtable]$Source)
    
    $copy = @{}
    foreach ($key in $Source.Keys) {
        $value = $Source[$key]
        if ($value -is [hashtable]) {
            $copy[$key] = Copy-Hashtable -Source $value
        }
        elseif ($value -is [array]) {
            $copy[$key] = @($value)
        }
        else {
            $copy[$key] = $value
        }
    }
    return $copy
}

function Add-ToConfigPath {
    <#
    .SYNOPSIS
        Adds a value to configuration at the specified path.
    .DESCRIPTION
        Supports dot-notation paths (e.g., "Package.git") for nested config.
    .PARAMETER Config
        The configuration hashtable to modify.
    .PARAMETER Path
        Dot-separated path to the value location.
    .PARAMETER Value
        The value to add.
    .OUTPUTS
        The modified configuration.
    #>
    param(
        [hashtable]$Config,
        [string]$Path,
        $Value
    )
    
    $parts = $Path.Split('.')
    $current = $Config
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $current.ContainsKey($part)) {
            $current[$part] = @{}
        }
        $current = $current[$part]
    }
    
    $current[$parts[-1]] = $Value
    return $Config
}

function Remove-FromConfigPath {
    <#
    .SYNOPSIS
        Removes a value from configuration at the specified path.
    .DESCRIPTION
        Supports dot-notation paths for nested config removal.
    .PARAMETER Config
        The configuration hashtable to modify.
    .PARAMETER Path
        Dot-separated path to the value to remove.
    .OUTPUTS
        The modified configuration.
    #>
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    $parts = $Path.Split('.')
    $current = $Config
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $current.ContainsKey($part)) {
            return $Config
        }
        $current = $current[$part]
    }
    
    if ($current.ContainsKey($parts[-1])) {
        $current.Remove($parts[-1])
    }
    
    return $Config
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
    .OUTPUTS
        Boolean indicating equality.
    #>
    param($Value1, $Value2)
    
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
            if (-not (Test-ValuesEqual -Value1 $Value1[$key] -Value2 $Value2[$key])) {
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
            if (-not (Test-ValuesEqual -Value1 $Value1[$i] -Value2 $Value2[$i])) {
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

function Resolve-ConfigPath {
    <#
    .SYNOPSIS
        Resolves the output path for config operations.
    .DESCRIPTION
        Determines where to save config files. Priority:
        1. Explicit OutputPath parameter
        2. WINSPEC_CONFIG environment variable
        3. User config directory (~/.config/winspec/)
        4. Current directory
    .PARAMETER OutputPath
        Explicit output path if provided.
    .OUTPUTS
        Resolved path string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    # If explicit path provided and not empty, use it
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        return $OutputPath
    }
    
    # Check environment variable
    if ($env:WINSPEC_CONFIG) {
        $configPath = $env:WINSPEC_CONFIG
        if (Test-Path $configPath -PathType Container) {
            return Join-Path $configPath $DefaultConfigFilename
        }
        if ([System.IO.Path]::HasExtension($configPath)) {
            return $configPath
        }
        return Join-Path $configPath $DefaultConfigFilename
    }
    
    # Use user config directory (create if needed)
    if (-not (Test-Path $UserConfigDir)) {
        try {
            New-Item -ItemType Directory -Path $UserConfigDir -Force | Out-Null
        }
        catch {
            Write-Log -Level "WARN" -Message "Cannot create user config directory. Using current directory."
            return Join-Path (Get-Location) $DefaultConfigFilename
        }
    }
    
    return Join-Path $UserConfigDir $DefaultConfigFilename
}

function Resolve-SpecPath {
    <#
    .SYNOPSIS
        Resolves the spec/config file path for operations.
    .DESCRIPTION
        Auto-resolves spec path: explicit > config env var > default.
    .PARAMETER Spec
        Explicit spec path.
    .PARAMETER ConfigPath
        Optional config directory path.
    .OUTPUTS
        Resolved spec path string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # If explicit spec provided, use it
    if (-not [string]::IsNullOrWhiteSpace($Spec)) {
        if (Test-Path $Spec) {
            return $Spec
        }
        # Try as relative path
        $fullPath = Join-Path (Get-Location) $Spec
        if (Test-Path $fullPath) {
            return $fullPath
        }
        Write-Log -Level "ERROR" -Message "Spec file not found: $Spec"
        return $null
    }
    
    # Check WINSPEC_CONFIG environment variable
    if ($env:WINSPEC_CONFIG) {
        $configPath = $env:WINSPEC_CONFIG
        if (Test-Path $configPath -PathType Container) {
            $specPath = Join-Path $configPath $DefaultConfigFilename
            if (Test-Path $specPath) {
                return $specPath
            }
        }
        elseif ([System.IO.Path]::HasExtension($configPath) -and (Test-Path $configPath)) {
            return $configPath
        }
    }
    
    # Use ConfigPath if provided
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (Test-Path $ConfigPath -PathType Container) {
            $specPath = Join-Path $ConfigPath $DefaultConfigFilename
            if (Test-Path $specPath) {
                return $specPath
            }
        }
        elseif (Test-Path $ConfigPath) {
            return $ConfigPath
        }
    }
    
    # Fall back to user config directory
    $userSpecPath = Join-Path $UserConfigDir $DefaultConfigFilename
    if (Test-Path $userSpecPath) {
        return $userSpecPath
    }
    
    # Fall back to current directory
    $currentSpecPath = Join-Path (Get-Location) $DefaultConfigFilename
    if (Test-Path $currentSpecPath) {
        return $currentSpecPath
    }
    
    Write-Log -Level "ERROR" -Message "No spec file found. Use -Spec to specify a config file."
    return $null
}

# =============================================================================
# EXPORT
# =============================================================================

Export-ModuleMember -Function @(
    "Resolve-ConfigPath"
    "Resolve-SpecPath"
    "ConvertTo-DisplayValue"
    "ConvertTo-DetailedDisplayValue"
    "ConvertTo-HashtableString"
    "ConvertTo-PowerShellValue"
    "Save-Configuration"
    "Import-Configuration"
    "Import-Spec"
    "Copy-Hashtable"
    "Add-ToConfigPath"
    "Remove-FromConfigPath"
    "Test-ValuesEqual"
    "Merge-Hashtables"
)
