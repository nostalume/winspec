Import-Module (Join-Path $PSScriptRoot 'spec.psm1') -Force

function Test-MergeValueEqual {
    param($Left, $Right)
    return (($Left | ConvertTo-Json -Depth 64 -Compress) -ceq ($Right | ConvertTo-Json -Depth 64 -Compress))
}

function Merge-WinSpecMap {
    param([hashtable]$Base, [hashtable]$Incoming, [string]$Strategy, [string]$Path = '')
    $merged = @{}
    $conflicts = @()
    $keys = @($Base.Keys + $Incoming.Keys | Sort-Object -Unique)
    foreach ($key in $keys) {
        $itemPath = if ($Path) { "$Path.$key" } else { [string]$key }
        $inBase = $Base.ContainsKey($key)
        $inIncoming = $Incoming.ContainsKey($key)
        if (-not $inIncoming) { $merged[$key] = $Base[$key]; continue }
        if (-not $inBase) { $merged[$key] = $Incoming[$key]; continue }
        $left = $Base[$key]
        $right = $Incoming[$key]
        if (Test-MergeValueEqual $left $right) { $merged[$key] = $left; continue }
        if ($left -is [hashtable] -and $right -is [hashtable]) {
            $nested = Merge-WinSpecMap $left $right $Strategy $itemPath
            $merged[$key] = $nested.Merged
            $conflicts += @($nested.Conflicts)
            continue
        }
        switch ($Strategy) {
            'ours' { $merged[$key] = $left }
            'theirs' { $merged[$key] = $right }
            'union' {
                if (($left -is [array]) -and ($right -is [array])) {
                    $merged[$key] = @($left + $right | Select-Object -Unique)
                } else { $merged[$key] = $right }
            }
            default {
                $conflicts += [pscustomobject]@{ Path = $itemPath; Base = $left; Incoming = $right }
            }
        }
    }
    return [pscustomobject]@{ Merged = $merged; Conflicts = @($conflicts) }
}

function Invoke-MergeEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Incoming,
        [ValidateSet('auto', 'union', 'ours', 'theirs')][string]$Strategy = 'auto')
    $result = Merge-WinSpecMap $Base $Incoming $Strategy
    return [pscustomobject]@{
        Success = (@($result.Conflicts).Count -eq 0)
        Merged = $result.Merged
        Conflicts = @($result.Conflicts)
        Strategy = $Strategy
    }
}

function Merge-Configuration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Incoming,
        [string]$Output, [ValidateSet('auto', 'union', 'ours', 'theirs')][string]$Strategy = 'auto',
        [switch]$Force)
    $result = Invoke-MergeEngine -Base $Base -Incoming $Incoming -Strategy $Strategy
    if ($Output -and $result.Success) {
        Save-Configuration -Config $result.Merged -Path $Output -Force:$Force | Out-Null
    }
    return $result
}

Export-ModuleMember -Function 'Merge-Configuration', 'Invoke-MergeEngine'
