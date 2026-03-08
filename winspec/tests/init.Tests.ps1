# tests/init.Tests.ps1 - Tests for init module (no system changes)

BeforeAll {
    Import-Module "$PSScriptRoot\..\logging.psm1" -Force
    Import-Module "$PSScriptRoot\..\export.psm1" -Force
    Import-Module "$PSScriptRoot\..\init.psm1" -Force
}

Describe "Initialize-WinSpecConfig" {
    BeforeEach {
        $TestPath = Join-Path $TestDrive "test-config.ps1"
    }
    
    AfterEach {
        if (Test-Path $TestPath) {
            Remove-Item $TestPath -Force
        }
    }
    
    It "Should create output file with default settings" {
        Mock Export-SystemState -ModuleName init {
            return @{
                Name = "test"
                Description = "test"
                Package = @{
                    Installed = @("git")
                }
            }
        }
        
        $result = Initialize-WinSpecConfig -OutputPath $TestPath
        $result | Should -Be $true
        Test-Path $TestPath | Should -Be $true
    }
    
    It "Should include custom name and description" {
        Mock Export-SystemState -ModuleName init {
            return @{
                Name = "test"
                Description = "test"
            }
        }
        
        $result = Initialize-WinSpecConfig -OutputPath $TestPath -Name "Custom Name" -Description "Custom Description"
        $result | Should -Be $true
        
        $content = Get-Content $TestPath -Raw
        $content | Should -Match "Custom Name"
        $content | Should -Match "Custom Description"
    }
    
    It "Should fail if output file exists and not in interactive mode" {
        # Create existing file
        "existing content" | Out-File -FilePath $TestPath
        
        Mock Export-SystemState -ModuleName init { return @{ Name = "test"; Description = "test" } }
        
        # With -Minimal switch, should error on existing file
        $result = Initialize-WinSpecConfig -OutputPath $TestPath -Minimal
        $result | Should -Be $false
    }
}

Describe "Show-StateSummary" {
    It "Should display package count" {
        $state = @{
            Package = @{
                Installed = @("git", "nodejs", "vscode")
            }
        }
        
        { Show-StateSummary -State $state } | Should -Not -Throw
    }
    
    It "Should display registry count" {
        $state = @{
            Registry = @{
                Explorer = @{
                    ShowHidden = $true
                    HideFileExt = $false
                }
            }
        }
        
        { Show-StateSummary -State $state } | Should -Not -Throw
    }
    
    It "Should display service count" {
        $state = @{
            Service = @{
                bits = @{ Startup = "manual" }
                wuauserv = @{ Startup = "automatic" }
            }
        }
        
        { Show-StateSummary -State $state } | Should -Not -Throw
    }
    
    It "Should display feature count" {
        $state = @{
            Feature = @{
                "Microsoft-Windows-Subsystem-Linux" = "enabled"
                "TelnetClient" = "disabled"
            }
        }
        
        { Show-StateSummary -State $state } | Should -Not -Throw
    }
}

Describe "Filter-MinimalConfig" {
    It "Should filter out default registry values" {
        $state = @{
            Name = "test"
            Description = "test"
            Registry = @{
                Explorer = @{
                    ShowHidden = $false  # Default value
                    HideFileExt = $true  # Default value
                    LaunchTo = 2  # Non-default
                }
            }
        }
        
        $result = Filter-MinimalConfig -State $state
        
        $result.ContainsKey("Registry") | Should -Be $true
        $result.Registry.Explorer.ContainsKey("ShowHidden") | Should -Be $false
        $result.Registry.Explorer.ContainsKey("HideFileExt") | Should -Be $false
        $result.Registry.Explorer.ContainsKey("LaunchTo") | Should -Be $true
    }
    
    It "Should keep all packages in minimal mode" {
        $state = @{
            Name = "test"
            Description = "test"
            Package = @{
                Installed = @("git", "nodejs")
            }
        }
        
        $result = Filter-MinimalConfig -State $state
        
        $result.Package.Installed.Count | Should -Be 2
    }
    
    It "Should only include enabled features in minimal mode" {
        $state = @{
            Name = "test"
            Description = "test"
            Feature = @{
                "Feature1" = "enabled"
                "Feature2" = "disabled"
                "Feature3" = "enabled"
            }
        }
        
        $result = Filter-MinimalConfig -State $state
        
        $result.Feature.Count | Should -Be 2
        $result.Feature.ContainsKey("Feature2") | Should -Be $false
    }
}

