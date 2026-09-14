BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:WinSpec = Join-Path (Join-Path $script:RepoRoot 'winspec') 'winspec.ps1'
    function Invoke-WinSpecIntegration {
        param([string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $text = & pwsh -NoProfile -File $script:WinSpec @Arguments 2>&1 | Out-String
        [pscustomobject]@{ExitCode = $LASTEXITCODE; Text = $text.Trim() }
    }
}

Describe 'external state provider integration' {
    BeforeEach {
        $script:ProviderRoot = Join-Path $TestDrive 'providers'
        $script:Package = Join-Path $script:ProviderRoot 'acme'
        New-Item -ItemType Directory -Path $script:Package -Force | Out-Null
        $script:Sentinel = Join-Path $TestDrive 'provider-ran'
        $providerSource = @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Set-Content -LiteralPath $request.input.configuration.sentinel -Value $request.operation
@{
    protocolVersion=1
    requestId=$request.requestId
    status='Succeeded'
    output=@{value=$request.input.configuration.value}
    diagnostics=@()
} | ConvertTo-Json -Depth 10 -Compress
'@
        Set-Content -LiteralPath (Join-Path $script:Package 'provider.ps1') -Value $providerSource
        Set-Content -LiteralPath (Join-Path $script:Package 'provider.json') -Value (
            '{"schemaVersion":1,"name":"Acme","kind":"State","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["capture","compare","apply"]}')
        $script:Spec = Join-Path $TestDrive 'external.winspec.psd1'
        Set-Content -LiteralPath $script:Spec -Value (
            "@{ SchemaVersion=1; Acme=@{ value='observed'; sentinel='$script:Sentinel' } }")
    }

    It 'validates external configuration without executing provider code' {
        $result = Invoke-WinSpecIntegration @('validate', $script:Spec, '-ProviderPath', $script:ProviderRoot, '-Json')
        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:Sentinel | Should -BeFalse
        ($result.Text | ConvertFrom-Json).diagnostics.code | Should -Contain 'ProviderValidationUnavailable'
    }


    It 'routes selected status to one external provider process' {
        $result = Invoke-WinSpecIntegration @('status', $script:Spec, '-ProviderPath', $script:ProviderRoot,
            '-Providers', 'Acme', '-Json')
        $result.ExitCode | Should -Be 0
        (Get-Content -Raw $script:Sentinel).Trim() | Should -Be 'capture'
        ($result.Text | ConvertFrom-Json).results.state.Acme.value | Should -Be 'observed'
    }

    It 'does not execute a discovered external State provider without selection' {
        $dormantPackage = Join-Path $script:ProviderRoot 'dormant'
        $dormantSentinel = Join-Path $TestDrive 'dormant-ran'
        $escapedSentinel = $dormantSentinel.Replace("'", "''")
        New-Item -ItemType Directory -Path $dormantPackage -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.json') `
            -Value ('{"schemaVersion":1,"name":"Dormant","kind":"State",' +
            '"protocolVersion":1,"script":"provider.ps1",' +
            '"operations":["capture","compare","apply"]}')
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.ps1') `
            -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Set-Content -LiteralPath '$escapedSentinel' -Value `$request.operation
`$status = if (`$request.operation -eq 'compare') { 'Unchanged' } else { 'Succeeded' }
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = `$status
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@

        $result = Invoke-WinSpecIntegration @(
            'status', '-ProviderPath', $script:ProviderRoot, '-Json')

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $dormantSentinel | Should -BeFalse
        { $result.Text | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'defaults a spec-scoped status to only the State sections in that spec' {
        $dormantPackage = Join-Path $script:ProviderRoot 'dormant'
        $dormantSentinel = Join-Path $TestDrive 'dormant-ran'
        $escapedSentinel = $dormantSentinel.Replace("'", "''")
        New-Item -ItemType Directory -Path $dormantPackage -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.json') `
            -Value ('{"schemaVersion":1,"name":"Dormant","kind":"State",' +
            '"protocolVersion":1,"script":"provider.ps1",' +
            '"operations":["capture","compare","apply"]}')
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.ps1') `
            -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Set-Content -LiteralPath '$escapedSentinel' -Value `$request.operation
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Succeeded'
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@

        $result = Invoke-WinSpecIntegration @(
            'status', $script:Spec, '-ProviderPath', $script:ProviderRoot,
            '-Json')

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $dormantSentinel | Should -BeFalse
        $document = $result.Text | ConvertFrom-Json
        @($document.results.state.psobject.Properties.Name) |
            Should -Be @('Acme')
    }

    It 'keeps unrelated State packages inert for diff apply and Workflow Apply' {
        $dormantPackage = Join-Path $script:ProviderRoot 'dormant'
        $dormantSentinel = Join-Path $TestDrive 'dormant-ran'
        $escapedSentinel = $dormantSentinel.Replace("'", "''")
        New-Item -ItemType Directory -Path $dormantPackage -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.json') `
            -Value ('{"schemaVersion":1,"name":"Dormant","kind":"State",' +
            '"protocolVersion":1,"script":"provider.ps1",' +
            '"operations":["capture","compare","apply"]}')
        Set-Content -LiteralPath (Join-Path $dormantPackage 'provider.ps1') `
            -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Set-Content -LiteralPath '$escapedSentinel' -Value `$request.operation
`$status = if (`$request.operation -eq 'compare') { 'Unchanged' } else { 'Succeeded' }
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = `$status
    output = @{ differences = @() }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@
        Set-Content -LiteralPath (Join-Path $script:Package 'provider.ps1') `
            -Value @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($request.input.configuration.sentinel) {
    Set-Content -LiteralPath $request.input.configuration.sentinel -Value $request.operation
}
$status = switch ($request.operation) {
    'capture' { 'Succeeded' }
    'compare' { 'Unchanged' }
    'apply' { 'Succeeded' }
}
$output = if ($request.operation -eq 'capture') {
    @{ value = 'observed' }
} else {
    @{ differences = @() }
}
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = $status
    output = $output
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@

        foreach ($command in @('diff', 'apply')) {
            $result = Invoke-WinSpecIntegration @(
                $command, $script:Spec, '-ProviderPath',
                $script:ProviderRoot, '-Json')
            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $dormantSentinel | Should -BeFalse
        }

        Set-Content -LiteralPath $script:Spec -Value (
            "@{ SchemaVersion=1; Acme=@{ value='observed'; sentinel='$script:Sentinel' }; " +
            "Workflows=@{ setup=@{ Steps=@(@{ Apply=@{} }) } } }")
        $workflow = Invoke-WinSpecIntegration @(
            'workflow', 'setup', '-Spec', $script:Spec,
            '-ProviderPath', $script:ProviderRoot, '-DryRun', '-Json')

        $workflow.ExitCode | Should -Be 0
        Test-Path -LiteralPath $dormantSentinel | Should -BeFalse
    }

    It 'uses capture and compare before applying and rechecks at the effect seam' {
        $log = Join-Path $TestDrive 'operations.txt'
        $providerSource = @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Content -LiteralPath $request.input.configuration.log -Value $request.operation
$status = switch ($request.operation) {
    'capture' { 'Succeeded' }
    'compare' { 'Different' }
    'apply' { 'Succeeded' }
}
$output = if ($request.operation -eq 'capture') {
    @{ value = 'actual' }
} else {
    @{ differences = @(@{ path = 'value'; kind = 'Changed' }) }
}
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = $status
    output = $output
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@
        Set-Content -LiteralPath (Join-Path $script:Package 'provider.ps1') `
            -Value $providerSource
        Set-Content -LiteralPath $script:Spec -Value (
            "@{ SchemaVersion=1; Acme=@{ value='desired'; log='$log' } }")

        $result = Invoke-WinSpecIntegration @(
            'apply', $script:Spec, '-ProviderPath', $script:ProviderRoot,
            '-Providers', 'Acme', '-Json')

        $result.ExitCode | Should -Be 0
        @(Get-Content -LiteralPath $log) |
            Should -Be @('capture', 'compare', 'capture', 'compare', 'apply')
    }
}
