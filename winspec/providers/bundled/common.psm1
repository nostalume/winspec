Import-Module (Join-Path $PSScriptRoot '../../provider-runtime.psm1') -ErrorAction Stop

$Script:MaximumScriptBytes = 16MB

function Read-BundledProviderRequest {
    $text = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'InvalidRequest: standard input is empty'
    }
    return $text | ConvertFrom-Json -ErrorAction Stop
}

function Write-BundledProviderResponse {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Status,
        [hashtable]$Output = @{},
        [object[]]$Diagnostics = @()
    )

    [ordered]@{
        protocolVersion = 1
        requestId = $Request.requestId
        status = $Status
        output = $Output
        diagnostics = @($Diagnostics)
    } | ConvertTo-Json -Depth 32 -Compress
}

function Write-BundledProviderFailure {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    Write-BundledProviderResponse $Request 'Failed' @{} @(@{
            code = ($message -split ':')[0]
            message = $message
        })
}

function Assert-BundledProviderFields {
    param($Configuration, [string[]]$Allowed)

    if ($null -eq $Configuration) { return }
    foreach ($property in @($Configuration.PSObject.Properties.Name |
                Where-Object { $null -ne $_ })) {
        if ($property -notin $Allowed) {
            throw "UnknownConfigurationField: '$property'"
        }
    }
}

function Get-BundledActionConfiguration {
    param([Parameter(Mandatory)]$Request)

    $configuration = $Request.input.configuration
    if ($null -eq $configuration) {
        return [pscustomobject]@{}
    }
    return $configuration
}

function Get-BundledActionArguments {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$Configuration)

    $arguments = @()
    if ($Configuration.PSObject.Properties.Name -contains 'Args') {
        $arguments += @($Configuration.Args)
    }
    $arguments += @($Request.input.arguments)
    foreach ($argument in $arguments) {
        if ($argument -isnot [string]) {
            throw 'InvalidActionArguments: every argument must be a string'
        }
    }
    return @($arguments)
}

function Get-BundledInteraction {
    param([Parameter(Mandatory)]$Configuration)

    if ($Configuration.PSObject.Properties.Name -notcontains 'Interactive') {
        return $false
    }
    if ($Configuration.Interactive -isnot [bool]) {
        throw 'InvalidInteractive: Interactive must be a Boolean'
    }
    return [bool]$Configuration.Interactive
}

function Get-BundledTimeoutSeconds {
    param([Parameter(Mandatory)]$Request)

    $value = $Request.input.executionPolicy.timeoutSeconds
    if ($value -isnot [int] -and $value -isnot [long]) {
        throw 'InvalidTimeout: timeoutSeconds must be an integer'
    }
    if ($value -lt 1 -or $value -gt 3600) {
        throw 'InvalidTimeout: timeoutSeconds must be between 1 and 3600'
    }
    return [int]$value
}

function Get-BundledTemporaryDirectory {
    param([Parameter(Mandatory)]$Request)

    $path = [string]$Request.input.executionPolicy.temporaryDirectory
    if ([string]::IsNullOrWhiteSpace($path)) {
        return [IO.Path]::GetTempPath()
    }
    $fullPath = [IO.Path]::GetFullPath($path)
    if (-not [IO.Directory]::Exists($fullPath)) {
        throw "TemporaryDirectoryNotFound: '$fullPath'"
    }
    return $fullPath
}

function Get-BundledDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateRange(1, 1GB)][long]$MaximumBytes,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [string]$Extension = '.bin'
    )

    if ($Uri.Scheme -notin @('http', 'https')) {
        throw "InvalidDownloadUri: '$Uri'"
    }
    if (-not [IO.Directory]::Exists($Directory)) {
        throw "DownloadDirectoryNotFound: '$Directory'"
    }

    $path = Join-Path $Directory ([IO.Path]::GetRandomFileName() + $Extension)
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $request.UserAgent = 'WinSpec/1'
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $completed = $false
    $primaryError = $null
    try {
        $response = $request.GetResponse()
        if ($response.ContentLength -gt $MaximumBytes) {
            throw "DownloadTooLarge: exceeds $MaximumBytes bytes"
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open(
            $path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $buffer = New-Object byte[] 81920
        $size = [long]0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($size + $read -gt $MaximumBytes) {
                throw "DownloadTooLarge: exceeds $MaximumBytes bytes"
            }
            $outputStream.Write($buffer, 0, $read)
            $null = $algorithm.TransformBlock($buffer, 0, $read, $null, 0)
            $size += $read
        }
        $empty = New-Object byte[] 0
        $null = $algorithm.TransformFinalBlock($empty, 0, 0)
        $digest = ([BitConverter]::ToString($algorithm.Hash)).Replace(
            '-', '').ToLowerInvariant()
        $completed = $true
        return [pscustomobject]@{
            Path = $path
            RequestedUri = $Uri.AbsoluteUri
            FinalUri = $response.ResponseUri.AbsoluteUri
            Size = $size
            Digest = $digest
        }
    }
    catch {
        $primaryError = $_
        throw
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $algorithm.Dispose()
        if (-not $completed -and [IO.File]::Exists($path)) {
            try {
                [IO.File]::Delete($path)
            }
            catch {
                if ($primaryError) {
                    $primaryError.Exception.Data['DownloadCleanupError'] =
                    $_.Exception.Message
                }
                else {
                    throw
                }
            }
        }
    }
}

