# pull.Tests.ps1 - Tests for pull.psm1 module

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot "..\pull.psm1"
    $ModuleRoot = Split-Path $ModulePath -Parent
    
    # Import required modules
    Import-Module (Join-Path $ModuleRoot "logging.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "state.psm1") -Force
    Import-Module (Join-Path $ModuleRoot "utils.psm1") -Force
    Import-Module $ModulePath -Force
}

Describe "Invoke-Pull" {
    Context "Parameter validation" {
        It "Should accept Output parameter" {
            { Invoke-Pull -Output "test.ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Providers parameter" {
            { Invoke-Pull -Providers @("Scoop") -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Spec parameter" {
            { Invoke-Pull -Spec "test.ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Format parameter" {
            { Invoke-Pull -Format "ps1" -WhatIf } | Should -Not -Throw
            { Invoke-Pull -Format "json" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept DryRun parameter (via WhatIf)" {
            { Invoke-Pull -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Interactive parameter" {
            { Invoke-Pull -Interactive -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Template parameter" {
            { Invoke-Pull -Template -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Minimal parameter" {
            { Invoke-Pull -Minimal -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Name parameter" {
            { Invoke-Pull -Name "Test Config" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Description parameter" {
            { Invoke-Pull -Description "Test description" -WhatIf } | Should -Not -Throw
        }
    }
    
    Context "Output path resolution" {
        It "Should resolve default output path" {
            # This test verifies path resolution works
            $result = Invoke-Pull -WhatIf
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Invoke-PullInteractive" {
    Context "Function existence" {
        It "Should have Invoke-PullInteractive function" {
            Get-Command Invoke-PullInteractive -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Invoke-PullMinimal" {
    Context "Function existence" {
        It "Should have Invoke-PullMinimal function" {
            Get-Command Invoke-PullMinimal -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Backward compatibility" {
    It "Should export Export-SystemState alias" {
        Get-Alias Export-SystemState -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    
    It "Export-SystemState should point to Invoke-Pull" {
        $alias = Get-Alias Export-SystemState
        $alias.Definition | Should -Be "Invoke-Pull"
    }
}
