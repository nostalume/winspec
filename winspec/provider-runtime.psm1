Import-Module (Join-Path $PSScriptRoot 'spec.psm1') -ErrorAction Stop

$Script:ProtocolVersion = 1
$Script:MaximumMessageBytes = 4MB
$Script:MaximumDiagnosticBytes = 1MB
function New-CoreProvider {
    param(
        [string]$Name,
        [ValidateSet('State', 'Action')][string]$Kind,
        [string[]]$Operations
    )

    return [pscustomobject]@{
        Name = $Name
        Kind = $Kind
        ProtocolVersion = 0
        Operations = @($Operations)
        EntryPointType = 'BuiltIn'
        EntryPoint = $null
        PackageRoot = $PSScriptRoot
        Origin = 'Core'
        Execution = 'Core'
    }
}

function Get-ProviderCatalog {
    [CmdletBinding()]
    param([string[]]$ProviderPath)

    $catalog = @(
        New-CoreProvider Registry State @('capture', 'compare', 'apply')
        New-CoreProvider Service State @('capture', 'compare', 'apply')
        New-CoreProvider Feature State @('capture', 'compare', 'apply')
        New-CoreProvider Script Action @('run', 'preview')
    )
    $names = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $catalog) {
        $null = $names.Add($item.Name)
    }

    $userProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
    $roots = @(
        [pscustomobject]@{
            Path = Join-Path $PSScriptRoot 'providers/bundled'
            Origin = 'Bundled'
            Required = $true
        }
        [pscustomobject]@{
            Path = Join-Path (Join-Path $userProfile '.config/winspec') 'providers'
            Origin = 'User'
            Required = $false
        }
    )
    foreach ($path in @($ProviderPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $roots += [pscustomobject]@{
                Path = $path
                Origin = 'Explicit'
                Required = $false
            }
        }
    }

    $seenRoots = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($descriptor in $roots) {
        $root = [IO.Path]::GetFullPath($descriptor.Path)
        if (-not $seenRoots.Add($root)) {
            continue
        }
        if (-not [IO.Directory]::Exists($root)) {
            if ($descriptor.Required) {
                throw "BundledProviderRootMissing: '$root'"
            }
            continue
        }

        foreach ($package in @(
                Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
            $manifestPath = Join-Path $package.FullName 'provider.json'
            if (-not [IO.File]::Exists($manifestPath)) {
                continue
            }
            $manifest = Import-Configuration $manifestPath
            foreach ($required in @(
                    'schemaVersion', 'name', 'kind', 'protocolVersion',
                    'operations')) {
                if (-not $manifest.ContainsKey($required)) {
                    throw "InvalidProviderManifest: '$manifestPath' lacks '$required'"
                }
            }
            if ($manifest.schemaVersion -ne 1 -or
                $manifest.protocolVersion -ne $Script:ProtocolVersion) {
                throw "UnsupportedProviderProtocol: '$manifestPath'"
            }
            if ($manifest.name -isnot [string] -or
                [string]::IsNullOrWhiteSpace($manifest.name)) {
                throw "InvalidProviderManifest: '$manifestPath' has invalid name"
            }
            if ($manifest.kind -notin @('State', 'Action')) {
                throw "InvalidProviderManifest: '$manifestPath' has invalid kind"
            }

            $hasExecutable = $manifest.ContainsKey('executable')
            $hasScript = $manifest.ContainsKey('script')
            if ($hasExecutable -eq $hasScript) {
                throw "InvalidProviderManifest: '$manifestPath' needs exactly one entrypoint"
            }
            $entryType = if ($hasExecutable) { 'Executable' } else { 'PowerShell' }
            $entryValue = if ($hasExecutable) {
                $manifest.executable
            }
            else {
                $manifest.script
            }
            if ($entryValue -isnot [string] -or
                [IO.Path]::IsPathRooted($entryValue)) {
                throw "InvalidProviderEntrypoint: '$manifestPath'"
            }
            $entry = [IO.Path]::GetFullPath(
                (Join-Path $package.FullName $entryValue))
            $prefix = $package.FullName.TrimEnd(
                [IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
            if (-not $entry.StartsWith(
                    $prefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not [IO.File]::Exists($entry)) {
                throw "InvalidProviderEntrypoint: '$entryValue'"
            }

            $operations = @($manifest.operations)
            $operationNames = New-Object (
                'System.Collections.Generic.HashSet[string]') (
                [StringComparer]::OrdinalIgnoreCase)
            $allowed = if ($manifest.kind -eq 'State') {
                @('capture', 'compare', 'apply')
            }
            else {
                @('run', 'preview')
            }
            foreach ($operation in $operations) {
                if ($operation -isnot [string] -or
                    $operation -notin $allowed -or
                    -not $operationNames.Add($operation)) {
                    throw "InvalidProviderOperation: '$operation' for '$($manifest.name)'"
                }
            }
            $requiredOperations = if ($manifest.kind -eq 'State') {
                @('capture', 'compare', 'apply')
            }
            else {
                @('run')
            }
            foreach ($operation in $requiredOperations) {
                if ($operation -notin $operations) {
                    throw "InvalidProviderManifest: '$($manifest.name)' requires '$operation'"
                }
            }
            if (-not $names.Add($manifest.name)) {
                throw "DuplicateProvider: '$($manifest.name)'"
            }

            $catalog += [pscustomobject]@{
                Name = $manifest.name
                Kind = $manifest.kind
                ProtocolVersion = $Script:ProtocolVersion
                Operations = @($operations)
                EntryPointType = $entryType
                EntryPoint = $entry
                PackageRoot = $package.FullName
                Origin = $descriptor.Origin
                Execution = 'Protocol'
            }
        }
    }
    return @($catalog | Sort-Object Name)
}

function Get-CurrentPowerShellPath {
    try {
        return (Get-Process -Id $PID -ErrorAction Stop).Path
    }
    catch {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            return 'powershell.exe'
        }
        return 'pwsh.exe'
    }
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                $null = $builder.Append(
                    [string]::new([char]92, $backslashes * 2))
            }
            $null = $builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append([string]::new([char]92, $backslashes))
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append([string]::new([char]92, $backslashes * 2))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Stop-ProviderProcessTree {
    param([Parameter(Mandatory)]$Process)

    try {
        & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null
    }
    catch {
        try {
            $Process.Kill()
        }
        catch {
        }
    }
}

function Remove-ProviderTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ([IO.Directory]::Exists($Path)) {
                [IO.Directory]::Delete($Path, $true)
            }
            return
        }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Receive-BoundedProcessOutput {
    param(
        [Parameter(Mandatory)]$Process,
        [int]$TimeoutSeconds,
        [int]$StdoutLimit = 4MB,
        [int]$StderrLimit = 1MB,
        [string]$TimeoutMessage = 'ProcessTimeout'
    )

    $stdoutBuffer = New-Object byte[] 8192
    $stderrBuffer = New-Object byte[] 8192
    $stdout = New-Object IO.MemoryStream
    $stderr = New-Object IO.MemoryStream
    $stdoutDone = $false
    $stderrDone = $false
    $stdoutTruncated = $false
    $stderrTruncated = $false
    $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync(
        $stdoutBuffer, 0, $stdoutBuffer.Length)
    $stderrTask = $Process.StandardError.BaseStream.ReadAsync(
        $stderrBuffer, 0, $stderrBuffer.Length)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not ($stdoutDone -and $stderrDone)) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Stop-ProviderProcessTree $Process
                throw $TimeoutMessage
            }
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $count = $stdoutTask.Result
                if ($count -eq 0) {
                    $stdoutDone = $true
                }
                else {
                    $keep = [Math]::Min(
                        $count,
                        [Math]::Max(0, $StdoutLimit - [int]$stdout.Length))
                    if ($keep -gt 0) {
                        $stdout.Write($stdoutBuffer, 0, $keep)
                    }
                    if ($keep -lt $count) {
                        $stdoutTruncated = $true
                    }
                    $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync(
                        $stdoutBuffer, 0, $stdoutBuffer.Length)
                }
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $count = $stderrTask.Result
                if ($count -eq 0) {
                    $stderrDone = $true
                }
                else {
                    $keep = [Math]::Min(
                        $count,
                        [Math]::Max(0, $StderrLimit - [int]$stderr.Length))
                    if ($keep -gt 0) {
                        $stderr.Write($stderrBuffer, 0, $keep)
                    }
                    if ($keep -lt $count) {
                        $stderrTruncated = $true
                    }
                    $stderrTask = $Process.StandardError.BaseStream.ReadAsync(
                        $stderrBuffer, 0, $stderrBuffer.Length)
                }
            }
            if (-not (($stdoutDone -or $stdoutTask.IsCompleted) -and
                    ($stderrDone -or $stderrTask.IsCompleted))) {
                Start-Sleep -Milliseconds 5
            }
        }
        $Process.WaitForExit()
        $encoding = New-Object Text.UTF8Encoding($false)
        return [pscustomobject]@{
            Stdout = $encoding.GetString($stdout.ToArray())
            Stderr = $encoding.GetString($stderr.ToArray())
            StdoutTruncated = $stdoutTruncated
            StderrTruncated = $stderrTruncated
        }
    }
    finally {
        $timer.Stop()
        $stdout.Dispose()
        $stderr.Dispose()
    }
}