function Test-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "InvalidPublisherSignature: '$Path' is not signed by Microsoft"
    }
}

function Invoke-BundledProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [switch]$Interactive,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    $start.Arguments = ((@($ArgumentList) | ForEach-Object {
                ConvertTo-ProcessArgument ([string]$_)
            }) -join ' ')
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    $start.UseShellExecute = [bool]$Interactive
    $start.CreateNoWindow = -not $Interactive
    if (-not $Interactive) {
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw "ChildStartFailed: '$FilePath'"
        }
        if ($Interactive) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-ProviderProcessTree $process
                throw "ChildTimeout: '$FilePath' exceeded $TimeoutSeconds seconds"
            }
            $streams = [pscustomobject]@{
                Stdout = $null
                Stderr = $null
                StdoutTruncated = $false
                StderrTruncated = $false
            }
        }
        else {
            $streams = Receive-BoundedProcessOutput -Process $process `
                -TimeoutSeconds $TimeoutSeconds -StdoutLimit 1MB `
                -StderrLimit 1MB `
                -TimeoutMessage "ChildTimeout: '$FilePath' exceeded $TimeoutSeconds seconds"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $streams.Stdout
            Stderr = $streams.Stderr
            StdoutTruncated = $streams.StdoutTruncated
            StderrTruncated = $streams.StderrTruncated
            DurationMilliseconds = $timer.ElapsedMilliseconds
            Interactive = [bool]$Interactive
        }
    }
    finally {
        $timer.Stop()
        $process.Dispose()
    }
}

function Invoke-BundledCurrentScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][uri]$Uri
    )

    $configuration = Get-BundledActionConfiguration $Request
    Assert-BundledProviderFields $configuration @('Args', 'Interactive')
    $arguments = @(Get-BundledActionArguments $Request $configuration)
    $interactive = Get-BundledInteraction $configuration
    if ($Request.operation -eq 'preview') {
        return [pscustomobject]@{
            Status = 'Planned'
            Output = @{
                requestedUri = $Uri.AbsoluteUri
                arguments = @($arguments)
                interactive = $interactive
                downloadsCurrentCode = $true
                opaque = $true
            }
        }
    }

    $timeout = Get-BundledTimeoutSeconds $Request
    $download = Get-BundledDownload -Uri $Uri `
        -Directory (Get-BundledTemporaryDirectory $Request) `
        -MaximumBytes $Script:MaximumScriptBytes -TimeoutSeconds $timeout `
        -Extension '.ps1'
    try {
        $hostArguments = @('-NoProfile')
        if (-not $interactive) { $hostArguments += '-NonInteractive' }
        $hostArguments += @('-File', $download.Path)
        $hostArguments += $arguments
        $result = Invoke-BundledProcess -FilePath (Get-CurrentPowerShellPath) `
            -ArgumentList $hostArguments -Interactive:$interactive `
            -TimeoutSeconds $timeout
        $output = @{
            requestedUri = $download.RequestedUri
            finalUri = $download.FinalUri
            receivedBytes = $download.Size
            receivedSha256 = $download.Digest
            digestVerified = $false
            arguments = @($arguments)
            interactive = $interactive
            captureMode = if ($interactive) { 'Inherited' } else { 'Bounded' }
            exitCode = $result.ExitCode
            durationMilliseconds = $result.DurationMilliseconds
            stdout = $result.Stdout
            stderr = $result.Stderr
            stdoutTruncated = $result.StdoutTruncated
            stderrTruncated = $result.StderrTruncated
        }
        return [pscustomobject]@{
            Status = if ($result.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }
            Output = $output
        }
    }
    finally {
        if ([IO.File]::Exists($download.Path)) {
            [IO.File]::Delete($download.Path)
        }
    }
}

Export-ModuleMember -Function @(
    'Read-BundledProviderRequest', 'Write-BundledProviderResponse',
    'Write-BundledProviderFailure', 'Assert-BundledProviderFields',
    'Get-BundledActionConfiguration', 'Get-BundledActionArguments',
    'Get-BundledInteraction', 'Get-BundledTimeoutSeconds',
    'Get-BundledTemporaryDirectory', 'Get-BundledDownload',
    'Test-MicrosoftSignature', 'Invoke-BundledProcess',
    'Invoke-BundledCurrentScript')
