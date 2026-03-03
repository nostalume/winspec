# tests/core.Tests.ps1 - Tests for core module with mocked system operations

BeforeAll {
    # Import modules
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\schema.psm1" -Force
    
    # Mock all system-changing operations
    Mock Get-ItemProperty { 
        param($Path, $Name)
        return @{ $Name = 1 }  # Default mock return
    }
    
    Mock Set-ItemProperty { 
        # Do nothing - safe mock
    }
    
    Mock New-Item { 
        return @{ FullName = "MockPath" }
    }
    
    Mock Test-Path { return $true }
    
    Mock Get-Service { 
        return @{ Status = "Running"; Name = "MockService" }
    }
    
    Mock Get-WmiObject { 
        return @{ StartMode = "Automatic" }
    }
    
    Mock Set-Service { }
    Mock Start-Service { }
    Mock Stop-Service { }
    
    Mock Get-WindowsOptionalFeature { 
        return @{ State = "Enabled"; Name = "MockFeature" }
    }
    
    Mock Enable-WindowsOptionalFeature { }
    Mock Disable-WindowsOptionalFeature { }
    
    Mock Get-Command { 
        param($Name)
        if ($Name -eq "scoop") {
            return @{ Name = "scoop" }
        }
        return $null
    }
    
    Mock Invoke-RestMethod { return "mock script content" }
    Mock Invoke-WebRequest { }
    Mock Start-Process { }
    
    Mock Get-ComputerInfo { return @{ RestoreStatus = "Enabled" } }
    Mock Enable-ComputerRestore { }
    Mock Checkpoint-Computer { }
    Mock Get-ComputerRestorePoint { return @() }
    Mock Restore-Computer { }
    
    # Now import core module which depends on mocked functions
    Import-Module "$PSScriptRoot\..\core.psm1" -Force
}

Describe "Import-Spec" {
    It "Should import valid specification file" {
        # Create a temp spec file dynamically
        $tempFile = Join-Path $env:TEMP "valid-spec-$(Get-Random).ps1"
        @'
@{
    Name = "minimal"
    Description = "Test spec"
    Registry = @{}
}
'@ | Out-File $tempFile -Force
        
        try {
            $result = Import-Spec -Path $tempFile
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "minimal"
        }
        finally {
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }
    
    It "Should return null for non-existent file" {
        $result = Import-Spec -Path "C:\NonExistent\File.ps1"
        $result | Should -BeNullOrEmpty
    }
    
    It "Should return null for invalid specification" {
        # Create temp file with invalid content
        $tempFile = Join-Path $env:TEMP "invalid-spec-$(Get-Random).ps1"
        "This is not a hashtable" | Out-File $tempFile -Force
        
        $result = Import-Spec -Path $tempFile
        $result | Should -BeNullOrEmpty
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

Describe "Merge-Hashtables" {
    It "Should merge two hashtables" {
        $base = @{ A = 1; B = 2 }
        $override = @{ B = 3; C = 4 }
        
        $result = Merge-Hashtables -Base $base -Override $override
        
        $result.A | Should -Be 1
        $result.B | Should -Be 3  # Overridden
        $result.C | Should -Be 4
    }
    
    It "Should recursively merge nested hashtables" {
        $base = @{ 
            Registry = @{ Explorer = @{ ShowHidden = $true } }
        }
        $override = @{ 
            Registry = @{ Theme = @{ AppTheme = "dark" } }
        }
        
        $result = Merge-Hashtables -Base $base -Override $override
        
        $result.Registry.Explorer.ShowHidden | Should -Be $true
        $result.Registry.Theme.AppTheme | Should -Be "dark"
    }
    
    It "Should merge arrays with unique values" {
        $base = @{ Package = @{ Installed = @("git", "nodejs") } }
        $override = @{ Package = @{ Installed = @("nodejs", "python") } }
        
        $result = Merge-Hashtables -Base $base -Override $override
        
        $result.Package.Installed | Should -Contain "git"
        $result.Package.Installed | Should -Contain "nodejs"
        $result.Package.Installed | Should -Contain "python"
        ($result.Package.Installed | Where-Object { $_ -eq "nodejs" }).Count | Should -Be 1
    }
}

Describe "Resolve-Spec" {
    It "Should resolve specification without imports" {
        $config = @{
            Name = "test"
            Registry = @{ Explorer = @{ ShowHidden = $true } }
        }
        
        $result = Resolve-Spec -Config $config
        
        $result.Name | Should -Be "test"
        $result.Registry.Explorer.ShowHidden | Should -Be $true
    }
    
    It "Should remove Import key from result" {
        $config = @{
            Name = "test"
            Import = @(".\some-file.ps1")
        }
        
        $result = Resolve-Spec -Config $config
        
        $result.ContainsKey("Import") | Should -Be $false
    }
}

Describe "Test-SpecSchema" {
    It "Should validate correct specification" {
        InModuleScope schema {
            $config = @{
                Name = "test"
                Registry = @{ Explorer = @{ ShowHidden = $true } }
            }
            
            Test-SpecSchema -Config $config | Should -Be $true
        }
    }
    
    It "Should reject invalid specification" {
        InModuleScope schema {
            $config = @{
                Registry = @{ UnknownCategory = @{ Prop = $true } }
            }
            
            Test-SpecSchema -Config $config | Should -Be $false
        }
    }
}

Describe "Write-Report" {
    It "Should generate report without errors" {
        $results = @{
            Registry = @{ Status = "AlreadyInDesiredState" }
            Package = @{ Status = "Applied" }
        }
        
        { Write-Report -Results $results } | Should -Not -Throw
    }
}

Describe "Resolve-ConfigLocation" {
    It "Should return explicit ConfigPath when provided" {
        Mock -ModuleName core Test-Path { return $true } -ParameterFilter { $Path -eq "C:\Test\Config" }
        
        $result = Resolve-ConfigLocation -ConfigPath "C:\Test\Config"
        $result | Should -Be "C:\Test\Config"
    }
    
    It "Should return null when no config location exists" {
        Mock -ModuleName core Test-Path { return $false }
        
        $result = Resolve-ConfigLocation
        $result | Should -BeNullOrEmpty
    }
}

Describe "Find-TriggerScript" {
    It "Should return explicit path when provided" {
        Mock -ModuleName core Test-Path { return $true } -ParameterFilter { $Path -eq ".\triggers\test.ps1" }
        
        $result = Find-TriggerScript -Name "test" -Path ".\triggers\test.ps1"
        $result | Should -Be ".\triggers\test.ps1"
    }
    
    It "Should return null when trigger not found" {
        Mock -ModuleName core Test-Path { return $false }
        
        $result = Find-TriggerScript -Name "nonexistent"
        $result | Should -BeNullOrEmpty
    }
}

Describe "Import-Manager" {
    It "Should return false for non-existent manager" {
        Mock Test-Path { return $false }

        $result = Import-Manager -Name "NonExistent"
        $result | Should -Be $false
    }
}

Describe "Import-BuiltInTrigger" {
    It "Should return false for non-existent trigger" {
        Mock Test-Path { return $false }

        $result = Import-BuiltInTrigger -Name "NonExistent"
        $result | Should -Be $false
    }
}
