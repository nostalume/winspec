@{
    SchemaVersion = 1
    Actions = @{
        hello = @{
            Use = 'Script'
            With = @{
                File = './scripts/hello.ps1'
                Args = @('configured')
            }
        }
    }
}
