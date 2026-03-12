# tests/exec.Tests.ps1 - Tests for exec.psm1 module

# This file tests the exported functions from exec.psm1
# Note: Many internal functions exist but are not exported

BeforeAll {
    # Import modules
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\schema.psm1" -Force
    Import-Module "$PSScriptRoot\..\registry-maps.psm1" -Force
    
    # Mock all system-changing operations
    Mock Get-ItemProperty { param($Path, $Name); return @{ $Name = 1 } }
    Mock Set-ItemProperty { }
    Mock New-Item { return @{ FullName = "MockPath" } }
    Mock Test-Path { return $true } -ParameterFilter { $Path -notmatch "NonExistent" }
    Mock Test-Path { return $false } -ParameterFilter { $Path -match "NonExistent" }
    Mock Get-Service { param($Name); return @{ Status = "Running"; Name = $Name } }
    Mock Get-WmiObject { return @{ StartMode = "Automatic" } }
    Mock Set-Service { }
    Mock Start-Service { }
    Mock Stop-Service { }
    Mock Get-WindowsOptionalFeature { param($FeatureName); return @{ State = "Enabled"; FeatureName = $FeatureName } }
    Mock Enable-WindowsOptionalFeature { }
    Mock Disable-WindowsOptionalFeature { }
    Mock Get-Command { param($Name); if ($Name -eq "scoop") { return @{ Name = "scoop" } }; return $null }
    Mock Invoke-RestMethod { return "mock script content" }
    Mock Invoke-WebRequest { }
    Mock Start-Process { }
    Mock Get-ComputerInfo { return @{ RestoreStatus = "Enabled" } }
    Mock Enable-ComputerRestore { }
    Mock Checkpoint-Computer { }
    Mock Get-ComputerRestorePoint { return @() }
    Mock Restore-Computer { }
    
    # Now import exec module
    Import-Module "$PSScriptRoot\..\exec.psm1" -Force
}

Describe "exec.psm1 Module" {
    Context "Exported functions" {
        It "Should export Invoke-WinSpec" {
            $module = Get-Module exec
            $module.ExportedFunctions.Keys | Should -Contain "Invoke-WinSpec"
        }
    }
}
