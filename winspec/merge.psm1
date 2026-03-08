# merge.psm1 - Merge functionality for bidirectional sync
# Provides merge strategies and conflict resolution for WinSpec configurations

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force

function Merge-Configuration {
    <#
    .SYNOPSIS
        Merges two WinSpec configurations with conflict resolution.
    .DESCRIPTION
        Performs a three-way merge between base, incoming configurations using
        specified merge strategy. Supports interactive and non-interactive modes.
    .PARAMETER BasePath
        Path to the base configuration file.
    .PARAMETER IncomingPath
        Path to the incoming configuration file.
    .PARAMETER OutputPath
        Path to write the merged configuration.
    .PARAMETER Strategy
        Merge strategy: auto, union, ours, theirs.
    .PARAMETER Interactive
        Enable interactive conflict resolution.
    .OUTPUTS
        Hashtable with merge results and conflicts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        
        [Parameter(Mandatory = $true)]
        [string]$IncomingPath,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("auto", "union", "ours", "theirs")]
        [string]$Strategy = "auto",
        
        [Parameter(Mandatory = $false)]
        [switch]$Interactive
    )
    
    Write-Log -Level "INFO" -Message "Starting configuration merge..."
    Write-Log -Level "INFO" -Message "Base: $BasePath"
    Write-Log -Level "INFO" -Message "Incoming: $IncomingPath"
    Write-Log -Level "INFO" -Message "Strategy: $Strategy"
    
    # Load configurations
    $baseConfig = Import-MergeSpec -Path $BasePath
    if (-not $baseConfig) {
        Write-Log -Level "ERROR" -Message "Failed to load base configuration"
        return $null
    }
    
    $incomingConfig = Import-MergeSpec -Path $IncomingPath
    if (-not $incomingConfig) {
        Write-Log -Level "ERROR" -Message "Failed to load incoming configuration"
        return $null
    }
    
    # Perform merge
    $mergeResult = Invoke-MergeEngine -Base $baseConfig -Incoming $incomingConfig -Strategy $Strategy -Interactive:$Interactive
    
    if ($mergeResult.Success) {
        # Write output if specified
        if ($OutputPath) {
            Export-MergedConfig -Config $mergeResult.Merged -Path $OutputPath
        }
        
        Write-Log -Level "OK" -Message "Merge completed successfully"
        Write-Log -Level "INFO" -Message "Conflicts resolved: $($mergeResult.ResolvedConflicts)"
        Write-Log -Level "INFO" -Message "Auto-merged: $($mergeResult.AutoMerged)"
    }
    else {
        Write-Log -Level "ERROR" -Message "Merge failed with $($mergeResult.Conflicts.Count) unresolved conflicts"
    }
    
    return $mergeResult
}

