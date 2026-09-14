@{
    SchemaVersion = 1
    Actions = @{
        activateWindows = @{
            Use = 'MicrosoftActivation'
            With = @{ Args = @('/HWID') }
        }
        activateOffice = @{
            Use = 'MicrosoftActivation'
            With = @{ Args = @('/Ohook') }
        }
        debloat = @{
            Use = 'WindowsDebloat'
            With = @{ Args = @('-RunDefaultsLite', '-Silent') }
        }
        deployOffice = @{
            Use = 'OfficeDeployment'
            With = @{ Path = './downloads/office'; Cache = $true }
        }
    }
    Workflows = @{
        prepare = @{
            Checkpoint = $true
            Steps = @(
                @{ Run = 'debloat' }
                @{ Run = 'deployOffice' }
                @{ Run = 'activateWindows' }
                @{ Run = 'activateOffice' }
                @{ Capture = @{
                        Output = './observed.winspec.psd1'
                        Providers = @('Registry', 'Service', 'Feature')
                    } }
            )
        }
    }
}
