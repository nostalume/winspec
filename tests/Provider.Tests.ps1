# Provider-Specific Integration Tests
# Tests for individual provider modules

BeforeAll {
    # Import core modules directly (do NOT dot-source winspec.ps1)
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    
    Import-Module (Join-Path $winspecRoot "logging.psm1")                  -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1")                    -Force -Global
    Import-Module (Join-Path $winspecRoot "schema.psm1")                   -Force -Global
    Import-Module (Join-Path $winspecRoot "state.psm1")                    -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "registry.psm1")      -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "feature.psm1")       -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "service.psm1")       -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "scoop.psm1")         -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "winget.psm1")        -Force -Global
}

Describe "Registry Provider" {
    Context "Get-RegistryValue" {
        It "Should get registry value" {
            # Mock Get-ItemProperty inside the registry module scope
            InModuleScope registry {
                Mock Get-ItemProperty {
                    return [PSCustomObject]@{ TestValue = "TestData" }
                }
                
                $value = Get-RegistryValue -Path "HKCU:\Software\TestKey" -Property "TestValue"
                $value | Should -Be "TestData"
            }
        }
    }
    
    Context "Test-RegistryState" {
        It "Should test registry state with desired hashtable" {
            InModuleScope registry {
                # Use Desktop.MenuShowDelay which has no Map - plain string comparison
                Mock Get-RegistryMaps {
                    return @{
                        Desktop = @{
                            Path = "HKCU:\Control Panel\Desktop"
                            Properties = @{
                                MenuShowDelay = @{
                                    Name = "MenuShowDelay"
                                    Type = "String"
                                }
                            }
                        }
                    }
                }
                # Return the same value as desired so Test-RegistryState returns $true
                Mock Get-ItemProperty {
                    return [PSCustomObject]@{ MenuShowDelay = "400" }
                }
                
                $desired = @{ Desktop = @{ MenuShowDelay = "400" } }
                $result = Test-RegistryState -Desired $desired
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Set-RegistryValue" {
        It "Should set registry value without error" {
            InModuleScope registry {
                Mock Test-Path { return $true }
                Mock Set-ItemProperty { }
                
                { Set-RegistryValue -Path "HKCU:\Software\TestKey" -Property "TestValue" -Type "String" -Value "TestData" } | Should -Not -Throw
            }
        }
    }
}

Describe "Feature Provider" {
    Context "Get-FeatureState" {
        It "Should get feature state" {
            # Get-FeatureState calls Export-FeatureState; mock it in feature module scope
            InModuleScope feature {
                Mock Export-FeatureState {
                    return @{ TestFeature = "Enabled" }
                }
                
                $state = Get-FeatureState -FeatureName "TestFeature"
                $state | Should -Not -BeNullOrEmpty
                $state | Should -Be "Enabled"
            }
        }
    }
    
    Context "Test-FeatureState" {
        It "Should test feature state with desired hashtable" {
            InModuleScope feature {
                Mock Export-FeatureState {
                    return @{ TestFeature = "Enabled" }
                }
                
                $desired = @{ TestFeature = "enabled" }
                $result = Test-FeatureState -Desired $desired
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Set-FeatureState" {
        It "Should process feature state with WhatIf" {
            InModuleScope feature {
                Mock Export-FeatureState { return @{ TestFeature = "Disabled" } }
                Mock Invoke-AdminCommand { }
                
                { Set-FeatureState -Desired @{ TestFeature = "enabled" } -WhatIf } | Should -Not -Throw
            }
        }
    }
}

Describe "Service Provider" {
    Context "Get-ServiceState" {
        It "Should get service state" {
            InModuleScope service {
                Mock Get-Service {
                    return [PSCustomObject]@{
                        Name      = "TestService"
                        Status    = "Running"
                        StartType = "Automatic"
                    }
                }
                
                $state = Get-ServiceState -ServiceNames @("TestService")
                $state | Should -Not -BeNullOrEmpty
                $state.Keys | Should -Contain "TestService"
            }
        }
    }
    
    Context "Test-ServiceState" {
        It "Should test service state with desired hashtable" {
            InModuleScope service {
                Mock Get-Service {
                    return [PSCustomObject]@{
                        Name      = "TestService"
                        Status    = "Running"
                        StartType = "Automatic"
                    }
                }
                
                $desired = @{ TestService = @{ State = "Running"; Startup = "Automatic" } }
                $result = Test-ServiceState -Desired $desired
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Set-ServiceState" {
        It "Should process service state with WhatIf" {
            InModuleScope service {
                Mock Get-Service {
                    return [PSCustomObject]@{
                        Name      = "TestService"
                        Status    = "Stopped"
                        StartType = "Manual"
                    }
                }
                Mock Start-Service { }
                Mock Stop-Service { }
                Mock Set-Service { }
            }
            InModuleScope utils {
                Mock Test-IsAdmin { return $true }
            }
            
            { Set-ServiceState -Desired @{ TestService = @{ State = "Running" } } -WhatIf } | Should -Not -Throw
        }
    }
}

Describe "Scoop Provider" {
    Context "Test-ScoopInstalled" {
        It "Should return true when Scoop is installed" {
            InModuleScope scoop {
                Mock Get-Command { return [PSCustomObject]@{ Name = "scoop" } }
                
                $result = Test-ScoopInstalled
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Export-ScoopState" {
        It "Should export scoop state" {
            InModuleScope scoop {
                Mock Test-ScoopInstalled { return $true }
                Mock Invoke-ScoopCommand {
                    return '{"apps":[{"name":"git","version":"2.40.0","bucket":"main"}],"buckets":[{"name":"main","source":"https://github.com/ScoopInstaller/Main"}]}'
                }
                
                $state = Export-ScoopState
                $state | Should -Not -BeNullOrEmpty
            }
        }
    }
    
    Context "Test-ScoopState" {
        It "Should return true for installed package" {
            InModuleScope scoop {
                Mock Test-ScoopInstalled { return $true }
                Mock Invoke-ScoopCommand {
                    return '{"apps":[{"name":"git","version":"2.40.0","bucket":"main"}],"buckets":[]}'
                }
                
                $desired = @{ Installed = @("git") }
                $result = Test-ScoopState -Desired $desired
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Set-ScoopState" {
        It "Should return DryRun result with WhatIf" {
            InModuleScope scoop {
                Mock Test-ScoopInstalled { return $true }
                # Mock Get-InstalledScoopPackages to return empty list so package is not yet installed
                Mock Get-InstalledScoopPackages { return @() }
                
                $result = Set-ScoopState -Desired @{ Installed = @("newpkg") } -WhatIf
                $result | Should -Not -BeNullOrEmpty
                $result.Values | ForEach-Object { $_.Status | Should -Be "DryRun" }
            }
        }
    }
}

Describe "Winget Provider" {
    Context "Test-WingetInstalled" {
        It "Should return true when Winget is installed" {
            InModuleScope winget {
                Mock Get-Command { return [PSCustomObject]@{ Name = "winget" } }
                
                $result = Test-WingetInstalled
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Test-WingetState" {
        It "Should return true when no Installed packages desired" {
            InModuleScope winget {
                Mock Test-WingetInstalled { return $true }
                
                $desired = @{}
                $result = Test-WingetState -Desired $desired
                $result | Should -BeTrue
            }
        }
        
        It "Should return true when desired package is installed" {
            InModuleScope winget {
                Mock Test-WingetInstalled { return $true }
                Mock Get-WingetExport {
                    return @{
                        Packages = @( @{ Name = "Git.Git"; Source = "winget" } )
                        Sources  = @()
                    }
                }
                
                $desired = @{ Installed = @("Git.Git") }
                $result = Test-WingetState -Desired $desired
                $result | Should -BeTrue
            }
        }
    }
    
    Context "Set-WingetState" {
        It "Should return DryRun result with WhatIf" {
            InModuleScope winget {
                Mock Test-WingetInstalled { return $true }
                # Mock Get-InstalledWingetPackages to return empty list
                Mock Get-InstalledWingetPackages { return @() }
                
                $result = Set-WingetState -Desired @{ Installed = @("SomeNew.Package") } -WhatIf
                $result | Should -Not -BeNullOrEmpty
                $result.Values | ForEach-Object { $_.Status | Should -Be "DryRun" }
            }
        }
    }
}
