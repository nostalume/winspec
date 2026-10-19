BeforeDiscovery {
    $humanCases = @(
        @{ Name = 'providers'; Tokens = @('providers'); Exit = 0; Context = @{} }
        @{ Name = 'actions'; Tokens = @('actions', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Spec = '<SPEC>'; NextAction = 'hello' } }
        @{ Name = 'actions-empty'; Tokens = @('actions', '<EMPTY>'); Exit = 0; Context = @{ Spec = '<EMPTY>' } }
        @{ Name = 'validate-empty'; Tokens = @('validate', '<EMPTY>'); Exit = 0; Context = @{ Spec = '<EMPTY>' } }
        @{ Name = 'validate-partial'; Tokens = @('validate', '<PARTIAL>'); Exit = 0; Context = @{ Spec = '<PARTIAL>' } }
        @{ Name = 'status'; Tokens = @('status', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Spec = '<SPEC>' } }
        @{ Name = 'diff'; Tokens = @('diff', '<SPEC>', '-Against', '<AGAINST>', '-ProviderPath', '<PROVIDERS>'); Exit = 1; Context = @{ Spec = '<SPEC>'; Against = '<AGAINST>' } }
        @{ Name = 'diff-empty'; Tokens = @('diff', '<EMPTY>', '-Against', '<EMPTY>'); Exit = 0; Context = @{ Spec = '<EMPTY>'; Against = '<EMPTY>' } }
        @{ Name = 'diff-skipped'; Tokens = @('diff', '<EMPTY>', '-Against', '<EMPTY>', '-Providers', 'Registry'); Exit = 0; Context = @{ Spec = '<EMPTY>'; Against = '<EMPTY>'; ExplicitProviders = $true } }
        @{ Name = 'apply-plan'; Tokens = @('apply', '<SPEC>', '-DryRun', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Spec = '<SPEC>' } }
        @{ Name = 'apply-empty'; Tokens = @('apply', '<EMPTY>'); Exit = 0; Context = @{ Spec = '<EMPTY>' } }
        @{ Name = 'apply'; Tokens = @('apply', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Spec = '<SPEC>' } }
        @{ Name = 'run-plan'; Tokens = @('run', 'hello', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>', '-DryRun'); Exit = 0; Context = @{ Spec = '<SPEC>'; ActionProvider = 'Script'; ActionName = 'hello' } }
        @{ Name = 'run'; Tokens = @('run', 'hello', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Spec = '<SPEC>'; ActionProvider = 'Script'; ActionName = 'hello' } }
        @{ Name = 'run-failed'; Tokens = @('run', 'broken', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 3; Context = @{ Spec = '<SPEC>'; ActionProvider = 'Script'; ActionName = 'broken' } }
        @{ Name = 'run-warning'; Tokens = @('run', '<ROOT>\warning.ps1'); Exit = 0; Context = @{ ActionProvider = 'Script' } }
        @{ Name = 'run-timeout'; Tokens = @('run', '<SLOW>', '-TimeoutSeconds', '1'); Exit = 4; Context = @{ ActionProvider = 'Script'; Source = '<SLOW>'; TimeoutSeconds = 1 } }
        @{ Name = 'provider-plan'; Tokens = @('run', '-Provider', 'HumanAction', '-ProviderPath', '<PROVIDERS>', '-DryRun'); Exit = 0; Context = @{ ActionProvider = 'HumanAction'; RunSelection = 'Provider' } }
        @{ Name = 'remote-plan'; Tokens = @('run', 'https://user:secret@example.invalid/test.ps1?token=private#fragment', '-DryRun'); Exit = 0; Context = @{ ActionProvider = 'Script' } }
        @{ Name = 'workflow-failed'; Tokens = @('workflow', 'setup', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 3; Context = @{ Spec = '<SPEC>'; Steps = @(@{ Identity = 'hello' }, @{ Identity = 'broken' }, @{ Identity = 'hello' }) } }
        @{ Name = 'workflow-plan'; Tokens = @('workflow', 'setup', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>', '-DryRun'); Exit = 0; Context = @{ Spec = '<SPEC>' } }
        @{ Name = 'capture'; Tokens = @('capture', '<OUTPUT>', '-Force', '-Providers', 'HumanState', '-ProviderPath', '<PROVIDERS>'); Exit = 0; Context = @{ Force = $true } }
        @{ Name = 'merge'; Tokens = @('merge', '<EMPTY>', '<INCOMING>'); Exit = 0; Context = @{ Base = '<EMPTY>'; Incoming = '<INCOMING>' } }
        @{ Name = 'merge-conflict'; Tokens = @('merge', '<MERGEBASE>', '<INCOMING>'); Exit = 2; Context = @{} }
        @{ Name = 'rollback'; Tokens = @('rollback', '-Last', '-DryRun'); Exit = 0; Context = @{} }
        @{ Name = 'unknown-action'; Tokens = @('run', 'helo', '-Spec', '<SPEC>', '-ProviderPath', '<PROVIDERS>'); Exit = 2; Context = @{ Target = 'helo'; Spec = '<SPEC>' } }
        @{ Name = 'retired'; Tokens = @('sandbox'); Exit = 2; Context = @{} }
        @{ Name = 'missing-value'; Tokens = @('run', 'hello', '-Spec'); Exit = 2; Context = @{} }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:Bindings = @{}
    function ConvertTo-GoldenText {
        param([string]$Text)
        foreach ($key in @($script:Bindings.Keys | Sort-Object { $script:Bindings[$_].Length } -Descending)) {
            $Text = $Text.Replace($script:Bindings[$key], "<$key>")
        }
        # Alignment is deliberately not a wire contract; line order and prose are.
        (($Text -replace "`r`n", "`n" -split "`n" | ForEach-Object {
                ($_ -replace '[\t ]+', ' ').Trim()
            }) -join "`n").Trim()
    }

    function ConvertTo-MachineGolden {
        param($Value, [string]$Key = '')
        if ($Key -eq 'DurationMilliseconds') { return 0 }
        if ($Key -eq 'requestId') { return '<REQUEST-ID>' }
        if ($Key -eq 'Interpreter') { return '<HOST>' }
        if ($null -eq $Value) { return $null }
        if ($Value -is [string]) {
            foreach ($binding in @($script:Bindings.Keys | Sort-Object { $script:Bindings[$_].Length } -Descending)) {
                $Value = $Value.Replace($script:Bindings[$binding], "<$binding>")
            }
            return $Value.Replace("`r`n", "`n")
        }
        if ($Value -is [Collections.IList]) {
            $items = @($Value | ForEach-Object { ConvertTo-MachineGolden $_ })
            return , $items
        }
        if ($Value -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object)) {
                $result[$property] = ConvertTo-MachineGolden $Value.$property $property
            }
            return $result
        }
        return $Value
    }
}

Describe 'human result rendering from approved receipts' -Tag 'Unit' {
    BeforeAll {
        Import-Module (Join-Path $script:Repo 'winspec/spec.psm1') -Force
        Import-Module (Join-Path $script:Repo 'winspec/console.psm1') -Force
    }
    It '<Name> renders the approved stdout and stderr without an operation' -ForEach $humanCases {
        # Reuse the unchanged JSON contract snapshot as input, not text as its
        # own oracle. Context is explicit fixture data, not a CLI implementation.
        $document = ConvertTo-WinSpecHashtable ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "golden/$Name.json.txt")) | ConvertFrom-Json)
        $stdout = New-Object IO.StringWriter
        $stderr = New-Object IO.StringWriter
        try {
            @(Write-WinSpecHumanResult $document $Context -ExitCode $Exit -OutputWriter $stdout -ErrorWriter $stderr).Count | Should -Be 0
            foreach ($stream in @(@{ Name = 'stdout'; Writer = $stdout }, @{ Name = 'stderr'; Writer = $stderr })) {
                $expected = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "golden/$Name.$($stream.Name).txt"))
                ConvertTo-GoldenText ($stream.Writer.ToString()) | Should -Be (ConvertTo-GoldenText $expected)
            }
            ($stdout.ToString() + $stderr.ToString()) | Should -Not -Match 'secret-argument|WAIT |\u001b'
        }
        finally { $stdout.Dispose(); $stderr.Dispose() }
    }
}
Describe 'real CLI receipts and representative human wiring' -Tag 'Boundary' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Import-Module (Join-Path $script:Repo 'winspec/provider-runtime.psm1') -Force
        $script:Executable = Get-CurrentPowerShellPath
        $script:Entry = Join-Path $script:Repo 'winspec/winspec.ps1'
        $script:Fixture = Join-Path $TestDrive 'human'
        $null = New-Item -ItemType Directory -Path $script:Fixture
        $script:Bindings = @{ ROOT = $script:Fixture; SPEC = (Join-Path $script:Fixture 'machine.json') }
        foreach ($name in 'empty', 'partial', 'against', 'incoming', 'mergebase') {
            $script:Bindings[$name.ToUpperInvariant()] = Join-Path $script:Fixture "$name.json"
        }
        $script:Bindings['OUTPUT'] = Join-Path $script:Fixture 'published.json'
        $script:Bindings['SCRIPT'] = Join-Path $script:Fixture 'hello.ps1'
        $script:Bindings['BROKEN'] = Join-Path $script:Fixture 'broken.ps1'
        $script:Bindings['SLOW'] = Join-Path $script:Fixture 'slow.ps1'
        $script:Bindings['PROVIDERS'] = Join-Path $script:Fixture 'providers'
        Set-Content $script:Bindings.SCRIPT "'Hello from controlled fixture'"
        Set-Content $script:Bindings.BROKEN "[Console]::Error.WriteLine('fixture failure: missing input'); exit 7"
        Set-Content (Join-Path $script:Fixture 'warning.ps1') "'payload'; [Console]::Error.WriteLine('notice only')"
        Set-Content (Join-Path $script:Fixture 'slow.ps1') 'Start-Sleep -Seconds 5'
        $spec = @{
            SchemaVersion = 1
            HumanState = @{ value = $true }
            Actions = @{
                hello = @{ Use = 'Script'; With = @{ File = 'hello.ps1'; Args = @('secret-argument') } }
                broken = @{ Use = 'Script'; With = @{ File = 'broken.ps1' } }
            }
            Workflows = @{
                setup = @{ Steps = @(@{ Run = 'hello' }, @{ Run = 'broken' }, @{ Run = 'hello' }) }
                happy = @{ Steps = @(@{ Run = 'hello' }) }
            }
        }
        $spec | ConvertTo-Json -Depth 12 | Set-Content $script:Bindings.SPEC
        '{"SchemaVersion":1}' | Set-Content $script:Bindings.EMPTY
        '{"SchemaVersion":1,"Actions":{"activate":{"Use":"MicrosoftActivation"}}}' | Set-Content $script:Bindings.PARTIAL
        '{"SchemaVersion":1,"HumanState":{"value":false}}' | Set-Content $script:Bindings.AGAINST
        '{"SchemaVersion":1,"Registry":{"Explorer":{"ShowHidden":false}}}' | Set-Content $script:Bindings.INCOMING
        '{"SchemaVersion":1,"Registry":{"Explorer":{"ShowHidden":true}}}' | Set-Content $script:Bindings.MERGEBASE
        $package = Join-Path $script:Bindings.PROVIDERS 'HumanState'
        $null = New-Item -ItemType Directory -Path $package -Force
        '{"schemaVersion":1,"name":"HumanState","kind":"State","protocolVersion":1,"script":"provider.ps1","operations":["capture","compare","apply"]}' |
            Set-Content (Join-Path $package 'provider.json')
        Set-Content (Join-Path $package 'provider.ps1') @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
