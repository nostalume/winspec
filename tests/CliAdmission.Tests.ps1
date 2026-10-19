BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:Entry = Join-Path $script:Repo 'winspec/winspec.ps1'
    Import-Module (Join-Path $script:Repo 'winspec/provider-runtime.psm1') -Force
    $script:Executable = Get-CurrentPowerShellPath

    function Invoke-AdmissionCli {
        param([string[]]$Arguments)
        $r = Invoke-TestProcess -Executable $script:Executable -Path $script:Entry -Arguments $Arguments -Profile $script:Profile
        [pscustomobject]@{ ExitCode = $r.ExitCode; Stdout = $r.Stdout.Trim(); Stderr = $r.Stderr.Trim() }
    }

    function Expand-AdmissionArguments {
        param([string[]]$Tokens)
        foreach ($token in $Tokens) {
            $token.Replace('{spec}', $script:Spec).
            Replace('{script}', $script:ScriptPath).
            Replace('{root}', $script:ProviderRoot).
            Replace('{badroot}', $script:BadRoot)
        }
    }
}

Describe 'CLI admission before effects' -Tag 'Boundary' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Profile = Join-Path $TestDrive 'profile'
        $contextRoot = Join-Path $script:Profile '.config/winspec/sandbox'
        $null = New-Item -ItemType Directory -Path $contextRoot -Force
        $script:Context = Join-Path $contextRoot 'sandbox.json'
        $script:ContextText = '{"Mode":"Mock","Snapshot":"retained","Changes":[],"State":{}}'
        Set-Content -LiteralPath $script:Context -Value $script:ContextText
        $script:Sentinel = Join-Path $TestDrive 'ran.txt'
        $script:ScriptPath = Join-Path $TestDrive 'effect.ps1'
        Set-Content -LiteralPath $script:ScriptPath -Value (
            "Set-Content -LiteralPath '$script:Sentinel' -Value ran; 'controlled'")
        $script:Spec = Join-Path $TestDrive 'machine.json'
        @{
            SchemaVersion = 1
            Actions = @{
                effect = @{ Use = 'Script'; With = @{ File = $script:ScriptPath } }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Spec
        $script:BadRoot = Join-Path $TestDrive 'invalid-providers'
        $badPackage = Join-Path $script:BadRoot 'bad'
        $null = New-Item -ItemType Directory -Path $badPackage -Force
        Set-Content -LiteralPath (Join-Path $badPackage 'provider.json') -Value '{}'
        $script:ProviderRoot = Join-Path $TestDrive 'providers'
        $package = Join-Path $script:ProviderRoot 'echo'
        $null = New-Item -ItemType Directory -Path $package -Force
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Value @'
{"schemaVersion":1,"name":"AdmissionEcho","kind":"Action","protocolVersion":1,"script":"provider.ps1","operations":["run","preview"]}
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Value @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($request.input.configuration.sentinel) {
    Set-Content -LiteralPath $request.input.configuration.sentinel -Value started
}
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = if ($request.operation -eq 'preview') { 'Planned' } else { 'Succeeded' }
    output = @{ arguments = @($request.input.arguments) }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:Sentinel -ErrorAction SilentlyContinue
    }

    It 'rejects <Case> without executing a Script or reading a broken catalog' -ForEach @(
        @{ Case = 'extra run operand'; Tokens = @('run', '{script}', 'oops', '-Json'); Code = 'UnexpectedOperand' }
        @{ Case = 'extra validate operand'; Tokens = @('validate', '{spec}', 'oops', '-Json'); Code = 'UnexpectedOperand' }
        @{ Case = 'providers operand'; Tokens = @('providers', 'oops', '-Json'); Code = 'UnexpectedOperand' }
        @{ Case = 'missing Spec value'; Tokens = @('run', 'effect', '-Spec', '-Json'); Code = 'MissingOptionValue' }
        @{ Case = 'option as Spec value'; Tokens = @('run', 'effect', '-Spec', '-DryRun', '-Json'); Code = 'MissingOptionValue' }
        @{ Case = 'empty Spec'; Tokens = @('run', 'effect', '-Spec', '', '-ProviderPath', '{badroot}', '-Json'); Code = 'InvalidOptionValue' }
        @{ Case = 'whitespace Provider'; Tokens = @('run', '-Provider', ' ', '-Json'); Code = 'InvalidOptionValue' }
        @{ Case = 'duplicate Spec'; Tokens = @('run', 'effect', '-Spec', '{spec}', '-Spec', '{spec}', '-Json'); Code = 'DuplicateOption' }
        @{ Case = 'duplicate switch'; Tokens = @('run', '{script}', '-DryRun', '-DryRun', '-Json'); Code = 'DuplicateOption' }
        @{ Case = 'duplicate Json'; Tokens = @('providers', '-Json', '-jSoN'); Code = 'DuplicateOption' }
        @{ Case = 'default Strategy on wrong command'; Tokens = @('providers', '-Strategy', 'auto', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'zero SequenceNumber on wrong command'; Tokens = @('providers', '-SequenceNumber', '0', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'static command timeout'; Tokens = @('providers', '-TimeoutSeconds', '300', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'structural validation timeout'; Tokens = @('validate', '{spec}', '-TimeoutSeconds', '300', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'empty list item'; Tokens = @('status', '{spec}', '-Providers', 'Registry,,Service', '-Json'); Code = 'InvalidOptionValue' }
        @{ Case = 'timeout zero'; Tokens = @('run', '{script}', '-TimeoutSeconds', '0', '-Json'); Code = 'InvalidTimeout' }
        @{ Case = 'negative timeout'; Tokens = @('run', '{script}', '-TimeoutSeconds', '-1', '-Json'); Code = 'InvalidTimeout' }
        @{ Case = 'timeout 3601'; Tokens = @('run', '{script}', '-TimeoutSeconds', '3601', '-Json'); Code = 'InvalidTimeout' }
        @{ Case = 'fractional timeout'; Tokens = @('run', '{script}', '-TimeoutSeconds', '1.5', '-Json'); Code = 'InvalidOptionValue' }
        @{ Case = 'invalid SHA'; Tokens = @('run', 'https://example.test/inert.ps1', '-Sha256', 'bad', '-Json'); Code = 'InvalidSha256' }
        @{ Case = 'provider and target'; Tokens = @('run', '{script}', '-Provider', 'AdmissionEcho', '-Json'); Code = 'InvalidSelection' }
        @{ Case = 'direct Script and Spec'; Tokens = @('run', '{script}', '-Spec', '{spec}', '-Json'); Code = 'InvalidSelection' }
        @{ Case = 'named Interactive'; Tokens = @('run', 'effect', '-Spec', '{spec}', '-Interactive', '-Json'); Code = 'InvalidSelection' }
        @{ Case = 'local SHA'; Tokens = @('run', '{script}', '-Sha256', 'abc', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'both rollback selectors'; Tokens = @('rollback', '-Last', '-SequenceNumber', '1', '-DryRun', '-Json'); Code = 'InvalidRollbackTarget' }
        @{ Case = 'zero rollback sequence'; Tokens = @('rollback', '-SequenceNumber', '0', '-DryRun', '-Json'); Code = 'InvalidSequenceNumber' }
        @{ Case = 'empty separator on wrong command'; Tokens = @('providers', '-Json', '--'); Code = 'UnexpectedArguments' }
        @{ Case = 'failure before catalog'; Tokens = @('run', '{script}', 'oops', '-ProviderPath', '{badroot}', '-Json'); Code = 'UnexpectedOperand' }
        @{ Case = 'Force does not admit invalid selection'; Tokens = @('run', '{script}', '-Force', '-Json'); Code = 'InvalidOption' }
        @{ Case = 'Help extra operand'; Tokens = @('run', 'effect', '-Help', '-Json'); Code = 'UnexpectedOperand' }
        @{ Case = 'unknown Help topic JSON'; Tokens = @('help', 'not-a-command', '-Json'); Code = 'UnknownCommand' }
        @{ Case = 'retired Help topic JSON'; Tokens = @('help', 'sandbox', '-Json'); Code = 'RetiredCommand' }
    ) {
        $result = Invoke-AdmissionCli (Expand-AdmissionArguments $Tokens)
        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -BeNullOrEmpty
        $document = $result.Stdout | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.status | Should -Be 'Failed'
        $document.diagnostics[0].code | Should -Be $Code
        Test-Path -LiteralPath $script:Sentinel | Should -BeFalse
    }

    It 'retires <Flag> without an alias' -ForEach @(
        @{ Flag = '-Verbose' }, @{ Flag = '-Debug' }, @{ Flag = '-Enter' },
        @{ Flag = '-Exit' }, @{ Flag = '-List' }, @{ Flag = '-Mode' },
        @{ Flag = '-Snapshot' }
    ) {
        $result = Invoke-AdmissionCli @('providers', $Flag, '-Json')
        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -BeNullOrEmpty
        ($result.Stdout | ConvertFrom-Json).diagnostics[0].code | Should -Be 'RetiredOption'
    }

    It 'retires sandbox while retaining old context bytes' -Tag 'Quick' {
        $before = [IO.File]::ReadAllBytes($script:Context)
        $result = Invoke-AdmissionCli @('sandbox', '-Json')
        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -BeNullOrEmpty
        ($result.Stdout | ConvertFrom-Json).diagnostics[0].code | Should -Be 'RetiredCommand'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Context)) |
            Should -Be ([Convert]::ToBase64String($before))
        (Invoke-AdmissionCli @('help')).Stdout | Should -Not -Match '(?m)^  sandbox\s+-'
    }

    It 'forwards special tokens literally without changing WinSpec output mode' {
        $forwarded = @('-Json', '-Help', '-TimeoutSeconds', '', 'two words', 'a"b', 'tail\')
        $result = Invoke-AdmissionCli (@('run', '-Provider', 'AdmissionEcho',
                '-ProviderPath', $script:ProviderRoot, '--') + $forwarded)
        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        $result.Stdout | Should -Match '^OK run \[AdmissionEcho\] -- provider reported Succeeded'
        $result.Stdout | Should -Not -Match 'schemaVersion|two words|tail\\'
        # Human metadata deliberately suppresses argument vectors; the literal
        # forwarding contract is observable in the unchanged machine receipt.
        $machine = Invoke-AdmissionCli (@('run', '-Provider', 'AdmissionEcho',
                '-ProviderPath', $script:ProviderRoot, '-Json', '--') + $forwarded)
        $machine.ExitCode | Should -Be 0
        $machine.Stderr | Should -BeNullOrEmpty
        $payload = $machine.Stdout | ConvertFrom-Json
        @($payload.results.actions[0].result.output.arguments) | Should -Be $forwarded
    }

    It 'accepts repeated list options and scans each canonical root once' {
        $result = Invoke-AdmissionCli @('providers', '-ProviderPath', $script:ProviderRoot,
            '-ProviderPath', ($script:ProviderRoot + '\.'), '-Json')
        $result.ExitCode | Should -Be 0
        $providers = @((($result.Stdout | ConvertFrom-Json).results.providers) |
                Where-Object Name -EQ 'AdmissionEcho')
        $providers.Count | Should -Be 1
    }

    It 'accepts case-insensitive commands, valid preview timeout and an empty run separator' {
        $result = Invoke-AdmissionCli @('rUn', '-pRoViDeR', 'AdmissionEcho',
            '-ProviderPath', $script:ProviderRoot, '-DryRun', '-TimeoutSeconds', '3600', '-Json', '--')
        $result.ExitCode | Should -Be 0
        ($result.Stdout | ConvertFrom-Json).status | Should -Be 'Planned'
        $validation = Invoke-AdmissionCli @('validate', $script:Spec,
            '-PreviewActions', '-TimeoutSeconds', '1', '-Json')
        $validation.ExitCode | Should -Be 0
    }

    It 'deduplicates State provider selection before invocation' {
        $package = Join-Path $script:ProviderRoot 'state'
        $null = New-Item -ItemType Directory -Path $package -Force
        $calls = Join-Path $TestDrive 'state-calls.txt'
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Value @'
{"schemaVersion":1,"name":"AdmissionState","kind":"State","protocolVersion":1,"script":"provider.ps1","operations":["capture","compare","apply"]}
'@
        $source = @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Content -LiteralPath '__CALLS__' -Value $request.operation
@{
    protocolVersion=1
    requestId=$request.requestId
    status='Succeeded'
    output=@{value=1}
    diagnostics=@()
} | ConvertTo-Json -Compress
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Value (
            $source.Replace('__CALLS__', $calls.Replace("'", "''")))
        $result = Invoke-AdmissionCli @('status', '-Providers', ' AdmissionState,admissionstate ',
            '-Providers', 'AdmissionState', '-ProviderPath', $script:ProviderRoot, '-Json')
        $result.ExitCode | Should -Be 0
        @(Get-Content -LiteralPath $calls).Count | Should -Be 1
    }

    It 'rejects a later interactive Workflow step before any earlier provider preview' {
        $path = Join-Path $TestDrive 'interactive-workflow.json'
        @{
            SchemaVersion = 1
            Actions = @{
                first = @{ Use = 'AdmissionEcho'; With = @{ sentinel = $script:Sentinel } }
                later = @{ Use = 'Script'; With = @{ File = $script:ScriptPath; Interactive = $true } }
            }
            Workflows = @{
                setup = @{ Steps = @(@{Run = 'first' }, @{Run = 'later' }) }
            }
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
        $result = Invoke-AdmissionCli @('workflow', 'setup', '-Spec', $path,
            '-ProviderPath', $script:ProviderRoot, '-DryRun', '-Json')
        $result.ExitCode | Should -Be 2
        ($result.Stdout | ConvertFrom-Json).diagnostics[0].code | Should -Be 'InteractiveWorkflowOutput'
        Test-Path -LiteralPath $script:Sentinel | Should -BeFalse
    }

}
