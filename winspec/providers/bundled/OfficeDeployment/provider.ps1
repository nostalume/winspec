Import-Module (Join-Path $PSScriptRoot '../common.psm1') -ErrorAction Stop

$sourceUri = [uri]('https://c2rsetup.officeapps.live.com/c2r/download.aspx?' +
    'ProductreleaseID=O365ProPlusRetail&platform=x64&language=en-us&version=O16GA')
$request = Read-BundledProviderRequest
try {
    $configuration = Get-BundledActionConfiguration $request
    Assert-BundledProviderFields $configuration @('Path', 'Cache')
    if (@($request.input.arguments).Count -gt 0) {
        throw 'UnexpectedArguments: OfficeDeployment does not accept -- arguments'
    }
    if ($configuration.PSObject.Properties.Name -contains 'Path' -and
        ($configuration.Path -isnot [string] -or
        [string]::IsNullOrWhiteSpace($configuration.Path))) {
        throw 'InvalidOfficePath: Path must be a non-empty string'
    }
    if ($configuration.PSObject.Properties.Name -contains 'Cache' -and
        $configuration.Cache -isnot [bool]) {
        throw 'InvalidOfficeCache: Cache must be a Boolean'
    }

    $base = [string]$request.input.executionPolicy.workingDirectory
    $path = if ($configuration.Path) { [string]$configuration.Path } else { $base }
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $base $path }
    $path = [IO.Path]::GetFullPath($path)
    $cache = if ($configuration.PSObject.Properties.Name -contains 'Cache') {
        [bool]$configuration.Cache
    }
    else {
        $false
    }
    $installerPath = Join-Path $path 'OfficeSetup.exe'
    if ($request.operation -eq 'preview') {
        Write-BundledProviderResponse $request 'Planned' @{
            requestedUri = $sourceUri.AbsoluteUri
            path = $path
            installerPath = $installerPath
            cache = $cache
            downloadsCurrentInstaller = $true
            verifiesMicrosoftPublisher = $true
            opaque = $true
        }
        return
    }

    $timeout = Get-BundledTimeoutSeconds $request
    $download = Get-BundledDownload -Uri $sourceUri `
        -Directory (Get-BundledTemporaryDirectory $request) `
        -MaximumBytes 64MB -TimeoutSeconds $timeout -Extension '.exe'
    try {
        Test-MicrosoftSignature $download.Path
        if (-not [IO.Directory]::Exists($path)) {
            $null = [IO.Directory]::CreateDirectory($path)
        }
        [IO.File]::Copy($download.Path, $installerPath, $true)

        $output = @{
            requestedUri = $download.RequestedUri
            finalUri = $download.FinalUri
            receivedBytes = $download.Size
            receivedSha256 = $download.Digest
            digestVerified = $false
            publisherVerified = $true
            path = $path
            installerPath = $installerPath
            cache = $cache
        }
        if (-not $cache) {
            $result = Invoke-BundledProcess -FilePath $installerPath `
                -WorkingDirectory $path -TimeoutSeconds $timeout
            $output.exitCode = $result.ExitCode
            $output.durationMilliseconds = $result.DurationMilliseconds
            $output.stdout = $result.Stdout
            $output.stderr = $result.Stderr
            $output.stdoutTruncated = $result.StdoutTruncated
            $output.stderrTruncated = $result.StderrTruncated
            $status = if ($result.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }
        }
        else {
            $status = 'Succeeded'
        }
        Write-BundledProviderResponse $request $status $output
    }
    finally {
        if ([IO.File]::Exists($download.Path)) {
            [IO.File]::Delete($download.Path)
        }
    }
}
catch {
    Write-BundledProviderFailure $request $_
}
