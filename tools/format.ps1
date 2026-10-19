[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$requiredVersion = [version]'1.24.0'
$module = Get-Module -ListAvailable PSScriptAnalyzer |
    Where-Object Version -GE $requiredVersion |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $module) {
    throw "FormatterUnavailable: install PSScriptAnalyzer $requiredVersion or newer"
}
$discoveryMilliseconds = $timer.Elapsed.TotalMilliseconds
Import-Module $module.Path -ErrorAction Stop
$importMilliseconds = $timer.Elapsed.TotalMilliseconds - $discoveryMilliseconds

$extensions = @('.ps1', '.psm1', '.psd1', '.json', '.yml', '.yaml', '.md')
$enumerationStart = $timer.Elapsed.TotalMilliseconds
$pending = New-Object 'Collections.Generic.Stack[string]'
$pending.Push($repoRoot)
$files = @(
    while ($pending.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Pop()) {
            if ($entry.PSIsContainer) {
                # Prune before descent; retain the original path exclusions.
                $directory = $entry.FullName + [IO.Path]::DirectorySeparatorChar
                if ($directory -match '[\\/](\.git|\.agents)[\\/]' -or
                    $directory -match '[\\/]docs[\\/]report[\\/]') { continue }
                # Native recursion skips directory links on both supported hosts.
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $pending.Push($entry.FullName)
            }
            elseif ($entry.Extension -in $extensions -or
                $entry.Name -in @('.editorconfig', '.gitattributes', '.gitignore')) {
                $entry
            }
        }
    }
)
$enumerationMilliseconds = $timer.Elapsed.TotalMilliseconds - $enumerationStart
$encoding = New-Object Text.UTF8Encoding($false)
$changed = @()
$formatterMilliseconds = 0.0
$formatterCount = 0
$fileStart = $timer.Elapsed.TotalMilliseconds
foreach ($file in $files) {
    $original = [IO.File]::ReadAllText($file.FullName)
    $formatted = $original.Replace("`r`n", "`n").Replace("`r", "`n")
    $formatted = [regex]::Replace($formatted, '(?m)[ \t]+$', '')
    $formatted = $formatted.TrimEnd("`n") + "`n"
    if ($file.Extension -in @('.ps1', '.psm1', '.psd1')) {
        $formatterStart = $timer.Elapsed.TotalMilliseconds
        $formatted = Invoke-Formatter -ScriptDefinition $formatted `
            -Settings $settings
        $formatterMilliseconds += $timer.Elapsed.TotalMilliseconds - $formatterStart
        $formatterCount++
        $formatted = $formatted.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
    }
    if ($formatted -cne $original) {
        $changed += $file.FullName.Substring($repoRoot.Length + 1)
        if (-not $Check) {
            [IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
        }
    }
}
$fileOtherMilliseconds = $timer.Elapsed.TotalMilliseconds - $fileStart - $formatterMilliseconds
Write-Verbose ('FormatTiming discoveryMs={0:F3}; importMs={1:F3}; enumerationMs={2:F3}; fileOtherMs={3:F3}; formatterMs={4:F3}; totalMs={5:F3}; files={6}; formatterCalls={7}' -f
    $discoveryMilliseconds, $importMilliseconds, $enumerationMilliseconds,
    $fileOtherMilliseconds, $formatterMilliseconds, $timer.Elapsed.TotalMilliseconds,
    $files.Count, $formatterCount)
Write-Verbose "FormatModule version=$($module.Version); path=$($module.Path)"
if ($Check -and $changed.Count -gt 0) {
    $changed | ForEach-Object { Write-Error "FormatRequired: $_" }
    exit 1
}
if (-not $Check) {
    $changed | ForEach-Object { Write-Host "Formatted $_" }
}
