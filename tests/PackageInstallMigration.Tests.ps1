BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:WinSpec = Join-Path $script:RepoRoot 'winspec/winspec.ps1'
    $script:InstallScript = Join-Path $script:RepoRoot `
        'examples/scripts/install-packages.ps1'
    $script:MigrationSpec = Join-Path $script:RepoRoot `
        'examples/package-install-migration.winspec.psd1'
    $script:PwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source

    function Invoke-HostProcess {
        param([string]$HostPath, [string[]]$Arguments)
        $text = & $HostPath -NoProfile @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    }
}

Describe 'one-file PackageInstall migration' {
    It 'validates the data-only replacement and keeps interactive daily out of setup' {
        $result = Invoke-HostProcess pwsh @(
            '-File', $script:WinSpec, 'validate', $script:MigrationSpec, '-Json')

        $result.ExitCode | Should -Be 0
        $document = ConvertFrom-Json $result.Text
        $document.results.valid | Should -BeTrue

        $spec = Import-PowerShellDataFile -LiteralPath $script:MigrationSpec
        @($spec.Workflows.setup.Steps).Count | Should -Be 2
        $spec.Workflows.setup.Steps[1].Run | Should -Be 'installPackages'
        $spec.Actions.installDailyPackages.With.Interactive | Should -BeTrue
        $spec.Actions.installPackages.With.Args[1] | Should -Be 'base,dev,backup'
    }

    It 'previews the ordinary Action as opaque without running package tools' {
        $result = Invoke-HostProcess pwsh @(
            '-File', $script:WinSpec, 'run', 'installPackages', '-Spec',
            $script:MigrationSpec, '-DryRun', '-Json')

        $result.ExitCode | Should -Be 0
        $action = (ConvertFrom-Json $result.Text).results.actions[0].result
        $action.status | Should -Be 'Planned'
        $action.opaque | Should -BeTrue
    }

    It 'splits comma-separated roles and invokes only their catalog entries' -ForEach @(
        @{ HostPath = 'pwsh' }
        @{ HostPath = 'powershell.exe' }
    ) {
        $bin = Join-Path $TestDrive ('bin-' + [IO.Path]::GetFileNameWithoutExtension($HostPath))
        $null = New-Item -ItemType Directory -Path $bin -Force
        $log = Join-Path $TestDrive ('calls-' + [IO.Path]::GetFileNameWithoutExtension($HostPath))
        foreach ($name in @('scoop', 'winget')) {
            Set-Content -LiteralPath (Join-Path $bin "$name.cmd") `
                -Encoding Ascii -Value "@echo $name %*>>`"$log`"`r`n@exit /b 0"
        }
        $oldPath = $env:PATH
        try {
            $env:PATH = $bin + [IO.Path]::PathSeparator + $oldPath
            $result = Invoke-HostProcess $HostPath @(
                '-File', $script:InstallScript, '-Roles', ' dev, backup ')
        }
        finally {
            $env:PATH = $oldPath
        }

        $result.ExitCode | Should -Be 0
        $calls = @(Get-Content -LiteralPath $log)
        $calls.Count | Should -Be 7
        @($calls | Where-Object { $_ -match 'Rustlang[.]Rustup' }).Count |
            Should -Be 1
        @($calls | Where-Object { $_ -match 'PowerToys|Vivaldi|utils' }).Count |
            Should -Be 0
    }

    It 'rejects the undefined legacy utils role without starting a package tool' -ForEach @(
        @{ HostPath = 'pwsh' }
        @{ HostPath = 'powershell.exe' }
    ) {
        $result = Invoke-HostProcess $HostPath @(
            '-File', $script:InstallScript, '-Roles', 'utils')

        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match 'UnknownRole:'
    }

    It 'rejects a missing package manager before starting another one' {
        $bin = Join-Path $TestDrive 'missing-manager-bin'
        $null = New-Item -ItemType Directory -Path $bin
        $log = Join-Path $TestDrive 'unexpected-call'
        Set-Content -LiteralPath (Join-Path $bin 'scoop.cmd') `
            -Encoding Ascii -Value "@echo called>>`"$log`"`r`n@exit /b 0"
        $oldPath = $env:PATH
        try {
            $env:PATH = $bin
            $result = Invoke-HostProcess $script:PwshPath @(
                '-File', $script:InstallScript, '-Roles', 'dev')
        }
        finally {
            $env:PATH = $oldPath
        }

        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match "PackageManagerNotFound: 'winget'"
        Test-Path -LiteralPath $log | Should -BeFalse
    }
}
