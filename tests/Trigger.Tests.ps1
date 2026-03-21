# Trigger-Specific Integration Tests
# Tests for trigger provider functionality

BeforeAll {
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    
    Import-Module (Join-Path $winspecRoot "logging.psm1") -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1")    -Force -Global
    Import-Module (Join-Path $winspecRoot "schema.psm1")   -Force -Global
    Import-Module (Join-Path $winspecRoot "state.psm1")    -Force -Global
}

# Each trigger module exports a function called Invoke-Trigger (same name in all three).
# Load each in isolation using -Prefix to avoid name collision.

Describe "Activation Trigger" {
    BeforeAll {
        $activationPath = Join-Path $PSScriptRoot ".." "winspec" "triggers" "activation.psm1"
        Import-Module $activationPath -Force -Global -Prefix "Act"
    }
    
    Context "Invoke-ActTrigger" {
        It "Should return DryRun result with WhatIf" {
            $result = Invoke-ActTrigger -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should return DryRun for Windows option with WhatIf" {
            $result = Invoke-ActTrigger -Option "Windows" -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should return DryRun for Office option with WhatIf" {
            $result = Invoke-ActTrigger -Option "Office" -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
    }
}

Describe "Debloat Trigger" {
    BeforeAll {
        $debloatPath = Join-Path $PSScriptRoot ".." "winspec" "triggers" "debloat.psm1"
        Import-Module $debloatPath -Force -Global -Prefix "Deb"
    }
    
    Context "Invoke-DebTrigger" {
        It "Should return DryRun result with WhatIf" {
            $result = Invoke-DebTrigger -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should return DryRun for silent option with WhatIf" {
            $result = Invoke-DebTrigger -Option @{ Silent = $true } -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
    }
}

Describe "Office Trigger" {
    BeforeAll {
        $officePath = Join-Path $PSScriptRoot ".." "winspec" "triggers" "office.psm1"
        Import-Module $officePath -Force -Global -Prefix "Off"
    }
    
    Context "Invoke-OffTrigger" {
        It "Should return DryRun result with WhatIf" {
            $result = Invoke-OffTrigger -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should return DryRun for custom path with WhatIf" {
            $result = Invoke-OffTrigger -Option "C:\Test" -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
    }
}

Describe "Trigger Execution" {
    Context "Invoke-Triggers" {
        It "Should return a hashtable when no triggers configured" {
            # Invoke-Triggers returns @{} (empty) when Triggers is null - empty hashtable is valid
            InModuleScope state {
                $result = Invoke-Triggers -Config @{} -Triggers $null
                $result -is [hashtable] | Should -BeTrue
            }
        }
        
        It "Should return a hashtable when triggers list is empty array" {
            InModuleScope state {
                $result = Invoke-Triggers -Config @{} -Triggers @()
                $result -is [hashtable] | Should -BeTrue
            }
        }
    }
}