function Import-MergeSpec {
    <#
    .SYNOPSIS
        Imports a specification file for merging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        Write-Log -Level "ERROR" -Message "Spec file not found: $Path"
        return $null
    }
    
    try {
        $config = & $Path
        
        if ($config -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Spec must return a hashtable: $Path"
            return $null
        }
        
        return $config
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to parse spec: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-MergeEngine {
    <#
    .SYNOPSIS
        Core merge engine that combines two configurations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Base,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Incoming,
        
        [Parameter(Mandatory = $true)]
        [string]$Strategy,
        
        [Parameter(Mandatory = $false)]
        [switch]$Interactive
    )
    
    $result = @{
        Success = $true
        Merged = @{}
        Conflicts = @()
        ResolvedConflicts = 0
        AutoMerged = 0
        Path = ""
    }
    
    # Get all unique keys from both configurations
    $allKeys = ($Base.Keys + $Incoming.Keys) | Select-Object -Unique
    
    foreach ($key in $allKeys) {
        $baseValue = $Base[$key]
        $incomingValue = $Incoming[$key]
        $path = $key
        
        $mergeItem = Resolve-MergeItem `
            -Path $path `
            -BaseValue $baseValue `
            -IncomingValue $incomingValue `
            -Strategy $Strategy `
            -Interactive:$Interactive
        
        if ($mergeItem.Conflict) {
            $result.Conflicts += $mergeItem.ConflictInfo
            if (-not $mergeItem.Resolved) {
                $result.Success = $false
            }
            else {
                $result.ResolvedConflicts++
                $result.Merged[$key] = $mergeItem.Value
            }
        }
        else {
            $result.AutoMerged++
            $result.Merged[$key] = $mergeItem.Value
        }
    }
    
    return $result
}

function Resolve-MergeItem {
    <#
    .SYNOPSIS
        Resolves a single merge item between base and incoming values.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        $BaseValue,
        $IncomingValue,
        [string]$Strategy,
        [switch]$Interactive
    )
    
    $result = @{
        Conflict = $false
        Resolved = $false
        Value = $null
        ConflictInfo = $null
    }
    
    # Case 1: Key only in base (not in incoming)
    if ($IncomingValue -eq $null -and $BaseValue -ne $null) {
        $result.Value = $BaseValue
        return $result
    }
    
    # Case 2: Key only in incoming (not in base)
    if ($BaseValue -eq $null -and $IncomingValue -ne $null) {
        $result.Value = $IncomingValue
        $result.Resolved = $true
        return $result
    }
    
    # Case 3: Same value in both
    if (Test-ValuesEqual -Value1 $BaseValue -Value2 $IncomingValue) {
        $result.Value = $BaseValue
        return $result
    }
    
    # Case 4: Different values - potential conflict
    $result.Conflict = $true
    
    # Try automatic resolution based on strategy
    $autoResult = Resolve-ByStrategy `
        -Path $Path `
        -BaseValue $BaseValue `
        -IncomingValue $IncomingValue `
        -Strategy $Strategy
    
    if ($autoResult.Success) {
        $result.Value = $autoResult.Value
        $result.Resolved = $true
        return $result
    }
    
    # If interactive, prompt user
    if ($Interactive) {
        $userChoice = Invoke-ConflictResolution `
            -Path $Path `
            -BaseValue $BaseValue `
            -IncomingValue $IncomingValue
        
        switch ($userChoice.Action) {
            "base" {
                $result.Value = $BaseValue
                $result.Resolved = $true
            }
            "incoming" {
                $result.Value = $IncomingValue
                $result.Resolved = $true
            }
            "union" {
                $result.Value = Merge-ValuesUnion -BaseValue $BaseValue -IncomingValue $IncomingValue
                $result.Resolved = $true
            }
            "skip" {
                # Keep both values as array for later resolution
                $result.Value = @($BaseValue, $incomingValue)
                $result.Resolved = $false
            }
        }
    }
    else {
        # Non-interactive: record conflict
        $result.ConflictInfo = @{
            Path = $Path
            BaseValue = $BaseValue
            IncomingValue = $IncomingValue
            Strategy = $Strategy
        }
    }
    
    return $result
}

