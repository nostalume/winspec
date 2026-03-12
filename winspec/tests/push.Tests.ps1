# push.Tests.ps1 - Tests for push.psm1 module

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot "..\push.psm1"
    $ModuleRoot = Split-Path $ModulePath -Parent
    
    # Import required modules
    Import-Module (Join-Path $ModuleRoot "logging.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "utils.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "registry-maps.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "exec.psm1") -Force
    Import-Module $ModulePath -Force
}

Describe "Invoke-Push" {
    Context "Function existence" {
        It "Should have Invoke-Push function" {
            Get-Command Invoke-Push -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Parameter validation" {
        It "Should accept Spec parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'Spec'
        }
        
        It "Should accept ConfigPath parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'ConfigPath'
        }
        
        It "Should accept DryRun parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'DryRun'
        }
        
        It "Should accept Checkpoint parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'Checkpoint'
        }
        
        It "Should accept WithTriggers parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'WithTriggers'
        }
        
        It "Should accept Providers parameter" {
            $params = (Get-Command Invoke-Push).Parameters
            $params.Keys | Should -Contain 'Providers'
        }
    }
    
    Context "Backward compatibility alias" {
        It "Should have Apply-Configuration alias" {
            Get-Alias Apply-Configuration -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

# End of tests
