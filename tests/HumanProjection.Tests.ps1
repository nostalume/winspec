BeforeAll {
    $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $script:Root 'winspec/console.psm1') -Force
    function Render-Human {
        param([string]$Command, $Value, [string]$Status = 'Succeeded', [hashtable]$Context = @{},
            [object[]]$Diagnostics = @(), [int]$ExitCode = 0)
        $stdout = New-Object IO.StringWriter
        $stderr = New-Object IO.StringWriter
        $result = @{ schemaVersion = 1; command = $Command; status = $Status; results = $Value; diagnostics = $Diagnostics }
        $before = $result | ConvertTo-Json -Depth 80 -Compress
        try {
            $pipeline = @(Write-WinSpecHumanResult $result $Context -ExitCode $ExitCode -OutputWriter $stdout -ErrorWriter $stderr)
            $pipeline.Count | Should -Be 0
            ($result | ConvertTo-Json -Depth 80 -Compress) | Should -Be $before
            [pscustomobject]@{ Stdout = $stdout.ToString(); Stderr = $stderr.ToString() }
        }
        finally { $stdout.Dispose(); $stderr.Dispose() }
    }
}

Describe 'bounded human projection without operation side effects' -Tag 'Unit' {
    It 'quotes copyable Next examples without treating data as PowerShell expressions' {
        $name = 'hello; $env:TEMP & "quoted"'
        $spec = 'C:\fixtures\$data`file.psd1'
        $actual = Render-Human actions @{ actions = @(@{ name = $name; provider = 'Script'; origin = 'Core'; operations = @('run', 'preview') }) } -Context @{ Spec = $spec; NextAction = $name }
        $next = ($actual.Stdout -split "`n" | Where-Object { $_ -like 'Next: *' }) -replace '^Next: ', ''
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($next, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $ast.EndBlock.Statements.Count | Should -Be 1
        $command = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
        $command.CommandElements[2].Value | Should -Be $name
        $command.CommandElements[4].Value | Should -Be $spec
        @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true)).Count | Should -Be 0
    }

    It 'distinguishes verified remote pins from observational digests without another download' {
        $receipt = @{ ExitCode = 0; Source = 'https://example.invalid/source'; RequestedUri = 'https://example.invalid/source'; FinalUri = 'https://cdn.invalid/final?secret=token'; DigestVerified = $true; ReceivedSha256 = ('a' * 64) }
        $actual = Render-Human run @{ actions = @($receipt) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'Received from: https://cdn.invalid/final'
        $actual.Stdout | Should -Match 'Digest: verified against expected pin'
        $actual.Stdout | Should -Not -Match 'secret=token'
        $receipt.DigestVerified = $false
        $actual = Render-Human run @{ actions = @($receipt) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'Digest: not pinned; received digest is observational only'
    }

    It 'shows success stderr separately, without classifying it as failure' {
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0; Stdout = 'payload'; Stderr = 'notice'; Source = 'fixture.ps1' }) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match '^OK run \[Script\]'
        $actual.Stderr | Should -Match 'Child stderr \(exit 0; not classified as failure\):'
        $actual.Stderr | Should -Not -Match '(?m)^FAIL '
    }

    It 'limits child display to head and tail and reports captured bytes omitted' {
        $text = ('a' * 5000) + ('b' * 5000)
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0; Stdout = $text; StdoutTruncated = $true }) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'display omitted 1808 captured bytes; use -Json for retained output\.'
        $actual.Stdout | Should -Match ('a' * 4096)
        $actual.Stdout | Should -Match ('b' * 4096)
        $actual.Stdout | Should -Not -Match ('a' * 4097)
        $actual.Stdout | Should -Match 'Warning: child capture itself was truncated; discarded bytes cannot be recovered\.'
    }

    It 'does not fabricate a capture-loss warning for display-only truncation' {
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0; Stderr = ('e' * 9000) }) } -Context @{ ActionProvider = 'Script' }
        $actual.Stderr | Should -Match 'display omitted 808 captured bytes'
        $actual.Stderr | Should -Not -Match 'capture itself was truncated'
    }

    It 'preserves Unicode boundaries and counts UTF-8 bytes, not characters' {
        $text = ([string][char]0x4f60) * 4000
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0; Stdout = $text }) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'display omitted 3810 captured bytes'
        $actual.Stdout | Should -Not -Match ([string][char]0xfffd)
    }

    It 'escapes ANSI, OSC, CR and bidi controls and scrubs URI credentials and query' {
        $text = "safe$([char]27)]0;bad$([char]7)`r$([char]0x202e) HTTPS://user:secret@example.invalid/source?token=private#hash"
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0; Stdout = $text }) } -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match '\\u001b\]0;bad\\u0007\\u000d\\u202e'
        $actual.Stdout | Should -Match 'https://example.invalid/source'
        $actual.Stdout | Should -Not -Match 'secret|private|hash|\u001b|\u202e'
    }

    It 'bounds generic provider leaves and values without dumping configuration or JSON' {
        $output = @{ arguments = @('secret'); With = @{ pin = 'private' }; Configuration = @{ password = 'hidden' } }
        foreach ($index in 1..105) { $output[('item{0:d3}' -f $index)] = 'x' * 400 }
        $actual = Render-Human run @{ actions = @(@{ result = @{ status = 'Succeeded'; output = $output } }) } -Context @{ ActionProvider = 'Example' }
        $actual.Stdout | Should -Match 'Provider output:'
        $actual.Stdout | Should -Match 'display omitted 5 result rows'
        $actual.Stdout | Should -Match '\[display truncated; use -Json\]'
        $actual.Stdout | Should -Not -Match 'secret|private|hidden|item101|"output"|xxx{256}'
    }

    It 'keeps distinct diagnostic resources while removing duplicate receipts and code prefixes' {
        $a = @{ code = 'ExampleFailure'; message = 'ExampleFailure: rejected'; resource = 'one' }
        $b = @{ code = 'ExampleFailure'; message = 'ExampleFailure: rejected'; resource = 'two' }
        $actual = Render-Human validate @{ valid = $false; validation = @{ mode = 'Structural'; subjects = @() } } Failed -Diagnostics @($a, $a, $b)
        ([regex]::Matches($actual.Stderr, 'ExampleFailure')).Count | Should -Be 2
        $actual.Stderr | Should -Match 'Resource: one'
        $actual.Stderr | Should -Match 'Resource: two'
        $actual = Render-Human validate @{ valid = $false; validation = @{ mode = 'Structural'; subjects = @() } } Failed -Diagnostics @(
            @{ code = 'Same'; message = 'reported'; resource = "one`npart" }
            @{ code = "part`nSame"; message = 'reported'; resource = 'one' })
        ([regex]::Matches($actual.Stderr, '(?m)^Code:')).Count | Should -Be 2
    }

    It 'bounds diagnostic messages and count without confusing them with child capture loss' {
        $diagnostics = @(1..103 | ForEach-Object { @{ code = "Error$_"; message = $(if ($_ -eq 1) { 'm' * 5000 } else { 'rejected' }); resource = "resource$_" } })
        $actual = Render-Human validate @{ valid = $false; validation = @{ mode = 'Structural'; subjects = @() } } Failed -Diagnostics $diagnostics
        ([regex]::Matches($actual.Stderr, '(?m)^Code:')).Count | Should -Be 100
        $actual.Stderr | Should -Match 'display omitted 3 diagnostics'
        $actual.Stderr | Should -Match 'display omitted 904 captured bytes'
        $actual.Stderr | Should -Not -Match 'capture itself was truncated'
    }

    It 'shares a command-wide diagnostic budget across nested provider receipts' {
        $providers = @(1..2 | ForEach-Object {
                $name = "Provider$_"
                @{ Name = $name; Status = 'Failed'; Diagnostics = @(1..60 | ForEach-Object { @{ code = "Code$_"; message = 'rejected' } }) }
            })
        $actual = Render-Human apply @{ comparison = @{ Providers = @() }; providers = $providers } Failed
        ([regex]::Matches($actual.Stderr, '(?m)^Code:')).Count | Should -Be 100
        $actual.Stderr | Should -Match 'display omitted 20 diagnostics'
    }

    It 'does not allow an Action identity newline to impersonate another summary' {
        $actual = Render-Human run @{ actions = @(@{ ExitCode = 0 }) } -Context @{ ActionName = "one`nFAIL forged"; ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'one\\nFAIL forged'
        $actual.Stdout | Should -Not -Match '(?m)^FAIL forged'
    }

    It 'reports actual apply receipts and does not claim convergence was verified' {
        $actual = Render-Human apply @{
            comparison = @{ Providers = @(@{ Name = 'Example'; Differences = @() }) }
            providers = @(@{ Name = 'Example'; Status = 'Succeeded' }); checkpoint = $null
        } -Context @{ Spec = 'machine.json' }
        $actual.Stdout | Should -Match 'selected providers reported success'
        $actual.Stdout | Should -Match 'Post-apply verification: not performed'
        $actual.Stdout | Should -Not -Match 'verified converged'
    }

    It 'preserves partial apply failure, resource diagnostics and recovery warning' {
        $actual = Render-Human apply @{
            comparison = @{ Providers = @(@{ Name = 'One' }, @{ Name = 'Two' }) }
            providers = @(@{ Name = 'One'; Status = 'Succeeded' }, @{ Name = 'Two'; Status = 'Failed'; Diagnostics = @(@{ code = 'Denied'; message = 'Denied: access rejected'; resource = 'Two.item' }) })
        } Failed -ExitCode 3
        $actual.Stdout | Should -BeNullOrEmpty
        $actual.Stderr | Should -Match '^FAIL apply -- 1 provider failed; earlier changes may remain'
        $actual.Stderr | Should -Match 'Two.item'
        $actual.Stderr | Should -Match 'no automatic rollback occurred'
        ([regex]::Matches($actual.Stderr, 'Denied')).Count | Should -Be 1
    }

    It 'retains Unchanged execution receipts, checkpoint facts and Workflow counts after recheck' {
        $actual = Render-Human apply @{
            comparison = @{ Providers = @(@{ Name = 'Example'; Status = 'Different'; Differences = @() }) }
            providers = @(@{ Name = 'Example'; Status = 'Unchanged' }); checkpoint = @{ Success = $true; Name = 'reported-checkpoint' }
        } Unchanged -Context @{ Checkpoint = $true }
        $actual.Stdout | Should -Match 'Example\s+Unchanged'
        $actual.Stdout | Should -Match 'Checkpoint: reported created'
        $actual.Stdout | Should -Match 'reported-checkpoint'
        $actual.Stdout | Should -Match 'Post-apply verification: not performed'
        $actual = Render-Human apply @{
            comparison = @{ Providers = @(@{ Name = 'Example'; Status = 'Different' }) }
            providers = @(@{ Name = 'Example'; Status = 'Failed' }); checkpoint = @{ Success = $true; Name = 'reported-checkpoint' }
        } Failed -Context @{ Checkpoint = $true }
        $actual.Stderr | Should -Match 'Checkpoint: reported created'
        $actual.Stderr | Should -Match 'reported-checkpoint'
        $actual = Render-Human workflow @{
            Name = 'setup'; CheckpointCreated = $true; Steps = @(@{ Index = 0; Kind = 'Apply'; Status = 'Unchanged' })
        }
        $actual.Stdout | Should -Match 'Summary: 0 succeeded, 0 failed, 0 skipped, 1 unchanged'
        $actual.Stdout | Should -Match 'Checkpoint created: true'
        $actual = Render-Human workflow @{
            Name = 'setup'; CheckpointCreated = $false; Steps = @(@{ Index = 0; Kind = 'Capture'; Status = 'Succeeded'; Result = @{ Path = 'published.json' } })
        }
        $actual.Stdout | Should -Match 'Capture\s+published.json\s+Succeeded'
    }

    It 'distinguishes unavailable validation from business-invalid validation' {
        $actual = Render-Human validate @{ valid = $true; validation = @{ mode = 'ActionPreview'; subjects = @(@{ path = 'Actions.one'; provider = 'Example'; status = 'Unavailable' }) } }
        $actual.Stdout | Should -Match '^PARTIAL validate'
        $actual.Stdout | Should -Match '0 valid, 0 not run, 1 unavailable, 0 invalid'
        $actual.Stdout | Should -Not -Match 'trusted provider code was started'
    }

    It 'labels successful declared previews and rejected subjects accurately' {
        $subject = @{ path = 'Actions.one'; provider = 'Example'; status = 'Valid' }
        $actual = Render-Human validate @{ valid = $true; validation = @{ mode = 'ActionPreview'; subjects = @($subject) } }
        $actual.Stdout | Should -Match '^OK validate -- structural checks and declared provider previews passed'
        $actual.Stdout | Should -Match 'Mode: ActionPreview \(trusted provider code was started\)'
        $actual.Stdout | Should -Match 'preview acceptance only; runtime success is not proven'
        $subject.status = 'Invalid'
        $actual = Render-Human validate @{ valid = $false; validation = @{ mode = 'ActionPreview'; subjects = @($subject) } } Failed
        $actual.Stderr | Should -Match '^FAIL validate -- provider validation rejected 1 subject'
    }

    It 'distinguishes compared-equal State from empty selection' {
        $comparison = @{ Providers = @(@{ Name = 'Example'; Status = 'Unchanged'; Differences = @() }) }
        $actual = Render-Human diff $comparison Unchanged -Context @{ Spec = 'machine.json' }
        $actual.Stdout | Should -Match '^OK diff -- no differences in 1 selected provider'
        $actual.Stdout | Should -Not -Match 'NO-WORK'
        $actual = Render-Human apply @{ comparison = $comparison; providers = @() } Unchanged -Context @{ Spec = 'machine.json' }
        $actual.Stdout | Should -Match 'selected State was already unchanged'
        $actual.Stdout | Should -Not -Match 'reported success'
    }

    It 'does not invent missing drift values or print opaque runtime type names' {
        $comparison = @{ Providers = @(@{ Name = 'Example'; Status = 'Different'; Differences = @() }) }
        $actual = Render-Human diff $comparison Different
        $actual.Stdout | Should -Match 'provider reported differences; details not reported'
        $actual.Stdout | Should -Not -Match '0 differences'
        $actual = Render-Human apply @{ comparison = $comparison; providers = @() } Planned
        $actual.Stdout | Should -Match 'some details not reported; apply was not called'
        $comparison.Providers[0].Differences = @(@{ Path = 'Example.item'; ConfigValue = @{ answer = 42 } })
        $actual = Render-Human diff $comparison Different
        $actual.Stdout | Should -Match '\(absent\)'
        $actual.Stdout | Should -Match 'object \(1 fields; use -Json\)'
        $actual.Stdout | Should -Not -Match 'System.Collections.Hashtable'
    }

    It 'does not claim a pinned remote preview downloaded or verified anything' {
        $actual = Render-Human run @{ actions = @(@{ Source = 'https://example.invalid/source'; RequestedUri = 'https://example.invalid/source'; ExpectedSha256 = ('a' * 64) }) } Planned -Context @{ ActionProvider = 'Script' }
        $actual.Stdout | Should -Match 'Download: not performed'
        $actual.Stdout | Should -Match 'Digest: expected pin supplied'
        $actual.Stdout | Should -Not -Match 'digest verified'
    }

    It 'shows a successful Workflow and its external provider payload without interpreting private fields' {
        $actual = Render-Human workflow @{
            Name = 'setup'; CheckpointCreated = $false
            Steps = @(@{ Index = 0; Kind = 'Run'; Name = 'one'; Status = 'Succeeded'; Result = @{ output = @{ nested = @{ answer = 42 }; arguments = @('secret') }; stderr = 'provider notice'; diagnostics = @() } })
        }
        $actual.Stdout | Should -Match '^OK workflow setup -- all 1 steps reported success'
        $actual.Stdout | Should -Match 'Step 1 / one provider output:'
        $actual.Stdout | Should -Match 'nested.answer\s+42'
        $actual.Stdout | Should -Not -Match 'secret|Child exit:'
        ([regex]::Matches($actual.Stderr, 'provider notice')).Count | Should -Be 1
        $actual.Stderr | Should -Match 'Step 1 / one provider stderr:'
    }

    It 'shows merge publication only from the already-resolved output context' {
        $actual = Render-Human merge @{ Success = $true; Strategy = 'auto'; Conflicts = @() } -Context @{ Base = 'one.json'; Incoming = 'two.json'; Output = 'published.json' }
        $actual.Stdout | Should -Match 'merged specification published'
        $actual.Stdout | Should -Match 'Output: published.json'
        $actual.Stdout | Should -Not -Match 'no file was written'
    }

    It 'does not infer Script execution from a generic provider output exitCode field' {
        $actual = Render-Human run @{ actions = @(@{ result = @{ status = 'Succeeded'; output = @{ exitCode = 7 } } }) } -Context @{ ActionProvider = 'Example' }
        $actual.Stdout | Should -Match '^OK run \[Example\] -- provider reported Succeeded'
        $actual.Stdout | Should -Not -Match 'child exited|Child exit:'
        $actual.Stdout | Should -Match 'exitCode\s+7'
    }

    It 'renders a provider without preview as opaque and not started' {
        $actual = Render-Human run @{ actions = @(@{ result = @{ Status = 'Planned'; Opaque = $true } }) } Planned -Context @{ ActionProvider = 'Example' }
        $actual.Stdout | Should -Match 'opaque preview; provider was not started'
        $actual.Stdout | Should -Not -Match 'trusted provider code was started'
    }

    It 'shows rollback acceptance without claiming completed recovery or querying a target' {
        $actual = Render-Human rollback @{ rollback = @{ Success = $true; SequenceNumber = 42 } }
        $actual.Stdout | Should -Match 'Windows System Restore request accepted'
        $actual.Stdout | Should -Match 'Sequence: 42'
        $actual.Stdout | Should -Match 'Description: not reported'
        $actual.Stdout | Should -Match 'system recovery has not been verified complete'
    }

    It 'renders workflow exception diagnostics and skipped identity without adding receipt fields' {
        $actual = Render-Human workflow @{
            Name = 'setup'; CheckpointCreated = $true; Steps = @(
                @{ Index = 0; Kind = 'Run'; Name = 'one'; Status = 'Failed'; Diagnostics = @(@{ code = 'ScriptTimeout'; message = 'ScriptTimeout: operation timed out' }) }
                @{ Index = 1; Kind = 'Run'; Status = 'Skipped' })
        } Failed -Context @{ Steps = @(@{ Identity = 'one' }, @{ Identity = 'two' }) }
        $actual.Stderr | Should -Match '2\s+Run\s+two\s+Skipped'
        $actual.Stderr | Should -Match 'Code: ScriptTimeout'
        $actual.Stderr | Should -Match 'steps already completed were not undone'
        $actual.Stderr | Should -Match 'Checkpoint created: true'
    }

    It 'does not merge the same resource diagnostic from two different Workflow steps' {
        $diagnostic = @{ code = 'Notice'; message = 'reported warning'; resource = 'same.item' }
        $actual = Render-Human workflow @{
            Name = 'setup'; CheckpointCreated = $false; Steps = @(
                @{ Index = 0; Kind = 'Run'; Name = 'one'; Status = 'Succeeded'; Result = @{ diagnostics = @($diagnostic) } }
                @{ Index = 1; Kind = 'Run'; Name = 'one'; Status = 'Succeeded'; Result = @{ diagnostics = @($diagnostic) } })
        }
        ([regex]::Matches($actual.Stderr, 'Code: Notice')).Count | Should -Be 2
        ([regex]::Matches($actual.Stderr, 'same.item')).Count | Should -Be 2
    }

    It 'formats truthful WAIT stages and elapsed time without fake percentage or cursor escapes' {
        $writer = New-Object IO.StringWriter
        try {
            Write-WinSpecHumanWait run 'executing child' 0 300 -Writer $writer
            Write-WinSpecHumanWait run 'executing child' 1.5 300 -Writer $writer
            $writer.ToString() | Should -Match 'WAIT run -- executing child'
            $writer.ToString() | Should -Match 'WAIT run -- elapsed 1s / operation budget 300s'
            $writer.ToString() | Should -Not -Match '%|\u001b'
        }
        finally { $writer.Dispose() }
    }

    It 'bounds unusual diagnostic identities and preserves reported cleanup failure' {
        $code = 'x' * 10000
        $actual = Render-Human run @{} Failed -Diagnostics @(@{ code = $code; message = $code })
        $actual.Stderr | Should -Match 'display truncated; use -Json'
        $actual.Stderr.Length | Should -BeLessThan 600
        $actual = Render-Human run @{} Failed -ExitCode 4 -Context @{ TimeoutSeconds = 1; CleanupFailed = $true } -Diagnostics @(@{ code = 'ScriptTimeout'; message = 'ScriptTimeout: deadline exceeded' })
        $actual.Stderr | Should -Match 'Cleanup: failure reported'
        ([regex]::Matches($actual.Stderr, 'ScriptTimeout')).Count | Should -Be 1
    }
}

