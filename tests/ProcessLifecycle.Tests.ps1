BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $script:Repo 'winspec/provider-runtime.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:Fixture = Join-Path $TestDrive 'process'
    $null = New-Item -ItemType Directory -Path $script:Fixture
    $script:Native = Join-Path $script:Fixture 'fixture.exe'
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    & $compiler /nologo /target:exe "/out:$script:Native" (Join-Path $PSScriptRoot 'fixtures/process-fixture.cs')
    if ($LASTEXITCODE -ne 0) { throw 'LifecycleFixtureCompilationFailed' }
}

Describe 'one operation deadline and owned process cleanup' -Tag 'Boundary', 'Safety' {
    AfterEach {
        # All IDs come from this suite's unique, compiled, disposable fixture.
        foreach ($file in Get-ChildItem -LiteralPath $script:Fixture -Filter '*.pid') {
            $child = Get-Process -Id ([int](Get-Content -LiteralPath $file.FullName)) -ErrorAction SilentlyContinue
            if ($child -and $child.Path -eq $script:Native) { $child.Kill(); $null = $child.WaitForExit(1000); $child.Dispose() }
            Remove-Item -LiteralPath $file.FullName
        }
    }

    It 'bounds <Mode>, cleans its directory, and stops surviving descendants' -ForEach @(
        @{ Mode = 'noinput'; Expected = '^ProviderTimeout:' },
        @{ Mode = 'orphan'; Expected = '^ProviderTimeout:' },
        @{ Mode = 'bad'; Expected = '^InvalidProviderResponse:' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:Fixture 'mode.txt') -Value $Mode
        $result = Join-Path $script:Fixture 'result.json'
        { Invoke-TestProcess -Path (Join-Path $PSScriptRoot 'fixtures/lifecycle-probe.ps1') `
                -Arguments @('-Repo', $script:Repo, '-Fixture', $script:Fixture, '-Mode', $Mode, '-Result', $result) `
                -TimeoutSeconds 6 } | Should -Not -Throw
        $r = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
        $r.error | Should -Match $Expected
        $r.elapsed | Should -BeLessThan 3.5
        $r.cleanupError | Should -BeNullOrEmpty
        @($r.newDirectories).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:Fixture 'root.pid') | Should -BeTrue
        if ($Mode -in @('orphan', 'bad')) { Test-Path -LiteralPath (Join-Path $script:Fixture 'child.pid') | Should -BeTrue }
        foreach ($file in Get-ChildItem -LiteralPath $script:Fixture -Filter '*.pid') {
            Get-Process -Id ([int](Get-Content -LiteralPath $file.FullName)) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'writes a large request while concurrently draining a large valid response' {
        Set-Content -LiteralPath (Join-Path $script:Fixture 'mode.txt') -Value duplex
        $result = Join-Path $script:Fixture 'duplex.json'
        $process = Invoke-TestProcess -Path (Join-Path $PSScriptRoot 'fixtures/lifecycle-probe.ps1') `
            -Arguments @('-Repo', $script:Repo, '-Fixture', $script:Fixture, '-Mode', 'duplex', '-Result', $result) `
            -TimeoutSeconds 8
        $process.ExitCode | Should -Be 0
        $r = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
        $r.error | Should -BeNullOrEmpty
        $r.status | Should -Be 'Succeeded'
        $r.length | Should -Be 1MB
        @($r.newDirectories).Count | Should -Be 0
    }

    It 'preserves a callback failure and reports cleanup failure rather than replacing it' {
        InModuleScope provider-runtime -Parameters @{ Native = $script:Native; Root = $script:Fixture } {
            param($Native, $Root)
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $Native; $start.Arguments = 'sleep'; $start.WorkingDirectory = $Root
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $script:StoppedId = 0
            Mock Stop-ProviderProcessTree {
                param($Process)
                $script:StoppedId = $Process.Id
                $Process.Kill()
                $null = $Process.WaitForExit(1000)
                throw 'fixture cleanup failure'
            }
            try { Invoke-BoundedProcess -StartInfo $start -TimeoutSeconds 5 -Progress { throw 'fixture primary failure' } }
            catch {
                $_.Exception.Message | Should -Be 'fixture primary failure'
                $_.Exception.Data['ProcessCleanupError'] | Should -Be 'fixture cleanup failure'
            }
            $script:StoppedId | Should -BeGreaterThan 0
            Get-Process -Id $script:StoppedId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'does not start a process after an already consumed shared budget' {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 20
        $start = New-Object Diagnostics.ProcessStartInfo
        # A Start() call would fail with file-not-found, not ProcessTimeout.
        $start.FileName = Join-Path $script:Fixture 'must-not-start.exe'
        $start.UseShellExecute = $false
        { Invoke-BoundedProcess -StartInfo $start -DeadlineTimer $timer -TimeoutSeconds 0.001 } | Should -Throw '*ProcessTimeout*'
    }

    It 'enforces the deadline after both pipes reach EOF while the process is still alive' {
        InModuleScope provider-runtime -Parameters @{ Native = $script:Native; Root = $script:Fixture } {
            param($Native, $Root)
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $Native; $start.Arguments = 'sleep'; $start.WorkingDirectory = $Root
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $script:EofChild = New-Object Diagnostics.Process; $script:EofChild.StartInfo = $start
            $null = $script:EofChild.Start(); $id = $script:EofChild.Id
            $facade = [pscustomobject]@{
                StartInfo = $start
                StandardOutput = [pscustomobject]@{ BaseStream = (New-Object IO.MemoryStream) }
                StandardError = [pscustomobject]@{ BaseStream = (New-Object IO.MemoryStream) }
            }
            $facade | Add-Member ScriptProperty Id { $script:EofChild.Id }
            $facade | Add-Member ScriptProperty Handle { $script:EofChild.Handle }
            $facade | Add-Member ScriptProperty StartTime { $script:EofChild.StartTime }
            $facade | Add-Member ScriptProperty HasExited { $script:EofChild.HasExited }
            $facade | Add-Member ScriptMethod Start { $true }
            $facade | Add-Member ScriptMethod Kill { $script:EofChild.Kill() }
            $facade | Add-Member ScriptMethod WaitForExit {
                param([int]$Milliseconds)
                if ($PSBoundParameters.ContainsKey('Milliseconds')) { return $script:EofChild.WaitForExit($Milliseconds) }
                $script:EofChild.WaitForExit()
            }
            $facade | Add-Member ScriptMethod Dispose { $script:EofChild.Dispose() }
            $script:EofFacade = $facade
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            Mock New-Object { $script:EofFacade } -ParameterFilter { $TypeName -eq 'Diagnostics.Process' }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                # Empty streams deterministically expose EOF; the independent
                # native child remains alive, so EOF cannot imply completion.
                $script:EofChild.HasExited | Should -BeFalse
                { Invoke-BoundedProcess -StartInfo $start -TimeoutSeconds 1 } | Should -Throw '*ProcessTimeout*'
                $timer.Elapsed.TotalSeconds | Should -BeLessThan 3.5
                Get-Process -Id $id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
            finally {
                $live = Get-Process -Id $id -ErrorAction SilentlyContinue
                if ($live -and $live.Path -eq $Native) { $live.Kill(); $null = $live.WaitForExit(1000); $live.Dispose() }
                $facade.StandardOutput.BaseStream.Dispose(); $facade.StandardError.BaseStream.Dispose()
                $script:EofChild.Dispose()
            }
        }
    }

    It 'does not trust descendants below a stale or reused ancestor identity' {
        InModuleScope provider-runtime -Parameters @{ Native = $script:Native; Root = $script:Fixture } {
            param($Native, $Root)
            $all = @()
            try {
                foreach ($index in 1..3) {
                    $start = New-Object Diagnostics.ProcessStartInfo
                    $start.FileName = $Native; $start.Arguments = 'sleep'; $start.WorkingDirectory = $Root
                    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
                    $null = $process.Start(); $all += $process
                }
                $script:SnapshotRows = @(
                    [pscustomobject]@{ ProcessId = $all[1].Id; ParentProcessId = $all[0].Id; CreationDate = $all[1].StartTime.ToUniversalTime().AddTicks(-1); Name = 'stale' },
                    [pscustomobject]@{ ProcessId = $all[2].Id; ParentProcessId = $all[1].Id; CreationDate = $all[2].StartTime.ToUniversalTime(); Name = 'unrelated' }
                )
                Mock Get-ProcessTreeSnapshot { $script:SnapshotRows }
                Stop-ProviderProcessTree $all[0]
                $all[0].HasExited | Should -BeTrue
                $all[1].HasExited | Should -BeFalse
                $all[2].HasExited | Should -BeFalse
            }
            finally {
                foreach ($process in $all) {
                    if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(1000) }
                    $process.Dispose()
                }
            }
        }
    }

    It 'keeps primary and cleanup diagnostics in one JSON document (workflow=<Workflow>)' -ForEach @(
        @{ Workflow = $false }, @{ Workflow = $true }
    ) {
        $copy = Join-Path $TestDrive ('runtime-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $script:Repo 'winspec') -Destination $copy -Recurse
        $runtime = Join-Path $copy 'provider-runtime.psm1'
        $source = [IO.File]::ReadAllText($runtime)
        $needle = 'Stop-ProviderProcessTree $process -StartedAt $startedAt'
        $source.Contains($needle) | Should -BeTrue
        # Fault only after the real supervisor has terminated its owned tree.
        [IO.File]::WriteAllText($runtime, $source.Replace($needle, $needle + "; throw 'fixture cleanup failure'"))
        $scriptPath = Join-Path $TestDrive 'sleep.ps1'
        Set-Content -LiteralPath $scriptPath -Value 'Start-Sleep -Seconds 10'
        $tokens = @('run', $scriptPath, '-TimeoutSeconds', '1', '-Json')
        if ($Workflow) {
            $specPath = Join-Path $TestDrive 'failure.json'
            @{ SchemaVersion = 1; Actions = @{ sleep = @{ Use = 'Script'; With = @{ File = $scriptPath } } }; Workflows = @{ fail = @{ Steps = @(@{ Run = 'sleep' }, @{ Run = 'sleep' }) } } } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $specPath
            $tokens = @('workflow', 'fail', '-Spec', $specPath, '-TimeoutSeconds', '1', '-Json')
        }
        $r = Invoke-TestProcess -Path (Join-Path $copy 'winspec.ps1') -Arguments $tokens
        $r.ExitCode | Should -Be $(if ($Workflow) { 3 } else { 4 })
        $r.Stderr | Should -BeNullOrEmpty
        $document = $r.Stdout | ConvertFrom-Json -ErrorAction Stop
        $document.schemaVersion | Should -Be 1
        $document.status | Should -Be Failed
        $diagnostics = if ($Workflow) { $document.results.steps[0].Diagnostics } else { $document.diagnostics }
        @($diagnostics).Count | Should -Be 2
        $diagnostics[0].code | Should -Be ScriptTimeout
        $diagnostics[1].code | Should -Be ProcessCleanupError
        $diagnostics[1].message | Should -Match 'fixture cleanup failure'
        if ($Workflow) { $document.results.steps[1].Status | Should -Be Skipped }
    }

    It 'refuses to delete a directory outside its invocation namespace' {
        $outside = Join-Path $TestDrive 'unowned'
        $null = New-Item -ItemType Directory -Path $outside
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value keep
        InModuleScope provider-runtime -Parameters @{ Outside = $outside } {
            param($Outside)
            { Remove-ProviderTemporaryDirectory $Outside } | Should -Throw '*InvalidProviderTemporaryDirectory*'
        }
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
    }

    It 'refuses a reparse invocation root but safely removes nested links without following them' {
        $outside = Join-Path $TestDrive 'junction-target'
        $null = New-Item -ItemType Directory -Path $outside
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value keep
        $root = Join-Path ([IO.Path]::GetTempPath()) ('winspec-provider-' + [guid]::NewGuid().ToString('D'))
        try {
            $null = New-Item -ItemType Junction -Path $root -Target $outside
            InModuleScope provider-runtime -Parameters @{ Root = $root } {
                param($Root)
                { Remove-ProviderTemporaryDirectory $Root } | Should -Throw '*reparse point*'
            }
            [IO.Directory]::Delete($root, $false)
            $null = [IO.Directory]::CreateDirectory($root)
            $null = New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target $outside
            InModuleScope provider-runtime -Parameters @{ Root = $root } {
                param($Root)
                Remove-ProviderTemporaryDirectory $Root
            }
            Test-Path -LiteralPath $root | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
        }
        finally {
            # Only nonrecursive removal of this test's known junction/empty root.
            if ([IO.Directory]::Exists((Join-Path $root 'link'))) { [IO.Directory]::Delete((Join-Path $root 'link'), $false) }
            if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $false) }
        }
    }

    It 'preserves preview/execution counts and fresh processes for <Steps> Workflow steps (plan=<Plan>)' -ForEach @(
        @{ Steps = 2; Plan = $false }, @{ Steps = 2; Plan = $true }
    ) {
        Import-Module (Join-Path $script:Repo 'winspec/workflow.psm1') -Force
        Set-Content -LiteralPath (Join-Path $script:Fixture 'mode.txt') -Value counter
        $log = Join-Path $script:Fixture 'operations.log'
        if (Test-Path $log) { Remove-Item -LiteralPath $log }
        $provider = [pscustomobject]@{
            Name = 'Counter'; Kind = 'Action'; Execution = 'Protocol'; Operations = @('preview', 'run')
            EntryPointType = 'Executable'; EntryPoint = $script:Native; PackageRoot = $script:Fixture
        }
        $document = [pscustomobject]@{
            Path = (Join-Path $script:Fixture 'spec.json')
            Spec = @{ Actions = @{ count = @{ Use = 'Counter' } }; Workflows = @{ setup = @{ Steps = @(1..$Steps | ForEach-Object { @{ Run = 'count' } }) } } }
        }
        $r = Invoke-WinSpecWorkflow -Document $document -Name setup -Catalog @($provider) -MachineOutput -DryRun:$Plan -TimeoutSeconds 5
        $r.Status | Should -Be $(if ($Plan) { 'Planned' } else { 'Succeeded' })
        @($r.Steps).Count | Should -Be $Steps
        $lines = @(Get-Content -LiteralPath $log)
        $expected = @(1..$Steps | ForEach-Object { 'preview' })
        if (-not $Plan) { $expected += @(1..$Steps | ForEach-Object { 'run' }) }
        @($lines | ForEach-Object { ($_ -split '[|]')[0] }) | Should -Be $expected
        $identities = @($lines | ForEach-Object { ($_ -split '[|]')[1] })
        @($identities | Sort-Object -Unique).Count | Should -Be $expected.Count
        foreach ($identity in $identities) { [int]($identity -split '@')[0] | Should -Not -Be $PID }
    }
}
