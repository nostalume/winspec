BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:Entry = Join-Path $script:Repo 'winspec/winspec.ps1'
    Import-Module (Join-Path $script:Repo 'winspec/provider-runtime.psm1') -Force
    $script:Executable = Get-CurrentPowerShellPath
    function Invoke-HelpCli {
        param([string[]]$Tokens, [string]$Entry = $script:Entry)
        Invoke-TestProcess -Executable $script:Executable -Path $Entry -Arguments $Tokens -WorkingDirectory $script:Repo
    }
    function ConvertTo-HelpCanonical {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [Collections.IList]) {
            return , @($Value | ForEach-Object { ConvertTo-HelpCanonical $_ })
        }
        if ($Value -is [pscustomobject]) {
            $map = [ordered]@{}
            foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object)) {
                $map[$name] = ConvertTo-HelpCanonical $Value.$name
            }
            return $map
        }
        return $Value
    }
}

Describe 'Human command help and unchanged machine contract' -Tag 'Boundary' {
    It 'explains <Topic> selection, effects, accepted options and exits' -Tag 'Quick' -ForEach @(
        @{ Topic = 'capture'; Meaning = 'State snapshot|arbitrary files'; Rule = 'core State' }
        @{ Topic = 'status'; Meaning = 'does not prove compliance|use diff'; Rule = 'Without a spec' }
        @{ Topic = 'validate'; Meaning = 'not proven execution success'; Rule = 'NotRun' }
        @{ Topic = 'diff'; Meaning = 'Exit 1 is a successful comparison'; Rule = 'Against' }
        @{ Topic = 'apply'; Meaning = 'does not elevate or guarantee rollback'; Rule = 'never calls apply' }
        @{ Topic = 'run'; Meaning = 'nothing is retried or undone'; Rule = 'empty With configuration' }
        @{ Topic = 'workflow'; Meaning = 'not automatically undone'; Rule = 'not a Workflow-wide budget' }
        @{ Topic = 'merge'; Meaning = 'does not resolve conflicts'; Rule = 'otherwise no file is written' }
        @{ Topic = 'providers'; Meaning = 'never starts a provider'; Rule = 'static' }
        @{ Topic = 'actions'; Meaning = 'Does not run or preview'; Rule = 'empty Action map' }
        @{ Topic = 'rollback'; Meaning = 'does not mean recovery has completed'; Rule = 'exactly one' }
        @{ Topic = 'help'; Meaning = 'Reads no spec/catalog'; Rule = 'same page' }
    ) {
        $first = Invoke-HelpCli @('help', $Topic)
        $first.ExitCode | Should -Be 0
        $first.Stderr | Should -BeNullOrEmpty
        $first.Stdout | Should -Match "^WinSpec $Topic -- "
        foreach ($section in @('Usage', 'Selection', 'Options', 'Effects and limits', 'Examples', 'Exit')) {
            $first.Stdout | Should -Match "(?m)^$section\r?$"
        }
        ($first.Stdout -replace '\s+', ' ') | Should -Match $Meaning
        ($first.Stdout -replace '\s+', ' ') | Should -Match $Rule
        # Additional prose assertions share this exact Help response; no cached
        # receipts or responses from a different entry/profile are substituted.
        $prose = $first.Stdout -replace '\s+', ' '
        switch ($Topic) {
            'run' {
                foreach ($term in @('Named Action:', 'Direct provider:', 'Direct Script:',
                        'A provider name is never inferred', 'without loading a specification',
                        '-- ends WinSpec parsing', 'appended after With.Args',
                        'HTTP requires Sha256', 'HTTPS without a digest',
                        'does not run/download', 'preview is unavailable',
                        'Interactive cannot use Json or DryRun', 'Named Actions configure',
                        '1..3600', 'default 300', 'per managed operation',
                        'not returned as WinSpec exit codes', 'not an OS security sandbox')) {
                    $prose | Should -Match ([regex]::Escape($term))
                }
            }
            'status' {
                $prose | Should -Match 'comma-separated/repeatable'
                $prose | Should -Match 'empty items fail and duplicates are removed'
                $prose | Should -Match 'All other options may occur only once'
                $prose | Should -Match '1..3600, default 300'
            }
            'validate' {
                $prose | Should -Match 'requires PreviewActions'
                $prose | Should -Match 'declared external Action-provider previews'
                $prose | Should -Match 'Core Script source existence and runtime dependencies are not checked by validate'
            }
            'rollback' { $first.Stdout | Should -Match 'positive' }
            'merge' { $prose | Should -Match 'auto, union, ours or theirs; default auto' }
        }
        $machine = Invoke-HelpCli @('help', $Topic, '-Json')
        $machine.ExitCode | Should -Be 0
        $machine.Stderr | Should -BeNullOrEmpty
        $document = $machine.Stdout | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.command | Should -Be 'help'
        $document.status | Should -Be 'Succeeded'
        @($document.diagnostics).Count | Should -Be 0
        @($document.results.PSObject.Properties.Name) | Should -Be @('help')
        $expected = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "golden/help/$Topic.json") | ConvertFrom-Json
        (ConvertTo-HelpCanonical $document.results.help | ConvertTo-Json -Depth 25 -Compress) |
            Should -Be (ConvertTo-HelpCanonical $expected | ConvertTo-Json -Depth 25 -Compress)
        if ($Topic -eq 'run') {
            # Both aliases share one Help dispatcher; exercise their JSON/text
            # forms here, while every topic retains its own prose and JSON golden.
            $second = Invoke-HelpCli @($Topic, '-Help')
            $second.ExitCode | Should -Be 0
            $second.Stderr | Should -BeNullOrEmpty
            $first.Stdout | Should -Be $second.Stdout
            $alternate = Invoke-HelpCli @($Topic, '-Help', '-Json')
            $alternate.ExitCode | Should -Be 0
            $alternate.Stderr | Should -BeNullOrEmpty
            (ConvertTo-HelpCanonical ($alternate.Stdout | ConvertFrom-Json).results.help |
                ConvertTo-Json -Depth 25 -Compress) |
                    Should -Be (ConvertTo-HelpCanonical $expected | ConvertTo-Json -Depth 25 -Compress)
        }
        $help = $document.results.help
        $optionText = [regex]::Match($first.Stdout, '(?s)\r?\nOptions\r?\n(.*?)\r?\nEffects and limits').Groups[1].Value
        $actualOptions = @([regex]::Matches($optionText, '(?m)^  (-[A-Za-z0-9]+)(?: |\r?$)') |
                ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
        $actualOptions | Should -Be @($help.options | ForEach-Object name)
        foreach ($line in $optionText -split '\r?\n') { $line.Length | Should -BeLessOrEqual 100 }
        foreach ($option in $help.options) {
            $escaped = [regex]::Escape($option.name)
            $first.Stdout | Should -Match "(?im)^  $escaped(?: <[^>]+>)? +\S.+"
        }
        $paths = @([regex]::Matches($first.Stdout, '(?m)^(?:See: |     )(.+\.md)\r?$') |
                ForEach-Object { $_.Groups[1].Value.Trim() })
        $paths.Count | Should -Be 2
        foreach ($path in $paths) {
            [IO.Path]::IsPathRooted($path) | Should -BeTrue
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
        $first.Stdout | Should -Not -Match '\x1b|(?m)^WAIT |Purpose:|Options:'
    }

    It 'preserves the top-level Help JSON value' -Tag 'Quick' {
        $machine = Invoke-HelpCli @('help', '-Json')
        $machine.ExitCode | Should -Be 0
        $machine.Stderr | Should -BeNullOrEmpty
        $document = $machine.Stdout | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.command | Should -Be 'help'
        $document.status | Should -Be 'Succeeded'
        $document.results.help.topic | Should -BeOfType ([string])
        $document.results.help.topic | Should -BeExactly ''
        @($document.diagnostics).Count | Should -Be 0
        @($document.results.PSObject.Properties.Name) | Should -Be @('help')
        $expected = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'golden/help/top.json') | ConvertFrom-Json
        (ConvertTo-HelpCanonical $document.results.help | ConvertTo-Json -Depth 25 -Compress) |
            Should -Be (ConvertTo-HelpCanonical $expected | ConvertTo-Json -Depth 25 -Compress)
    }

    It 'groups all twelve commands and explains defaults without loading them' -Tag 'Quick' {
        $top = Invoke-HelpCli @('help')
        $top.ExitCode | Should -Be 0
        $top.Stderr | Should -BeNullOrEmpty
        foreach ($section in 'Inspect', 'Change', 'Files', 'Recovery', 'Help', 'Start safely') {
            $top.Stdout | Should -Match "(?m)^$section\r?$"
        }
        @([regex]::Matches($top.Stdout, '(?m)^  (capture|status|validate|diff|apply|run|workflow|merge|providers|actions|rollback|help) +[A-Z]')).Count |
            Should -Be 12
        $top.Stdout | Should -Match 'Both present is an error'
        $top.Stdout | Should -Match 'status without a spec observes core State'
        $top.Stdout | Should -Match 'exit 1 means differences'
        $top.Stdout | Should -Not -Match '(?im)^  sandbox|Verbose|Debug'
        (Invoke-HelpCli @()).Stdout | Should -Be $top.Stdout
    }

    It 'does not import any runtime module or read malformed spec/catalog during Help' {
        $isolated = Join-Path $TestDrive 'help-only/winspec'
        $null = New-Item -ItemType Directory -Path $isolated -Force
        $entry = Join-Path $isolated 'winspec.ps1'
        Copy-Item -LiteralPath $script:Entry -Destination $entry
        $sentinel = Join-Path $TestDrive 'unexpected-module.txt'
        $poison = "[IO.File]::WriteAllText('$($sentinel.Replace("'", "''"))', 'started'); throw 'HelpLoadedRuntime'"
        foreach ($module in 'spec', 'schema', 'provider-runtime', 'console') {
            Set-Content -LiteralPath (Join-Path $isolated "$module.psm1") -Value $poison
        }
        $bad = Join-Path $isolated 'providers/bundled/broken'
        $null = New-Item -ItemType Directory -Path $bad -Force
        Set-Content -LiteralPath (Join-Path $bad 'provider.json') -Value '{ invalid'
        Set-Content -LiteralPath (Join-Path $isolated '.winspec.json') -Value '{ invalid'
        foreach ($tokens in @(@('help'), @('help', 'run'), @('run', '-Help'), @('help', 'run', '-Json'))) {
            $result = Invoke-HelpCli -Tokens $tokens -Entry $entry
            $result.ExitCode | Should -Be 0
            $result.Stderr | Should -BeNullOrEmpty
        }
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'reads displayed defaults from the option records rather than copied prose' {
        $entry = Join-Path $TestDrive 'mutated-defaults.ps1'
        $text = [IO.File]::ReadAllText($script:Entry).
        Replace('Default = 300', 'Default = 301').
        Replace("Default = 'auto'", "Default = 'ours'")
        [IO.File]::WriteAllText($entry, $text)
        ((Invoke-HelpCli -Tokens @('help', 'run') -Entry $entry).Stdout -replace '\s+', ' ') |
            Should -Match '1..3600, default 301'
        ((Invoke-HelpCli -Tokens @('help', 'merge') -Entry $entry).Stdout -replace '\s+', ' ') |
            Should -Match 'auto, union, ours or theirs; default ours'
    }

    It 'states the actual external-preview and core Script validation boundary' {
        $path = Join-Path $TestDrive 'missing-source.json'
        '{"SchemaVersion":1,"Actions":{"missing":{"Use":"Script","With":{"File":"absent-script.ps1"}}}}' |
            Set-Content -LiteralPath $path
        $validation = Invoke-HelpCli @('validate', $path, '-PreviewActions', '-Json')
        $validation.ExitCode | Should -Be 0
        $validation.Stderr | Should -BeNullOrEmpty
        $document = $validation.Stdout | ConvertFrom-Json
        $document.results.valid | Should -BeTrue
        @($document.results.validation.subjects).Count | Should -Be 0
        $preview = Invoke-HelpCli @('run', 'missing', '-Spec', $path, '-DryRun', '-Json')
        $preview.ExitCode | Should -Be 2
        $preview.Stderr | Should -BeNullOrEmpty
        ($preview.Stdout | ConvertFrom-Json).status | Should -Be 'Failed'
        ($preview.Stdout | ConvertFrom-Json).diagnostics[0].code | Should -Be 'ScriptNotFound'
    }
}
