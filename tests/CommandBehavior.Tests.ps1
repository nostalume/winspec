BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:WinSpec = Join-Path (Join-Path $script:RepoRoot 'winspec') 'winspec.ps1'
    Import-Module (Join-Path (Join-Path $script:RepoRoot 'winspec') `
            'provider-runtime.psm1') -Force
    function Invoke-WinSpecProcess {
        param([string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $text = & pwsh -NoProfile -File $script:WinSpec @Arguments 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.Trim() }
    }
    function Invoke-WinSpecHostProcess {
        param([string]$Executable, [string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $text = & $Executable -NoProfile -File $script:WinSpec @Arguments 2>&1 |
            Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.Trim() }
    }

    function Invoke-WinSpecSeparatedProcess {
        param(
            [string]$Executable = 'pwsh.exe',
            [string[]]$Arguments
        )

        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $Executable
        $start.Arguments = ((@('-NoProfile', '-File', $script:WinSpec) +
                @($Arguments) | ForEach-Object {
                    ConvertTo-ProcessArgument ([string]$_)
                }) -join ' ')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        if ([IO.Path]::GetFileName($Executable) -ieq 'powershell.exe') {
            $windowsModules = Join-Path $env:SystemRoot `
                'System32\WindowsPowerShell\v1.0\Modules'
            $modulePath = [string]$start.EnvironmentVariables['PSModulePath']
            $otherModules = @($modulePath -split ';' | Where-Object {
                    $_ -and $_ -ine $windowsModules
                })
            $start.EnvironmentVariables['PSModulePath'] =
            @($windowsModules) + $otherModules -join ';'
        }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            [pscustomobject]@{
                ExitCode = $process.ExitCode
                Stdout = $stdout.Trim()
                Stderr = $stderr.Trim()
            }
        }
        finally {
            $process.Dispose()
        }
    }

    function New-TestActionProvider {
        param(
            [string]$Root,
            [string]$Name,
            [string[]]$Operations,
            [string]$Source
        )

        $package = Join-Path $Root $Name
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        @{
            schemaVersion = 1
            name = $Name
            kind = 'Action'
            protocolVersion = 1
            script = 'provider.ps1'
            operations = @($Operations)
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $package 'provider.json')
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Value $Source
    }
}

