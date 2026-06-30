# State Management Integration Tests
# Tests for state comparison, diff, and merge functionality

BeforeAll {
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    
    Import-Module (Join-Path $winspecRoot "logging.psm1") -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "schema.psm1")   -Force -Global
    Import-Module (Join-Path $winspecRoot "state.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "diff.psm1")     -Force -Global
    Import-Module (Join-Path $winspecRoot "merge.psm1")    -Force -Global
}

Describe "State Comparison" {
    Context "Compare-SystemState" {
        It "Should return flat diff hashtable with Added/Removed/Changed/Equal keys" {
            InModuleScope state {
                Mock Get-Managers { return @() }
                
                $spec = @{
                    Registry = @{ Explorer = @{ ShowHidden = $true } }
                }
                
                $result = Compare-SystemState -Spec $spec -Against @{}
                $result | Should -Not -BeNullOrEmpty
                $result -is [hashtable] | Should -BeTrue
                $result.ContainsKey("Added")   | Should -BeTrue
                $result.ContainsKey("Changed") | Should -BeTrue
                $result.ContainsKey("Removed") | Should -BeTrue
            }
        }
        
        It "Should handle empty spec" {
            InModuleScope state {
                Mock Get-Managers { return @() }
                
                $result = Compare-SystemState -Spec @{} -Against @{}
                $result | Should -Not -BeNullOrEmpty
            }
        }
        
        It "Should handle spec with multiple provider keys" {
            InModuleScope state {
                Mock Get-Managers { return @() }
                
                $spec = @{
                    Registry = @{ Explorer = @{ ShowHidden = $true } }
                    Feature  = @{ TelnetClient = "enabled" }
                }
                
                $result = Compare-SystemState -Spec $spec -Against @{}
                $result | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe "Diff Output" {
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
        
        It "Should format mixed changes" {
            InModuleScope state {
                $diff = @{
                    Added = @(
                        @{ Path = "Registry.Explorer.NewValue"; ConfigValue = $true; SystemValue = $null }
                    )
                    Changed = @(
                        @{ Path = "Registry.Explorer.OldValue"; SystemValue = $false; ConfigValue = $true }
                    )
                    Removed = @(
                        @{ Path = "Registry.Explorer.RemovedValue"; SystemValue = $true; ConfigValue = $null }
                    )
                    Equal = @()
                }
                
                $output = Format-DiffOutput -Differences $diff
                $output | Should -Not -BeNullOrEmpty
                $output | Should -Match "ADDED"
                $output | Should -Match "CHANGED"
                $output | Should -Match "REMOVED"
            }
        }
    }
}

Describe "State Merge" {
    Context "Merge-Configuration" {
        It "Should merge two config hashtables" {
            $base = @{
                Registry = @{ Explorer = @{ ShowHidden = $false } }
            }
            $incoming = @{
                Registry = @{ Explorer = @{ ShowHidden = $true } }
            }
            
            $result = Merge-Configuration -Base $base -Incoming $incoming
            $result | Should -Not -BeNullOrEmpty
            $result.Success | Should -BeTrue
        }
        
        It "Should handle empty incoming" {
            $base = @{
                Registry = @{ Explorer = @{ ShowHidden = $true } }
            }
            
            $result = Merge-Configuration -Base $base -Incoming @{}
            $result | Should -Not -BeNullOrEmpty
            $result.Success | Should -BeTrue
        }
    }
}

Describe "State Export" {
    Context "Get-SystemState" {
        It "Should return a hashtable" {
            InModuleScope state {
                Mock Get-Managers {
                    return @(
                        [PSCustomObject]@{ Name = "Registry"; Type = "Declarative"; Path = "" }
                    )
                }
                Mock Export-ProviderState { return @{ Explorer = @{ ShowHidden = $true } } }
                
                $result = Get-SystemState -NoCache
                $result | Should -Not -BeNullOrEmpty
                $result -is [hashtable] | Should -BeTrue
            }
        }
        
        It "Should accept Providers filter" {
            InModuleScope state {
                Mock Get-Managers {
                    return @(
                        [PSCustomObject]@{ Name = "Registry"; Type = "Declarative"; Path = "" }
                    )
                }
                Mock Export-ProviderState { return @{ Explorer = @{ ShowHidden = $true } } }
                
                $result = Get-SystemState -Providers @("Registry") -NoCache
                $result | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe "Provider Discovery" {
    Context "Get-Managers" {
        It "Should not discover retired Scoop or Winget package managers" {
            InModuleScope state {
                $managerNames = @(Get-Managers | ForEach-Object { $_.Name })

                $managerNames | Should -Not -Contain "Scoop"
                $managerNames | Should -Not -Contain "Winget"
            }
        }
    }
}

Describe "Utility Surface" {
    Context "Retired package helpers" {
        It "Should not export package merge helpers after package managers are retired" {
            Get-Command Merge-PackageState -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Command Merge-SourceCollection -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe "State Validation" {
    Context "Test-SpecSchema" {
        It "Should return true for valid spec with known keys" {
            $spec = @{
                Registry = @{
                    Explorer = @{ ShowHidden = $true }
                }
            }
            
            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeTrue
        }
        
        It "Should return false for spec with unknown top-level key" {
            $spec = @{
                UnknownInvalidTopLevelKey = "some value"
            }
            
            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeFalse
        }

        It "Should reject retired package-manager sections" {
            $spec = @{
                Scoop  = @{ Installed = @("git") }
                Winget = @{ Installed = @("Git.Git") }
            }

            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeFalse
        }

        It "Should reject unknown Registry properties" {
            $spec = @{
                Registry = @{
                    Explorer = @{ DefinitelyNotASetting = $true }
                }
            }

            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeFalse
        }

        It "Should reject invalid mapped Registry values" {
            $spec = @{
                Registry = @{
                    Theme = @{ AppTheme = "blue" }
                }
            }

            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeFalse
        }

        It "Should accept expanded Taskbar and Start registry categories" {
            $spec = @{
                Registry = @{
                    Taskbar = @{ Alignment = "left"; ShowTaskViewButton = $false }
                    Start   = @{ ShowRecommendations = $false; ShowRecentlyAddedApps = $true }
                }
            }

            $result = Test-SpecSchema -Spec $spec
            $result | Should -BeTrue
        }
    }
}