Describe 'operation observation without changing captured receipts' -Tag 'Boundary' {
    BeforeAll { Import-Module (Join-Path $script:Root 'winspec/actions.psm1') -Force }
    It 'emits initial and throttled elapsed callbacks from the existing drain loop' {
        $path = Join-Path $TestDrive 'wait.ps1'
        Set-Content $path 'Start-Sleep -Milliseconds 2400; [Console]::Write("payload")'
        $events = New-Object Collections.ArrayList
        $observer = { param($Activity, $Elapsed, $Budget) $null = $events.Add(@{ Activity = $Activity; Elapsed = $Elapsed; Budget = $Budget }) }.GetNewClosure()
        $receipt = Invoke-PowerShellScript $path -TimeoutSeconds 15 -Progress $observer
        $receipt.ExitCode | Should -Be 0
        $receipt.Stdout | Should -Be 'payload'
        $events.Count | Should -BeGreaterOrEqual 2
        $events[0].Elapsed | Should -Be 0
        $events[1].Elapsed | Should -BeGreaterOrEqual 1
        foreach ($index in 2..($events.Count - 1) | Where-Object { $_ -ge 2 -and $_ -lt $events.Count }) {
            ($events[$index].Elapsed - $events[$index - 1].Elapsed) | Should -BeGreaterOrEqual 2
        }
        $receipt.PSObject.Properties.Name | Should -Not -Contain 'Progress'
    }
}