Describe 'replacement command surface' {
    It 'describes every command in top-level and per-command help' {
        $commands = @(
            'capture', 'status', 'validate', 'diff', 'apply', 'run',
            'workflow', 'merge', 'providers', 'actions', 'sandbox',
            'rollback', 'help')
        $top = Invoke-WinSpecSeparatedProcess -Arguments @('help')

        $top.ExitCode | Should -Be 0
        $top.Stderr | Should -BeNullOrEmpty
        foreach ($command in $commands) {
            $top.Stdout | Should -Match "(?m)^  $command\s+-\s+"
            $result = Invoke-WinSpecSeparatedProcess `
                -Arguments @($command, '-Help')
            $result.ExitCode | Should -Be 0
            $result.Stderr | Should -BeNullOrEmpty
            $result.Stdout | Should -Match "WinSpec $command"
            $result.Stdout | Should -Match '(?m)^Purpose:'
            $result.Stdout | Should -Match '(?m)^Usage:'
            $result.Stdout | Should -Match '(?m)^Effects:'
            $result.Stdout | Should -Match '(?m)^Default:'
            $result.Stdout | Should -Match '(?m)^Example:'
        }
    }

    It 'renders a human diagnostic code exactly once' -ForEach @(
        @{ Executable = 'powershell.exe' }
        @{ Executable = 'pwsh.exe' }
    ) {
        $path = Join-Path $TestDrive 'invalid-human.winspec.psd1'
        Set-Content -LiteralPath $path -Value @'
@{
    SchemaVersion = 1
    Registry = @{ Taskbar = @{ Alignment = 'diagonal' } }
}
'@

        $result = Invoke-WinSpecSeparatedProcess -Executable $Executable `
            -Arguments @('validate', $path)

        $result.ExitCode | Should -Be 2
        $result.Stdout | Should -Match '^validate: Failed'
        $result.Stderr | Should -BeExactly `
            "InvalidRegistryValue: 'Taskbar.Alignment'"
    }

    It 'keeps JSON diagnostics in stdout and stderr empty' -ForEach @(
        @{ Executable = 'powershell.exe' }
        @{ Executable = 'pwsh.exe' }
    ) {
        $path = Join-Path $TestDrive 'invalid-json.winspec.psd1'
        Set-Content -LiteralPath $path -Value @'
@{
    SchemaVersion = 1
    Registry = @{ Taskbar = @{ Alignment = 'diagonal' } }
}
'@

        $result = Invoke-WinSpecSeparatedProcess -Executable $Executable `
            -Arguments @('validate', $path, '-Json')

        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -BeNullOrEmpty
        $document = $result.Stdout | ConvertFrom-Json
        $document.diagnostics[0].code | Should -Be 'InvalidRegistryValue'
        $result.Stdout.TrimStart()[0] | Should -Be '{'
        $result.Stdout.TrimEnd()[-1] | Should -Be '}'
    }

    It 'rejects removed commands without aliases' {
        foreach ($command in @('pull', 'push', 'trigger')) {
            $result = Invoke-WinSpecProcess @($command)
            $result.ExitCode | Should -Be 2
            $result.Text | Should -Match 'UnknownCommand'
        }
    }

    It 'rejects run -All and emits parser failures as one JSON document' {
        $result = Invoke-WinSpecProcess @('run', '-All', '-Json')

        $result.ExitCode | Should -Be 2
        $document = $result.Text | ConvertFrom-Json
        $document.status | Should -Be 'Failed'
        $document.diagnostics[0].code | Should -Be 'UnknownOption'
    }

    It 'emits one parseable JSON provider result' {
        $result = Invoke-WinSpecProcess @('providers', '-Json')
        $result.ExitCode | Should -Be 0
        $document = $result.Text | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.status | Should -Be 'Succeeded'
        @($document.results.providers.Name) | Should -Contain 'Script'
    }

    It 'separates discovered providers from configured Actions without execution' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $sentinel = Join-Path $TestDrive 'provider-ran'
        New-TestActionProvider -Root $providerRoot -Name 'Acme' `
            -Operations @('run', 'preview') -Source @"
Set-Content -LiteralPath '$sentinel' -Value started
throw 'provider must remain inert'
"@
        $spec = Join-Path $TestDrive 'actions.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{
    SchemaVersion = 1
    Actions = @{
        zebra = @{ Use = 'Acme'; With = @{ Message = 'last' } }
        alpha = @{ Use = 'Acme' }
    }
}
'@

        $providers = Invoke-WinSpecProcess @(
            'providers', '-ProviderPath', $providerRoot, '-Json')
        $providers.ExitCode | Should -Be 0
        @((ConvertFrom-Json $providers.Text).results.providers.name) |
            Should -Contain 'Acme'
        Test-Path -LiteralPath $sentinel | Should -BeFalse

        $actions = Invoke-WinSpecProcess @(
            'actions', $spec, '-ProviderPath', $providerRoot, '-Json')
        $actions.ExitCode | Should -Be 0
        $items = @((ConvertFrom-Json $actions.Text).results.actions)
        @($items.name) | Should -Be @('alpha', 'zebra')
        @($items.provider) | Should -Be @('Acme', 'Acme')
        @($items.origin) | Should -Be @('Explicit', 'Explicit')
        @($items[0].operations) | Should -Be @('run', 'preview')
        $items[0].PSObject.Properties.Name | Should -Not -Contain 'with'
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'runs a direct provider through the Action preview path' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $sentinel = Join-Path $TestDrive 'provider-operations.txt'
        New-TestActionProvider -Root $providerRoot -Name 'Acme' `
            -Operations @('run', 'preview') -Source @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Content -LiteralPath '$sentinel' -Value `$request.operation
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = if (`$request.operation -eq 'preview') { 'Planned' } else { 'Succeeded' }
    output = @{
        arguments = @(`$request.input.arguments)
        configurationCount = @(`$request.input.configuration.PSObject.Properties).Count
        workingDirectory = `$request.input.executionPolicy.workingDirectory
    }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@

        $result = Invoke-WinSpecProcess @(
            'run', '-Provider', 'Acme', '-ProviderPath', $providerRoot,
            '-DryRun', '-Json', '--', 'first', 'two words')

        $result.ExitCode | Should -Be 0
        $action = (ConvertFrom-Json $result.Text).results.actions[0]
        $action.provider | Should -Be 'Acme'
        $action.result.status | Should -Be 'Planned'
        @($action.result.output.arguments) | Should -Be @('first', 'two words')
        $action.result.output.configurationCount | Should -Be 0
        $action.result.output.workingDirectory | Should -Be `
        ([IO.Path]::GetFullPath($PWD))

        $executed = Invoke-WinSpecProcess @(
            'run', '-Provider', 'Acme', '-ProviderPath', $providerRoot,
            '-Json', '--', 'execute')
        $executed.ExitCode | Should -Be 0
        $executedAction =
        (ConvertFrom-Json $executed.Text).results.actions[0]
        $executedAction.provider | Should -Be 'Acme'
        $executedAction.result.status | Should -Be 'Succeeded'
        @($executedAction.result.output.arguments) | Should -Be @('execute')
        @(Get-Content -LiteralPath $sentinel) |
            Should -Be @('preview', 'run')
    }

    It 'keeps an opaque direct provider inert during dry-run' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $sentinel = Join-Path $TestDrive 'opaque-ran'
        New-TestActionProvider -Root $providerRoot -Name 'Opaque' `
            -Operations @('run') -Source @"
Set-Content -LiteralPath '$sentinel' -Value started
throw 'dry-run must not start this provider'
"@

        $result = Invoke-WinSpecProcess @(
            'run', '-Provider', 'Opaque', '-ProviderPath', $providerRoot,
            '-DryRun', '-Json')

        $result.ExitCode | Should -Be 0
        $action = (ConvertFrom-Json $result.Text).results.actions[0]
        $action.provider | Should -Be 'Opaque'
        $action.result.status | Should -Be 'Planned'
        $action.result.opaque | Should -BeTrue
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'rejects ambiguous or invalid direct provider selections' -ForEach @(
        @{ Arguments = @('run', '-Provider', 'Missing', '-Json'); Code = 'UnknownProvider' }
        @{ Arguments = @('run', '-Provider', 'Registry', '-Json'); Code = 'WrongProviderKind' }
        @{ Arguments = @('run', 'named', '-Provider', 'Script', '-Json'); Code = 'InvalidSelection' }
        @{ Arguments = @('run', '-Provider', 'Script', '-Spec', 'x', '-Json'); Code = 'InvalidSelection' }
        @{ Arguments = @('run', '-Provider', 'Script', '-Interactive', '-Json'); Code = 'InvalidSelection' }
        @{ Arguments = @('run', '-Provider', 'Script', '-Sha256', ('0' * 64), '-Json'); Code = 'InvalidSelection' }
    ) {
        $result = Invoke-WinSpecProcess $Arguments

        $result.ExitCode | Should -Be 2
        (ConvertFrom-Json $result.Text).diagnostics[0].code | Should -Be $Code
    }

    It 'keeps named Action and direct provider namespaces unambiguous' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $sentinel = Join-Path $TestDrive 'same-provider-ran'
        New-TestActionProvider -Root $providerRoot -Name 'Same' `
            -Operations @('run', 'preview') -Source @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Set-Content -LiteralPath '$sentinel' -Value `$request.operation
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Planned'
    output = @{ selected = 'provider' }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@
        Set-Content -LiteralPath (Join-Path $TestDrive 'named.ps1') `
            -Value "'named-action'"
        $spec = Join-Path $TestDrive 'same.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{
    SchemaVersion = 1
    Actions = @{ Same = @{ Use = 'Script'; With = @{ File = './named.ps1' } } }
}
'@

        $named = Invoke-WinSpecProcess @(
            'run', 'Same', '-Spec', $spec, '-ProviderPath', $providerRoot,
            '-DryRun', '-Json')
        $direct = Invoke-WinSpecProcess @(
            'run', '-Provider', 'Same', '-ProviderPath', $providerRoot,
            '-DryRun', '-Json')

        $named.ExitCode | Should -Be 0
        $direct.ExitCode | Should -Be 0
        (ConvertFrom-Json $named.Text).results.actions[0].name |
            Should -Be 'Same'
        (ConvertFrom-Json $direct.Text).results.actions[0].provider |
            Should -Be 'Same'
        (Get-Content -Raw -LiteralPath $sentinel).Trim() | Should -Be 'preview'
    }

    It 'emits exactly one JSON document from <Executable>' -ForEach @(
        @{ Executable = 'powershell.exe' }
        @{ Executable = 'pwsh.exe' }
    ) {
        $result = Invoke-WinSpecHostProcess $Executable @('providers', '-Json')

        $result.ExitCode | Should -Be 0
        $document = $result.Text | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $result.Text.TrimStart()[0] | Should -Be '{'
        $result.Text.TrimEnd()[-1] | Should -Be '}'
    }

    It 'rejects invalid built-in State through one JSON admission result' {
        $path = Join-Path $TestDrive 'invalid-state.winspec.psd1'
        Set-Content -LiteralPath $path -Value @'
@{
    SchemaVersion = 1
    Registry = @{ Taskbar = @{ Alignment = 'diagonal' } }
    Service = @{ EventLog = @{ State = 'running' } }
}
'@

        $result = Invoke-WinSpecProcess @('validate', $path, '-Json')

        $result.ExitCode | Should -Be 2
        $document = $result.Text | ConvertFrom-Json
        $document.status | Should -Be 'Failed'
        @($document.diagnostics.code) | Should -Contain 'InvalidRegistryValue'
        @($document.diagnostics.code) | Should -Contain 'ServiceNotManaged'
    }

    It 'reports static provider-validation coverage without execution' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $sentinel = Join-Path $TestDrive 'static-validation-ran'
        New-TestActionProvider -Root $providerRoot -Name 'Acme' `
            -Operations @('run', 'preview') -Source @"
Set-Content -LiteralPath '$sentinel' -Value started
throw 'static validation must remain inert'
"@
        $spec = Join-Path $TestDrive 'coverage.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{
    SchemaVersion = 1
    Actions = @{
        zebra = @{ Use = 'Acme'; With = @{ Value = 2 } }
        alpha = @{ Use = 'Acme'; With = @{ Value = 1 } }
    }
}
'@

        $result = Invoke-WinSpecProcess @(
            'validate', $spec, '-ProviderPath', $providerRoot, '-Json')

        $result.ExitCode | Should -Be 0
        $document = ConvertFrom-Json $result.Text
        $document.results.valid | Should -BeTrue
        $document.results.validation.mode | Should -Be 'Structural'
        @($document.results.validation.subjects.path) |
            Should -Be @('Actions.alpha', 'Actions.zebra')
        @($document.results.validation.subjects.status) |
            Should -Be @('NotRun', 'NotRun')
        @($document.diagnostics).Count | Should -Be 0
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'previews configured Actions in stable order and reports validation' {
        $providerRoot = Join-Path $TestDrive 'providers'
        $log = Join-Path $TestDrive 'preview-order.txt'
        $validSource = @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Content -LiteralPath '$log' -Value `$request.input.configuration.name
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Planned'
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@
        $invalidSource = @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Content -LiteralPath '$log' -Value `$request.input.configuration.name
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Failed'
    output = @{}
    diagnostics = @(@{ code = 'InvalidValue'; message = 'value is invalid' })
} | ConvertTo-Json -Depth 10 -Compress
"@
        $opaqueSentinel = Join-Path $TestDrive 'opaque-preview-ran'
        New-TestActionProvider -Root $providerRoot -Name 'Good' `
            -Operations @('run', 'preview') -Source $validSource
        New-TestActionProvider -Root $providerRoot -Name 'Bad' `
            -Operations @('run', 'preview') -Source $invalidSource
        New-TestActionProvider -Root $providerRoot -Name 'Opaque' `
            -Operations @('run') -Source @"
