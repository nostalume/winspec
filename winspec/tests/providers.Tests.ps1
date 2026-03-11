# tests/providers.Tests.ps1 - Tests for provider modules with mocked system operations

BeforeAll {
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\schema.psm1" -Force
}

Describe "Registry Provider" {
    BeforeAll {
        # Import only the registry module for this test block
        Import-Module "$PSScriptRoot\..\managers\registry.psm1" -Force
        
        # Mock registry operations within the module scope
        Mock Get-ItemProperty -ModuleName registry { 
            param($Path, $Name)
            switch ($Name) {
                "Hidden" { return @{ Hidden = 1 } }  # $true = 1 per registry-maps
                "HideFileExt" { return @{ HideFileExt = 0 } }  # $true = 0 per registry-maps
                "EnableClipboardHistory" { return @{ EnableClipboardHistory = 1 } }
                "AppsUseLightTheme" { return @{ AppsUseLightTheme = 0 } }
                "TestProp" { return @{ TestProp = 1 } }
                default { return @{ $Name = 1 } }
            }
        } -Verifiable
        Mock Set-ItemProperty -ModuleName registry { }
        Mock New-Item -ModuleName registry { return @{ FullName = "MockPath" } }
        Mock Test-Path -ModuleName registry { return $true }
    }
    
    Context "Get-ProviderInfo" {
        It "Should return correct provider info" {
            $info = Get-ProviderInfo
            $info.Name | Should -Be "Registry"
            $info.Type | Should -Be "Declarative"
        }
    }
    
    Context "Get-RegistryValue" {
        It "Should return registry value" {
            $result = Get-RegistryValue -Path "HKCU:\Test" -Property "TestProp" -Default 0
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should return default for missing key" {
            Mock Get-ItemProperty -ModuleName registry { return $null }
            $result = Get-RegistryValue -Path "HKCU:\Missing" -Property "Test" -Default "default"
            $result | Should -Be "default"
        }
    }
    
    Context "Test-RegistryState" {
        It "Should return true when in desired state" {
            $desired = @{
                Explorer = @{ ShowHidden = $true }
            }
            
            $result = Test-RegistryState -Desired $desired
            $result | Should -Be $true
        }
        
        It "Should return false when not in desired state" {
            $desired = @{
                Explorer = @{ ShowHidden = $false }
            }
            
            $result = Test-RegistryState -Desired $desired
            $result | Should -Be $false
        }
    }
    
    Context "Set-RegistryState" {
        It "Should apply registry changes" {
            $desired = @{
                Explorer = @{ ShowHidden = $false }
            }
            
            $result = Set-RegistryState -Desired $desired
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should handle WhatIf correctly" {
            $desired = @{
                Explorer = @{ ShowHidden = $false }
            }
            
            # ShouldProcess will prevent actual changes
            $result = Set-RegistryState -Desired $desired -WhatIf
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Service Provider" {
    BeforeAll {
        # Import only the service module for this test block
        Import-Module "$PSScriptRoot\..\managers\service.psm1" -Force
        
        # Mock service operations within the module scope
        # OPTIMIZATION: Get-Service now returns both Status and StartType - no WMI needed
        # Handle both: called with Name (single service) and without params (all services)
        Mock Get-Service -ModuleName service { 
            param($Name)
            if ($Name) {
                # Single service query
                return [PSCustomObject]@{ 
                    Status = "Running"
                    Name = $Name
                    StartType = "Automatic"
                }
            }
            else {
                # All services query (for Get-AllServiceStates)
                return @(
                    [PSCustomObject]@{ 
                        Status = "Running"
                        Name = "wuauserv"
                        StartType = "Automatic"
                    }
                )
            }
        }
        # Get-WmiObject is no longer used - removed mock
        Mock Set-Service -ModuleName service { }
        Mock Start-Service -ModuleName service { }
        Mock Stop-Service -ModuleName service { }
    }
    
    Context "Get-ProviderInfo" {
        It "Should return correct provider info" {
            $info = Get-ProviderInfo
            $info.Name | Should -Be "Service"
            $info.Type | Should -Be "Declarative"
        }
    }
    
    Context "Get-ServiceState" {
        It "Should return service state" {
            $result = Get-ServiceState -ServiceName "wuauserv"
            $result | Should -Not -BeNullOrEmpty
            $result.State | Should -Be "running"
            $result.Startup | Should -Be "automatic"
        }
    }
    
    Context "Test-ServiceState" {
        It "Should return true when in desired state" {
            $desired = @{
                "wuauserv" = @{ State = "running"; Startup = "automatic" }
            }
            
            $result = Test-ServiceState -Desired $desired
            $result | Should -Be $true
        }
        
        It "Should return false when not in desired state" {
            $desired = @{
                "wuauserv" = @{ State = "stopped" }
            }
            
            $result = Test-ServiceState -Desired $desired
            $result | Should -Be $false
        }
    }
    
    Context "Set-ServiceState" {
        It "Should apply service changes" {
            $desired = @{
                "wuauserv" = @{ State = "stopped"; Startup = "disabled" }
            }
            
            $result = Set-ServiceState -Desired $desired
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Feature Provider" {
    BeforeAll {
        # Import only the feature module for this test block
        Import-Module "$PSScriptRoot\..\managers\feature.psm1" -Force
        
        # Mock Windows feature operations within the module scope
        Mock Get-WindowsOptionalFeature -ModuleName feature { 
            param($FeatureName)
            return [PSCustomObject]@{ 
                State = "Enabled"
                FeatureName = $FeatureName
            }
        }
        Mock Enable-WindowsOptionalFeature -ModuleName feature { }
        Mock Disable-WindowsOptionalFeature -ModuleName feature { }
    }
    
    Context "Get-ProviderInfo" {
        It "Should return correct provider info" {
            $info = Get-ProviderInfo
            $info.Name | Should -Be "Feature"
            $info.Type | Should -Be "Declarative"
        }
    }
    
    Context "Get-FeatureState" {
        It "Should return feature state" {
            $result = Get-FeatureState -FeatureName "Microsoft-Windows-Subsystem-Linux"
            $result | Should -Be "Enabled"
        }
    }
    
    Context "Test-FeatureState" {
        It "Should return true when in desired state" {
            $desired = @{
                "Microsoft-Windows-Subsystem-Linux" = "enabled"
            }
            
            $result = Test-FeatureState -Desired $desired
            $result | Should -Be $true
        }
        
        It "Should return false when not in desired state" {
            $desired = @{
                "Microsoft-Windows-Subsystem-Linux" = "disabled"
            }
            
            $result = Test-FeatureState -Desired $desired
            $result | Should -Be $false
        }
    }
    
    Context "Set-FeatureState" {
        It "Should apply feature changes" {
            $desired = @{
                "VirtualMachinePlatform" = "enabled"
            }
            
            $result = Set-FeatureState -Desired $desired
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Package Provider" {
    BeforeAll {
        # Import only the package module for this test block
        Import-Module "$PSScriptRoot\..\managers\scoop.psm1" -Force
    }
    
    Context "Get-ProviderInfo" {
        It "Should return correct provider info" {
            $info = Get-ProviderInfo
            $info.Name | Should -Be "Scoop"
            $info.Type | Should -Be "Declarative"
        }
    }
    
    Context "Test-ScoopInstalled" {
        It "Should return true when Scoop is installed" {
            Mock Get-Command -ModuleName package { 
                return [PSCustomObject]@{ Name = "scoop" }
            }
            
            Test-ScoopInstalled | Should -Be $true
        }
        
        It "Should throw error when Scoop is not installed" {
            Mock Get-Command -ModuleName package { return $null }
            
            { Test-ScoopInstalled } | Should -Throw
        }
    }
    
    Context "Get-ScoopExport" {
        It "Should parse scoop export JSON correctly" {
            $mockJson = @'
{
    "buckets": [
        {"name": "main", "source": "https://github.com/ScoopInstaller/Main"}
    ],
    "apps": [
        {"name": "git", "version": "2.42.0", "bucket": "main", "architecture": "64bit"},
        {"name": "neovim", "version": "0.9.0", "bucket": "main", "architecture": "64bit"}
    ]
}
'@
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package { return $mockJson }
            
            $result = Get-ScoopExport
            $result.apps | Should -HaveCount 2
            $result.buckets | Should -HaveCount 1
            $result.apps[0].name | Should -Be "git"
        }
        
        It "Should handle empty export" {
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package { return "{}" }
            
            $result = Get-ScoopExport
            $result.apps | Should -HaveCount 0
            $result.buckets | Should -HaveCount 0
        }
    }
    
    Context "Get-InstalledPackages" {
        It "Should return list of installed package names" {
            $mockJson = @'
{
    "buckets": [],
    "apps": [
        {"name": "git", "version": "2.42.0"},
        {"name": "neovim", "version": "0.9.0"}
    ]
}
'@
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package { return $mockJson }
            
            $result = Get-InstalledPackages
            $result | Should -HaveCount 2
            $result | Should -Contain "git"
            $result | Should -Contain "neovim"
        }
    }
    
    Context "Get-PackageInfo" {
        It "Should return package metadata" {
            $mockJson = @'
{
    "buckets": [],
    "apps": [
        {"name": "git", "version": "2.42.0", "bucket": "main", "architecture": "64bit"}
    ]
}
'@
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package { return $mockJson }
            
            $result = Get-PackageInfo -PackageName "git"
            $result | Should -Not -BeNullOrEmpty
            $result.name | Should -Be "git"
            $result.version | Should -Be "2.42.0"
        }
    }
    
    Context "Test-PackageState" {
        BeforeEach {
            $mockJson = @'
{
    "buckets": [],
    "apps": [
        {"name": "git", "version": "2.42.0"},
        {"name": "neovim", "version": "0.9.0"}
    ]
}
'@
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package { return $mockJson }
        }
        
        It "Should return true when all packages installed" {
            $desired = @{
                Installed = @("git")
            }
            
            $result = Test-PackageState -Desired $desired
            $result | Should -Be $true
        }
        
        It "Should return true when all packages installed (multiple)" {
            $desired = @{
                Installed = @("git", "neovim")
            }
            
            $result = Test-PackageState -Desired $desired
            $result | Should -Be $true
        }
        
        It "Should return false when package missing" {
            $desired = @{
                Installed = @("git", "missing-package")
            }
            
            $result = Test-PackageState -Desired $desired
            $result | Should -Be $false
        }
        
        It "Should return true when no packages specified" {
            $desired = @{}
            
            $result = Test-PackageState -Desired $desired
            $result | Should -Be $true
        }
    }
    
    Context "Set-PackageState" {
        BeforeEach {
            $mockJson = @'
{
    "buckets": [],
    "apps": [
        {"name": "git", "version": "2.42.0"}
    ]
}
'@
            Mock Get-Command -ModuleName package { return [PSCustomObject]@{ Name = "scoop" } }
            Mock Invoke-ScoopCommand -ModuleName package {
                param($Command, $Arguments)
                if ($Command -eq "export") { return $mockJson }
                return $null
            }
        }
        
        It "Should skip already installed packages" {
            $desired = @{
                Installed = @("git")
            }
            
            $result = Set-PackageState -Desired $desired
            $result["git"].Status | Should -Be "AlreadyInstalled"
        }
        
        It "Should mark packages for installation when not present" {
            $desired = @{
                Installed = @("new-package")
            }
            
            $result = Set-PackageState -Desired $desired -WhatIf
            $result["new-package"].Status | Should -Be "DryRun"
        }
        
        It "Should return error when Scoop is not installed" {
            Mock Get-Command -ModuleName package { return $null }
            
            $desired = @{
                Installed = @("git")
            }
            
            $result = Set-PackageState -Desired $desired
            $result["Scoop"].Status | Should -Be "Error"
        }
    }
}
