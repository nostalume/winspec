# tests/schema.Tests.ps1 - Tests for schema module (no system changes)

BeforeAll {
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\schema.psm1" -Force
}

Describe "Get-RegistryMaps" {
    It "Should return registry maps" {
        $maps = Get-RegistryMaps
        $maps | Should -Not -BeNullOrEmpty
    }
    
    It "Should contain expected categories" {
        $maps = Get-RegistryMaps
        $maps.Keys | Should -Contain "Clipboard"
        $maps.Keys | Should -Contain "Explorer"
        $maps.Keys | Should -Contain "Theme"
    }
    
    It "Should return specific category when requested" {
        $explorer = Get-RegistryMaps -Category "Explorer"
        $explorer | Should -Not -BeNullOrEmpty
        $explorer.Path | Should -Be "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    }
}

Describe "Get-SpecSchema" {
    It "Should return specification schema" {
        $schema = Get-SpecSchema
        $schema | Should -Not -BeNullOrEmpty
    }
    
    It "Should contain expected keys" {
        $schema = Get-SpecSchema
        $schema.Keys | Should -Contain "Name"
        $schema.Keys | Should -Contain "Registry"
        $schema.Keys | Should -Contain "Scoop"
        $schema.Keys | Should -Contain "Winget"
        $schema.Keys | Should -Contain "Service"
        $schema.Keys | Should -Contain "Feature"
        $schema.Keys | Should -Contain "Trigger"
    }
}

Describe "Test-SpecSchema" {
    It "Should validate correct specification" {
        $validSpec = @{
            Name = "test"
            Registry = @{
                Explorer = @{ ShowHidden = $true }
            }
            Scoop = @{
                Installed = @("git", "nodejs")
            }
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should reject unknown registry category" {
        $invalidSpec = @{
            Registry = @{
                UnknownCategory = @{ SomeProp = $true }
            }
        }
        
        Test-SpecSchema -Config $invalidSpec | Should -Be $false
    }
    
    It "Should reject invalid feature value" {
        $invalidSpec = @{
            Feature = @{
                "SomeFeature" = "invalid"
            }
        }
        
        Test-SpecSchema -Config $invalidSpec | Should -Be $false
    }
    
    It "Should accept valid feature values" {
        $validSpec = @{
            Feature = @{
                "TestFeature" = "enabled"
            }
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should reject invalid service state" {
        $invalidSpec = @{
            Service = @{
                "TestService" = @{ State = "invalid" }
            }
        }
        
        Test-SpecSchema -Config $invalidSpec | Should -Be $false
    }
    
    It "Should accept valid service configuration" {
        $validSpec = @{
            Service = @{
                "TestService" = @{ 
                    State = "stopped"
                    Startup = "disabled"
                }
            }
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should reject non-array trigger format" {
        $invalidSpec = @{
            Trigger = @{
                Name = "Activation"
            }
        }
        
        Test-SpecSchema -Config $invalidSpec | Should -Be $false
    }
    
    It "Should accept valid trigger array format" {
        $validSpec = @{
            Trigger = @(
                @{ Name = "Activation" }
                @{ Name = "Debloat"; Value = "silent" }
                @{ Name = "Office"; Value = "C:\Installers" }
            )
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should accept triggers with Path field" {
        $validSpec = @{
            Trigger = @(
                @{ Name = "my-trigger"; Path = ".\triggers\my-trigger.ps1" }
            )
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should accept triggers with Enabled field" {
        $validSpec = @{
            Trigger = @(
                @{ Name = "Activation"; Enabled = $false }
            )
        }
        
        Test-SpecSchema -Config $validSpec | Should -Be $true
    }
    
    It "Should reject trigger entry without Name field" {
        $invalidSpec = @{
            Trigger = @(
                @{ Value = "test" }  # Missing Name
            )
        }
        
        Test-SpecSchema -Config $invalidSpec | Should -Be $false
    }
}

# Note: Get-ProviderMetadata function has been removed from schema.psm1
# Provider metadata is now handled by individual provider modules via Get-ProviderInfo
# See individual provider tests in providers.Tests.ps1 and triggers.Tests.ps1