Set-Content -LiteralPath '$opaqueSentinel' -Value started
throw 'preview is unavailable'
"@
        $spec = Join-Path $TestDrive 'preview-actions.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{
    SchemaVersion = 1
    Actions = @{
        zebra = @{ Use = 'Good'; With = @{ name = 'zebra' } }
        middle = @{ Use = 'Opaque' }
        alpha = @{ Use = 'Bad'; With = @{ name = 'alpha' } }
    }
}
'@

        $result = Invoke-WinSpecProcess @(
            'validate', $spec, '-ProviderPath', $providerRoot,
            '-PreviewActions', '-Json')

        $result.ExitCode | Should -Be 2
        $document = ConvertFrom-Json $result.Text
        $document.status | Should -Be 'Failed'
        $document.results.valid | Should -BeFalse
        $document.results.validation.mode | Should -Be 'ActionPreview'
        @($document.results.validation.subjects.path) |
            Should -Be @('Actions.alpha', 'Actions.middle', 'Actions.zebra')
        @($document.results.validation.subjects.status) |
            Should -Be @('Invalid', 'Unavailable', 'Valid')
        @(Get-Content -LiteralPath $log) | Should -Be @('alpha', 'zebra')
        Test-Path -LiteralPath $opaqueSentinel | Should -BeFalse
        @($document.diagnostics.code) | Should -Contain 'InvalidValue'
    }

    It 'fails Action preview validation when a provider process fails' {
        $providerRoot = Join-Path $TestDrive 'providers'
        New-TestActionProvider -Root $providerRoot -Name 'Broken' `
            -Operations @('run', 'preview') -Source 'exit 17'
        $spec = Join-Path $TestDrive 'broken-preview.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{ SchemaVersion = 1; Actions = @{ broken = @{ Use = 'Broken' } } }
'@

        $result = Invoke-WinSpecProcess @(
            'validate', $spec, '-ProviderPath', $providerRoot,
            '-PreviewActions', '-Json')

        $result.ExitCode | Should -Be 3
        $document = ConvertFrom-Json $result.Text
        $document.status | Should -Be 'Failed'
        $document.results.validation.subjects[0].path |
            Should -Be 'Actions.broken'
        @($document.diagnostics.code) | Should -Contain 'ProviderProcessFailed'
    }

    It 'times out Action preview validation and preserves its subject' {
        $providerRoot = Join-Path $TestDrive 'providers'
        New-TestActionProvider -Root $providerRoot -Name 'Slow' `
            -Operations @('run', 'preview') -Source @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Start-Sleep -Seconds 10
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = 'Planned'
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@
        $spec = Join-Path $TestDrive 'slow-preview.winspec.psd1'
        Set-Content -LiteralPath $spec -Value @'
@{ SchemaVersion = 1; Actions = @{ slow = @{ Use = 'Slow' } } }
'@

        $result = Invoke-WinSpecProcess @(
            'validate', $spec, '-ProviderPath', $providerRoot,
            '-PreviewActions', '-TimeoutSeconds', '1', '-Json')

        $result.ExitCode | Should -Be 4
        $document = ConvertFrom-Json $result.Text
        $document.status | Should -Be 'Failed'
        $document.results.validation.subjects[0].path |
            Should -Be 'Actions.slow'
        $document.results.validation.subjects[0].status |
            Should -Be 'Unavailable'
        @($document.diagnostics.code) | Should -Contain 'ProviderTimeout'
    }

    It 'reports a failed Script Action as one failed JSON document' {
        $path = Join-Path $TestDrive 'fail.ps1'
        Set-Content -LiteralPath $path -Value 'exit 17'

        $result = Invoke-WinSpecProcess @('run', $path, '-Json')

        $result.ExitCode | Should -Be 3
        $document = $result.Text | ConvertFrom-Json
        $document.status | Should -Be 'Failed'
        $document.results.actions[0].Status | Should -Be 'Failed'
        $document.results.actions[0].ExitCode | Should -Be 17
    }

    It 'validates a data-only spec and rejects a ps1 spec' {
        $valid = Join-Path $TestDrive 'valid.winspec.psd1'
        $legacy = Join-Path $TestDrive 'legacy.ps1'
        Set-Content -LiteralPath $valid -Value '@{ SchemaVersion = 1 }'
        Set-Content -LiteralPath $legacy -Value '@{ SchemaVersion = 1 }'
        (Invoke-WinSpecProcess @('validate', $valid, '-Json')).ExitCode | Should -Be 0
        $failed = Invoke-WinSpecProcess @('validate', $legacy, '-Json')
        $failed.ExitCode | Should -Be 2
        $failed.Text | Should -Match 'UnsupportedSpecFormat'
    }

    It 'runs a direct script with discrete arguments' {
        $scriptPath = Join-Path $TestDrive 'echo args.ps1'
        Set-Content -LiteralPath $scriptPath -Value 'param([string]$One,[string]$Two); "$One|$Two"'
        $result = Invoke-WinSpecProcess @('run', $scriptPath, '-Json', '--', 'hello world', 'second')
        $result.ExitCode | Should -Be 0
        $document = $result.Text | ConvertFrom-Json
        $document.results.actions[0].Stdout.Trim() | Should -Be 'hello world|second'
    }

    It 'admits an explicitly selected unpinned HTTPS Script without network during dry-run' {
        $result = Invoke-WinSpecProcess @(
            'run', 'https://example.test/setup.ps1', '-DryRun', '-Json')

        $result.ExitCode | Should -Be 0
        $action = ($result.Text | ConvertFrom-Json).results.actions[0]
        $action.status | Should -Be 'Planned'
        $action.requestedUri | Should -Be 'https://example.test/setup.ps1'
        $action.integrity | Should -Be 'Unpinned'
        $action.opaque | Should -BeTrue
    }

    It 'requires a digest for an HTTP Script' {
        $result = Invoke-WinSpecProcess @(
            'run', 'http://example.test/setup.ps1', '-DryRun', '-Json')

        $result.ExitCode | Should -Be 2
        $document = $result.Text | ConvertFrom-Json
        $document.diagnostics[0].code | Should -Be 'InsecureRemoteScript'
    }

    It 'rejects the retired unverified-code escape flag' {
        $result = Invoke-WinSpecProcess @(
            'run', 'https://example.test/setup.ps1',
            '-AllowUnverifiedCode', '-DryRun', '-Json')

        $result.ExitCode | Should -Be 2
        ($result.Text | ConvertFrom-Json).diagnostics[0].code |
            Should -Be 'UnknownOption'
    }

    It 'does not publish a conflicted merge' {
        $base = Join-Path $TestDrive 'base.winspec.psd1'
        $incoming = Join-Path $TestDrive 'incoming.winspec.psd1'
        $output = Join-Path $TestDrive 'merged.winspec.psd1'
        Set-Content -LiteralPath $base -Value '@{ SchemaVersion = 1; Name = ''base'' }'
        Set-Content -LiteralPath $incoming -Value '@{ SchemaVersion = 1; Name = ''incoming'' }'
        $result = Invoke-WinSpecProcess @('merge', $base, $incoming, '-Output', $output, '-Json')
        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'fails capture output conflict before observation' {
        $output = Join-Path $TestDrive 'existing.winspec.json'
        Set-Content -LiteralPath $output -Value '{"SchemaVersion":1}'
        $result = Invoke-WinSpecProcess @('capture', $output, '-Providers', 'DefinitelyMissing', '-Json')
        $result.ExitCode | Should -Be 3
        $result.Text | Should -Match 'OutputExists'
        $result.Text | Should -Not -Match 'UnknownProvider'
    }
}
