# Integration Tests for WinSpec
# Tests verify core functionality using the actual module APIs

BeforeAll {
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    
    # Import modules individually (do NOT dot-source winspec.ps1)
    # logging MUST be imported first and globally before state
    Import-Module (Join-Path $winspecRoot "logging.psm1")  -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "schema.psm1")   -Force -Global
    Import-Module (Join-Path $winspecRoot "state.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "diff.psm1")     -Force -Global
    Import-Module (Join-Path $winspecRoot "merge.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "pull.psm1")     -Force -Global
    Import-Module (Join-Path $winspecRoot "push.psm1")     -Force -Global
    Import-Module (Join-Path $winspecRoot "sandbox.psm1")  -Force -Global
    Import-Module (Join-Path $winspecRoot "checkpoint.psm1") -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "registry.psm1") -Force -Global
    
    # Create a test config directory and spec file
    $script:TestConfigDir = Join-Path $TestDrive "winspec-test-config"
    New-Item -ItemType Directory -Path $script:TestConfigDir -Force | Out-Null
    
    $script:TestSpecPath = Join-Path $script:TestConfigDir "test-spec.ps1"
    @"
@{
    Explorer = @{
        ShowHidden = `$true
    }
}
"@ | Out-File -FilePath $script:TestSpecPath -Encoding UTF8
}

AfterAll {
    if (Test-Path $script:TestConfigDir) {
        Remove-Item -Path $script:TestConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Provider Discovery" {
    Context "Get-Providers" {
        It "Should discover all providers" {
            InModuleScope state {
                $providers = Get-Providers
                $providers | Should -Not -BeNullOrEmpty
                $providers.Count | Should -BeGreaterThan 0
            }
        }
        
        It "Should discover Declarative providers" {
            InModuleScope state {
                $providers = Get-Providers -Type "Declarative"
                $providers | Should -Not -BeNullOrEmpty
                $providers | ForEach-Object { $_.Type | Should -Be "Declarative" }
            }
        }
        
        It "Should discover Trigger providers" {
            InModuleScope state {
                $providers = Get-Providers -Type "Trigger"
                $providers | Should -Not -BeNullOrEmpty
                $providers | ForEach-Object { $_.Type | Should -Be "Trigger" }
            }
        }
    }
}

Describe "State Management" {
    Context "Compare-SystemState" {
        It "Should return a hashtable with Added/Removed/Changed/Equal keys" {
            InModuleScope state {
                Mock Get-Managers { return @([PSCustomObject]@{ Name = "Registry"; Type = "Declarative"; Path = "registry.psm1" }) }
                Mock Compare-ProviderState { return @() }

                $spec    = @{ Registry = @{ Explorer = @{ ShowHidden = $true } } }
                $against = @{ Registry = @{ Explorer = @{ ShowHidden = $false } } }
                
                $result = Compare-SystemState -Spec $spec -Against $against
                $result | Should -Not -BeNullOrEmpty
                $result -is [hashtable] | Should -BeTrue
            }
        }
        
        It "Should return result for empty spec" {
            InModuleScope state {
                Mock Get-Managers { return @() }

                $result = Compare-SystemState -Spec @{} -Against @{}
                $result | Should -Not -BeNullOrEmpty
            }
        }
    }
    
    Context "Format-DiffOutput" {
        It "Should format added items" {
            InModuleScope diff {
                $diff = @{
                    Added = @(
                        @{ Path = "Registry.Explorer.ShowHidden"; ConfigValue = $true; SystemValue = $null }
                    )
                    Changed = @()
                    Removed = @()
                    Equal   = @()
                }
                
                $output = Format-DiffOutput -Differences $diff
                $output | Should -Not -BeNullOrEmpty
                $output | Should -Match "ADDED"
                $output | Should -Match "ShowHidden"
            }
        }
        
        It "Should format changed items" {
            InModuleScope diff {
                $diff = @{
                    Added   = @()
                    Changed = @(
                        @{ Path = "Registry.Explorer.ShowHidden"; SystemValue = $false; ConfigValue = $true }
                    )
                    Removed = @()
                    Equal   = @()
                }
                
                $output = Format-DiffOutput -Differences $diff
                $output | Should -Not -BeNullOrEmpty
                $output | Should -Match "CHANGED"
            }
        }
        
        It "Should format removed items" {
            InModuleScope diff {
                $diff = @{
                    Added   = @()
                    Changed = @()
                    Removed = @(
                        @{ Path = "Registry.Explorer.ShowHidden"; SystemValue = $true; ConfigValue = $null }
                    )
                    Equal   = @()
                }
                
                $output = Format-DiffOutput -Differences $diff
                $output | Should -Not -BeNullOrEmpty
                $output | Should -Match "REMOVED"
            }
        }
    }
}

Describe "Provider Execution" {
    Context "Invoke-Managers" {
        It "Should return a hashtable result with WhatIf" {
            InModuleScope registry {
                Mock Get-ItemProperty { return [PSCustomObject]@{ Hidden = 1 } }
                Mock Test-Path { return $true }
                Mock Set-ItemProperty { }
            }
            
            InModuleScope state {
                $spec = @{
                    Registry = @{
                        Explorer = @{ ShowHidden = $true }
                    }
                }
                
                $result = Invoke-Managers -Config $spec -WhatIf
                $result | Should -Not -BeNullOrEmpty
                $result -is [hashtable] | Should -BeTrue
            }
        }

        It "Should discover user managers from ConfigPath" {
            $root = Join-Path $TestDrive "user-manager"
            $managerDir = Join-Path $root "managers"
            New-Item -ItemType Directory -Path $managerDir -Force | Out-Null
            @'
function Get-ProviderInfo { @{ Name = "Custom"; Type = "Declarative" } }
function Test-CustomState { param([hashtable]$Desired) $false }
function Set-CustomState { param([hashtable]$Desired) @{ Status = "Applied"; Desired = $Desired } }
Export-ModuleMember -Function Get-ProviderInfo, Test-CustomState, Set-CustomState
'@ | Set-Content -Path (Join-Path $managerDir "Custom.psm1")

            InModuleScope state -Parameters @{ Root = $root } {
                param($Root)
                $result = Invoke-Managers -Config @{ Custom = @{ Enabled = $true } } -ConfigPath $Root

                $result.ContainsKey("Custom") | Should -BeTrue
                $result.Custom.Status | Should -Be "Applied"
            }
        }
    }
}

Describe "WinSpec Execution" {
    Context "Invoke-WinSpec" {
        It "Should forward WhatIf to trigger commands" {
            $root = Join-Path $TestDrive "winspec-whatif-trigger"
            $triggerDir = Join-Path $root "triggers"
            New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
            @'
function Get-ProviderInfo { @{ Name = "guarded"; Type = "Trigger" } }
function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if ($PSCmdlet.ShouldProcess("guarded", "execute")) { @{ Status = "Executed" } }
    else { @{ Status = "DryRun" } }
}
Export-ModuleMember -Function Get-ProviderInfo, Invoke-Trigger
'@ | Set-Content -Path (Join-Path $triggerDir "guarded.psm1")

            InModuleScope state -Parameters @{ Root = $root } {
                param($Root)
                $result = Invoke-WinSpec -Spec @{ Trigger = @("guarded") } -ConfigPath $Root -WhatIf

                $result.Triggers.guarded.Status | Should -Be "DryRun"
            }
        }

        It "Should not summarize Success as a provider result" {
            InModuleScope state {
                Mock Test-SpecSchema { $true }
                Mock Invoke-Managers { @{ Registry = @{ Status = "AlreadyInDesiredState" } } }
                Mock Invoke-Triggers { @{} }
                Mock Write-Log { }
                Mock Write-LogHeader { }
                Mock Write-LogSection { }

                Invoke-WinSpec -Spec @{ Registry = @{ Explorer = @{ ShowHidden = $true } } } | Out-Null

                Should -Invoke Write-Log -ParameterFilter { $Message -like "*[Success]:*" } -Times 0
            }
        }
    }
}

Describe "Trigger Execution" {
    Context "Invoke-Triggers" {
        It "Should return a hashtable when no triggers configured" {
            InModuleScope state {
                $result = Invoke-Triggers -Config @{} -Triggers $null
                $result -is [hashtable] | Should -BeTrue
            }
        }
    }
}

Describe "Configuration Loading" {
    Context "Import-Configuration" {
        It "Should load spec hashtable from .ps1 file" {
            InModuleScope utils {
                $testPath = [System.IO.Path]::GetTempFileName() + ".ps1"
                "@{ Explorer = @{ ShowHidden = `$true } }" | Out-File $testPath -Encoding UTF8
                
                $spec = Import-Configuration -Path $testPath
                Remove-Item $testPath -Force -ErrorAction SilentlyContinue
                
                $spec | Should -Not -BeNullOrEmpty
                $spec -is [hashtable] | Should -BeTrue
            }
        }
    }
}


