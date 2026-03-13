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
        
        It "Should accept Providers parameter with Winget" {
            { Invoke-Pull -Providers @("Winget") -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept multiple Providers parameter" {
            { Invoke-Pull -Providers @("Scoop", "Winget") -WhatIf } | Should -Not -Throw
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

Describe "Invoke-Pull with Interactive parameter" {
    Context "Functionality" {
        It "Should accept Interactive parameter" {
            # Interactive parameter is part of Invoke-Pull function
            Get-Command Invoke-Pull | Should -Not -BeNullOrEmpty
            (Get-Command Invoke-Pull).Parameters.Keys | Should -Contain 'Interactive'
        }
    }
}

Describe "Invoke-Pull with Minimal parameter" {
    Context "Functionality" {
        It "Should accept Minimal parameter" {
            # Minimal parameter is part of Invoke-Pull function
            Get-Command Invoke-Pull | Should -Not -BeNullOrEmpty
            (Get-Command Invoke-Pull).Parameters.Keys | Should -Contain 'Minimal'
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
