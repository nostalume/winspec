BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:WinSpec = Join-Path (Join-Path $script:RepoRoot 'winspec') 'winspec.ps1'

    function Invoke-WinSpecProcess {
        param([string[]]$Arguments)
        $text = & pwsh -NoProfile -File $script:WinSpec @Arguments 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.Trim() }
    }

    function Write-TestJson {
        param([string]$Path, [hashtable]$Value)
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

Describe 'bundled Action catalog' {
    It 'discovers all maintained Actions without a provider path' {
        $result = Invoke-WinSpecProcess @('providers', '-Json')

        $result.ExitCode | Should -Be 0
        $providers = @((ConvertFrom-Json $result.Text).results.providers)
        foreach ($name in @('MicrosoftActivation', 'WindowsDebloat', 'OfficeDeployment')) {
            $provider = @($providers | Where-Object name -EQ $name)
            $provider.Count | Should -Be 1
            $provider[0].origin | Should -Be 'Bundled'
        }
    }
}

Describe 'custom Script Actions' {
    It 'preserves empty, spaced, quoted, and trailing-backslash arguments' {
        $scriptPath = Join-Path $TestDrive 'arguments.ps1'
        $specPath = Join-Path $TestDrive 'arguments.winspec.json'
        Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value (
            'ConvertTo-Json -InputObject @($args) -Compress')
        $expected = @('two words', '', 'quote"inside', 'trailing\')
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{
                arguments = @{
                    Use = 'Script'
                    With = @{ File = './arguments.ps1'; Args = $expected }
                }
            }
        }

        $result = Invoke-WinSpecProcess @(
            'run', 'arguments', '-Spec', $specPath, '-Json')

        $result.ExitCode | Should -Be 0
        $stdout = (ConvertFrom-Json $result.Text).results.actions[0].result.stdout
        $actual = [object[]](ConvertFrom-Json -InputObject $stdout)
        $actual.Count | Should -Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $actual[$index] | Should -BeExactly $expected[$index]
        }
    }

    It 'rejects a digest on a local Script instead of silently ignoring it' {
        $scriptPath = Join-Path $TestDrive 'local.ps1'
        Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value 'exit 0'
        $specPath = Join-Path $TestDrive 'digest.winspec.json'
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{
                local = @{
                    Use = 'Script'
                    With = @{
                        File = './local.ps1'
                        Sha256 = ('0' * 64)
                    }
                }
            }
        }

        $result = Invoke-WinSpecProcess @('validate', $specPath, '-Json')

        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match 'InvalidSha256'
    }

    It 'runs a named local Script through the Use and With envelope' {
        $scriptPath = Join-Path $TestDrive 'hello.ps1'
        $specPath = Join-Path $TestDrive 'script.winspec.json'
        Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value (
            'param([string]$First,[string]$Second); "$First|$Second"')
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{
                hello = @{
                    Use = 'Script'
                    With = @{ File = './hello.ps1'; Args = @('configured') }
                }
            }
        }

        $result = Invoke-WinSpecProcess @(
            'run', 'hello', '-Spec', $specPath, '-Json', '--', 'forwarded')

        $result.ExitCode | Should -Be 0
        $document = ConvertFrom-Json $result.Text
        $document.results.actions[0].result.stdout.Trim() |
            Should -Be 'configured|forwarded'
    }

    It 'rejects obsolete flat Script fields' {
        $specPath = Join-Path $TestDrive 'flat.winspec.json'
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{ old = @{ Use = 'Script'; File = './old.ps1' } }
        }

        $result = Invoke-WinSpecProcess @('validate', $specPath, '-Json')

        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match 'UnknownActionField'
    }

    It 'rejects interactive machine output before starting the script' {
        $scriptPath = Join-Path $TestDrive 'sentinel.ps1'
        $sentinel = Join-Path $TestDrive 'started'
        Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value (
            "Set-Content -LiteralPath '$sentinel' -Value started")

        $result = Invoke-WinSpecProcess @(
            'run', $scriptPath, '-Interactive', '-Json')

        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'previews a named unpinned HTTPS Script through a Workflow' {
        $specPath = Join-Path $TestDrive 'remote-workflow.winspec.json'
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{
                remote = @{
                    Use = 'Script'
                    With = @{ Uri = 'https://example.test/current.ps1' }
                }
            }
            Workflows = @{
                setup = @{ Steps = @(@{ Run = 'remote' }) }
            }
        }

        $result = Invoke-WinSpecProcess @(
            'workflow', 'setup', '-Spec', $specPath, '-DryRun', '-Json')

        $result.ExitCode | Should -Be 0
        $step = ($result.Text | ConvertFrom-Json).results.steps[0]
        $step.status | Should -Be 'Planned'
        $step.result.integrity | Should -Be 'Unpinned'
        $step.result.requestedUri | Should -Be (
            'https://example.test/current.ps1')
    }

    It 'rejects a named unpinned HTTP Script during validation' {
        $specPath = Join-Path $TestDrive 'insecure-remote.winspec.json'
        Write-TestJson $specPath @{
            SchemaVersion = 1
            Actions = @{
                remote = @{
                    Use = 'Script'
                    With = @{ Uri = 'http://example.test/current.ps1' }
                }
            }
        }

        $result = Invoke-WinSpecProcess @('validate', $specPath, '-Json')

        $result.ExitCode | Should -Be 2
        ($result.Text | ConvertFrom-Json).diagnostics[0].code |
            Should -Be 'InsecureRemoteScript'
    }
}

