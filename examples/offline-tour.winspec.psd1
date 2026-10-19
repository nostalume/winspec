@{
    SchemaVersion = 1
    Name = 'Offline CLI tour (no machine State)'
    Actions = @{
        hello = @{
            Use = 'Script'
            With = @{
                File = './scripts/hello.ps1'
                Args = @('configured')
            }
        }
    }
    Workflows = @{
        hello = @{ Steps = @(@{ Run = 'hello' }) }
    }
}
