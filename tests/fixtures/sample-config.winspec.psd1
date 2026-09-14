@{
    SchemaVersion = 1
    Name = 'Sample'
    Registry = @{
        Explorer = @{
            ShowHidden = $true
            ShowFileExt = $true
        }
    }
    Actions = @{
        hello = @{
            Use = 'Script'
            File = './hello.ps1'
            Args = @('world')
        }
    }
}