function Test-ValuesEqual {
    <#
    .SYNOPSIS
        Tests if two values are equal, handling hashtables and arrays.
    #>
    param($Value1, $Value2)
    
    if ($Value1 -eq $null -and $Value2 -eq $null) {
        return $true
    }
    
    if ($Value1 -eq $null -or $Value2 -eq $null) {
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

function Resolve-ByStrategy {
    <#
    .SYNOPSIS
        Attempts to resolve a conflict using the specified strategy.
    #>
    param(
        [string]$Path,
        $BaseValue,
        $IncomingValue,
        [string]$Strategy
    )
    
    $result = @{
        Success = $false
        Value = $null
    }
    
    switch ($Strategy) {
        "ours" {
            $result.Success = $true
            $result.Value = $BaseValue
        }
        "theirs" {
            $result.Success = $true
            $result.Value = $IncomingValue
        }
        "union" {
            $result.Success = $true
            $result.Value = Merge-ValuesUnion -BaseValue $BaseValue -IncomingValue $IncomingValue
        }
        "auto" {
            # For auto strategy, only resolve non-conflicting additions
            # Arrays and simple values can be unioned
            if ($BaseValue -is [array] -or $IncomingValue -is [array]) {
                $result.Success = $true
                $result.Value = Merge-ValuesUnion -BaseValue $BaseValue -IncomingValue $IncomingValue
            }
            # Hashtables can be recursively merged
            elseif ($BaseValue -is [hashtable] -and $IncomingValue -is [hashtable]) {
                $result.Success = $true
                $result.Value = Merge-ValuesUnion -BaseValue $BaseValue -IncomingValue $IncomingValue
            }
            # Different primitive values - conflict requires resolution
            else {
                $result.Success = $false
            }
        }
    }
    
    return $result
}

function Merge-ValuesUnion {
    <#
    .SYNOPSIS
        Creates a union of two values (arrays are concatenated, hashtables are merged).
    #>
    param($BaseValue, $IncomingValue)
    
    # Handle arrays
    if ($BaseValue -is [array] -or $IncomingValue -is [array]) {
        $baseArray = if ($BaseValue -is [array]) { $BaseValue } else { @($BaseValue) }
        $incomingArray = if ($IncomingValue -is [array]) { $IncomingValue } else { @($IncomingValue) }
        
        # Union with deduplication for primitive types
        $result = @($baseArray)
        foreach ($item in $incomingArray) {
            $found = $false
            foreach ($existing in $result) {
                if (Test-ValuesEqual -Value1 $item -Value2 $existing) {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $result += $item
            }
        }
        return $result
    }
    
    # Handle hashtables
    if ($BaseValue -is [hashtable] -and $IncomingValue -is [hashtable]) {
        $result = @{}
        
        # Copy all from base
        foreach ($key in $BaseValue.Keys) {
            $result[$key] = $BaseValue[$key]
        }
        
        # Merge from incoming
        foreach ($key in $IncomingValue.Keys) {
            if ($result.ContainsKey($key)) {
                # Key exists in both - recursively merge if both are hashtables
                if ($result[$key] -is [hashtable] -and $IncomingValue[$key] -is [hashtable]) {
                    $result[$key] = Merge-ValuesUnion -BaseValue $result[$key] -IncomingValue $IncomingValue[$key]
                }
                # Otherwise, incoming takes precedence
                else {
                    $result[$key] = $IncomingValue[$key]
                }
            }
            else {
                $result[$key] = $IncomingValue[$key]
            }
        }
        
        return $result
    }
    
    # Default: return incoming value
    return $IncomingValue
}

function Invoke-ConflictResolution {
    <#
    .SYNOPSIS
        Interactive conflict resolution prompt.
    .DESCRIPTION
        Presents a conflict to the user and captures their resolution choice.
    #>
    param(
        [string]$Path,
        $BaseValue,
        $IncomingValue
    )
    
    Write-Host ""
    Write-Host "=== CONFLICT ===" -ForegroundColor Red
    Write-Host "Path: $Path" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Base (ours):" -ForegroundColor Yellow
    Write-Host (Format-ValueForDisplay -Value $BaseValue)
    Write-Host ""
    Write-Host "Incoming (theirs):" -ForegroundColor Yellow
    Write-Host (Format-ValueForDisplay -Value $IncomingValue)
    Write-Host ""
    Write-Host "Options:" -ForegroundColor Green
    Write-Host "  [b] Keep base (ours)" -ForegroundColor White
    Write-Host "  [i] Accept incoming (theirs)" -ForegroundColor White
    Write-Host "  [u] Use union (merge both)" -ForegroundColor White
    Write-Host "  [s] Skip (keep both for later)" -ForegroundColor White
    Write-Host "  [?] Show help" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Resolution choice"
        
        switch ($choice.ToLower()) {
            "b" { return @{ Action = "base" } }
            "base" { return @{ Action = "base" } }
            "ours" { return @{ Action = "base" } }
            "i" { return @{ Action = "incoming" } }
            "incoming" { return @{ Action = "incoming" } }
            "theirs" { return @{ Action = "incoming" } }
            "u" { return @{ Action = "union" } }
            "union" { return @{ Action = "union" } }
            "s" { return @{ Action = "skip" } }
            "skip" { return @{ Action = "skip" } }
            "?" { 
                Write-Host "Help:" -ForegroundColor Cyan
                Write-Host "  b/base/ours   - Keep the base value (from -Base file)" -ForegroundColor White
                Write-Host "  i/incoming/theirs - Accept the incoming value (from -Incoming file)" -ForegroundColor White
                Write-Host "  u/union       - Merge both values (works well for arrays and hashtables)" -ForegroundColor White
                Write-Host "  s/skip        - Keep both values as array for manual resolution later" -ForegroundColor White
            }
            default {
                Write-Host "Invalid choice. Enter b, i, u, s, or ? for help." -ForegroundColor Red
            }
        }
    } while ($true)
}

function Format-ValueForDisplay {
    <#
    .SYNOPSIS
        Formats a value for display in conflict resolution.
    #>
    param($Value)
    
    if ($null -eq $Value) {
        return "<null>"
    }
    
    if ($Value -is [hashtable]) {
        $lines = @()
        foreach ($key in $Value.Keys) {
            $lines += "  $key = $(Format-ValueForDisplay -Value $Value[$key])"
        }
        return "@{`n$($lines -join "`n")`n}"
    }
    
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "@()"
        }
        $items = $Value | ForEach-Object { Format-ValueForDisplay -Value $_ }
        return "@($($items -join ', '))"
    }
    
    if ($Value -is [string]) {
        return '"' + $Value + '"'
    }
    
    return $Value.ToString()
}

