# tests/cli.Tests.ps1 - Tests for WinSpec CLI commands
# Focuses on parameter validation and basic function availability

BeforeAll {
    $script:WinspecRoot = $PSScriptRoot | Split-Path -Parent
    
    # Import core modules
    Import-Module "$script:WinspecRoot\logging.psm1" -Force
    Import-Module "$script:WinspecRoot\utils.psm1" -Force
    Import-Module "$script:WinspecRoot\pull.psm1" -Force
    Import-Module "$script:WinspecRoot\push.psm1" -Force
    
    # Mock all system operations to prevent real changes
    Mock Get-ItemProperty { return @{ TestProp = 1 } }
    Mock Set-ItemProperty { }
    Mock Test-Path { return $true } -ParameterFilter { $Path -notmatch "NonExistent" }
    Mock Test-Path { return $false } -ParameterFilter { $Path -match "NonExistent" }
    Mock Get-Service { return [PSCustomObject]@{ Status = "Running"; Name = "TestSvc"; StartType = "Automatic" } }
    Mock Set-Service { }
    Mock Get-WindowsOptionalFeature { return [PSCustomObject]@{ State = "Enabled"; FeatureName = "TestFeature" } }
    Mock Get-Command { return $null }
    Mock Invoke-RestMethod { return "@{ Name = 'test' }" }
    Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200 } }
}

Describe "CLI - Pull Command Parameter Tests" {
    Context "Invoke-Pull Parameters" {
        It "Should accept -Output parameter" {
            { Invoke-Pull -Output "test.ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Providers parameter" {
            { Invoke-Pull -Providers @("Registry") -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Format ps1 parameter" {
            { Invoke-Pull -Format "ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Format json parameter" {
            { Invoke-Pull -Format "json" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -WhatIf parameter" {
            { Invoke-Pull -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Interactive parameter" {
            { Invoke-Pull -Interactive -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Template parameter" {
            { Invoke-Pull -Template -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Minimal parameter" {
            { Invoke-Pull -Minimal -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Name parameter" {
            { Invoke-Pull -Name "Test Config" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept -Description parameter" {
            { Invoke-Pull -Description "Test" -WhatIf } | Should -Not -Throw
        }
    }
}

Describe "CLI - Alias Tests" {
    Context "Export-SystemState Alias" {
        It "Should export Export-SystemState alias" {
            Get-Alias Export-SystemState -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Export-SystemState should point to Invoke-Pull" {
            $alias = Get-Alias Export-SystemState
            $alias.Definition | Should -Be "Invoke-Pull"
        }
    }
    
    Context "Apply-Configuration Alias" {
        It "Should export Apply-Configuration alias" {
            Get-Alias Apply-Configuration -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Apply-Configuration should point to Invoke-Push" {
            $alias = Get-Alias Apply-Configuration
            $alias.Definition | Should -Be "Invoke-Push"
        }
    }
}