function Invoke-ExternalProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][string]$Operation,
        [Alias('Input')][hashtable]$RequestInput = @{},
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    if ($Provider.Execution -ne 'Protocol') {
        throw "InvalidProviderInvocation: '$($Provider.Name)' is core"
    }
    if ($Operation -notin @($Provider.Operations)) {
        throw "UnsupportedProviderOperation: '$($Provider.Name)' does not declare '$Operation'"
    }
    Assert-WinSpecValue $RequestInput
    $requestId = [Guid]::NewGuid().ToString('D')
    $admittedInput = @{}
    foreach ($key in $RequestInput.Keys) {
        $admittedInput[$key] = $RequestInput[$key]
    }
    $executionPolicy = if ($admittedInput.ContainsKey('executionPolicy')) {
        if ($admittedInput.executionPolicy -isnot [Collections.IDictionary]) {
            throw 'InvalidProviderRequest: executionPolicy must be an object'
        }
        $copy = @{}
        foreach ($key in $admittedInput.executionPolicy.Keys) {
            $copy[$key] = $admittedInput.executionPolicy[$key]
        }
        $copy
    }
    else {
        @{}
    }
    $temporaryDirectory = $null
    $process = $null
    $primaryError = $null
    try {
        $temporaryDirectory = [IO.Path]::Combine(
            [IO.Path]::GetTempPath(), 'winspec-provider-' + $requestId)
        $null = [IO.Directory]::CreateDirectory($temporaryDirectory)
        $executionPolicy.temporaryDirectory = $temporaryDirectory
        $admittedInput.executionPolicy = $executionPolicy
        $request = [ordered]@{
            protocolVersion = $Script:ProtocolVersion
            requestId = $requestId
            operation = $Operation
            input = $admittedInput
        }
        $requestJson = $request | ConvertTo-Json -Depth 64 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($requestJson) -gt
            $Script:MaximumMessageBytes) {
            throw 'ProviderRequestTooLarge: request exceeds 4 MiB'
        }

        $start = New-Object Diagnostics.ProcessStartInfo
        if ($Provider.EntryPointType -eq 'PowerShell') {
            $start.FileName = Get-CurrentPowerShellPath
            $providerHost = Join-Path $PSScriptRoot 'provider-host.ps1'
            $start.Arguments = @(
                '-NoProfile', '-NonInteractive', '-File', $providerHost,
                $Provider.EntryPoint
            ) | ForEach-Object {
                ConvertTo-ProcessArgument ([string]$_)
            }
            $start.Arguments = $start.Arguments -join ' '
        }
        else {
            $start.FileName = $Provider.EntryPoint
            $start.Arguments = ''
        }
        $start.WorkingDirectory = $Provider.PackageRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $utf8 = New-Object Text.UTF8Encoding($false)
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) {
            throw "ProviderStartFailed: '$($Provider.Name)'"
        }
        # StreamWriter differs across Windows PowerShell hosts and can prepend a
        # BOM. The provider protocol is explicitly BOM-free UTF-8.
        $requestBytes = $utf8.GetBytes($requestJson)
        $process.StandardInput.BaseStream.Write(
            $requestBytes, 0, $requestBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        $receiveParameters = @{
            Process = $process
            TimeoutSeconds = $TimeoutSeconds
            StdoutLimit = $Script:MaximumMessageBytes
            StderrLimit = $Script:MaximumDiagnosticBytes
            TimeoutMessage = (
                "ProviderTimeout: '$($Provider.Name)' exceeded " +
                "$TimeoutSeconds seconds")
        }
        $streams = Receive-BoundedProcessOutput @receiveParameters
        $stdout = $streams.Stdout
        $stderr = $streams.Stderr
        if ($streams.StdoutTruncated) {
            throw "ProviderResponseTooLarge: '$($Provider.Name)'"
        }
        if ($process.ExitCode -ne 0) {
            throw "ProviderProcessFailed: '$($Provider.Name)' exited " +
            "$($process.ExitCode): $stderr"
        }
        try {
            $rawResponse = $stdout | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "InvalidProviderResponse: '$($Provider.Name)': " +
            $_.Exception.Message
        }
        $response = ConvertTo-WinSpecHashtable $rawResponse
        if ($null -eq $response) {
            throw "InvalidProviderResponse: '$($Provider.Name)' returned " +
            "empty or JSON null output (stdout chars: $($stdout.Length); " +
            "stderr chars: $($stderr.Length))"
        }
        $responseFields = @(
            'protocolVersion', 'requestId', 'status', 'output', 'diagnostics')
        foreach ($field in $response.Keys) {
            if ($field -notin $responseFields) {
                throw "InvalidProviderResponse: unknown field '$field'"
            }
        }
        foreach ($required in @(
                'protocolVersion', 'requestId', 'status', 'output',
                'diagnostics')) {
            if (-not $response.ContainsKey($required)) {
                throw "InvalidProviderResponse: missing '$required'"
            }
        }
        if ($response.protocolVersion -ne $Script:ProtocolVersion) {
            throw "InvalidProviderResponse: protocol mismatch; expected " +
            "'$($Script:ProtocolVersion)', received '$($response.protocolVersion)'"
        }
        if ($response.requestId -cne $requestId) {
            throw "InvalidProviderResponse: request mismatch; expected " +
            "'$requestId', received '$($response.requestId)'"
        }
        if ($response.output -isnot [Collections.IDictionary]) {
            throw 'InvalidProviderResponse: output must be an object'
        }
        if ($response.diagnostics -is [string] -or
            $response.diagnostics -is [Collections.IDictionary] -or
            $response.diagnostics -isnot [Collections.IEnumerable]) {
            throw 'InvalidProviderResponse: diagnostics must be an array'
        }
        foreach ($diagnostic in @($response.diagnostics)) {
            if ($diagnostic -isnot [Collections.IDictionary] -or
                -not $diagnostic.Contains('code') -or
                -not $diagnostic.Contains('message') -or
                $diagnostic.code -isnot [string] -or
                [string]::IsNullOrWhiteSpace($diagnostic.code) -or
                $diagnostic.message -isnot [string] -or
                [string]::IsNullOrWhiteSpace($diagnostic.message)) {
                throw 'InvalidProviderResponse: each diagnostic needs string code and message'
            }
        }
        $statusKey = "$($Provider.Kind):$Operation".ToLowerInvariant()
        $allowedStatuses = switch ($statusKey) {
            'action:preview' { @('Planned', 'Failed') }
            'action:run' { @('Succeeded', 'Failed') }
            'state:capture' { @('Succeeded', 'Failed') }
            'state:compare' { @('Unchanged', 'Different', 'Failed') }
            'state:apply' { @('Succeeded', 'Unchanged', 'Failed') }
            default { throw "InvalidProviderOperation: '$statusKey'" }
        }
        if ($response.status -notin $allowedStatuses) {
            throw "InvalidProviderStatus: '$($Provider.Name)' $Operation returned '$($response.status)'"
        }
        if ($streams.StderrTruncated) {
            $response['stderrTruncated'] = $true
        }
        if ($stderr) {
            $response['stderr'] = $stderr
        }
        return $response
    }
    catch {
        $primaryError = $_
        throw
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
        try {
            if ($temporaryDirectory) {
                Remove-ProviderTemporaryDirectory $temporaryDirectory
            }
        }
        catch {
            if ($primaryError) {
                $primaryError.Exception.Data['TemporaryCleanupError'] =
                $_.Exception.Message
            }
            else {
                throw "ProviderTemporaryCleanupFailed: '$temporaryDirectory': " +
                $_.Exception.Message
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ProviderCatalog', 'Invoke-ExternalProvider',
    'Get-CurrentPowerShellPath', 'ConvertTo-ProcessArgument',
    'Receive-BoundedProcessOutput',
    'Stop-ProviderProcessTree')
