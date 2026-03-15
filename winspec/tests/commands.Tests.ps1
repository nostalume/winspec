# tests/commands.Tests.ps1 - Tests for WinSpec CLI commands via module functions

BeforeAll {
    $script:WinspecRoot = $PSScriptRoot | Split-Path -Parent
    
    # Import modules in the same way as other test files
    Import-Module "$script:WinspecRoot\logging.psm1" -Force
    Import-Module "$script:WinspecRoot\utils.psm1" -Force
    Import-Module "$script:WinspecRoot\state.psm1" -Force
    Import-Module "$script:WinspecRoot\registry-maps.psm1" -Force
    Import-Module "$script:WinspecRoot\schema.psm1" -Force
    Import-Module "$script:WinspecRoot\pull.psm1" -Force
    Import-Module "$script:WinspecRoot\push.psm1" -Force
    
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

Describe "WinSpec CLI Commands - Spec Schema Validation" {
    Context "Valid specifications" {
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

Describe "WinSpec CLI Commands - Pull Command" {
    Context "Invoke-Pull" {
        It "Should accept Output parameter" {
            { Invoke-Pull -Output "test.ps1" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Providers parameter" {
            { Invoke-Pull -Providers @("Package") -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept DryRun parameter (via WhatIf)" {
            { Invoke-Pull -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Template parameter" {
            { Invoke-Pull -Template -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Minimal parameter" {
            { Invoke-Pull -Minimal -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Name parameter" {
            { Invoke-Pull -Name "Test Config" -WhatIf } | Should -Not -Throw
        }
        
        It "Should accept Description parameter" {
            { Invoke-Pull -Description "Test description" -WhatIf } | Should -Not -Throw
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
            $schema.Keys | Should -Contain "Scoop"
            $schema.Keys | Should -Contain "Winget"
            $schema.Keys | Should -Contain "Service"
            $schema.Keys | Should -Contain "Feature"
            $schema.Keys | Should -Contain "Trigger"
        }
    }
}
