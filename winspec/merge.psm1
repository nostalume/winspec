# merge.psm1 - Merge functionality for bidirectional sync
# Provides merge strategies and conflict resolution for WinSpec configurations
# Implements the 'merge' command as part of Git-like workflow

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

function Merge-Configuration {
    <#
    .SYNOPSIS
        Merges two WinSpec configurations with conflict resolution.
    .DESCRIPTION
        Performs a three-way merge between base, incoming configurations using
        specified merge strategy. Supports interactive and non-interactive modes.
        Implements the 'merge' command for Git-like workflow.
    .PARAMETER Base
        Path to the base configuration file.
    .PARAMETER Incoming
        Path to the incoming configuration file.
    .PARAMETER Output
        Path to write the merged configuration.
    .PARAMETER Strategy
        Merge strategy: auto, union, ours, theirs.
    .PARAMETER Interactive
        Enable interactive conflict resolution.
    .PARAMETER DryRun
        Preview merge without writing.
    .OUTPUTS
        Hashtable with merge results and conflicts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Base,
        
        [Parameter(Mandatory = $false)]
        [string]$Incoming,
        
        [Parameter(Mandatory = $false)]
        [string]$Output,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("auto", "union", "ours", "theirs")]
        [string]$Strategy = "auto",
        
        [Parameter(Mandatory = $false)]
        [switch]$Interactive,
        
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    
    Write-Log -Level "INFO" -Message "Starting configuration merge..."
    
    # Resolve paths using common function
    $basePath = if ($Base) { Resolve-SpecPath -Spec $Base } else { $null }
    $incomingPath = if ($Incoming) { Resolve-SpecPath -Spec $Incoming } else { $null }
    
    if (-not $basePath -or -not (Test-Path $basePath)) {
        Write-Log -Level "ERROR" -Message "Base configuration not found: $Base"
        return $null
    }
    
    if (-not $incomingPath -or -not (Test-Path $incomingPath)) {
        Write-Log -Level "ERROR" -Message "Incoming configuration not found: $Incoming"
        return $null
    }
    
    Write-Log -Level "INFO" -Message "Base: $basePath"
    Write-Log -Level "INFO" -Message "Incoming: $incomingPath"
    Write-Log -Level "INFO" -Message "Strategy: $Strategy"
    
    # Load configurations using shared utility
    $baseConfig = Import-Configuration -Path $basePath
    if (-not $baseConfig) {
        Write-Log -Level "ERROR" -Message "Failed to load base configuration"
        return $null
    }
    
    $incomingConfig = Import-Configuration -Path $incomingPath
    if (-not $incomingConfig) {
        Write-Log -Level "ERROR" -Message "Failed to load incoming configuration"
        return $null
    }
    
    # Perform merge
    $mergeResult = Invoke-MergeEngine -Base $baseConfig -Incoming $incomingConfig -Strategy $Strategy -Interactive:$Interactive
    
    if ($mergeResult.Success) {
        # Write output if specified
        if ($Output) {
            if ($DryRun) {
                Write-Log -Level "INFO" -Message "[DryRun] Would save merged config to: $Output"
            }
            else {
                $null = Save-Configuration -Config $mergeResult.Merged -Path $Output
            }
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
        Success           = $true
        Merged            = @{}
        Conflicts         = @()
        ResolvedConflicts = 0
        AutoMerged        = 0
        Path              = ""
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
        Conflict     = $false
        Resolved     = $false
        Value        = $null
        ConflictInfo = $null
    }
    
    # Case 1: Key only in base (not in incoming)
    if (-not $IncomingValue -and $BaseValue) {
        $result.Value = $BaseValue
        return $result
    }
    
    # Case 2: Key only in incoming (not in base)
    if (-not $BaseValue -and $IncomingValue) {
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
                $result.Value = @($BaseValue, $IncomingValue)
                $result.Resolved = $false
            }
        }
    }
    else {
        # Non-interactive: record conflict
        $result.ConflictInfo = @{
            Path          = $Path
            BaseValue     = $BaseValue
            IncomingValue = $IncomingValue
            Strategy      = $Strategy
        }
    }
    
    return $result
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
        Value   = $null
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
    .PARAMETER BaseValue
        The base value.
    .PARAMETER IncomingValue
        The incoming value to merge.
    .PARAMETER MaxDepth
        Maximum recursion depth to prevent stack overflow on circular refs.
    .PARAMETER CurrentDepth
        Internal parameter tracking current recursion depth.
    #>
    param(
        $BaseValue,
        $IncomingValue,
        [int]$MaxDepth = 10,
        [int]$CurrentDepth = 0
    )
    
    # Check recursion depth
    if ($CurrentDepth -gt $MaxDepth) {
        Write-Verbose "Merge-ValuesUnion: Max depth ($MaxDepth) exceeded"
        return $IncomingValue
    }
    
    # Handle arrays
    if ($BaseValue -is [array] -or $IncomingValue -is [array]) {
        $baseArray = if ($BaseValue -is [array]) { $BaseValue } else { @($BaseValue) }
        $incomingArray = if ($IncomingValue -is [array]) { $IncomingValue } else { @($IncomingValue) }
        
        # Union with deduplication using hashtable for O(n) lookup
        $seen = @{}  # Hashtable for O(1) lookup
        $result = @()
        
        # Process base array
        foreach ($item in $baseArray) {
            $key = $item.ToString()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $result += $item
            }
        }
        
        # Process incoming array
        foreach ($item in $incomingArray) {
            $key = $item.ToString()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
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
                    $result[$key] = Merge-ValuesUnion -BaseValue $result[$key] -IncomingValue $IncomingValue[$key] -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1)
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
    Write-Host (ConvertTo-DetailedDisplayValue -Value $BaseValue)
    Write-Host ""
    Write-Host "Incoming (theirs):" -ForegroundColor Yellow
    Write-Host (ConvertTo-DetailedDisplayValue -Value $IncomingValue)
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
    "Merge-ValuesUnion"
    "Invoke-MergeEngine"
    "Resolve-MergeItem"
    "Resolve-ByStrategy"
    "Invoke-ConflictResolution"
)