function Export-MergedConfig {
    <#
    .SYNOPSIS
        Exports merged configuration to a file.
    #>
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    try {
        # Determine format from extension
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
        
        Write-Log -Level "OK" -Message "Merged configuration saved to: $Path"
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to save merged configuration: $($_.Exception.Message)"
    }
}

function ConvertTo-HashtableString {
    <#
    .SYNOPSIS
        Converts a hashtable to a PowerShell hashtable string representation.
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
        $formattedValue = Format-ValueForExport -Value $value -IndentLevel ($IndentLevel + 1)
        $lines += "$indent    $key = $formattedValue"
    }
    
    if ($IndentLevel -eq 0) {
        $lines += "}"
    }
    
    return $lines -join "`n"
}

function Format-ValueForExport {
    <#
    .SYNOPSIS
        Formats a value for export as PowerShell code.
    #>
    param($Value, [int]$IndentLevel)
    
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
        $items = $Value | ForEach-Object { Format-ValueForExport -Value $_ -IndentLevel $IndentLevel }
        return "@($($items -join ', '))"
    }
    
    if ($Value -is [hashtable]) {
        $lines = @("@{`n")
        foreach ($key in $Value.Keys) {
            $formattedValue = Format-ValueForExport -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
            $lines += "$indent    $key = $formattedValue`n"
        }
        $lines += "$indent}"
        return $lines -join ""
    }
    
    return '"' + $Value.ToString() + '"'
}

function Format-MergeReport {
    <#
    .SYNOPSIS
        Formats merge results for human-readable display.
    #>
    param(
        [hashtable]$MergeResult
    )
    
    $output = @()
    $output += "`n=== MERGE REPORT ===`n"
    
    if ($MergeResult.Success) {
        $output += "Status: SUCCESS"
    }
    else {
        $output += "Status: FAILED (has unresolved conflicts)"
    }
    
    $output += ""
    $output += "Statistics:"
    $output += "  Auto-merged: $($MergeResult.AutoMerged)"
    $output += "  Conflicts resolved: $($MergeResult.ResolvedConflicts)"
    $output += "  Unresolved conflicts: $($MergeResult.Conflicts.Count)"
    
    if ($MergeResult.Conflicts.Count -gt 0) {
        $output += ""
        $output += "Unresolved Conflicts:"
        foreach ($conflict in $MergeResult.Conflicts) {
            $output += "  - $($conflict.Path)"
        }
    }
    
    return $output -join "`n"
}

Export-ModuleMember -Function @(
    "Merge-Configuration"
    "Format-MergeReport"
)
