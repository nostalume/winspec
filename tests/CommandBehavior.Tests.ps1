# Command-level behavior tests for WinSpec
# These tests exercise the real CLI entrypoint instead of importing modules only.

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $script:WinSpecScript = Join-Path $script:RepoRoot "winspec" "winspec.ps1"
    $script:ShimPath = Join-Path $TestDrive "winspec-shim.ps1"

    @"
`$path = '$script:WinSpecScript'
if (`$MyInvocation.ExpectingInput) { `$input | & `$path @args } else { & `$path @args }
exit `$LASTEXITCODE
"@ | Set-Content -Path $script:ShimPath -Encoding UTF8

    $script:ConfigRoot = Join-Path $TestDrive "command-config"
    New-Item -ItemType Directory -Path $script:ConfigRoot -Force | Out-Null

    $script:ValidSpec = Join-Path $script:ConfigRoot ".winspec.ps1"
    @'
@{
    Registry = @{
        Explorer = @{ ShowHidden = $true }
    }
}
'@ | Set-Content -Path $script:ValidSpec -Encoding UTF8

    $script:InvalidSpec = Join-Path $script:ConfigRoot "invalid.ps1"
    '@{ DefinitelyInvalid = $true }' | Set-Content -Path $script:InvalidSpec -Encoding UTF8

    $script:IncomingSpec = Join-Path $script:ConfigRoot "incoming.ps1"
    @'
@{
    Registry = @{
        Explorer = @{ ShowFileExt = $true }
    }
}
'@ | Set-Content -Path $script:IncomingSpec -Encoding UTF8

    $triggerDir = Join-Path $script:ConfigRoot "triggers"
    New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
    @'
function Get-ProviderInfo { @{ Name = "guarded"; Type = "Trigger"; Description = "Command behavior test trigger" } }
function Invoke-Trigger { @{ Status = "Executed"; Source = "CommandBehavior" } }
Export-ModuleMember -Function Get-ProviderInfo, Invoke-Trigger
'@ | Set-Content -Path (Join-Path $triggerDir "guarded.psm1") -Encoding UTF8

    $script:TriggerSpec = Join-Path $script:ConfigRoot "trigger.ps1"
    '@{ Trigger = @("guarded") }' | Set-Content -Path $script:TriggerSpec -Encoding UTF8

    function Invoke-CommandSurface {
        param(
            [ValidateSet("script", "shim")]
            [string]$Surface,
            [string[]]$Arguments
        )

        $entry = if ($Surface -eq "script") { $script:WinSpecScript } else { $script:ShimPath }
        $output = & pwsh -NoProfile -File $entry @Arguments 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = $output
        }
    }

    function Should-BeSuccessfulCommand {
        param($Result, [string]$ExpectedText)

        $Result.ExitCode | Should -Be 0
        $Result.Text | Should -Not -Match "The term 'Write-Log' is not recognized"
        $Result.Text | Should -Not -Match "ParameterBindingException"
        if ($ExpectedText) {
            $Result.Text | Should -Match $ExpectedText
        }
    }
}

Describe "WinSpec command behavior integration" {
    It "shows top-level help" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("help")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "AVAILABLE COMMANDS"
        }
    }

    It "shows per-command help for every command" {
        foreach ($surface in @("script", "shim")) {
            foreach ($command in @("pull", "push", "diff", "merge", "status", "rollback", "providers", "validate", "trigger", "sandbox")) {
                $result = Invoke-CommandSurface -Surface $surface -Arguments @($command, "-Help")
                Should-BeSuccessfulCommand -Result $result -ExpectedText ("WinSpec .*" + $command)
            }
        }
    }

    It "lists providers" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("providers", "-Spec", $script:ValidSpec)
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Registry"
        }
    }

    It "captures status for a safe provider" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("status", "-Providers", "Registry")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "System Status\(JSON\)"
            $result.Text | Should -Match '"Registry"'
        }
    }

    It "dry-runs pull to a directory output" {
        foreach ($surface in @("script", "shim")) {
            $outputDir = Join-Path $TestDrive ("pull-output-" + $surface)
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

            $result = Invoke-CommandSurface -Surface $surface -Arguments @("pull", "-Providers", "Registry", "-DryRun", "-Output", $outputDir)

            Should-BeSuccessfulCommand -Result $result -ExpectedText "DryRun: would save spec to"
            $result.Text | Should -Match ([regex]::Escape((Join-Path $outputDir ".winspec.ps1")))
        }
    }

    It "fails pull output conflict before provider capture" {
        foreach ($surface in @("script", "shim")) {
            $target = Join-Path $TestDrive ("existing-" + $surface + ".ps1")
            '@{}' | Set-Content -Path $target -Encoding UTF8

            $result = Invoke-CommandSurface -Surface $surface -Arguments @("pull", "-Output", $target)

            $result.Text | Should -Match "OutputExists"
            $result.Text | Should -Not -Match "Capturing system state"
            $result.Text | Should -Not -Match "Write-Log"
        }
    }

    It "validates a valid spec" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("validate", "-Spec", $script:ValidSpec)
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Specification is valid"
        }
    }

    It "rejects an invalid spec" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("validate", "-Spec", $script:InvalidSpec)
            $result.ExitCode | Should -Be 1
            $result.Text | Should -Match "Specification is invalid"
            $result.Text | Should -Not -Match "The term 'Write-Log' is not recognized"
        }
    }

    It "diffs a spec against live safe provider state" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("diff", "-Spec", $script:ValidSpec, "-Providers", "Registry")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Registry"
        }
    }

    It "merges specs in dry-run mode" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("merge", "-Base", $script:ValidSpec, "-Incoming", $script:IncomingSpec, "-DryRun")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Merge"
        }
    }

    It "dry-runs push through a safe provider" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("push", "-Spec", $script:ValidSpec, "-Providers", "Registry", "-DryRun")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Push completed successfully"
        }
    }

    It "runs a custom trigger from the spec config path" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("trigger", "guarded", "-Spec", $script:TriggerSpec)
            Should-BeSuccessfulCommand -Result $result -ExpectedText "CommandBehavior"
        }
    }

    It "shows sandbox status without side effects" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("sandbox")
            Should-BeSuccessfulCommand -Result $result -ExpectedText "Sandbox"
        }
    }

    It "rejects rollback without a target" {
        foreach ($surface in @("script", "shim")) {
            $result = Invoke-CommandSurface -Surface $surface -Arguments @("rollback")
            $result.ExitCode | Should -Be 1
            $result.Text | Should -Match "Specify -SequenceNumber or -Last"
            $result.Text | Should -Not -Match "The term 'Write-Log' is not recognized"
        }
    }
}
