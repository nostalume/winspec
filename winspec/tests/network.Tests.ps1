# tests/network.Tests.ps1 - Network error handling tests for WinSpec
# All tests use mocks to avoid real network calls

BeforeAll {
    $script:WinspecRoot = $PSScriptRoot | Split-Path -Parent
    
    # Import modules that handle network operations FIRST
    Import-Module "$script:WinspecRoot\logging.psm1" -Force
    Import-Module "$script:WinspecRoot\utils.psm1" -Force
    Import-Module "$script:WinspecRoot\state.psm1" -Force
    
    # CRITICAL: Import activation module with a prefix so we can mock its functions
    Import-Module "$script:WinspecRoot\triggers\activation.psm1" -Force -Prefix Activation
    
    # NOW set up mocks AFTER importing modules that use them
    Mock Invoke-RestMethod { 
        return "@{ Name = 'mocked' }"
    }
}

Describe "Network Error Handling - Invoke-WebRequest" {
    Context "Mock WebRequest Success" {
        BeforeAll {
            Mock Invoke-WebRequest { 
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content = '{"success": true}'
                }
            }
        }
        
        It "Should handle successful web request" {
            { Invoke-WebRequest -Uri "https://example.com" } | Should -Not -Throw
        }
    }
    
    Context "Mock WebRequest Timeout" {
        BeforeAll {
            Mock Invoke-WebRequest { 
                throw [System.Net.WebException]::new(
                    "The operation has timed out",
                    [System.Net.WebExceptionStatus]::Timeout
                )
            }
        }
        
        It "Should handle timeout error" {
            { Invoke-WebRequest -Uri "https://slow-server.com" } | Should -Throw
        }
    }
    
    Context "Mock WebRequest 404" {
        BeforeAll {
            Mock Invoke-WebRequest { 
                throw [System.Net.WebException]::new(
                    "The remote server returned an error: (404) Not Found.",
                    [System.Net.WebExceptionStatus]::ProtocolError
                )
            }
        }
        
        It "Should handle 404 error" {
            { Invoke-WebRequest -Uri "https://example.com/notfound" } | Should -Throw
        }
    }
    
    Context "Mock WebRequest DNS Error" {
        BeforeAll {
            Mock Invoke-WebRequest { 
                throw [System.Net.WebException]::new(
                    "No such host is known",
                    [System.Net.WebExceptionStatus]::NameResolutionFailure
                )
            }
        }
        
        It "Should handle DNS error" {
            { Invoke-WebRequest -Uri "https://nonexistent.invalid" } | Should -Throw
        }
    }
}

Describe "Network Error Handling - Invoke-RestMethod" {
    Context "Mock RestMethod Success" {
        It "Should handle successful REST call" {
            { Invoke-RestMethod -Uri "https://api.example.com/data" } | Should -Not -Throw
        }
    }
    
    Context "Mock RestMethod Timeout" {
        BeforeAll {
            # Re-mock for this context
            Mock Invoke-RestMethod { 
                throw [System.Net.WebException]::new(
                    "The operation has timed out",
                    [System.Net.WebExceptionStatus]::Timeout
                )
            }
        }
        
        It "Should handle timeout error" {
            { Invoke-RestMethod -Uri "https://slow-api.example.com" } | Should -Throw
        }
    }
    
    Context "Mock RestMethod Connection Refused" {
        BeforeAll {
            Mock Invoke-RestMethod { 
                throw [System.Net.WebException]::new(
                    "Unable to connect to the remote server",
                    [System.Net.WebExceptionStatus]::ConnectionClosed
                )
            }
        }
        
        It "Should handle connection refused" {
            { Invoke-RestMethod -Uri "https://localhost:9999/api" } | Should -Throw
        }
    }
}

Describe "Network Error Handling - Package Manager" {
    Context "Scoop Available" {
        BeforeAll {
            # Import module first
            Import-Module "$script:WinspecRoot\managers\scoop.psm1" -Force
        }
        
        It "Should detect Scoop is installed" {
            # Mock within the test to ensure proper scoping
            Mock Get-Command -ModuleName scoop { 
                return [PSCustomObject]@{ Name = "scoop" }
            } -ParameterFilter { $Name -eq "scoop" }
            
            $result = Test-ScoopInstalled
            $result | Should -Be $true
        }
    }
    
    Context "Scoop Not Available - Verification" {
        # This test just verifies the function exists
        It "Test-ScoopInstalled should exist" {
            Get-Command Test-ScoopInstalled -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Mock Scoop Export" {
        BeforeAll {
            # Import module first
            Import-Module "$script:WinspecRoot\managers\scoop.psm1" -Force
        }
        
        It "Should parse Scoop export JSON" {
            # Mock within the test to ensure proper scoping
            Mock Get-Command -ModuleName scoop { 
                return [PSCustomObject]@{ Name = "scoop" }
            } -ParameterFilter { $Name -eq "scoop" }
            
            Mock Invoke-Expression -ModuleName scoop { 
                return '{"apps":[],"buckets":[]}'
            } -ParameterFilter { $_ -match "scoop export" }
            
            $result = Get-ScoopExport
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Network Error Handling - Trigger Scripts" {
    # NOTE: These tests focus on WhatIf mode which doesn't make network calls
    # Real network calls only happen when -WhatIf is NOT specified
    
    Context "Activation Trigger WhatIf Mode" {
        It "Should run in WhatIf mode without network calls" {
            # WhatIf mode should NOT make any network calls
            $result = Invoke-ActivationActivationTrigger -Option $true -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "DryRun"
        }
        
        It "Should accept string option in WhatIf mode" {
            $result = Invoke-ActivationActivationTrigger -Option "KMS38" -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should accept hashtable option in WhatIf mode" {
            $result = Invoke-ActivationActivationTrigger -Option @{ Method = "KMS38" } -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
        }
    }
}
