# tests/commands.Tests.ps1 - Tests for WinSpec CLI commands via module functions

BeforeAll {
    $script:WinspecRoot = $PSScriptRoot | Split-Path -Parent
    
    # Import in correct order - logging first, then dependencies
    Import-Module "$script:WinspecRoot\logging.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\utils.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\registry-maps.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\schema.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\exec.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\pull.psm1" -Force -Global
    Import-Module "$script:WinspecRoot\push.psm1" -Force -Global
    
    # Helper function to create temp spec file
    function New-TempSpecFile {
        param([hashtable]$Content)
        $tempFile = [System.IO.Path]::GetTempFileName() + ".ps1"
        $ContentString = '@{' + "`n"
        foreach ($key in $Content.Keys) {
            $value = $Content[$key]
            if ($value -is [string]) {
                $ContentString += "    $key = `"$value`"`n"
            }
            elseif ($value -is [bool]) {
                $ContentString += "    $key = `$$value`n"
            }
            elseif ($value -is [array]) {
                $items = $value | ForEach-Object { 
                    if ($_ -is [string]) { "`"$_`"" }
                    else { $_ }
                } -join ", "
                $ContentString += "    $key = @($items)`n"
            }
            elseif ($value -is [hashtable]) {
                $ContentString += "    $key = @{`n"
                foreach ($k in $value.Keys) {
                    $v = $value[$k]
                    if ($v -is [string]) { $ContentString += "        $k = `"$v`"`n" }
                    elseif ($v -is [bool]) { $ContentString += "        $k = `$$v`n" }
                    elseif ($v -is [hashtable]) {
                        $ContentString += "        $k = @{`n"
                        foreach ($kk in $v.Keys) {
                            $vv = $v[$kk]
                            if ($vv -is [string]) { $ContentString += "            $kk = `"$vv`"`n" }
                            elseif ($vv -is [bool]) { $ContentString += "            $kk = `$$vv`n" }
                            else { $ContentString += "            $kk = $vv`n" }
                        }
                        $ContentString += "        }`n"
                    }
                    else { $ContentString += "        $k = $v`n" }
                }
                $ContentString += "    }`n"
            }
            else {
                $ContentString += "    $key = $value`n"
            }
        }
        $ContentString += '}'
        $ContentString | Out-File -FilePath $tempFile -Encoding UTF8
        return $tempFile
    }
}

Describe "WinSpec CLI Commands - Import and Resolve Spec" {
    Context "Import-Spec" {
        It "Should import valid spec file" {
            $spec = @{
                Name = "test-import"
                Registry = @{
                    Explorer = @{ ShowHidden = $true }
                }
            }
            $specFile = New-TempSpecFile -Content $spec
            
            try {
                $loadedSpec = Import-Spec -Path $specFile
                $loadedSpec | Should -Not -BeNullOrEmpty
                $loadedSpec.Name | Should -Be "test-import"
            }
            finally {
                Remove-Item $specFile -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should return null for non-existent file" {
            $result = Import-Spec -Path "C:\NonExistent\file.ps1"
            $result | Should -BeNullOrEmpty
        }
    }
    
    Context "Resolve-Spec" {
        It "Should resolve spec without imports" {
            $spec = @{
                Name = "test-resolve"
                Registry = @{
                    Explorer = @{ ShowHidden = $true }
                }
            }
            
            $resolved = Resolve-Spec -Config $spec
            $resolved | Should -Not -BeNullOrEmpty
            $resolved.Name | Should -Be "test-resolve"
        }
        
        It "Should resolve spec with nested imports" {
            $base = @{
                Name = "base"
                Registry = @{ Theme = @{ AppTheme = "dark" } }
            }
            $baseFile = New-TempSpecFile -Content $base
            
            $derived = @{
                Name = "derived"
                Import = @($baseFile)
                Registry = @{ Explorer = @{ ShowHidden = $true } }
            }
            
            try {
                $resolved = Resolve-Spec -Config $derived
                $resolved.Registry.Theme.AppTheme | Should -Be "dark"
                $resolved.Registry.Explorer.ShowHidden | Should -Be $true
            }
            finally {
                Remove-Item $baseFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "WinSpec CLI Commands - Spec Schema Validation" {
    Context "Valid specifications" {
        It "Should validate spec with valid registry category" {
            $spec = @{
                Name = "test-valid"
                Registry = @{
                    Explorer = @{ ShowHidden = $true }
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $true
        }
        
        It "Should validate Service startup types" {
            $spec = @{
                Name = "test-service"
                Service = @{
                    wuauserv = @{ Startup = "automatic" }
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $true
        }
        
        It "Should validate Trigger is array of hashtables" {
            $spec = @{
                Name = "test-trigger"
                Trigger = @(
                    @{ Name = "Activation" }
                )
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $true
        }
    }
    
    Context "Invalid specifications" {
        It "Should fail validation for unknown Registry category" {
            $spec = @{
                Name = "test-invalid"
                Registry = @{
                    UnknownCategory = @{ SomeValue = $true }
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $false
        }
        
        It "Should fail validation for invalid Feature value" {
            $spec = @{
                Name = "test-invalid-feature"
                Feature = @{
                    SomeFeature = "invalid"
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $false
        }
        
        It "Should fail validation for invalid Service State" {
            $spec = @{
                Name = "test-invalid-service"
                Service = @{
                    wuauserv = @{ State = "invalid" }
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $false
        }
        
        It "Should validate Package.Installed is array" {
            $spec = @{
                Name = "test-invalid-package"
                Package = @{
                    Installed = "git"  # Not an array
                }
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $false
        }
        
        It "Should fail for Trigger without Name field" {
            $spec = @{
                Name = "test-trigger-invalid"
                Trigger = @(
                    @{ Value = "test" }
                )
            }
            
            $valid = Test-SpecSchema -Config $spec
            $valid | Should -Be $false
        }
    }
}

Describe "WinSpec CLI Commands - Init Command" {
    Context "Initialize-WinSpecConfig" {
        BeforeEach {
            # Mock Export-SystemState to avoid reading real system state
            Mock Export-SystemState -ModuleName init {
                return @{
                    Name = "test"
                    Description = "test"
                    Package = @{
                        Installed = @("git", "nodejs")
                    }
                    Registry = @{
                        Explorer = @{
                            ShowHidden = $true
                        }
                    }
                }
            }
        }
        
        It "Should initialize new config" {
            $tempOutput = [System.IO.Path]::GetTempFileName() + ".ps1"
            Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            
            try {
                Initialize-WinSpecConfig -OutputPath $tempOutput
                Test-Path $tempOutput | Should -Be $true
            }
            finally {
                Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should initialize with specific providers" {
            $tempOutput = [System.IO.Path]::GetTempFileName() + ".ps1"
            Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            
            try {
                Initialize-WinSpecConfig -OutputPath $tempOutput -Providers @("Package", "Registry")
                Test-Path $tempOutput | Should -Be $true
                
                $content = Get-Content $tempOutput -Raw
                $content | Should -Match "Package"
                $content | Should -Match "Registry"
                
                # Verify that only the specified providers are included
                # (this helps catch bugs where providers are not properly filtered)
                $content | Should -Not -Match "[\r\n]\s*Feature\s*="
                $content | Should -Not -Match "[\r\n]\s*Service\s*="
            }
            finally {
                Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should initialize with template" {
            $tempOutput = [System.IO.Path]::GetTempFileName() + ".ps1"
            Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            
            try {
                Initialize-WinSpecConfig -OutputPath $tempOutput -Template
                Test-Path $tempOutput | Should -Be $true
                
                $content = Get-Content $tempOutput -Raw
                $content | Should -Match "#"
            }
            finally {
                Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should initialize with minimal option" {
            $tempOutput = [System.IO.Path]::GetTempFileName() + ".ps1"
            Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            
            try {
                Initialize-WinSpecConfig -OutputPath $tempOutput -Minimal
                Test-Path $tempOutput | Should -Be $true
            }
            finally {
                Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            }
        }
        
        It "Should handle error when Export-SystemState fails" {
            Mock Export-SystemState -ModuleName init { throw "Failed to export system state" }
            
            $tempOutput = [System.IO.Path]::GetTempFileName() + ".ps1"
            Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            
            try {
                # Should return false when export fails
                $result = Initialize-WinSpecConfig -OutputPath $tempOutput
                $result | Should -Be $false
            }
            finally {
                Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "WinSpec CLI Commands - Provider Discovery" {
    Context "Get-DiscoveredProviders" {
        It "Should discover declarative providers" {
            
            $managersPath = Join-Path $script:WinspecRoot "managers"
            $providers = Get-DiscoveredProviders -Path $managersPath -Type "Declarative"
            
            $providers.Count | Should -BeGreaterThan 0
            $providers | Should -Contain "Registry"
            $providers | Should -Contain "Package"
            $providers | Should -Contain "Service"
            $providers | Should -Contain "Feature"
        }
        
        It "Should discover trigger providers" {
            Import-Module "$script:WinspecRoot\exec.psm1" -Force
            
            $triggersPath = Join-Path $script:WinspecRoot "triggers"
            $triggers = Get-DiscoveredProviders -Path $triggersPath -Type "Trigger"
            
            $triggers.Count | Should -BeGreaterThan 0
            $triggers | Should -Contain "Activation"
            $triggers | Should -Contain "Debloat"
            $triggers | Should -Contain "Office"
        }
    }
}

Describe "WinSpec CLI Commands - Spec Schema Definition" {
    Context "Get-SpecSchema" {
        It "Should return spec schema definition" {
            Import-Module "$script:WinspecRoot\schema.psm1" -Force -Global
            
            $schema = Get-SpecSchema
            $schema | Should -Not -BeNullOrEmpty
            $schema.Keys | Should -Contain "Name"
            $schema.Keys | Should -Contain "Registry"
            $schema.Keys | Should -Contain "Package"
            $schema.Keys | Should -Contain "Service"
            $schema.Keys | Should -Contain "Feature"
            $schema.Keys | Should -Contain "Trigger"
        }
    }
}
