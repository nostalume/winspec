Import-Module (Join-Path $PSScriptRoot 'spec.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'provider-runtime.psm1') -ErrorAction Stop

$Script:MaximumRemoteBytes = 16MB

function Get-RemoteScriptIntegrity {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [string]$Sha256
    )

    if ($Sha256 -and $Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'InvalidSha256: expected 64 hexadecimal characters'
    }
    if ($Uri.Scheme -notin @('http', 'https')) {
        throw "InvalidScriptUri: '$Uri'"
    }
    if (-not $Sha256 -and $Uri.Scheme -ne 'https') {
        throw 'InsecureRemoteScript: HTTP requires Sha256'
    }
    if ($Sha256) { return 'Pinned' }
    return 'Unpinned'
}

function Get-RemoteScript {
    param(
        [uri]$Uri,
        [string]$Sha256,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $integrity = Get-RemoteScriptIntegrity -Uri $Uri -Sha256 $Sha256
    $requestedUri = $Uri.AbsoluteUri
    $currentUri = $Uri
    $redirects = 0
    $path = [IO.Path]::Combine(
        [IO.Path]::GetTempPath(),
        'winspec-script-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $completed = $false
    $primaryError = $null
    try {
        while ($true) {
            if ($integrity -eq 'Unpinned' -and
                $currentUri.Scheme -ne 'https') {
                throw "InsecureRemoteScriptRedirect: '$currentUri'"
            }
            $remaining = [Math]::Floor(
                ($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000)
            if ($remaining -lt 1) {
                throw "RemoteScriptTimeout: exceeded $TimeoutSeconds seconds"
            }
            $request = [Net.HttpWebRequest]::Create($currentUri)
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'WinSpec/1'
            $request.Timeout = [int][Math]::Min([int]::MaxValue, $remaining)
            $request.ReadWriteTimeout = $request.Timeout
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -le 299) {
                break
            }
            if ($statusCode -notin @(301, 302, 303, 307, 308)) {
                throw "RemoteScriptHttpStatus: received $statusCode"
            }
            if ($redirects -ge 5) {
                throw 'RemoteScriptRedirectLimit: exceeds five redirects'
            }
            $location = $response.Headers['Location']
            if ([string]::IsNullOrWhiteSpace($location)) {
                throw 'InvalidRemoteScriptRedirect: Location is required'
            }
            $nextUri = New-Object Uri($currentUri, $location)
            if ($nextUri.Scheme -notin @('http', 'https')) {
                throw "InvalidRemoteScriptRedirect: '$nextUri'"
            }
            $response.Dispose()
            $response = $null
            $currentUri = $nextUri
            $redirects++
        }
        if ($response.ContentLength -gt $Script:MaximumRemoteBytes) {
            throw 'RemoteScriptTooLarge: exceeds 16 MiB'
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open(
            $path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $buffer = New-Object byte[] 81920
        $size = [long]0
        while ($true) {
            $remaining = [Math]::Floor(
                ($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000)
            if ($remaining -lt 1) {
                throw "RemoteScriptTimeout: exceeded $TimeoutSeconds seconds"
            }
            if ($inputStream.CanTimeout) {
                $inputStream.ReadTimeout = [int][Math]::Min(
                    [int]::MaxValue, $remaining)
            }
            $read = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($size + $read -gt $Script:MaximumRemoteBytes) {
                throw 'RemoteScriptTooLarge: exceeds 16 MiB'
            }
            $outputStream.Write($buffer, 0, $read)
            $null = $algorithm.TransformBlock($buffer, 0, $read, $null, 0)
            $size += $read
        }
        $empty = New-Object byte[] 0
        $null = $algorithm.TransformFinalBlock($empty, 0, 0)
        $digest = ([BitConverter]::ToString($algorithm.Hash)).Replace(
            '-', '').ToLowerInvariant()
        if ($Sha256 -and $digest -cne $Sha256.ToLowerInvariant()) {
            throw "Sha256Mismatch: expected $Sha256, received $digest"
        }
        $completed = $true
        return [pscustomobject]@{
            Path = $path
            RequestedUri = $requestedUri
            FinalUri = $currentUri.AbsoluteUri
            Size = $size
            Digest = $digest
            Integrity = $integrity
            DigestVerified = [bool]$Sha256
            DurationMilliseconds = $timer.ElapsedMilliseconds
        }
    }
    catch {
        $primaryError = $_
        throw
    }
    finally {
        $timer.Stop()
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
                    $primaryError.Exception.Data['RemoteScriptCleanupError'] =
                    $_.Exception.Message
                }
                else {
                    throw
                }
            }
        }
    }
}

function Invoke-PowerShellScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments,
        [switch]$Interactive,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-CurrentPowerShellPath
    $parts = @('-NoProfile')
    if (-not $Interactive) { $parts += '-NonInteractive' }
    $parts += @('-File', $Path)
    $parts += @($Arguments)
    $start.Arguments = (($parts | ForEach-Object {
                ConvertTo-ProcessArgument ([string]$_)
            }) -join ' ')
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($Path)
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
        if (-not $process.Start()) { throw "ScriptStartFailed: '$Path'" }
        if ($Interactive) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-ProviderProcessTree $process
                throw "ScriptTimeout: '$Path' exceeded $TimeoutSeconds seconds"
            }
            $stdout = $null
            $stderr = $null
            $stdoutTruncated = $false
            $stderrTruncated = $false
        }
        else {
            $streams = Receive-BoundedProcessOutput -Process $process `
                -TimeoutSeconds $TimeoutSeconds -StdoutLimit 1MB `
                -StderrLimit 1MB `
                -TimeoutMessage "ScriptTimeout: '$Path' exceeded $TimeoutSeconds seconds"
            $stdout = $streams.Stdout
            $stderr = $streams.Stderr
            $stdoutTruncated = $streams.StdoutTruncated
            $stderrTruncated = $streams.StderrTruncated
        }
        return [pscustomobject]@{
            Status = if ($process.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
            StdoutTruncated = $stdoutTruncated
            StderrTruncated = $stderrTruncated
            DurationMilliseconds = $timer.ElapsedMilliseconds
            Interpreter = $start.FileName
            Arguments = @($Arguments)
            Interactive = [bool]$Interactive
        }
    }
    finally {
        $timer.Stop()
        $process.Dispose()
    }
}

function Invoke-ScriptAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [string]$BasePath = $PWD,
        [string[]]$Arguments,
        [string]$Sha256,
        [switch]$DryRun,
        [switch]$Interactive,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $hasFile = $Configuration.ContainsKey('File')
    $hasUri = $Configuration.ContainsKey('Uri')
    if ($hasFile -eq $hasUri) {
        throw 'InvalidScriptAction: exactly one of File or Uri is required'
    }
    if ($hasFile -and ($Sha256 -or $Configuration.ContainsKey('Sha256'))) {
        throw 'InvalidSha256: Sha256 is valid only for a remote Script'
    }
    $configuredInteractive = $Configuration.ContainsKey('Interactive') -and
    [bool]$Configuration.Interactive
    $useInteractive = [bool]$Interactive -or $configuredInteractive
    if ($hasUri -and $useInteractive) {
        throw 'InteractiveRemoteScript: interactive scripts must be local'
    }
    if ($DryRun -and $useInteractive) {
        throw 'InteractiveDryRun: interactive scripts cannot be previewed'
    }

    $configuredArguments = if ($Configuration.ContainsKey('Args')) {
        @($Configuration.Args)
    }
    else {
        @()
    }
    $forwardedArguments = @($Arguments | Where-Object { $null -ne $_ })
    $allArguments = @($configuredArguments) + $forwardedArguments
    $temporary = $null
    if ($hasFile) {
        $path = if ([IO.Path]::IsPathRooted($Configuration.File)) {
            [IO.Path]::GetFullPath($Configuration.File)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $BasePath $Configuration.File))
        }
        if (-not [IO.File]::Exists($path)) { throw "ScriptNotFound: '$path'" }
        $source = $path
    }
    else {
        $uri = New-Object Uri($Configuration.Uri, [UriKind]::Absolute)
        if ($uri.Scheme -notin @('http', 'https')) {
            throw "InvalidScriptUri: '$($Configuration.Uri)'"
        }
        $requestedDigest = if ($Sha256) { $Sha256 } else { $Configuration.Sha256 }
        $integrity = Get-RemoteScriptIntegrity -Uri $uri `
            -Sha256 $requestedDigest
        if ($DryRun) {
            return [pscustomobject]@{
                Status = 'Planned'
                Source = $Configuration.Uri
                RequestedUri = $uri.AbsoluteUri
                Arguments = $allArguments
                Integrity = $integrity
                ExpectedSha256 = if ($requestedDigest) {
                    $requestedDigest.ToLowerInvariant()
                }
                else {
                    $null
                }
                Opaque = $true
                Interactive = $false
            }
        }
        $temporary = Get-RemoteScript -Uri $uri -Sha256 $requestedDigest `
            -TimeoutSeconds $TimeoutSeconds
        $path = $temporary.Path
        $source = $Configuration.Uri
    }
    if ($DryRun) {
        return [pscustomobject]@{
            Status = 'Planned'
            Source = $source
            Arguments = $allArguments
            Opaque = $true
            Interactive = $false
        }
    }
    $primaryError = $null
    try {
        $childTimeout = $TimeoutSeconds
        if ($temporary) {
            $childTimeout = [Math]::Floor(
                $TimeoutSeconds -
                ($temporary.DurationMilliseconds / 1000))
            if ($childTimeout -lt 1) {
                throw "RemoteScriptTimeout: exceeded $TimeoutSeconds seconds"
            }
        }
        $result = Invoke-PowerShellScript -Path $path -Arguments $allArguments `
            -Interactive:$useInteractive -TimeoutSeconds $childTimeout
        $result | Add-Member NoteProperty Source $source
        if ($temporary) {
            $result | Add-Member NoteProperty Integrity $temporary.Integrity
            $result | Add-Member NoteProperty RequestedUri $temporary.RequestedUri
            $result | Add-Member NoteProperty FinalUri $temporary.FinalUri
            $result | Add-Member NoteProperty ReceivedBytes $temporary.Size
            $result | Add-Member NoteProperty ReceivedSha256 $temporary.Digest
            $result | Add-Member NoteProperty DigestVerified `
                $temporary.DigestVerified
        }
        return $result
    }
    catch {
        $primaryError = $_
        throw
    }
    finally {
        if ($temporary -and [IO.File]::Exists($temporary.Path)) {
            try {
                [IO.File]::Delete($temporary.Path)
            }
            catch {
                if ($primaryError) {
                    $primaryError.Exception.Data['RemoteScriptCleanupError'] =
                    $_.Exception.Message
                }
                else {
                    throw
                }
            }
        }
    }
}

function Invoke-WinSpecAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Action,
        [Parameter(Mandatory)]$Provider,
        [string]$BasePath = $PWD,
        [string[]]$Arguments,
        [switch]$DryRun,
        [switch]$Interactive,
        [string]$Sha256,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $configuration = if ($Action.ContainsKey('With')) { $Action.With } else { @{} }
    if ($Provider.Name -ieq 'Script') {
        return Invoke-ScriptAction -Configuration $configuration `
            -BasePath $BasePath -Arguments $Arguments -DryRun:$DryRun `
            -Interactive:$Interactive -Sha256 $Sha256 `
            -TimeoutSeconds $TimeoutSeconds
    }
    if ($Interactive) {
        throw "InteractiveProviderUnsupported: '$($Provider.Name)' owns its interaction policy"
    }
    $forwardedArguments = @($Arguments | Where-Object { $null -ne $_ })
    if ($DryRun -and 'preview' -notin @($Provider.Operations)) {
        return [pscustomobject]@{
            Status = 'Planned'
            Provider = $Provider.Name
            Opaque = $true
        }
    }
    $operation = if ($DryRun) { 'preview' } else { 'run' }
    return Invoke-ExternalProvider -Provider $Provider -Operation $operation `
        -RequestInput @{
        configuration = $configuration
        arguments = $forwardedArguments
        executionPolicy = @{
            timeoutSeconds = $TimeoutSeconds
            workingDirectory = [IO.Path]::GetFullPath($BasePath)
        }
    } -TimeoutSeconds $TimeoutSeconds
}

Export-ModuleMember -Function @(
    'Invoke-ScriptAction', 'Invoke-WinSpecAction', 'Invoke-PowerShellScript')
