BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:Repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $script:Repo 'winspec/provider-runtime.psm1') -Force
    $script:Executable = Get-CurrentPowerShellPath
    function Invoke-DocumentationProcess {
        param([string]$Path, [string[]]$Arguments = @())
        Invoke-TestProcess -Executable $script:Executable -Path $Path -Arguments $Arguments -WorkingDirectory $script:Repo -TimeoutSeconds 90
    }
}

Describe 'Executable user documentation and CLI reference' -Tag 'Flow' {
    It 'runs the exact marked offline first-run guide with no live State or upstream' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'docs/usage.md')
        $block = [regex]::Match($text, '(?s)<!-- executable: offline-tour -->\s*```powershell\r?\n(.*?)\r?\n```').Groups[1].Value
        $block | Should -Not -BeNullOrEmpty
        $lines = @('$ErrorActionPreference = ''Stop''')
        $commands = 0
        foreach ($line in $block -split '\r?\n') {
            $lines += $line
            if ($line.StartsWith('& $winspec ')) {
                $commands++
                $lines += 'if ($LASTEXITCODE -ne 0) { throw "OfflineTourFailed: $LASTEXITCODE" }'
            }
        }
        $commands | Should -Be 11
        $path = Join-Path $TestDrive 'offline-tour.ps1'
        [IO.File]::WriteAllText($path, ($lines -join "`n"))
        $result = Invoke-DocumentationProcess $path
        $result.ExitCode | Should -Be 0 -Because ($result.Stderr + $result.Stdout)
        $result.Stderr | Should -BeNullOrEmpty
        $result.Stdout | Should -Match 'OK validate'
        $result.Stdout | Should -Match 'PLAN run hello'
        $result.Stdout | Should -Match 'PLAN run \[MicrosoftActivation\]'
        $result.Stdout | Should -Match 'Download: not performed'
        $result.Stdout | Should -Match 'configured\|appended'
        $result.Stdout | Should -Match 'OK workflow hello'
        $result.Stdout | Should -Match 'PLAN rollback -- no restore was requested'
    }

    It 'checks the generated option reference without changing the file' {
        $api = Join-Path $script:Repo 'docs/api.md'
        $before = (Get-FileHash -LiteralPath $api).Hash
        $result = Invoke-DocumentationProcess (Join-Path $script:Repo 'tools/update-help-reference.ps1') @('-Check')
        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $api).Hash | Should -Be $before
        $table = [regex]::Match([IO.File]::ReadAllText($api), '(?s)<!-- BEGIN GENERATED CLI OPTIONS.*?<!-- END GENERATED CLI OPTIONS -->').Value
        @([regex]::Matches($table, '(?m)^\| `-')).Count | Should -Be 18
    }

    It 'detects stale generated explanations and refuses to overwrite in Check mode' {
        $copy = Join-Path $TestDrive 'reference-copy'
        foreach ($dir in 'tools', 'winspec', 'docs') { $null = New-Item -ItemType Directory -Path (Join-Path $copy $dir) -Force }
        foreach ($name in 'tools/update-help-reference.ps1', 'winspec/winspec.ps1', 'docs/api.md') {
            Copy-Item -LiteralPath (Join-Path $script:Repo $name) -Destination (Join-Path $copy $name)
        }
        $api = Join-Path $copy 'docs/api.md'
        $text = [IO.File]::ReadAllText($api).Replace('default 300;', 'default 999;')
        [IO.File]::WriteAllText($api, $text)
        $before = (Get-FileHash -LiteralPath $api).Hash
        $result = Invoke-DocumentationProcess (Join-Path $copy 'tools/update-help-reference.ps1') @('-Check')
        $result.ExitCode | Should -Not -Be 0
        $result.Stderr | Should -Match 'HelpReferenceDrift'
        (Get-FileHash -LiteralPath $api).Hash | Should -Be $before
    }

    It 'resolves local links and section anchors in the maintained user/developer guides' {
        $files = @('README.md') + @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'docs') -File -Filter '*.md' |
                ForEach-Object { 'docs/' + $_.Name })
        foreach ($name in $files) {
            $path = Join-Path $script:Repo $name
            $text = [IO.File]::ReadAllText($path)
            foreach ($link in [regex]::Matches($text, '(?<!!)\[[^\]]+\]\(([^)]+)\)')) {
                $target = $link.Groups[1].Value
                if ($target -match '^[a-z]+:') { continue }
                $parts = $target -split '#', 2
                $dest = if ($parts[0]) {
                    [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) ([Uri]::UnescapeDataString($parts[0]))))
                } else { $path }
                Test-Path -LiteralPath $dest | Should -BeTrue -Because "$name links to $target"
                if ($parts.Count -eq 2 -and $parts[1]) {
                    $headings = @([regex]::Matches([IO.File]::ReadAllText($dest), '(?m)^#{1,6} (.+)\r?$') |
                            ForEach-Object { ($_.Groups[1].Value.Trim().ToLowerInvariant() -replace '[^\p{L}\p{N}_\- ]', '') -replace ' ', '-' })
                    $headings | Should -Contain $parts[1] -Because "$name links to $target"
                }
            }
        }
    }
}
