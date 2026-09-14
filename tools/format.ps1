[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
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
Import-Module $module.Path -ErrorAction Stop

$extensions = @('.ps1', '.psm1', '.psd1', '.json', '.yml', '.yaml', '.md')
$files = Get-ChildItem -LiteralPath $repoRoot -File -Recurse | Where-Object {
    ($_.Extension -in $extensions -or
    $_.Name -in @('.editorconfig', '.gitattributes', '.gitignore')) -and
    $_.FullName -notmatch '[\\/](\.git|\.agents)[\\/]' -and
    $_.FullName -notmatch '[\\/]docs[\\/]report[\\/]'
}
$encoding = New-Object Text.UTF8Encoding($false)
$changed = @()
foreach ($file in $files) {
    $original = [IO.File]::ReadAllText($file.FullName)
    $formatted = $original.Replace("`r`n", "`n").Replace("`r", "`n")
    $formatted = [regex]::Replace($formatted, '(?m)[ \t]+$', '')
    $formatted = $formatted.TrimEnd("`n") + "`n"
    if ($file.Extension -in @('.ps1', '.psm1', '.psd1')) {
        $formatted = Invoke-Formatter -ScriptDefinition $formatted `
            -Settings $settings
        $formatted = $formatted.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
    }
    if ($formatted -cne $original) {
        $changed += $file.FullName.Substring($repoRoot.Length + 1)
        if (-not $Check) {
            [IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
        }
    }
}
if ($Check -and $changed.Count -gt 0) {
    $changed | ForEach-Object { Write-Error "FormatRequired: $_" }
    exit 1
}
if (-not $Check) {
    $changed | ForEach-Object { Write-Host "Formatted $_" }
}