Describe "Get-RegistryDefaults" {
    It "Should return default registry values" {
        $defaults = Get-RegistryDefaults
        
        $defaults | Should -Not -BeNullOrEmpty
        $defaults.ContainsKey("Explorer") | Should -Be $true
        $defaults.ContainsKey("Taskbar") | Should -Be $true
        $defaults.ContainsKey("Clipboard") | Should -Be $true
        $defaults.ContainsKey("Theme") | Should -Be $true
    }
    
    It "Should have expected Explorer defaults" {
        $defaults = Get-RegistryDefaults
        
        $defaults.Explorer.ShowHidden | Should -Be $false
        $defaults.Explorer.HideFileExt | Should -Be $true
    }
}

Describe "Get-ServiceDefaults" {
    It "Should return default service startup types" {
        $defaults = Get-ServiceDefaults
        
        $defaults | Should -Not -BeNullOrEmpty
        $defaults.Count | Should -BeGreaterThan 0
    }
}

Describe "ConvertTo-SimpleConfig" {
    It "Should generate valid PowerShell hashtable syntax" {
        $state = @{
            Name = "Test Config"
            Description = "Test Description"
            Package = @{
                Installed = @("git")
            }
        }
        
        $content = ConvertTo-SimpleConfig -State $state -Name "Test Config" -Description "Test Description"
        
        $content | Should -Match "@\{"
        $content | Should -Match "Name\s*="
        $content | Should -Match "Package"
    }
    
    It "Should handle nested structures" {
        $state = @{
            Name = "Test"
            Description = "Test"
            Registry = @{
                Explorer = @{
                    ShowHidden = $true
                }
            }
        }
        
        $content = ConvertTo-SimpleConfig -State $state -Name "Test" -Description "Test"
        
        $content | Should -Match "Registry"
        $content | Should -Match "Explorer"
        $content | Should -Match "ShowHidden"
    }
}

Describe "ConvertTo-TemplateConfig" {
    It "Should include header comments" {
        $state = @{
            Name = "Test"
            Description = "Test"
        }
        
        $content = ConvertTo-TemplateConfig -State $state -Name "Test Config" -Description "Test Description"
        
        $content | Should -Match "# WinSpec Configuration"
        $content | Should -Match "# Generated:"
        $content | Should -Match "# Edit this file"
    }
    
    It "Should include package section with comments" {
        $state = @{
            Name = "Test"
            Description = "Test"
            Package = @{
                Installed = @("git", "nodejs")
            }
        }
        
        $content = ConvertTo-TemplateConfig -State $state -Name "Test" -Description "Test"
        
        $content | Should -Match "Package Management"
        $content | Should -Match "scoop install"
        $content | Should -Match "git"
        $content | Should -Match "nodejs"
    }
    
    It "Should include registry section with comments" {
        $state = @{
            Name = "Test"
            Description = "Test"
            Registry = @{
                Explorer = @{
                    ShowHidden = $true
                }
            }
        }
        
        $content = ConvertTo-TemplateConfig -State $state -Name "Test" -Description "Test"
        
        $content | Should -Match "Windows Registry"
        $content | Should -Match "WARNING:"
        $content | Should -Match "Explorer"
        $content | Should -Match "ShowHidden"
    }
    
    It "Should include service section with comments" {
        $state = @{
            Name = "Test"
            Description = "Test"
            Service = @{
                bits = @{ Startup = "manual" }
            }
        }
        
        $content = ConvertTo-TemplateConfig -State $state -Name "Test" -Description "Test"
        
        $content | Should -Match "Windows Services"
        $content | Should -Match "bits"
        $content | Should -Match "Startup"
    }
    
    It "Should include feature section with comments" {
        $state = @{
            Name = "Test"
            Description = "Test"
            Feature = @{
                "WSL" = "enabled"
            }
        }
        
        $content = ConvertTo-TemplateConfig -State $state -Name "Test" -Description "Test"
        
        $content | Should -Match "Windows Features"
        $content | Should -Match "WSL"
    }
}

Describe "ConvertTo-PowerShellValue" {
    It "Should convert boolean values" {
        ConvertTo-PowerShellValue -Value $true | Should -Be "true"
        ConvertTo-PowerShellValue -Value $false | Should -Be "false"
    }
    
    It "Should convert integer values" {
        ConvertTo-PowerShellValue -Value 42 | Should -Be "42"
        ConvertTo-PowerShellValue -Value 0 | Should -Be "0"
    }
    
    It "Should convert string values with proper escaping" {
        ConvertTo-PowerShellValue -Value "test" | Should -Be "'test'"
        ConvertTo-PowerShellValue -Value "it's" | Should -Be "'it''s'"
    }
}
