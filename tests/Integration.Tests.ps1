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
    }
}
