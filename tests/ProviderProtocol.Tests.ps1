BeforeAll {
    $script:WinSpecRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'winspec'
    Import-Module (Join-Path $script:WinSpecRoot 'provider-runtime.psm1') -Force
    Import-Module (Join-Path $script:WinSpecRoot 'actions.psm1') -Force

    function ConvertTo-TestProcessArgument {
        param([string]$Value)
        return '"' + $Value.Replace('"', '\"') + '"'
    }

    function Start-TestHttpServer {
        param(
            [Parameter(Mandatory)][string]$ContentPath,
            [ValidateRange(0, 10)][int]$RedirectCount = 0,
            [switch]$OmitContentLength
        )

        $reservation = [Net.Sockets.TcpListener]::new(
            [Net.IPAddress]::Loopback, 0)
        $reservation.Start()
        $port = $reservation.LocalEndpoint.Port
        $reservation.Stop()
        $id = [Guid]::NewGuid().ToString('N')
        $readyPath = Join-Path $TestDrive "$id.ready"
        $requestLogPath = Join-Path $TestDrive "$id.requests"
        $serverPath = Join-Path $PSScriptRoot 'fixtures/http-server.ps1'
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-File', $serverPath,
            '-Port', [string]$port, '-ContentPath', $ContentPath,
            '-ReadyPath', $readyPath, '-RequestLogPath', $requestLogPath,
            '-RequestCount', [string]($RedirectCount + 1),
            '-RedirectCount', [string]$RedirectCount)
        if ($OmitContentLength) { $arguments += '-OmitContentLength' }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Get-CurrentPowerShellPath
        $start.Arguments = (($arguments | ForEach-Object {
                    ConvertTo-TestProcessArgument ([string]$_)
                }) -join ' ')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'test HTTP server did not start' }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($readyPath) -and
            $timer.Elapsed.TotalSeconds -lt 10 -and -not $process.HasExited) {
            Start-Sleep -Milliseconds 20
        }
        if (-not [IO.File]::Exists($readyPath)) {
            $errorText = $process.StandardError.ReadToEnd()
            $process.Dispose()
            throw "test HTTP server was not ready: $errorText"
        }
        return [pscustomobject]@{
            Process = $process
            Uri = "http://127.0.0.1:$port/start"
            RequestLogPath = $requestLogPath
        }
    }

    function Stop-TestHttpServer {
        param($Server)
        if (-not $Server) { return }
        if (-not $Server.Process.HasExited) { $Server.Process.Kill() }
        $Server.Process.Dispose()
    }

    function New-CopiedBundledProvider {
        param([Parameter(Mandatory)][string]$Name)
        $copiedRoot = Join-Path $TestDrive ('runtime-' + [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:WinSpecRoot -Destination $copiedRoot -Recurse
        $package = Join-Path (Join-Path $copiedRoot 'providers/bundled') $Name
        return [pscustomobject]@{
            Name = $Name
            Kind = 'Action'
            ProtocolVersion = 1
            Operations = @('run', 'preview')
            EntryPointType = 'PowerShell'
            EntryPoint = Join-Path $package 'provider.ps1'
            PackageRoot = $package
            Origin = 'Explicit'
            Execution = 'Protocol'
        }
    }
}

Describe 'static provider catalog' {
    It 'ships a complete inert package for every bundled Action' {
        $catalog = @(Get-ProviderCatalog | Where-Object Origin -EQ 'Bundled')

        $catalog.Name | Should -Be @(
            'MicrosoftActivation', 'OfficeDeployment', 'WindowsDebloat')
        foreach ($provider in $catalog) {
            Test-Path (Join-Path $provider.PackageRoot 'provider.json') |
                Should -BeTrue
            Test-Path (Join-Path $provider.PackageRoot 'sources.json') |
                Should -BeFalse
            Test-Path (Join-Path $provider.PackageRoot 'README.md') |
                Should -BeTrue
            $provider.Operations | Should -Contain 'preview'
        }
    }

    It 'previews current-script launchers without resolving or downloading them' -ForEach @(
        @{
            Name = 'MicrosoftActivation'
            Uri = 'https://get.activated.win/'
        }
        @{
            Name = 'WindowsDebloat'
            Uri = 'https://debloat.raphi.re/'
        }
    ) {
        $provider = Get-ProviderCatalog | Where-Object Name -EQ $Name

        $response = Invoke-WinSpecAction -Action @{
            Use = $Name
            With = @{ Args = @('-Configured'); Interactive = $true }
        } -Provider $provider -Arguments @('-Forwarded') -DryRun `
            -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be 'Planned'
        $response.Output.requestedUri | Should -Be $Uri
        @($response.Output.arguments) | Should -Be @('-Configured', '-Forwarded')
        $response.Output.interactive | Should -BeTrue
        $response.Output.downloadsCurrentCode | Should -BeTrue
        $response.Output.opaque | Should -BeTrue
        $response.Output.PSObject.Properties.Name | Should -Not -Contain 'sourceVersion'
    }

    It 'previews the Office online installer with Path and Cache only' {
        $provider = Get-ProviderCatalog |
            Where-Object Name -EQ 'OfficeDeployment'

        $response = Invoke-WinSpecAction -Action @{
            Use = 'OfficeDeployment'
            With = @{ Path = './office'; Cache = $true }
        } -Provider $provider -DryRun -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be 'Planned'
        $response.Output.requestedUri | Should -Match '^https://c2rsetup[.]officeapps[.]live[.]com/'
        $response.Output.path | Should -Be (
            [IO.Path]::GetFullPath((Join-Path $TestDrive 'office')))
        $response.Output.cache | Should -BeTrue
        $response.Output.downloadsCurrentInstaller | Should -BeTrue
        $response.Output.PSObject.Properties.Name | Should -Not -Contain 'sourceVersion'
    }

    It 'rejects retired bundled configuration instead of translating it' -ForEach @(
        @{ Name = 'MicrosoftActivation'; Configuration = @{ Method = 'HWID' } }
        @{ Name = 'WindowsDebloat'; Configuration = @{ Profile = 'DefaultsLite' } }
        @{ Name = 'OfficeDeployment'; Configuration = @{ ConfigurationFile = './office.xml' } }
    ) {
        $provider = Get-ProviderCatalog | Where-Object Name -EQ $Name

        $response = Invoke-WinSpecAction -Action @{
            Use = $Name
            With = $Configuration
        } -Provider $provider -DryRun -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be 'Failed'
        $response.Diagnostics[0].code | Should -Be 'UnknownConfigurationField'
    }

    It 'lists a manifest without executing its entrypoint' {
        $root = Join-Path $TestDrive 'providers'
        $package = Join-Path $root 'acme'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        $sentinel = Join-Path $TestDrive 'executed'
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Encoding UTF8 -Value (
            "Set-Content -LiteralPath '$sentinel' -Value bad")
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"Acme","kind":"State","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["capture","compare","apply"]}')

        $catalog = Get-ProviderCatalog -ProviderPath $root

        @($catalog | Where-Object Name -EQ 'Acme').Count | Should -Be 1
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }

    It 'rejects a provider name colliding with a built-in' {
        $root = Join-Path $TestDrive 'collision'
        $package = Join-Path $root 'registry'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Value (
            '{"schemaVersion":1,"name":"registry","kind":"State","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["capture","compare","apply"]}')

        { Get-ProviderCatalog -ProviderPath $root } | Should -Throw '*DuplicateProvider*'
    }
}

Describe 'external provider process protocol' {
    It 'forwards the Action envelope and arguments without reshaping them' {
        $root = Join-Path $TestDrive 'action-runtime'
        $package = Join-Path $root 'record'
        $record = Join-Path $TestDrive 'request.json'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Encoding UTF8 -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$request | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath '$record'
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Succeeded'
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') `
            -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"Record","kind":"Action","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["run","preview"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root |
            Where-Object Name -EQ 'Record'

        $null = Invoke-WinSpecAction `
            -Action @{ Use = 'Record'; With = @{ Value = 'kept' } } `
            -Provider $provider -Arguments @('one', 'two') `
            -TimeoutSeconds 10

        $request = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json
        $request.input.configuration.Value | Should -Be 'kept'
        @($request.input.arguments) | Should -Be @('one', 'two')
        $request.input.executionPolicy.timeoutSeconds | Should -Be 10
        $request.PSObject.Properties.Name | Should -Not -Contain 'mode'
        $request.input.executionPolicy.PSObject.Properties.Name |
            Should -Not -Contain 'allowUnverifiedCode'
        $temporaryDirectory = $request.input.executionPolicy.temporaryDirectory
        $temporaryDirectory | Should -Match 'winspec-provider-[0-9a-f-]+$'
        Test-Path -LiteralPath $temporaryDirectory | Should -BeFalse
    }

    It 'rejects unknown response fields' {
        $root = Join-Path $TestDrive 'extra-response'
        $package = Join-Path $root 'extra'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Encoding UTF8 -Value @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = 'Succeeded'
    output = @{}
    diagnostics = @()
    extra = $true
} | ConvertTo-Json -Depth 10 -Compress
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') `
            -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"Extra","kind":"Action","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["run"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root |
            Where-Object Name -EQ 'Extra'

        { Invoke-ExternalProvider $provider run @{} -TimeoutSeconds 10 } |
            Should -Throw '*unknown field*'
    }

    It '<Kind> <Operation> rejects illegal status <Status>' -ForEach @(
        @{
            Kind = 'Action'; Operations = @('run'); Operation = 'run'
            Status = 'Planned'
        }
        @{
            Kind = 'Action'; Operations = @('run', 'preview')
            Operation = 'preview'; Status = 'Succeeded'
        }
        @{
            Kind = 'State'; Operations = @('capture', 'compare', 'apply')
            Operation = 'capture'; Status = 'Different'
        }
        @{
            Kind = 'State'; Operations = @('capture', 'compare', 'apply')
            Operation = 'compare'; Status = 'Succeeded'
        }
        @{
            Kind = 'State'; Operations = @('capture', 'compare', 'apply')
            Operation = 'apply'; Status = 'Planned'
        }
    ) {
        $root = Join-Path $TestDrive 'invalid-status'
        $name = "Invalid$Kind$Operation"
        $package = Join-Path $root $name
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Encoding UTF8 -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = '$Status'
    output = @{}
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
"@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') `
            -Encoding UTF8 -Value (@{
                schemaVersion = 1
                name = $name
                kind = $Kind
                protocolVersion = 1
                script = 'provider.ps1'
                operations = @($Operations)
            } | ConvertTo-Json -Depth 5 -Compress)
        $provider = Get-ProviderCatalog -ProviderPath $root |
            Where-Object Name -EQ $name

        { Invoke-ExternalProvider -Provider $provider -Operation $Operation `
                -Input @{} -TimeoutSeconds 10 } |
            Should -Throw "*InvalidProviderStatus*$Operation*$Status*"
    }

    It 'rejects malformed provider <Field>' -ForEach @(
        @{
            Field = 'output'; Output = '@()'; Diagnostics = '@()'
            Expected = '*output must be an object*'
        }
        @{
            Field = 'diagnostics'; Output = '@{}'; Diagnostics = '@(''bad'')'
            Expected = '*each diagnostic needs string code and message*'
        }
    ) {
        $root = Join-Path $TestDrive "invalid-$Field"
        $package = Join-Path $root 'invalid'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Encoding UTF8 -Value @"
`$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
@{
    protocolVersion = 1
    requestId = `$request.requestId
    status = 'Succeeded'
    output = $Output
    diagnostics = $Diagnostics
} | ConvertTo-Json -Depth 10 -Compress
"@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') `
            -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"InvalidShape","kind":"Action","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["run"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root |
            Where-Object Name -EQ 'InvalidShape'

        { Invoke-ExternalProvider -Provider $provider -Operation run `
                -Input @{} -TimeoutSeconds 10 } | Should -Throw $Expected
    }

    It 'allows a provider to own and wait for a child process' {
        $root = Join-Path $TestDrive 'child-runtime'
        $package = Join-Path $root 'child'
        $sentinel = Join-Path $TestDrive 'child-finished'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'child.ps1') `
            -Encoding UTF8 -Value @'
param([string]$Path)
Set-Content -LiteralPath $Path -Value 'finished'
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') `
            -Encoding UTF8 -Value @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
$hostPath = (Get-Process -Id $PID).Path
$childPath = Join-Path $PSScriptRoot 'child.ps1'
& $hostPath -NoProfile -NonInteractive -File $childPath $request.input.configuration.sentinel
$exitCode = $LASTEXITCODE
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
    output = @{ childExitCode = $exitCode }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') `
            -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"Child","kind":"Action","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["run"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root |
            Where-Object Name -EQ 'Child'

        $result = Invoke-WinSpecAction `
            -Action @{ Use = 'Child'; With = @{ sentinel = $sentinel } } `
            -Provider $provider -TimeoutSeconds 10

        $result.Status | Should -Be 'Succeeded'
        (Get-Content -Raw -LiteralPath $sentinel).Trim() | Should -Be 'finished'
    }

    It 'round-trips one bounded request and response' {
        $root = Join-Path $TestDrive 'runtime'
        $package = Join-Path $root 'echo'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Encoding UTF8 -Value @'
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
@{
    protocolVersion = 1
    requestId = $request.requestId
    status = 'Succeeded'
    output = @{ echoed = $request.input.configuration.value }
    diagnostics = @()
} | ConvertTo-Json -Depth 10 -Compress
'@
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Encoding UTF8 -Value (
            '{"schemaVersion":1,"name":"Echo","kind":"State","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["capture","compare","apply"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root | Where-Object Name -EQ 'Echo'

        $value = -join @(
            [char]0x4f60, [char]0x597d, [char]0x20, [char]0x220e)
        $response = Invoke-ExternalProvider -Provider $provider -Operation capture -Input @{
            configuration = @{ value = $value }
            arguments = @()
        } -TimeoutSeconds 10

        $response.Status | Should -Be 'Succeeded'
        $response.Output.echoed | Should -Be $value
    }

    It 'times out without interpreting partial output as success' {
        $root = Join-Path $TestDrive 'timeout'
        $package = Join-Path $root 'slow'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $package 'provider.ps1') -Value (
            '[Console]::In.ReadToEnd() | Out-Null; Start-Sleep -Seconds 5')
        Set-Content -LiteralPath (Join-Path $package 'provider.json') -Value (
            '{"schemaVersion":1,"name":"Slow","kind":"Action","protocolVersion":1,' +
            '"script":"provider.ps1","operations":["run"]}')
        $provider = Get-ProviderCatalog -ProviderPath $root | Where-Object Name -EQ 'Slow'

        { Invoke-ExternalProvider -Provider $provider -Operation run -Input @{} -TimeoutSeconds 1 } |
            Should -Throw '*ProviderTimeout*'
    }

    It 'removes its temporary directory when request serialization exceeds the bound' {
        $provider = [pscustomobject]@{
            Name = 'NeverStarted'
            Operations = @('run')
            Execution = 'Protocol'
            EntryPointType = 'PowerShell'
            EntryPoint = Join-Path $TestDrive 'missing.ps1'
            PackageRoot = $TestDrive
        }
        $temporaryRoot = Join-Path $TestDrive 'provider-temporary-root'
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $previousTemp = $env:TEMP
        $previousTmp = $env:TMP
        try {
            $env:TEMP = $temporaryRoot
            $env:TMP = $temporaryRoot
            { Invoke-ExternalProvider -Provider $provider -Operation run -Input @{
                    configuration = @{ value = ('x' * (4MB + 1)) }
                } -TimeoutSeconds 10 } |
                Should -Throw '*ProviderRequestTooLarge*'

            @(Get-ChildItem -LiteralPath $temporaryRoot -Directory `
                    -Filter 'winspec-provider-*').Count | Should -Be 0
        }
        finally {
            $env:TEMP = $previousTemp
            $env:TMP = $previousTmp
        }
    }
}

Describe 'bundled current-script execution' {
    AfterEach {
        Stop-TestHttpServer $script:testServer
        $script:testServer = $null
    }

    It 'streams, identifies, forwards, waits, and cleans up using only the current endpoint' -ForEach @(
        @{ Name = 'MicrosoftActivation'; Official = 'https://get.activated.win/'; ExitCode = 0 }
        @{ Name = 'WindowsDebloat'; Official = 'https://debloat.raphi.re/'; ExitCode = 7 }
    ) {
        $bodyPath = Join-Path $TestDrive "$Name.ps1"
        $body = @"
param([string]`$First, [string]`$Second)
Write-Output "`$First|`$Second|`$PSCommandPath"
exit $ExitCode
"@
        [IO.File]::WriteAllText(
            $bodyPath, $body, (New-Object Text.UTF8Encoding($false)))
        $script:testServer = Start-TestHttpServer $bodyPath -RedirectCount 1
        $provider = New-CopiedBundledProvider $Name
        $entryText = [IO.File]::ReadAllText($provider.EntryPoint)
        [IO.File]::WriteAllText(
            $provider.EntryPoint,
            $entryText.Replace($Official, $script:testServer.Uri),
            (New-Object Text.UTF8Encoding($false)))

        $response = Invoke-WinSpecAction -Action @{
            Use = $Name
            With = @{ Args = @('configured') }
        } -Provider $provider -Arguments @('forwarded') `
            -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be $(if ($ExitCode -eq 0) {
                'Succeeded'
            }
            else {
                'Failed'
            })
        $response.Output.requestedUri | Should -Be $script:testServer.Uri
        $response.Output.finalUri | Should -Match '/redirect-0$'
        $response.Output.receivedBytes | Should -Be (
            [IO.File]::ReadAllBytes($bodyPath).Length)
        $response.Output.receivedSha256 | Should -Be (
            Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $response.Output.digestVerified | Should -BeFalse
        $response.Output.exitCode | Should -Be $ExitCode
        @($response.Output.arguments) | Should -Be @('configured', 'forwarded')
        $parts = $response.Output.stdout.Trim() -split '[|]'
        $parts[0..1] | Should -Be @('configured', 'forwarded')
        Test-Path -LiteralPath $parts[2] | Should -BeFalse
        @(Get-Content -LiteralPath $script:testServer.RequestLogPath).Count |
            Should -Be 2
    }

    It 'downloads a Microsoft-signed Office installer into Path without starting it when cached' {
        $bodyPath = Join-Path $env:SystemRoot 'System32/where.exe'
        $script:testServer = Start-TestHttpServer $bodyPath
        $provider = New-CopiedBundledProvider 'OfficeDeployment'
        $lines = [Collections.Generic.List[string]]@(
            [IO.File]::ReadAllLines($provider.EntryPoint))
        $sourceLine = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^[$]sourceUri = ') {
                $sourceLine = $index
                break
            }
        }
        $sourceLine | Should -BeGreaterOrEqual 0
        $lines[$sourceLine] = '$sourceUri = [uri]''' + $script:testServer.Uri + ''''
        $lines.RemoveAt($sourceLine + 1)
        [IO.File]::WriteAllLines(
            $provider.EntryPoint, $lines, (New-Object Text.UTF8Encoding($false)))
        $target = Join-Path $TestDrive 'office-cache'

        $response = Invoke-WinSpecAction -Action @{
            Use = 'OfficeDeployment'
            With = @{ Path = $target; Cache = $true }
        } -Provider $provider -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be 'Succeeded'
        $response.Output.publisherVerified | Should -BeTrue
        $response.Output.digestVerified | Should -BeFalse
        $response.Output.cache | Should -BeTrue
        $response.Output.PSObject.Properties.Name | Should -Not -Contain 'exitCode'
        $installer = Join-Path $target 'OfficeSetup.exe'
        Test-Path -LiteralPath $installer | Should -BeTrue
        (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash
        @(Get-Content -LiteralPath $script:testServer.RequestLogPath).Count |
            Should -Be 1
    }

    It 'bounds child stdout without corrupting the provider response' {
        $bodyPath = Join-Path $TestDrive 'large-output.ps1'
        [IO.File]::WriteAllText(
            $bodyPath, '[Console]::Out.Write((''x'' * (1MB + 4096)))',
            (New-Object Text.UTF8Encoding($false)))
        $script:testServer = Start-TestHttpServer $bodyPath
        $provider = New-CopiedBundledProvider 'MicrosoftActivation'
        $entryText = [IO.File]::ReadAllText($provider.EntryPoint)
        [IO.File]::WriteAllText(
            $provider.EntryPoint,
            $entryText.Replace('https://get.activated.win/', $script:testServer.Uri),
            (New-Object Text.UTF8Encoding($false)))

        $response = Invoke-WinSpecAction `
            -Action @{ Use = 'MicrosoftActivation' } -Provider $provider `
            -BasePath $TestDrive -TimeoutSeconds 10

        $response.Status | Should -Be 'Succeeded'
        $response.Output.stdout.Length | Should -Be 1MB
        $response.Output.stdoutTruncated | Should -BeTrue
    }

    It 'deletes a partial file when the download exceeds its byte bound' {
        $bodyPath = Join-Path $TestDrive 'oversize.bin'
        [IO.File]::WriteAllBytes($bodyPath, (New-Object byte[] 1025))
        $script:testServer = Start-TestHttpServer $bodyPath -OmitContentLength
        $downloadRoot = Join-Path $TestDrive 'bounded-download'
        $null = New-Item -ItemType Directory -Path $downloadRoot
        Import-Module (Join-Path $script:WinSpecRoot `
                'providers/bundled/common.psm1') -Force -Prefix Test

        { Get-TestBundledDownload -Uri $script:testServer.Uri `
                -Directory $downloadRoot -MaximumBytes 1024 `
                -TimeoutSeconds 10 } | Should -Throw '*DownloadTooLarge*'

        @(Get-ChildItem -LiteralPath $downloadRoot -File).Count | Should -Be 0
    }

    It 'removes the invocation temporary directory after timeout' {
        $bodyPath = Join-Path $TestDrive 'slow.ps1'
        $pathRecord = Join-Path $TestDrive 'slow-path.txt'
        [IO.File]::WriteAllText(
            $bodyPath, @'
param([string]$PathRecord)
[IO.File]::WriteAllText($PathRecord, $PSCommandPath)
Start-Sleep -Seconds 10
'@,
            (New-Object Text.UTF8Encoding($false)))
        $script:testServer = Start-TestHttpServer $bodyPath
        $provider = New-CopiedBundledProvider 'MicrosoftActivation'
        $entryText = [IO.File]::ReadAllText($provider.EntryPoint)
        [IO.File]::WriteAllText(
            $provider.EntryPoint,
            $entryText.Replace('https://get.activated.win/', $script:testServer.Uri),
            (New-Object Text.UTF8Encoding($false)))

        $response = $null
        $timeoutMessage = $null
        try {
            $response = Invoke-WinSpecAction `
                -Action @{
                Use = 'MicrosoftActivation'
                With = @{ Args = @($pathRecord) }
            } -Provider $provider -BasePath $TestDrive -TimeoutSeconds 3
        }
        catch {
            $timeoutMessage = $_.Exception.Message
        }
        if ($response) {
            $response.Status | Should -Be 'Failed'
            $response.Diagnostics[0].code | Should -Be 'ChildTimeout'
        }
        else {
            $timeoutMessage | Should -Match '^ProviderTimeout:'
        }
        Test-Path -LiteralPath $pathRecord | Should -BeTrue
        $downloadedPath = [IO.File]::ReadAllText($pathRecord)
        Test-Path -LiteralPath $downloadedPath | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($downloadedPath)) |
            Should -BeFalse
    }
}

Describe 'core remote Script execution' {
    AfterEach {
        Stop-TestHttpServer $script:testServer
        $script:testServer = $null
    }

    It 'streams and executes an HTTP Script when its digest is pinned' {
        $bodyPath = Join-Path $TestDrive 'pinned.ps1'
        [IO.File]::WriteAllText(
            $bodyPath, 'Write-Output $PSCommandPath',
            (New-Object Text.UTF8Encoding($false)))
        $script:testServer = Start-TestHttpServer $bodyPath -RedirectCount 1
        $digest = (Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash

        $response = Invoke-ScriptAction -Configuration @{
            Uri = $script:testServer.Uri
            Sha256 = $digest
        } -TimeoutSeconds 10

        $response.Status | Should -Be 'Succeeded'
        $response.Integrity | Should -Be 'Pinned'
        $response.RequestedUri | Should -Be $script:testServer.Uri
        $response.FinalUri | Should -Match '/redirect-0$'
        $response.ReceivedBytes | Should -Be (
            [IO.File]::ReadAllBytes($bodyPath).Length)
        $response.ReceivedSha256 | Should -Be $digest.ToLowerInvariant()
        $response.DigestVerified | Should -BeTrue
        $downloadedPath = $response.Stdout.Trim()
        Test-Path -LiteralPath $downloadedPath | Should -BeFalse
    }

    It 'removes a partial core Script when the streaming byte bound is exceeded' {
        $bodyPath = Join-Path $TestDrive 'oversize-script.ps1'
        [IO.File]::WriteAllBytes(
            $bodyPath, (New-Object byte[] (16MB + 1)))
        $script:testServer = Start-TestHttpServer $bodyPath -OmitContentLength
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) `
                -File -Filter 'winspec-script-*.ps1').FullName

        { Invoke-ScriptAction -Configuration @{
                Uri = $script:testServer.Uri
                Sha256 = ('0' * 64)
            } -TimeoutSeconds 10 } | Should -Throw '*RemoteScriptTooLarge*'

        $after = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) `
                -File -Filter 'winspec-script-*.ps1').FullName
        @($after | Where-Object { $_ -notin $before }).Count | Should -Be 0
    }
}
