# Checkpoint and rollback safety tests for WinSpec

BeforeAll {
    $winspecRoot = Join-Path $PSScriptRoot ".." "winspec"
    Import-Module (Join-Path $winspecRoot "logging.psm1") -Force -Global
    Import-Module (Join-Path $winspecRoot "utils.psm1") -Force -Global
    Import-Module (Join-Path $winspecRoot "checkpoint.psm1") -Force -Global
}

Describe "Checkpoint Safety" {
    Context "New-Checkpoint" {
        It "Should not enable System Restore implicitly" {
            InModuleScope checkpoint {
                Mock Write-Log { }
                Mock Test-SystemRestoreEnabled { $false }
                Mock Enable-SystemRestore { throw "Enable-SystemRestore should not run from New-Checkpoint" }

                $result = New-Checkpoint -Name "WinSpec-Test"

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "SystemRestoreDisabled"
                Should -Invoke Enable-SystemRestore -Times 0 -Exactly
            }
        }

        It "Should refuse checkpoint creation without Administrator privileges" {
            InModuleScope checkpoint {
                Mock Write-Log { }
                Mock Test-SystemRestoreEnabled { $true }
                Mock Test-IsAdmin { $false }
                Mock Checkpoint-Computer { throw "Checkpoint-Computer should not run" }

                $result = New-Checkpoint -Name "WinSpec-Test"

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "RequiresAdministrator"
                Should -Invoke Checkpoint-Computer -Times 0 -Exactly
            }
        }

        It "Should return structured failure when checkpoint creation fails" {
            InModuleScope checkpoint {
                Mock Write-Log { }
                Mock Test-SystemRestoreEnabled { $true }
                Mock Test-IsAdmin { $true }
                Mock Checkpoint-Computer { throw "quota exceeded" }

                $result = New-Checkpoint -Name "WinSpec-Test"

                $result.Success | Should -BeFalse
                $result.Reason | Should -Be "CheckpointFailed"
                $result.Error | Should -Match "quota exceeded"
            }
        }
    }
}

Describe "Rollback Safety" {
    BeforeEach {
        $script:RestorePoints = @(
            [pscustomobject]@{ SequenceNumber = 10; Description = "Manual Restore"; CreationTime = [datetime]"2026-01-01" },
            [pscustomobject]@{ SequenceNumber = 20; Description = "WinSpec-old"; CreationTime = [datetime]"2026-01-02" },
            [pscustomobject]@{ SequenceNumber = 30; Description = "WinSpec-new"; CreationTime = [datetime]"2026-01-03" }
        )
    }

    It "Should select most recent WinSpec checkpoint for Last rollback" {
        InModuleScope checkpoint -Parameters @{ Points = $script:RestorePoints } {
            param($Points)
            Mock Write-Log { }
            Mock Test-SystemRestoreEnabled { $true }
            Mock Get-ComputerRestorePoint { $Points }
            Mock Restore-Computer { param($RestorePoint) $script:Restored = $RestorePoint }

            $result = Invoke-Rollback -Last -Confirm:$false

            $result.Success | Should -BeTrue
            $result.SequenceNumber | Should -Be 30
            Should -Invoke Restore-Computer -Times 1 -Exactly
        }
    }

    It "Should not call Restore-Computer under WhatIf" {
        InModuleScope checkpoint -Parameters @{ Points = $script:RestorePoints } {
            param($Points)
            Mock Write-Log { }
            Mock Test-SystemRestoreEnabled { $true }
            Mock Get-ComputerRestorePoint { $Points }
            Mock Restore-Computer { throw "Restore-Computer should not run under WhatIf" }

            $result = Invoke-Rollback -Last -WhatIf

            $result.Success | Should -BeFalse
            $result.Reason | Should -Be "WhatIf"
            $result.SequenceNumber | Should -Be 30
            Should -Invoke Restore-Computer -Times 0 -Exactly
        }
    }

    It "Should return structured failure when target restore point is missing" {
        InModuleScope checkpoint -Parameters @{ Points = $script:RestorePoints } {
            param($Points)
            Mock Write-Log { }
            Mock Test-SystemRestoreEnabled { $true }
            Mock Get-ComputerRestorePoint { $Points }

            $result = Invoke-Rollback -SequenceNumber 999

            $result.Success | Should -BeFalse
            $result.Reason | Should -Be "RestorePointNotFound"
        }
    }

    It "Should return structured failure when rollback target is omitted" {
        InModuleScope checkpoint -Parameters @{ Points = $script:RestorePoints } {
            param($Points)
            Mock Write-Log { }
            Mock Test-SystemRestoreEnabled { $true }
            Mock Get-ComputerRestorePoint { $Points }

            $result = Invoke-Rollback

            $result.Success | Should -BeFalse
            $result.Reason | Should -Be "RollbackTargetRequired"
        }
    }
}
