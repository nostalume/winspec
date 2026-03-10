# push.Tests.ps1 - Tests for push.psm1 module

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot "..\push.psm1"
    $ModuleRoot = Split-Path $ModulePath -Parent
    
    # Import required modules
    Import-Module (Join-Path $ModuleRoot "logging.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "utils.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "exec.psm1") -Force
    Import-Module $ModulePath -Force
}

Describe "Invoke-Push" {
    Context "Parameter validation" {
        It "Should accept Spec parameter" {
            { Invoke-Push -Spec "test.ps1" -DryRun } | Should -Not -Throw
        }
        
        It "Should accept ConfigPath parameter" {
            { Invoke-Push -ConfigPath "." -DryRun } | Should -Not -Throw
        }
        
        It "Should accept DryRun parameter" {
            { Invoke-Push -DryRun } | Should -Not -Throw
        }
        
        It "Should accept Checkpoint parameter" {
            { Invoke-Push -Checkpoint -DryRun } | Should -Not -Throw
        }
        
        It "Should accept WithTriggers parameter" {
            { Invoke-Push -WithTriggers -DryRun } | Should -Not -Throw
        }
        
        It "Should accept Providers parameter" {
            { Invoke-Push -Providers @("Package") -DryRun } | Should -Not -Throw
        }
    }
    
    Context "Error handling" {
        It "Should handle missing spec file gracefully" {
            # Without a spec file, should fail
            { Invoke-Push } | Should -Throw
        }
    }
}

Describe "Backward compatibility" {
    It "Should export Apply-Configuration alias" {
        Get-Alias Apply-Configuration -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    
    It "Apply-Configuration should point to Invoke-Push" {
        $alias = Get-Alias Apply-Configuration
        $alias.Definition | Should -Be "Invoke-Push"
    }
}
