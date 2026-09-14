BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:WinSpec = Join-Path (Join-Path $script:RepoRoot 'winspec') 'winspec.ps1'
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
}

Describe 'replacement command surface' {
    It 'shows top-level and per-command help without provider execution' {
        (Invoke-WinSpecProcess @('help')).Text | Should -Match 'winspec capture'
        foreach ($command in @('capture', 'status', 'validate', 'diff', 'apply', 'run', 'workflow', 'merge', 'providers', 'sandbox', 'rollback')) {
            $result = Invoke-WinSpecProcess @($command, '-Help')
            $result.ExitCode | Should -Be 0
            $result.Text | Should -Match "WinSpec $command"
        }
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
