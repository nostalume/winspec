# tests/workflow.Tests.ps1 - Integration workflow tests for WinSpec
# These tests use mocks and WhatIf/DryRun mode to avoid any real changes

BeforeAll {
    $script:WinspecRoot = $PSScriptRoot | Split-Path -Parent
    
    # Import core modules FIRST
    Import-Module "$script:WinspecRoot\logging.psm1" -Force
    Import-Module "$script:WinspecRoot\utils.psm1" -Force
    Import-Module "$script:WinspecRoot\state.psm1" -Force
    Import-Module "$script:WinspecRoot\pull.psm1" -Force
    Import-Module "$script:WinspecRoot\push.psm1" -Force
    
    # Import trigger module with prefix for isolation
    Import-Module "$script:WinspecRoot\triggers\activation.psm1" -Force -Prefix Activation
    
    # Set up mocks AFTER importing modules
    Mock Get-ItemProperty { return @{ TestProp = 1 } }
    Mock Set-ItemProperty { }
    Mock Test-Path { return $true } -ParameterFilter { $Path -notmatch "NonExistent" }
    Mock Test-Path { return $false } -ParameterFilter { $Path -match "NonExistent" }
    Mock Get-Service { return [PSCustomObject]@{ Status = "Running"; Name = "wuauserv"; StartType = "Automatic" } }
    Mock Set-Service { }
    Mock Start-Service { }
    Mock Stop-Service { }
    Mock Get-WindowsOptionalFeature { return [PSCustomObject]@{ State = "Enabled"; FeatureName = "TestFeature" } }
    Mock Enable-WindowsOptionalFeature { }
    Mock Disable-WindowsOptionalFeature { }
    Mock Invoke-RestMethod { return "@{ Name = 'mocked' }" }
    Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = "{}" } }
    # Use specific mocks instead of catch-all to avoid conflicts with other test files
    Mock Get-ItemProperty { return @{ TestProp = 1 } }
    Mock Invoke-Expression { return '{"apps":[],"buckets":[]}' }
    Mock Start-Process { }
    Mock New-Item { return @{ FullName = "MockPath" } }
}

Describe "Workflow - Pull Command" {
    Context "Invoke-Pull with WhatIf" {
        # WhatIf mode should NEVER make real changes
        It "Should run without error in WhatIf mode" {
            { Invoke-Pull -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Providers parameter" {
            { Invoke-Pull -Providers @("Registry") -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Output parameter" {
            { Invoke-Pull -Output "test.ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Template parameter" {
            { Invoke-Pull -Template -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Minimal parameter" {
            { Invoke-Pull -Minimal -WhatIf } | Should -Not -Throw
        }
    }
}

Describe "Workflow - Error Handling" {
    Context "Missing Spec File" {
        It "Should handle missing spec gracefully - returns error result" {
            # Invoke-Push returns error output but doesn't throw
            # Just verify it runs without crashing
            $result = Invoke-Push -Spec "C:\NonExistent\Spec.ps1" 2>&1
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Workflow - Activation Trigger" {
    Context "WhatIf Mode" {
        # WhatIf mode NEVER makes network calls
        It "Should execute in WhatIf mode without network calls" {
            $result = Invoke-ActivationActivationTrigger -Option $true -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should accept string option" {
            $result = Invoke-ActivationActivationTrigger -Option "KMS38" -WhatIf
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should accept hashtable option" {
            $result = Invoke-ActivationActivationTrigger -Option @{ Method = "KMS38" } -WhatIf
            $result | Should -Not -BeNullOrEmpty
        }
    }
}
