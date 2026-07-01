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
        
        It "Should return DryRun for Method with WhatIf" {
            $result = Invoke-ActTrigger -Method "KMS38" -WhatIf
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should return DryRun for Office method with WhatIf" {
            $result = Invoke-ActTrigger -Method "Office" -WhatIf
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
            $result = Invoke-DebTrigger -Silent -WhatIf
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
            $result = Invoke-OffTrigger -Path "C:\Test" -WhatIf
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

        It "Should select triggers from spec and splat TriggerConfig into typed parameters" {
            $root = Join-Path $TestDrive "trigger-splat"
            $triggerDir = Join-Path $root "triggers"
            New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
            @'
function Get-ProviderInfo { @{ Name = "sample"; Type = "Trigger" } }
function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Silent, [string]$Mode = "default")
    @{ Status = "Success"; Silent = [bool]$Silent; Mode = $Mode }
}
Export-ModuleMember -Function Get-ProviderInfo, Invoke-Trigger
'@ | Set-Content -Path (Join-Path $triggerDir "sample.psm1")

            $config = @{
                Trigger = @("sample")
                TriggerConfig = @{
                    sample = @{ Silent = $true; Mode = "fast" }
                }
            }

            $result = Invoke-Triggers -Config $config -Triggers $null -ConfigPath $root

            $result.sample.Status | Should -Be "Success"
            $result.sample.Silent | Should -BeTrue
            $result.sample.Mode | Should -Be "fast"
        }

        It "Should keep Invoke-Trigger command identity per module" {
            $root = Join-Path $TestDrive "trigger-collision"
            $triggerDir = Join-Path $root "triggers"
            New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null

            foreach ($name in @("alpha", "beta")) {
                @"
function Get-ProviderInfo { @{ Name = "$name"; Type = "Trigger" } }
function Invoke-Trigger { [CmdletBinding()] param() @{ Status = "Success"; Trigger = "$name" } }
Export-ModuleMember -Function Get-ProviderInfo, Invoke-Trigger
"@ | Set-Content -Path (Join-Path $triggerDir "$name.psm1")
            }

            $result = Invoke-Triggers -Config @{ Trigger = @("alpha", "beta") } -Triggers $null -ConfigPath $root

            $result.alpha.Trigger | Should -Be "alpha"
            $result.beta.Trigger | Should -Be "beta"
        }

        It "Should forward WhatIf to trigger command" {
            $root = Join-Path $TestDrive "trigger-whatif"
            $triggerDir = Join-Path $root "triggers"
            New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
            @'
function Get-ProviderInfo { @{ Name = "guarded"; Type = "Trigger" } }
function Invoke-Trigger {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if ($PSCmdlet.ShouldProcess("guarded", "execute")) { return @{ Status = "Executed" } }
    @{ Status = "DryRun" }
}
Export-ModuleMember -Function Get-ProviderInfo, Invoke-Trigger
'@ | Set-Content -Path (Join-Path $triggerDir "guarded.psm1")

            $result = Invoke-Triggers -Config @{ Trigger = @("guarded") } -Triggers $null -ConfigPath $root -WhatIf

            $result.guarded.Status | Should -Be "DryRun"
        }
    }
}
