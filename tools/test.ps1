[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Full')][string]$Profile = 'Quick',
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cache = Join-Path $repo '.agents/cache/modules'
if (Test-Path -LiteralPath $cache) { $env:PSModulePath = $cache + ';' + $env:PSModulePath }
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;" + $env:PSModulePath
}
Import-Module Pester -MinimumVersion 5.7.1 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repo 'tests'
$configuration.Run.PassThru = $true
$configuration.Run.SkipRemainingOnFailure = 'Run'
if ($Profile -eq 'Quick') { $configuration.Filter.Tag = @('Unit', 'Quick') }
$configuration.Output.Verbosity = 'Normal'
if ($ResultPath) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = [IO.Path]::ChangeExtension($ResultPath, 'xml')
    $configuration.TestResult.OutputFormat = 'NUnit3'
}
$result = Invoke-Pester -Configuration $configuration
$selected = @($result.Tests | Where-Object ShouldRun)
$executed = $result.PassedCount + $result.FailedCount + $result.InconclusiveCount
if ($ResultPath) {
    [ordered]@{
        hostVersion = $PSVersionTable.PSVersion.ToString(); profile = $Profile
        result = [string]$result.Result; discovered = $result.TotalCount
        selected = $selected.Count; executed = $executed; passed = $result.PassedCount
        failed = $result.FailedCount; skipped = $result.SkippedCount; notRun = $result.NotRunCount
        seconds = $result.Duration.TotalSeconds
        selection = @($selected | ForEach-Object { [ordered]@{ file = [IO.Path]::GetFileName($_.ScriptBlock.File); name = $_.Name; topic = $_.Data.Topic } })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
if ($result.Result -ne 'Passed' -or $selected.Count -eq 0 -or $executed -ne $selected.Count -or $result.SkippedCount -ne 0) { exit 1 }
if ($Profile -eq 'Full' -and $selected.Count -ne $result.TotalCount) { exit 1 }
