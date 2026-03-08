# tests/sandbox.Tests.ps1 - Tests for sandbox module (no system changes)

BeforeAll {
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\sandbox.psm1" -Force
}

Describe "Sandbox Module" {
    BeforeEach {
        # Ensure clean sandbox state before each test
        if (Get-Command Test-SandboxActive -ErrorAction SilentlyContinue) {
            if (Test-SandboxActive) {
                Exit-Sandbox -DiscardChanges
            }
        }
    }
    
    AfterEach {
        # Clean up after each test
        if (Get-Command Test-SandboxActive -ErrorAction SilentlyContinue) {
            if (Test-SandboxActive) {
                Exit-Sandbox -DiscardChanges
            }
        }
    }
    
    Context "Enter-Sandbox" {
        It "Should enter sandbox mode with Mock mode" {
            $result = Enter-Sandbox -Mode Mock -Profile default
            $result | Should -Not -BeNullOrEmpty
            $result.Mode | Should -Be "Mock"
            $result.Profile | Should -Be "default"
            Test-SandboxActive | Should -Be $true
        }
        
        It "Should enter sandbox mode with DryRun mode" {
            $result = Enter-Sandbox -Mode DryRun -Profile default
            $result | Should -Not -BeNullOrEmpty
            $result.Mode | Should -Be "DryRun"
            Test-SandboxActive | Should -Be $true
        }
        
        It "Should initialize sandbox state for Mock mode" {
            Enter-Sandbox -Mode Mock -Profile default
            $state = Get-SandboxState -Provider "Package"
            $state | Should -Not -BeNullOrEmpty
            # Package state should have apps key
            $state.Keys | Should -Contain "apps"
        }
    }
    
    Context "Exit-Sandbox" {
        It "Should exit sandbox mode" {
            Enter-Sandbox -Mode Mock
            Test-SandboxActive | Should -Be $true
            
            Exit-Sandbox -DiscardChanges
            Test-SandboxActive | Should -Be $false
        }
        
        It "Should export history when not discarding changes" {
            Enter-Sandbox -Mode Mock
            Add-SandboxChange -Provider "Package" -Change @{ Status = "Success"; Installed = @("git") }
            
            Exit-Sandbox
            # History should be exported (file created)
            $historyDir = Join-Path $env:USERPROFILE ".config\winspec\sandbox\history"
            Test-Path $historyDir | Should -Be $true
        }
    }
    
    Context "Get-SandboxMode" {
        It "Should return Live when not in sandbox" {
            # Ensure we're not in sandbox
            if (Test-SandboxActive) {
                Exit-Sandbox -DiscardChanges
            }
            Get-SandboxMode | Should -Be "Live"
        }
        
        It "Should return Mock when in Mock sandbox" {
            Enter-Sandbox -Mode Mock
            Get-SandboxMode | Should -Be "Mock"
        }
        
        It "Should return DryRun when in DryRun sandbox" {
            Enter-Sandbox -Mode DryRun
            Get-SandboxMode | Should -Be "DryRun"
        }
    }
    
    Context "Sandbox State Management" {
        BeforeEach {
            Enter-Sandbox -Mode Mock -Profile default
        }
        
        It "Should get sandbox state for Package provider" {
            $state = Get-SandboxState -Provider "Package"
            $state | Should -Not -BeNullOrEmpty
        }
        
        It "Should get sandbox state for Registry provider" {
            $state = Get-SandboxState -Provider "Registry"
            $state | Should -Not -BeNullOrEmpty
        }
        
        It "Should set sandbox state for a provider" {
            $newState = @{
                apps = @(
                    @{ name = "git"; version = "2.42.0"; bucket = "main" }
                )
                buckets = @()
            }
            Set-SandboxState -Provider "Package" -State $newState
            
            $state = Get-SandboxState -Provider "Package"
            $state.apps.Count | Should -Be 1
            $state.apps[0].name | Should -Be "git"
        }
        
        It "Should reset sandbox state" {
            # Modify state
            $newState = @{
                apps = @(
                    @{ name = "git"; version = "2.42.0"; bucket = "main" }
                )
                buckets = @()
            }
            Set-SandboxState -Provider "Package" -State $newState
            
            # Reset
            Reset-SandboxState
            
            # State should be back to original (empty apps)
            $state = Get-SandboxState -Provider "Package"
            $state.apps.Count | Should -Be 0
        }
    }
    
    Context "Sandbox Changes" {
        BeforeEach {
            Enter-Sandbox -Mode Mock -Profile default
        }
        
        It "Should track sandbox changes" {
            Add-SandboxChange -Provider "Package" -Change @{ Status = "Success"; Installed = @("git") }
            
            $changes = Get-SandboxChanges
            $changes.Count | Should -BeGreaterThan 0
        }
        
        It "Should clear changes after reset" {
            Add-SandboxChange -Provider "Package" -Change @{ Status = "Success" }
            
            Reset-SandboxState
            
            $changes = Get-SandboxChanges
            $changes.Count | Should -Be 0
        }
    }
    
    Context "Sandbox Profiles" {
        It "Should list available profiles" {
            # First initialize sandbox directory by calling Get-SandboxProfiles
            $null = Get-SandboxProfiles
            
            # Now manually create a profile file - note: profiles are in state/profiles subfolder
            $profilePath = Join-Path $env:USERPROFILE ".config\winspec\sandbox\state\profiles\testlist.json"
            $profileDir = Split-Path $profilePath -Parent
            if (-not (Test-Path $profileDir)) {
                New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            }
            @{ Name = "testlist" } | ConvertTo-Json -Depth 10 | Out-File $profilePath -Encoding UTF8
            
            $profiles = Get-SandboxProfiles
            
            # Check count first - Pester might handle this differently
            $profiles.Count | Should -Be 1
            $profiles[0] | Should -Be "testlist"
            
            # Cleanup
            Remove-Item $profilePath -Force -ErrorAction SilentlyContinue
        }
        
        It "Should export and import sandbox state" {
            $testState = @{
                Package = @{
                    apps = @(
                        @{ name = "test-app"; version = "1.0.0" }
                    )
                    buckets = @()
                }
                Registry = @{}
                Service = @{}
                Feature = @{}
            }
            
            Export-SandboxState -Profile "test-profile" -State $testState
            
            # Import the state
            $imported = Import-SandboxState -Profile "test-profile"
            $imported.Package.apps[0].name | Should -Be "test-app"
            
            # Cleanup
            Remove-SandboxProfile -Profile "test-profile"
        }
    }
    
    Context "Compare-ProviderState" {
        It "Should compare Package state - added packages" {
            $current = @{
                apps = @()
                buckets = @()
            }
            $desired = @{
                Installed = @("git", "neovim")
            }
            
            $result = Compare-ProviderState -Provider "Package" -Current $current -Desired $desired
            $result.Added.Count | Should -Be 2
            $result.Removed.Count | Should -Be 0
        }
        
        It "Should compare Package state - removed packages" {
            $current = @{
                apps = @(
                    @{ name = "git" },
                    @{ name = "neovim" }
                )
                buckets = @()
            }
            $desired = @{
                Installed = @("git")
            }
            
            $result = Compare-ProviderState -Provider "Package" -Current $current -Desired $desired
            $result.Added.Count | Should -Be 0
            $result.Removed.Count | Should -Be 1
        }
        
        It "Should compare Registry state - changed values" {
            $current = @{
                Explorer = @{ ShowHidden = $false }
            }
            $desired = @{
                Explorer = @{ ShowHidden = $true }
            }
            
            $result = Compare-ProviderState -Provider "Registry" -Current $current -Desired $desired
            $result.Changed.Count | Should -Be 1
            $result.Changed[0].NewValue | Should -Be $true
        }
    }
}
