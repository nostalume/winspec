# merge.psm1 - Merge functionality for bidirectional sync
# Provides merge strategies and conflict resolution for WinSpec configurations
# Implements the 'merge' command as part of Git-like workflow

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

# =============================================================================
# CONFIGURATION MERGE MODULE
# =============================================================================

function Merge-Configuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Base,

        [Parameter(Mandatory = $true)]
        [hashtable]$Incoming,

        [string]$Output,

        [ValidateSet("auto", "union", "ours", "theirs")]
        [string]$Strategy = "auto",

        [switch]$Interactive,

        [switch]$DryRun
    )

    Write-Log -Level INFO -Message "Starting configuration merge"
    Write-Log -Level INFO -Message "Strategy: $Strategy"

    $mergeResult = Invoke-MergeEngine `
        -Base $Base `
        -Incoming $Incoming `
        -Strategy $Strategy `
        -Interactive:$Interactive

    if ($mergeResult.Success) {

        if ($Output) {
            if ($DryRun) {
                Write-Log -Level INFO -Message "[DryRun] Would save merged config to: $Output"
            }
            else {
                Save-Configuration -Config $mergeResult.Merged -Path $Output
            }
        }

        Write-Log -Level OK -Message "Merge completed successfully"
        Write-Log -Level INFO -Message "Conflicts resolved: $($mergeResult.ResolvedConflicts)"
        Write-Log -Level INFO -Message "Auto merged: $($mergeResult.AutoMerged)"
    }
    else {
        Write-Log -Level ERROR -Message "Merge failed with $($mergeResult.Conflicts.Count) unresolved conflicts"
    }

    return $mergeResult
}


# =============================================================================
# CORE MERGE ENGINE
# =============================================================================

function Invoke-MergeEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,

        [Parameter(Mandatory)]
        [hashtable]$Incoming,

        [string]$Strategy,

        [string]$Path = "",

        [switch]$Interactive
    )

    $result = @{
        Success           = $true
        Merged            = @{}
        Conflicts         = @()
        ResolvedConflicts = 0
        AutoMerged        = 0
    }

    $allKeys = ($Base.Keys + $Incoming.Keys) | Sort-Object -Unique

    foreach ($key in $allKeys) {
        $childPath = if ($Path) { "$Path.$key" } else { "$key" }

        $hasBase = $Base.ContainsKey($key)
        $hasIncoming = $Incoming.ContainsKey($key)

        $baseValue = if ($hasBase) { $Base[$key] } else { $null }
        $incomingValue = if ($hasIncoming) { $Incoming[$key] } else { $null }

        $mergeItem = Resolve-MergeItem `
            -Path $childPath `
            -HasBase $hasBase `
            -HasIncoming $hasIncoming `
            -BaseValue $baseValue `
            -IncomingValue $incomingValue `
            -Strategy $Strategy `
            -Interactive:$Interactive

        if ($mergeItem.Conflict) {

            $result.Conflicts += $mergeItem.ConflictInfo

            if ($mergeItem.Resolved) {
                $result.Merged[$key] = $mergeItem.Value
                $result.ResolvedConflicts++
            }
            else {
                $result.Success = $false
            }

        }
        else {

            $result.Merged[$key] = $mergeItem.Value
            $result.AutoMerged++

        }
    }

    return $result
}


# =============================================================================
# MERGE ITEM RESOLUTION
# =============================================================================

function Resolve-MergeItem {

    param(
        [string]$Path,

        [bool]$HasBase,
        [bool]$HasIncoming,

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

    if ($HasBase -and -not $HasIncoming) {
        $result.Value = $BaseValue
        return $result
    }

    if (-not $HasBase -and $HasIncoming) {
        $result.Value = $IncomingValue
        return $result
    }

    if (Test-ValuesEqual $BaseValue $IncomingValue) {
        $result.Value = $BaseValue
        return $result
    }

    # both exist but differ

    $result.Conflict = $true
    $auto = Resolve-ByStrategy `
        -Path $Path `
        -BaseValue $BaseValue `
        -IncomingValue $IncomingValue `
        -Strategy $Strategy `
        -Interactive:$Interactive

    if ($auto.Success) {
        $result.Value = $auto.Value
        $result.Resolved = $true
        return $result
    }

    if ($Interactive) {
        $choice = Invoke-ConflictResolution `
            -Path $Path `
            -BaseValue $BaseValue `
            -IncomingValue $IncomingValue

        switch ($choice.Action) {
            "base" {
                $result.Value = $BaseValue
                $result.Resolved = $true
            }
            "incoming" {
                $result.Value = $IncomingValue
                $result.Resolved = $true
            }
            "union" {
                $result.Value = Merge-ValuesUnion $BaseValue $IncomingValue
                $result.Resolved = $true
            }
            "skip" {
                $result.Value = @($BaseValue, $IncomingValue)
                $result.Resolved = $false
            }
        }

    }
    else {
        $result.ConflictInfo = [PSCustomObject]@{
            Path     = $Path
            Base     = $BaseValue
            Incoming = $IncomingValue
            Strategy = $Strategy
        }

    }

    return $result
}


# =============================================================================
# STRATEGY RESOLUTION
# =============================================================================

function Resolve-ByStrategy {
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
            $result.Value = Merge-ValuesUnion $BaseValue $IncomingValue
        }
        "auto" {
            if ($BaseValue -is [array] -or $IncomingValue -is [array]) {
                $result.Success = $true
                $result.Value = Merge-ValuesUnion $BaseValue $IncomingValue
            }
            elseif ($BaseValue -is [hashtable] -and $IncomingValue -is [hashtable]) {
                $merge = Invoke-MergeEngine `
                    -Base $BaseValue `
                    -Incoming $IncomingValue `
                    -Strategy "auto"

                $result.Success = $true
                $result.Value = $merge.Merged
            }
        }

    }

    return $result
}


# =============================================================================
# UNION MERGE
# =============================================================================

function Merge-ValuesUnion {
    param(
        $BaseValue,
        $IncomingValue
    )

    if ($BaseValue -is [array] -or $IncomingValue -is [array]) {

        $base = if ($BaseValue -is [array]) { $BaseValue } else { @($BaseValue) }
        $incoming = if ($IncomingValue -is [array]) { $IncomingValue } else { @($IncomingValue) }

        $set = [System.Collections.Generic.HashSet[string]]::new()
        $result = @()

        foreach ($item in $base + $incoming) {
            $key = ($item | ConvertTo-Json -Compress)

            if ($set.Add($key)) {
                $result += $item
            }

        }
        return $result
    }

    if ($BaseValue -is [hashtable] -and $IncomingValue -is [hashtable]) {
        $merge = Invoke-MergeEngine `
            -Base $BaseValue `
            -Incoming $IncomingValue `
            -Strategy "union"

        return $merge.Merged
    }

    return $IncomingValue
}


# =============================================================================
# VALUE COMPARISON
# =============================================================================

function Test-ValuesEqual {

    param(
        $Value1,
        $Value2
    )

    $a = $Value1 | ConvertTo-Json -Compress -Depth 20
    $b = $Value2 | ConvertTo-Json -Compress -Depth 20

    return $a -eq $b
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
