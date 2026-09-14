# Value equality and recursive differences for admitted WinSpec data.

function Test-WinSpecValueEqual {
    param($Left, $Right)

    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    if ($Left -is [System.Collections.IDictionary] -or
        $Right -is [System.Collections.IDictionary]) {
        if ($Left -isnot [System.Collections.IDictionary] -or
            $Right -isnot [System.Collections.IDictionary] -or
            $Left.Count -ne $Right.Count) {
            return $false
        }
        foreach ($key in $Left.Keys) {
            if (-not $Right.Contains($key) -or
                -not (Test-WinSpecValueEqual $Left[$key] $Right[$key])) {
                return $false
            }
        }
        return $true
    }
    $leftSequence = $Left -is [System.Collections.IEnumerable] -and
    $Left -isnot [string]
    $rightSequence = $Right -is [System.Collections.IEnumerable] -and
    $Right -isnot [string]
    if ($leftSequence -or $rightSequence) {
        if (-not $leftSequence -or -not $rightSequence) { return $false }
        $leftItems = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($index = 0; $index -lt $leftItems.Count; $index++) {
            if (-not (Test-WinSpecValueEqual `
                        $leftItems[$index] $rightItems[$index])) {
                return $false
            }
        }
        return $true
    }
    return $Left -ceq $Right
}

function Get-WinSpecDifference {
    param($Desired, $Actual, [string]$Path = '$')

    $items = New-Object 'System.Collections.Generic.List[object]'
    if ($Desired -is [hashtable] -and $Actual -is [hashtable]) {
        $keys = @($Desired.Keys + $Actual.Keys | Sort-Object -Unique)
        foreach ($key in $keys) {
            $childPath = if ($Path -eq '$') { '$.' + $key } else { $Path + '.' + $key }
            if (-not $Desired.ContainsKey($key)) {
                $null = $items.Add([pscustomobject]@{
                        Type = 'Removed'
                        Path = $childPath
                        ConfigValue = $null
                        SystemValue = $Actual[$key]
                    })
            }
            elseif (-not $Actual.ContainsKey($key)) {
                $null = $items.Add([pscustomobject]@{
                        Type = 'Added'
                        Path = $childPath
                        ConfigValue = $Desired[$key]
                        SystemValue = $null
                    })
            }
            else {
                foreach ($item in @(Get-WinSpecDifference `
                            $Desired[$key] $Actual[$key] $childPath)) {
                    $null = $items.Add($item)
                }
            }
        }
    }
    elseif (-not (Test-WinSpecValueEqual $Desired $Actual)) {
        $null = $items.Add([pscustomobject]@{
                Type = 'Changed'
                Path = $Path
                ConfigValue = $Desired
                SystemValue = $Actual
            })
    }
    return $items.ToArray()
}

Export-ModuleMember -Function 'Test-WinSpecValueEqual', 'Get-WinSpecDifference'