Describe "Sandbox Integration" {
    BeforeEach {
        $sandboxRoot = Join-Path $TestDrive "sandbox-integration"
        InModuleScope sandbox -Parameters @{ Root = $sandboxRoot } {
            param($Root)
            $Script:SandboxRoot = $Root
            $Script:SnapshotsDir = Join-Path $Root "snapshots"
            $Script:HistoryDir = Join-Path $Root "history"
            $Script:Sandbox = Join-Path $Root "sandbox.json"
            $Script:SandboxContext = $null
            Initialize-SandboxDirectory
        }
    }

    AfterEach {
        InModuleScope sandbox {
            $Script:SandboxContext = $null
            Remove-Item $Script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should route push through active mock sandbox without live registry mutation" {
        InModuleScope registry {
            Mock Set-RegistryValue { throw "live registry mutation should not run" }
        }

        InModuleScope sandbox {
            Enter-Sandbox -Mode Mock | Out-Null
        }

        $spec = @{
            Registry = @{
                Explorer = @{ ShowHidden = $true }
            }
        }

        $result = Invoke-Push -Spec $spec

        $result.Success | Should -BeTrue
        $result.Registry.Status | Should -Be "Success"

        InModuleScope sandbox {
            $state = Get-SandboxState -Provider "Registry"
            $state.Explorer.ShowHidden | Should -BeTrue
        }
    }

    It "Should clean active sandbox context after dry-run push" {
        $spec = @{ Registry = @{ Explorer = @{ ShowHidden = $true } } }

        Invoke-Push -Spec $spec -DryRun | Out-Null

        InModuleScope sandbox {
            Test-SandboxActive | Should -BeFalse
        }
    }

    It "Should save sandbox history on exit when mock changes exist" {
        InModuleScope sandbox {
            Enter-Sandbox -Mode Mock | Out-Null
            Update-SandboxChanges "Registry" "Apply" @{ Changed = @(@{ Key = "ShowHidden" }) }
            Exit-Sandbox

            @(Get-ChildItem $Script:HistoryDir -Filter "*.json").Count | Should -Be 1
        }
    }
}

Describe "Command Safety" {
    Context "Invoke-Pull" {
        It "Should not write output when DryRun is set" {
            $target = Join-Path $TestDrive "dryrun-output.ps1"

            InModuleScope pull -Parameters @{ Target = $target } {
                param($Target)

                Mock Get-SystemState { @{ Registry = @{ Explorer = @{ ShowHidden = $true } } } }
                Mock Save-Configuration { throw "Save-Configuration should not run during DryRun" }

                $result = Invoke-Pull -Output $Target -Spec @{} -DryRun

                $result.Registry.Explorer.ShowHidden | Should -BeTrue
                Test-Path $Target | Should -BeFalse
                Should -Invoke Save-Configuration -Times 0 -Exactly
            }
        }

        It "Should save captured state without passing unsupported Format to Save-Configuration" {
            $target = Join-Path $TestDrive "pull-output.ps1"

            InModuleScope pull -Parameters @{ Target = $target } {
                param($Target)

                Mock Get-SystemState { @{ Registry = @{ Explorer = @{ ShowHidden = $true } } } }
                Mock Save-Configuration {
                    param([hashtable]$Config, [string]$Path)
                    return $true
                }

                $result = Invoke-Pull -Output $Target -Spec @{}

                $result.Registry.Explorer.ShowHidden | Should -BeTrue
                Should -Invoke Save-Configuration -Times 1 -Exactly -ParameterFilter { $Path -eq $Target }
            }
        }

        It "Should capture custom providers from ConfigPath" {
            $root = Join-Path $TestDrive "pull-custom-provider"
            $managerDir = Join-Path $root "managers"
            New-Item -ItemType Directory -Path $managerDir -Force | Out-Null
            @'
function Get-ProviderInfo { @{ Name = "Custom"; Type = "Declarative" } }
function Export-CustomState { @{ Enabled = $true } }
function Test-CustomState { param([hashtable]$Desired) $true }
function Set-CustomState { param([hashtable]$Desired) @{ Status = "Applied" } }
Export-ModuleMember -Function Get-ProviderInfo, Export-CustomState, Test-CustomState, Set-CustomState
'@ | Set-Content -Path (Join-Path $managerDir "Custom.psm1")

            $result = Invoke-Pull -Spec @{} -Providers @("Custom") -ConfigPath $root -DryRun

            $result.Custom.Enabled | Should -BeTrue
        }

        It "Should return structured failure when no state is captured" {
            InModuleScope pull {
                Mock Get-SystemState { @{} }

                $result = Invoke-Pull -Spec @{}

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "NoStateCaptured"
            }
        }

        It "Should return structured failure when output exists without Apply" {
            $target = Join-Path $TestDrive "existing-output.ps1"
            "@{}" | Set-Content -Path $target

            InModuleScope pull -Parameters @{ Target = $target } {
                param($Target)
                Mock Get-SystemState { throw "Get-SystemState should not run when output exists without Apply" }

                $result = Invoke-Pull -Output $Target -Spec @{}

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "OutputExists"
                $result.Path | Should -Be $Target
            }
        }


        It "Should treat directory Output as the default spec file inside that directory" {
            $targetDir = Join-Path $TestDrive "winspec-output-dir"
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            $expected = Join-Path $targetDir ".winspec.ps1"

            InModuleScope pull -Parameters @{ TargetDir = $targetDir; Expected = $expected } {
                param($TargetDir, $Expected)
                Mock Get-SystemState { @{ Registry = @{ Explorer = @{ ShowHidden = $true } } } }
                Mock Save-Configuration { param([hashtable]$Config, [string]$Path) return $true }

                $result = Invoke-Pull -Output $TargetDir -Spec @{}

                $result.Registry.Explorer.ShowHidden | Should -BeTrue
                Should -Invoke Save-Configuration -Times 1 -Exactly -ParameterFilter { $Path -eq $Expected }
            }
        }

        It "Should return structured failure when merge fails" {
            $target = Join-Path $TestDrive "merge-fail-output.ps1"
            "@{}" | Set-Content -Path $target

            InModuleScope pull -Parameters @{ Target = $target } {
                param($Target)
                Mock Get-SystemState { @{ Registry = @{ Explorer = @{ ShowHidden = $true } } } }
                Mock Merge-Configuration { @{ Success = $false; Conflicts = @("boom") } }

                $result = Invoke-Pull -Output $Target -Spec @{} -Apply

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "MergeFailed"
            }
        }
    }

    Context "Invoke-Push" {
        It "Should not log success when WinSpec execution fails" {
            InModuleScope push {
                Mock Write-LogHeader { }
                Mock Invoke-WinSpec { @{ Success = $false; Reason = "SchemaInvalid" } }
                Mock Write-Log { }
                Mock Test-SandboxActive { $false }

                $result = Invoke-Push -Spec @{}

                $result.Success | Should -BeFalse
                Should -Invoke Write-Log -ParameterFilter { $Level -eq "OK" -and $Message -like "*completed successfully*" } -Times 0
                Should -Invoke Write-Log -ParameterFilter { $Level -eq "ERROR" -and $Message -eq "Push failed" } -Times 1
            }
        }

        It "Should exit dry-run sandbox when WinSpec execution fails" {
            InModuleScope push {
                Mock Invoke-WinSpec { @{ Success = $false; Reason = "SchemaInvalid" } }
                Mock Write-Log { }
                Mock Write-LogHeader { }

                $result = Invoke-Push -Spec @{} -DryRun

                $result.Success | Should -BeFalse
                Test-SandboxActive | Should -BeFalse
            }
        }
    }

    Context "New-Checkpoint" {
        It "Should not enable System Restore implicitly" {
            InModuleScope checkpoint {
                Mock Write-Log { }
                Mock Test-SystemRestoreEnabled { $false }
                Mock Enable-SystemRestore { throw "Enable-SystemRestore should not run from New-Checkpoint" }

                $result = New-Checkpoint -Name "WinSpec-Test"

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "SystemRestoreDisabled"
                Should -Invoke Enable-SystemRestore -Times 0 -Exactly
            }
        }
    }
}

Describe "Logging" {
    Context "Write-Log" {
        It "Should write log messages without error" {
            Import-Module (Join-Path $PSScriptRoot ".." "winspec" "logging.psm1") -Force
            { Write-Log -Level "INFO" -Message "Test message" } | Should -Not -Throw
        }

        It "Should be available inside utils when resolving missing spec paths" {
            InModuleScope utils {
                { Resolve-SpecPath -Path "Z:/definitely/missing/.winspec.ps1" } | Should -Not -Throw
            }
        }


        It "Should not emit Write-Log resolution errors from the CLI pull path" {
            $root = Resolve-Path (Join-Path $PSScriptRoot "..")
            $fakeHome = Join-Path $TestDrive "cli-home"
            $outputDir = Join-Path $TestDrive "cli-pull-output"
            New-Item -ItemType Directory -Path $fakeHome, $outputDir -Force | Out-Null

            $command = "`$env:USERPROFILE = '$fakeHome'; Remove-Item Env:WINSPEC_CONFIG -ErrorAction SilentlyContinue; Set-Location '$fakeHome'; & '$root/winspec/winspec.ps1' pull -Providers Registry -DryRun -Output '$outputDir'"
            $text = pwsh -NoProfile -Command $command 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $text | Should -Not -Match "Write-Log: The term 'Write-Log' is not recognized"
            $text | Should -Not -Match "No existing spec file found"
            $text | Should -Not -Match "Loading configuration"
            $text | Should -Match "DryRun: would save spec to"
        }
    }
}


Describe "WinSpec command invocation" {
    It "runs status through script path without missing logging commands" {
        $root = Resolve-Path (Join-Path $PSScriptRoot "..")
        $command = "& '$root/winspec/winspec.ps1' status -Providers Registry"
        $text = pwsh -NoProfile -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $text | Should -Not -Match "The term 'Write-Log' is not recognized"
        $text | Should -Match "System Status\(JSON\)"
        $text | Should -Match '"Registry"'
    }

    It "runs status through a shim wrapper without missing logging commands" {
        $root = Resolve-Path (Join-Path $PSScriptRoot "..")
        $shim = Join-Path $TestDrive "winspec-shim.ps1"
        @"
`$path = '$root/winspec/winspec.ps1'
if (`$MyInvocation.ExpectingInput) { `$input | & `$path @args } else { & `$path @args }
exit `$LASTEXITCODE
"@ | Set-Content -Path $shim -Encoding UTF8

        $text = pwsh -NoProfile -File $shim status -Providers Registry 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $text | Should -Not -Match "The term 'Write-Log' is not recognized"
        $text | Should -Match "System Status\(JSON\)"
        $text | Should -Match '"Registry"'
    }
}