$status = 'Succeeded'
$output = @{ value = $false }
if ($request.operation -eq 'compare') {
    $status = 'Different'
    $output = @{ differences = @(@{ Path = 'HumanState.value'; SystemValue = $false; ConfigValue = $true }) }
}
@{ protocolVersion = 1; requestId = $request.requestId; status = $status; output = $output; diagnostics = @() } |
    ConvertTo-Json -Depth 10 -Compress
'@
        $package = Join-Path $script:Bindings.PROVIDERS 'HumanAction'
        $null = New-Item -ItemType Directory -Path $package -Force
        '{"schemaVersion":1,"name":"HumanAction","kind":"Action","protocolVersion":1,"script":"provider.ps1","operations":["run","preview"]}' |
            Set-Content (Join-Path $package 'provider.json')
        Set-Content (Join-Path $package 'provider.ps1') @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
@{ protocolVersion = 1; requestId = $request.requestId; status = 'Planned'; output = @{ alpha = 'reported'; details = @{ enabled = $true }; arguments = @('secret-argument') }; diagnostics = @() } |
    ConvertTo-Json -Depth 10 -Compress
'@

        function Invoke-HumanCli {
            param([string[]]$Tokens, [switch]$Machine)
            $arguments = @($Tokens | ForEach-Object {
                    $token = $_
                    foreach ($key in $script:Bindings.Keys) { $token = $token.Replace("<$key>", $script:Bindings[$key]) }
                    $token
                })
            if ($Machine) { $arguments += '-Json' }
            Invoke-TestProcess -Executable $script:Executable -Path $script:Entry -Arguments $arguments -TimeoutSeconds 60
        }

    }
    # One sequential boundary check keeps the existing 28 JSON scenarios, not a
    # new cross-product of rendering and process cases. Failures name the receipt.
    It 'preserves every JSON receipt and representative human channels and exits' -ForEach @(@{ Cases = $humanCases }) {
        foreach ($case in $Cases) {
            $Name = $case.Name; $Tokens = $case.Tokens; $Exit = $case.Exit
            # Cover exits 0/1/2/3/4, success stderr and mixed/failure streams;
            # preserve CLI-only Next/Against/Force/selection/timeout context.
            if ($Name -in @('actions', 'diff', 'run-failed', 'run-warning', 'run-timeout', 'provider-plan', 'workflow-failed', 'capture', 'missing-value')) {
                $actual = Invoke-HumanCli $Tokens
                $actual.ExitCode | Should -Be $Exit -Because $Name
                foreach ($stream in 'Stdout', 'Stderr') {
                    $golden = Join-Path $PSScriptRoot "golden/$Name.$($stream.ToLowerInvariant()).txt"
                    $expected = [IO.File]::ReadAllText($golden)
                    ConvertTo-GoldenText $actual.$stream | Should -Be (ConvertTo-GoldenText $expected) -Because "$Name/$stream"
                }
                ($actual.Stdout + $actual.Stderr) | Should -Not -Match 'secret-argument|WAIT |\u001b'
                if ($Name -eq 'capture') {
                    Test-Path -LiteralPath $script:Bindings.OUTPUT | Should -BeTrue
                    # Reuse the existing JSON call to prove forced replacement.
                    [IO.File]::WriteAllText($script:Bindings.OUTPUT, '{"SchemaVersion":1,"BeforeOverwrite":true}')
                }
            }
            $machine = Invoke-HumanCli $Tokens -Machine
            $machine.ExitCode | Should -Be $Exit -Because $Name
            $machine.Stderr | Should -BeNullOrEmpty -Because $Name
            $document = $machine.Stdout | ConvertFrom-Json
            $document.schemaVersion | Should -Be 1 -Because $Name
            if ($Name -eq 'capture') {
                $published = Get-Content -Raw -LiteralPath $script:Bindings.OUTPUT | ConvertFrom-Json
                $published.SchemaVersion | Should -Be 1
                $published.HumanState.value | Should -BeFalse
                @($published.PSObject.Properties.Name) | Should -Not -Contain 'BeforeOverwrite'
            }
            $canonical = ConvertTo-MachineGolden $document | ConvertTo-Json -Depth 80 -Compress
            $expectedMachine = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "golden/$Name.json.txt")) |
                ConvertFrom-Json | ConvertTo-Json -Depth 80 -Compress
            $canonical | Should -Be $expectedMachine -Because $Name
        }
    }
}
