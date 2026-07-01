# Provider-Specific Integration Tests
# Tests for individual provider modules

BeforeAll {
    # Import core modules directly (do NOT dot-source winspec.ps1)
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    
    Import-Module (Join-Path $winspecRoot "logging.psm1")                  -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1")                    -Force -Global
    Import-Module (Join-Path $winspecRoot "schema.psm1")                   -Force -Global
    Import-Module (Join-Path $winspecRoot "state.psm1")                    -Force -Global
    Import-Module (Join-Path $winspecRoot "sandbox.psm1")                  -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "registry.psm1")      -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "feature.psm1")       -Force -Global
    Import-Module (Join-Path $winspecRoot "managers" "service.psm1")       -Force -Global
}

Describe "Registry Provider" {
    Context "Provider contract" {
        It "Should export sandbox apply function used by manager dispatcher" {
            Get-Command Invoke-RegistrySandboxApply -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should expose registry map metadata and allowed values" {
            InModuleScope registry {
                $maps = Get-RegistryMaps

                $maps.Explorer.Description | Should -Not -BeNullOrEmpty
                $maps.Explorer.Scope | Should -Be "HKCU"
                $maps.Explorer.Properties.ShowHidden.AllowedValues | Should -Contain $true
                $maps.Theme.Properties.AppTheme.AllowedValues | Should -Contain "dark"
                $maps.Taskbar.Properties.Alignment.AllowedValues | Should -Contain "left"
                $maps.Start.Properties.ShowRecommendations.AllowedValues | Should -Contain $false
            }
        }
    }

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
    Context "Provider contract" {
        It "Should export sandbox apply function used by manager dispatcher" {
            Get-Command Invoke-FeatureSandboxApply -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

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

    Context "Compare-FeatureState" {
        It "Should not report a diff when desired lowercase state matches exported Windows state" {
            InModuleScope feature {
                $diffs = Compare-FeatureState `
                    -System @{ TestFeature = "Enabled" } `
                    -Desired @{ TestFeature = "enabled" }

                $diffs | Should -BeNullOrEmpty
            }
        }

        It "Should not report omitted system features as removed in sparse desired specs" {
            InModuleScope feature {
                $diffs = Compare-FeatureState `
                    -System @{ TestFeature = "Enabled"; UnmanagedFeature = "Disabled" } `
                    -Desired @{ TestFeature = "enabled" }

                $diffs | Should -BeNullOrEmpty
            }
        }
    }

    Context "Test-FeatureState" {
        It "Should return false when a desired feature is missing from exported state" {
            InModuleScope feature {
                Mock Export-FeatureState { return @{} }

                $result = Test-FeatureState -Desired @{ MissingFeature = "enabled" }

                $result | Should -BeFalse
            }
        }
    }
}

Describe "Service Provider" {
    Context "Provider contract" {
        It "Should export sandbox apply function used by manager dispatcher" {
            Get-Command Invoke-ServiceSandboxApply -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

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

        It "Should accept lowercase spec values for Windows-cased service state" {
            InModuleScope service {
                Mock Get-Service {
                    return [PSCustomObject]@{
                        Name      = "TestService"
                        Status    = "Running"
                        StartType = "Automatic"
                    }
                }

                $desired = @{ TestService = @{ State = "running"; Startup = "automatic" } }
                $result = Test-ServiceState -Desired $desired
                $result | Should -BeTrue
            }
        }

        It "Should return false when a desired service is missing" {
            InModuleScope service {
                Mock Get-Service { return @() }

                $result = Test-ServiceState -Desired @{ MissingService = @{ State = "running" } }

                $result | Should -BeFalse
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
                Mock Test-IsAdmin { return $true }
            }
            
            { Set-ServiceState -Desired @{ TestService = @{ State = "Running" } } -WhatIf } | Should -Not -Throw
        }
    }

    Context "Compare-ServiceState" {
        It "Should treat lowercase desired values as equal to Windows-cased service state" {
            InModuleScope service {
                $system = @{ TestService = @{ State = "Running"; Startup = "Automatic" } }
                $desired = @{ TestService = @{ State = "running"; Startup = "automatic" } }
                $diffs = Compare-ServiceState -System $system -Desired $desired

                @($diffs).Count | Should -Be 1
                @($diffs)[0].Type | Should -Be "Equal"
            }
        }

        It "Should emit leaf rows for changed service fields" {
            InModuleScope service {
                $system = @{ TestService = @{ State = "Stopped"; Startup = "Manual" } }
                $desired = @{ TestService = @{ State = "running"; Startup = "automatic" } }
                $diffs = @(Compare-ServiceState -System $system -Desired $desired)

                $diffs.Count | Should -Be 2
                $diffs.Path | Should -Contain "Service.TestService.State"
                $diffs.Path | Should -Contain "Service.TestService.Startup"
            }
        }

        It "Should not report omitted system services as removed in sparse desired specs" {
            InModuleScope service {
                $system = @{
                    TestService = @{ State = "Running"; Startup = "Automatic" }
                    OtherService = @{ State = "Stopped"; Startup = "Manual" }
                }
                $desired = @{ TestService = @{ State = "running"; Startup = "automatic" } }
                $diffs = @(Compare-ServiceState -System $system -Desired $desired)

                $diffs | Where-Object Type -eq "Removed" | Should -BeNullOrEmpty
            }
        }
    }
}

Describe "Sandbox Engine" {
    BeforeEach {
        InModuleScope sandbox -Parameters @{ Root = (Join-Path $TestDrive "sandbox") } {
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

    It "Should hydrate sandbox mode from persisted context" {
        InModuleScope sandbox {
            Enter-Sandbox -Mode Mock | Out-Null
            $Script:SandboxContext = $null

            Get-SandboxMode | Should -Be "Mock"
        }
    }

    It "Should persist sandbox state mutations before exit" {
        InModuleScope sandbox {
            Enter-Sandbox -Mode Mock | Out-Null
            Update-SandboxState "Feature" { param($state) $state.TestFeature = "enabled"; return $state }
            $Script:SandboxContext = $null

            $state = Get-SandboxState -Provider "Feature"
            $state.TestFeature | Should -Be "enabled"
        }
    }

    It "Should seed registry mock state with public spec keys" {
        InModuleScope sandbox {
            $state = New-SandboxState

            $state.Registry.Explorer.ContainsKey("ShowFileExt") | Should -BeTrue
            $state.Registry.Explorer.ContainsKey("HideFileExt") | Should -BeFalse
        }
    }

    It "Should simulate both service state and startup in sandbox" {
        InModuleScope service {
            Mock Test-SandboxActive { $true }
        }
        InModuleScope sandbox {
            Enter-Sandbox -Mode Mock | Out-Null
        }

        InModuleScope service {
            Invoke-ServiceSandbox -Desired @{ TestService = @{ State = "running"; Startup = "automatic" } } | Out-Null
        }

        InModuleScope sandbox {
            $state = Get-SandboxState -Provider "Service"
            $state.TestService.State | Should -Be "running"
            $state.TestService.Startup | Should -Be "automatic"
        }
    }
}
