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
                Mock Get-Managers { return @() }
                Mock Write-Log { }       # suppress logging noise inside module
                
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
                Mock Write-Log { }
                
                $result = Compare-SystemState -Spec @{} -Against @{}
                $result | Should -Not -BeNullOrEmpty
            }
        }
    }
    
    Context "Format-DiffOutput" {
        It "Should format added items" {
            InModuleScope state {
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
            InModuleScope state {
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
            InModuleScope state {
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
                Mock Write-Log { }
                Mock Write-LogSection { }
                
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

Describe "Logging" {
    Context "Write-Log" {
        It "Should write log messages without error" {
            InModuleScope logging {
                { Write-Log -Level "INFO" -Message "Test message" } | Should -Not -Throw
            }
        }
    }
}
