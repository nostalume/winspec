BeforeAll {
    $script:Root = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'winspec'
    Import-Module (Join-Path $script:Root 'state.psm1') -Force
    Import-Module (Join-Path $script:Root 'merge.psm1') -Force
    Import-Module (Join-Path $script:Root 'schema.psm1') -Force
    Import-Module (Join-Path $script:Root 'provider-runtime.psm1') -Force
}

Describe 'built-in state authority' {
    It 'uses only the three explicit built-in state managers' {
        @(Get-Managers).Name | Should -Be @('Registry', 'Service', 'Feature')
    }

    It 'rejects an unknown selected provider' {
        { Resolve-ProviderList (Get-Managers) @('missing') } | Should -Throw '*UnknownProvider*'
    }

    It 'uses core-only defaults and spec-derived defaults without ambiguity' {
        $catalog = @(
            [pscustomobject]@{Name = 'Registry'; Kind = 'State'; Execution = 'Core' }
            [pscustomobject]@{Name = 'Acme'; Kind = 'State'; Execution = 'Protocol' }
        )

        @(Resolve-WinSpecStateProviders $catalog).Name |
            Should -Be @('Registry')
        @(Resolve-WinSpecStateProviders -Catalog $catalog `
                -Spec @{Acme = @{} } -SpecScoped).Name |
            Should -Be @('Acme')
        @(Resolve-WinSpecStateProviders -Catalog $catalog `
                -Providers @('Acme')).Name |
            Should -Be @('Acme')
    }
}

Describe 'schema and merge truth' {
    It 'accepts the versioned core schema and rejects removed trigger fields' {
        $catalog = Get-ProviderCatalog
        (Test-WinSpecSchema @{SchemaVersion = 1; Actions = @{} } $catalog).Valid | Should -BeTrue
        (Test-WinSpecSchema @{SchemaVersion = 1; Trigger = @('old') } $catalog).Valid | Should -BeFalse
    }

    It 'propagates a nested auto conflict and does not claim success' {
        $result = Invoke-MergeEngine -Base @{A = @{B = 1 } } -Incoming @{A = @{B = 2 } } -Strategy auto
        $result.Success | Should -BeFalse
        $result.Conflicts.Count | Should -Be 1
        $result.Conflicts[0].Path | Should -Be 'A.B'
    }

    It 'replaces conflicting values under theirs' {
        $result = Invoke-MergeEngine -Base @{A = @{B = 1 } } -Incoming @{A = @{B = 2 } } -Strategy theirs
        $result.Success | Should -BeTrue
        $result.Merged.A.B | Should -Be 2
    }
}

Describe 'built-in state admission' {
    BeforeAll {
        $script:Catalog = Get-ProviderCatalog
    }

    It 'rejects invalid mapped and primitive Registry values' -ForEach @(
        @{ Value = 'diagonal'; Path = 'Taskbar'; Property = 'Alignment' }
        @{ Value = 12; Path = 'Desktop'; Property = 'MenuShowDelay' }
        @{ Value = -1; Path = 'Desktop'; Property = 'ForegroundLockTimeout' }
        @{ Value = 4294967296; Path = 'Desktop'; Property = 'ForegroundLockTimeout' }
    ) {
        $spec = @{ SchemaVersion = 1; Registry = @{} }
        $spec.Registry[$Path] = @{$Property = $Value }

        (Test-WinSpecSchema $spec $script:Catalog).Valid | Should -BeFalse
    }

    It 'rejects services outside the safety allow-list' {
        $spec = @{
            SchemaVersion = 1
            Service = @{ EventLog = @{ State = 'running' } }
        }

        $result = Test-WinSpecSchema $spec $script:Catalog

        $result.Valid | Should -BeFalse
        $result.Errors | Should -Match 'ServiceNotManaged'
    }

    It 'accepts case-insensitive built-in State values and DWord bounds' {
        $spec = @{
            SchemaVersion = 1
            Registry = @{ Desktop = @{ ForegroundLockTimeout = 4294967295 } }
            Service = @{ WUAUSERV = @{ State = 'RUNNING'; Startup = 'MANUAL' } }
            Feature = @{ TelnetClient = 'DISABLED' }
        }

        (Test-WinSpecSchema $spec $script:Catalog).Valid | Should -BeTrue
    }

    It 'keeps the documented Registry inventory anchored to metadata' {
        InModuleScope schema {
            $count = 0
            foreach ($category in (Get-RegistryMaps).Values) {
                $count += $category.Properties.Count
            }

            $count | Should -Be 15
        }
    }
}

Describe 'core State result normalization' {
    It 'fails a partially applied provider and preserves sibling receipts' {
        InModuleScope state {
            $catalog = @([pscustomobject]@{
                    Name = 'Registry'
                    Kind = 'State'
                    Execution = 'Core'
                    Operations = @('capture', 'compare', 'apply')
                })
            Mock Get-Managers {
                @([pscustomobject]@{
                        Name = 'Registry'
                        Type = 'State'
                        Path = 'unused'
                    })
            }
            Mock Invoke-Manager {
                @{
                    Desktop = @{
                        MenuShowDelay = @{ Status = 'Applied'; Value = '0' }
                        ForegroundLockTimeout = @{
                            Status = 'Error'
                            Reason = 'AccessDenied'
                            Message = 'denied'
                        }
                    }
                }
            }

            $result = Invoke-WinSpecStateApply `
                -Spec @{Registry = @{Desktop = @{MenuShowDelay = '0' } } } `
                -Catalog $catalog

            $result.Status | Should -Be 'Failed'
            $result.Providers[0].Status | Should -Be 'Failed'
            $result.Providers[0].Output.Desktop.MenuShowDelay.Status |
                Should -Be 'Applied'
            $result.Providers[0].Diagnostics[0].Code | Should -Be 'AccessDenied'
            $result.Providers[0].Diagnostics[0].Resource |
                Should -Be 'Registry.Desktop.ForegroundLockTimeout'
        }
    }

    It 'translates an unexpected core apply exception at the provider boundary' {
        InModuleScope state {
            $catalog = @([pscustomobject]@{
                    Name = 'Registry'
                    Kind = 'State'
                    Execution = 'Core'
                    Operations = @('capture', 'compare', 'apply')
                })
            Mock Get-Managers {
                @([pscustomobject]@{
                        Name = 'Registry'
                        Type = 'State'
                        Path = 'unused'
                    })
            }
            Mock Invoke-Manager { throw 'AccessDenied: simulated failure' }

            $result = Invoke-WinSpecStateApply `
                -Spec @{Registry = @{Desktop = @{MenuShowDelay = '0' } } } `
                -Catalog $catalog

            $result.Status | Should -Be 'Failed'
            $result.Providers[0].Status | Should -Be 'Failed'
            $result.Providers[0].Diagnostics[0].code | Should -Be 'AccessDenied'
            $result.Providers[0].Diagnostics[0].resource |
                Should -Be 'Registry'
        }
    }
}