Describe 'top-level Workflows' {
    BeforeEach {
        $scriptPath = Join-Path $TestDrive 'append.ps1'
        $script:orderPath = Join-Path $TestDrive 'order.txt'
        Remove-Item -LiteralPath $script:orderPath -Force -ErrorAction SilentlyContinue
        $script:specPath = Join-Path $TestDrive 'workflow.winspec.json'
        Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value (
            'param([string]$Path,[string]$Value); Add-Content -LiteralPath $Path -Value $Value')
        Write-TestJson $script:specPath @{
            SchemaVersion = 1
            Actions = @{
                first = @{
                    Use = 'Script'
                    With = @{ File = './append.ps1'; Args = @($script:orderPath, 'first') }
                }
                second = @{
                    Use = 'Script'
                    With = @{ File = './append.ps1'; Args = @($script:orderPath, 'second') }
                }
            }
            Workflows = @{
                ordered = @{
                    Steps = @(
                        @{ Run = 'first' }
                        @{ Run = 'second' }
                    )
                }
            }
        }
    }

    It 'runs named Actions sequentially' {
        $result = Invoke-WinSpecProcess @(
            'workflow', 'ordered', '-Spec', $script:specPath, '-Json')

        $result.ExitCode | Should -Be 0
        @(Get-Content -LiteralPath $script:orderPath) | Should -Be @('first', 'second')
        $document = ConvertFrom-Json $result.Text
        @($document.results.steps).Count | Should -Be 2
        @($document.results.steps.status) | Should -Be @('Succeeded', 'Succeeded')
    }

    It 'does not start Actions during dry-run' {
        $result = Invoke-WinSpecProcess @(
            'workflow', 'ordered', '-Spec', $script:specPath, '-DryRun', '-Json')

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:orderPath | Should -BeFalse
        @((ConvertFrom-Json $result.Text).results.steps.status) |
            Should -Be @('Planned', 'Planned')
    }

    It 'records the remaining steps as skipped after failure' {
        $failurePath = Join-Path $TestDrive 'fail.ps1'
        Set-Content -LiteralPath $failurePath -Encoding utf8 -Value 'exit 7'
        $value = Get-Content -Raw -LiteralPath $script:specPath | ConvertFrom-Json
        $value.Actions.first.With.File = './fail.ps1'
        $value | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:specPath -Encoding utf8

        $result = Invoke-WinSpecProcess @(
            'workflow', 'ordered', '-Spec', $script:specPath, '-Json')

        $result.ExitCode | Should -Be 3
        Test-Path -LiteralPath $script:orderPath | Should -BeFalse
        @((ConvertFrom-Json $result.Text).results.steps.status) |
            Should -Be @('Failed', 'Skipped')
    }

    It 'rejects a later capture conflict before starting an earlier Action' {
        $value = Get-Content -Raw -LiteralPath $script:specPath |
            ConvertFrom-Json
        $capture = [pscustomobject]@{
            Output = $script:specPath
            Force = $true
        }
        $value.Workflows.ordered.Steps = @(
            [pscustomobject]@{ Run = 'first' }
            [pscustomobject]@{ Capture = $capture }
        )
        $value | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:specPath -Encoding utf8

        $result = Invoke-WinSpecProcess @(
            'workflow', 'ordered', '-Spec', $script:specPath, '-Json')

        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $script:orderPath | Should -BeFalse
        $result.Text | Should -Match 'CaptureOverwritesInput'
    }
}
