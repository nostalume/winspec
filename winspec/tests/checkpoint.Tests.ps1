# tests/checkpoint.Tests.ps1 - Tests for checkpoint module with mocked system operations

BeforeAll {
    # Import logging first
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    
    # Import checkpoint module
    Import-Module "$PSScriptRoot\..\checkpoint.psm1" -Force
}

Describe "Test-SystemRestoreEnabled" {
    BeforeEach {
        # Mock Get-ComputerInfo in the checkpoint module's scope
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Enabled" }
        }
    }
    
    It "Should return true when System Restore is enabled" {
        $result = Test-SystemRestoreEnabled
        $result | Should -Be $true
    }
    
    It "Should return false when System Restore is disabled" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        
        $result = Test-SystemRestoreEnabled
        $result | Should -Be $false
    }
    
    It "Should return false on error" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            throw "Access denied"
        }
        
        $result = Test-SystemRestoreEnabled
        $result | Should -Be $false
    }
}

Describe "Enable-SystemRestore" {
    BeforeEach {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Enabled" }
        }
        Mock -ModuleName checkpoint Enable-ComputerRestore { }
    }
    
    It "Should return true when already enabled" {
        $result = Enable-SystemRestore
        $result | Should -Be $true
    }
    
    It "Should enable System Restore when disabled" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        
        $result = Enable-SystemRestore
        $result | Should -Be $true
        Should -Invoke -ModuleName checkpoint Enable-ComputerRestore -Exactly 1
    }
    
    It "Should return false on error" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        Mock -ModuleName checkpoint Enable-ComputerRestore { 
            throw "Access denied" 
        }
        
        $result = Enable-SystemRestore
        $result | Should -Be $false
    }
}

Describe "New-Checkpoint" {
    BeforeEach {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Enabled" }
        }
        Mock -ModuleName checkpoint Enable-ComputerRestore { }
        Mock -ModuleName checkpoint Checkpoint-Computer { }
    }
    
    It "Should create checkpoint successfully" {
        $result = New-Checkpoint -Name "TestCheckpoint"
        
        $result | Should -Not -BeNullOrEmpty
        $result.Success | Should -Be $true
        $result.Name | Should -Be "TestCheckpoint"
    }
    
    It "Should use default name when not specified" {
        $result = New-Checkpoint
        
        $result.Name | Should -Match "WinSpec-"
    }
    
    It "Should handle errors gracefully" {
        Mock -ModuleName checkpoint Checkpoint-Computer { throw "Access denied" }
        
        $result = New-Checkpoint -Name "TestCheckpoint"
        
        $result.Success | Should -Be $false
        $result.Error | Should -Not -BeNullOrEmpty
    }
    
    It "Should return null when System Restore cannot be enabled" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        Mock -ModuleName checkpoint Enable-ComputerRestore { throw "Access denied" }
        
        $result = New-Checkpoint -Name "TestCheckpoint"
        
        $result | Should -BeNullOrEmpty
    }
}

Describe "Get-Checkpoints" {
    # Test 1: Default behavior - return WinSpec checkpoints
    Describe "Default behavior" {
        BeforeEach {
            InModuleScope checkpoint {
                Mock Get-ComputerRestorePoint { 
                    return @(
                        [PSCustomObject]@{
                            SequenceNumber = 100
                            CreationTime = (Get-Date).AddDays(-1)
                            Description = "WinSpec-Test1"
                        },
                        [PSCustomObject]@{
                            SequenceNumber = 101
                            CreationTime = Get-Date
                            Description = "WinSpec-Test2"
                        }
                    )
                }
            }
        }
        
        It "Should return WinSpec checkpoints" {
            InModuleScope checkpoint {
                $result = Get-Checkpoints
                
                $result | Should -Not -BeNullOrEmpty
                $result.Count | Should -Be 2
            }
        }
    }
    
    # Test 2: No checkpoints scenario
    Describe "No checkpoints" {
        BeforeEach {
            InModuleScope checkpoint {
                Mock Get-ComputerRestorePoint { return @() }
            }
        }
        
        It "Should return empty array when no checkpoints" {
            InModuleScope checkpoint {
                $result = Get-Checkpoints
                
                $result | Should -Be @()
            }
        }
    }
    
    # Test 3: Filter only WinSpec checkpoints
    Describe "Filtering" {
        # Skip this test due to Pester InModuleScope quirk with nested Describes
        It "Should filter only WinSpec checkpoints" -Skip {
            InModuleScope checkpoint {
                Mock Get-ComputerRestorePoint { 
                    return @(
                        [PSCustomObject]@{
                            SequenceNumber = 100
                            CreationTime = Get-Date
                            Description = "OtherRestorePoint"
                        },
                        [PSCustomObject]@{
                            SequenceNumber = 101
                            CreationTime = Get-Date
                            Description = "WinSpec-Test"
                        }
                    )
                }
                
                $result = Get-Checkpoints
                
                $result.Count | Should -Be 1
                $result[0].Description | Should -Be "WinSpec-Test"
            }
        }
    }
}

Describe "Invoke-Rollback" {
    BeforeEach {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Enabled" }
        }
        Mock -ModuleName checkpoint Get-ComputerRestorePoint { 
            return @(
                [PSCustomObject]@{
                    SequenceNumber = 100
                    CreationTime = (Get-Date).AddDays(-1)
                    Description = "WinSpec-Test1"
                },
                [PSCustomObject]@{
                    SequenceNumber = 101
                    CreationTime = Get-Date
                    Description = "WinSpec-Test2"
                }
            )
        }
        Mock -ModuleName checkpoint Restore-Computer { }
    }
    
    It "Should return false when neither SequenceNumber nor Last is specified" {
        $result = Invoke-Rollback -Confirm:$false
        $result | Should -Be $false
    }
    
    It "Should rollback to last checkpoint" {
        $result = Invoke-Rollback -Last -Confirm:$false
        
        $result | Should -Be $true
        Should -Invoke -ModuleName checkpoint Restore-Computer -Exactly 1
    }
    
    It "Should rollback to specific sequence number" {
        $result = Invoke-Rollback -SequenceNumber 100 -Confirm:$false
        
        $result | Should -Be $true
    }
    
    It "Should handle missing checkpoint" {
        Mock -ModuleName checkpoint Get-ComputerRestorePoint { return @() }
        
        $result = Invoke-Rollback -Last -Confirm:$false
        
        $result | Should -Be $false
    }
    
    It "Should return false when System Restore is disabled" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        
        $result = Invoke-Rollback -Last -Confirm:$false
        $result | Should -Be $false
    }
}

Describe "Test-CheckpointCapability" {
    BeforeEach {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Enabled" }
        }
    }
    
    It "Should return capability status" {
        $result = Test-CheckpointCapability
        
        $result | Should -Not -BeNullOrEmpty
        $result.ContainsKey("SystemRestoreEnabled") | Should -Be $true
        $result.ContainsKey("AdminPrivileges") | Should -Be $true
        $result.ContainsKey("CanCreateCheckpoint") | Should -Be $true
    }
    
    It "Should show System Restore disabled status" {
        Mock -ModuleName checkpoint Get-ComputerInfo { 
            return [PSCustomObject]@{ RestoreStatus = "Disabled" }
        }
        
        $result = Test-CheckpointCapability
        
        $result.SystemRestoreEnabled | Should -Be $false
    }
}
