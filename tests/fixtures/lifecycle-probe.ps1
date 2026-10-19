param([string]$Repo, [string]$Fixture, [string]$Mode, [string]$Result)
$ErrorActionPreference = 'Stop'
$env:TEMP = $env:TMP = Join-Path $Fixture 'temp'
$null = [IO.Directory]::CreateDirectory($env:TEMP)
Import-Module (Join-Path $Repo 'winspec/provider-runtime.psm1') -Force
$provider = [pscustomobject]@{
    Name = 'Lifecycle'; Kind = 'Action'; Execution = 'Protocol'; Operations = @('run')
    EntryPointType = 'Executable'; EntryPoint = (Join-Path $Fixture 'fixture.exe'); PackageRoot = $Fixture
}
$before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'winspec-provider-*' | ForEach-Object FullName)
$timer = [Diagnostics.Stopwatch]::StartNew()
$r = [ordered]@{ mode = $Mode }
try {
    $value = Invoke-ExternalProvider $provider run -TimeoutSeconds $(if ($Mode -in @('duplex', 'bad')) { 5 } else { 1 }) `
        -RequestInput @{ configuration = @{ blob = $(if ($Mode -in @('noinput', 'duplex')) { 'b' * 2MB } else { '' }) } }
    $r.status = $value.status
    $r.length = $value.output.blob.Length
}
catch {
    $r.error = $_.Exception.Message
    $r.cleanupError = $_.Exception.Data['ProcessCleanupError']
}
finally {
    $r.elapsed = $timer.Elapsed.TotalSeconds
    $r.newDirectories = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'winspec-provider-*' |
            Where-Object FullName -NotIn $before | ForEach-Object FullName)
    $r | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Result -Encoding utf8
}
