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

function Get-ProcessRemainingMilliseconds {
    param([Diagnostics.Stopwatch]$Timer, [double]$TimeoutSeconds, [string]$TimeoutMessage)
    $remaining = [Math]::Ceiling($TimeoutSeconds * 1000 - $Timer.Elapsed.TotalMilliseconds)
    if ($remaining -le 0) { throw $TimeoutMessage }
    return [int][Math]::Min([int]::MaxValue, $remaining)
}

function Get-ProcessTreeSnapshot {
    # Lazy, read-only Win32 ancestry snapshot. Avoid CIM auto-import/query cost
    # in the bounded failure-cleanup path; normal execution never loads it.
    if (-not ('WinSpec.Runtime.ProcessAncestry' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace WinSpec.Runtime {
    public sealed class ProcessIdentity {
        public int ProcessId, ParentProcessId;
        public DateTime CreationDate;
        public string Name;
    }
    public static class ProcessAncestry {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicInfo { public IntPtr reserved, peb, affinity, priority, id, parent; }
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle, int kind, out BasicInfo info, int size, out int returned);
        public static ProcessIdentity[] Snapshot() {
            var result = new List<ProcessIdentity>();
            int self; using (var current = Process.GetCurrentProcess()) { self = current.Id; }
            bool verifiedSelf = false;
            foreach (var process in Process.GetProcesses()) {
                IntPtr handle = IntPtr.Zero;
                try {
                    handle = OpenProcess(0x1000, false, process.Id);
                    if (handle == IntPtr.Zero) continue;
                    BasicInfo info; int returned; long created, exited, kernel, user;
                    if (NtQueryInformationProcess(handle, 0, out info, Marshal.SizeOf(typeof(BasicInfo)), out returned) != 0 || info.id.ToInt64() != process.Id ||
                        !GetProcessTimes(handle, out created, out exited, out kernel, out user)) continue;
                    if (process.Id == self && info.parent.ToInt64() > 0) verifiedSelf = true;
                    result.Add(new ProcessIdentity { ProcessId = process.Id, ParentProcessId = info.parent.ToInt32(), CreationDate = DateTime.FromFileTimeUtc(created), Name = process.ProcessName });
                }
                catch (InvalidOperationException) { } // Exited during observation.
                catch (System.ComponentModel.Win32Exception) { } // Not queryable with this token.
                finally { if (handle != IntPtr.Zero) CloseHandle(handle); process.Dispose(); }
            }
            if (!verifiedSelf) throw new InvalidOperationException("ProcessAncestryUnavailable: cannot verify the current process identity");
            return result.ToArray();
        }
    }
}
'@
    }
    return [WinSpec.Runtime.ProcessAncestry]::Snapshot()
}


function Stop-ProviderProcessTree {
    param([Parameter(Mandatory)]$Process, [datetime]$StartedAt)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = $Process.Handle
    $started = if ($PSBoundParameters.ContainsKey('StartedAt')) { $StartedAt.ToUniversalTime() } else { $Process.StartTime.ToUniversalTime() }
    # Keep the owned handle open: a bare PID is not a termination capability.
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { if (-not $Process.HasExited) { throw } }
    }
    $members = @(Get-ProcessTreeSnapshot)
    $parentStarts = @{ ([int]$Process.Id) = $started }
    $owned = New-Object Collections.ArrayList
    $failures = @()
    try {
        do {
            $added = $false
            foreach ($member in $members) {
                $parent = [int]$member.ParentProcessId
                if ($parentStarts.ContainsKey([int]$member.ProcessId) -or -not $parentStarts.ContainsKey($parent) -or $member.CreationDate -lt $parentStarts[$parent]) { continue }
                $child = Get-Process -Id $member.ProcessId -ErrorAction SilentlyContinue
                if (-not $child) { continue }
                try {
                    # Verify and pin an ancestor before trusting edges below it.
                    # A stale snapshot must not make a reused PID's children ours.
                    $null = $child.Handle
                    if ($child.StartTime.ToUniversalTime() -ne $member.CreationDate) { continue }
                    $parentStarts[$member.ProcessId] = $member.CreationDate
                    $null = $owned.Add(@{ Process = $child; Identity = $member })
                    $child = $null # Ownership transfers to the collection.
                    $added = $true
                }
                catch { if (-not $child.HasExited) { $failures += $_.Exception.Message } }
                finally { if ($child) { $child.Dispose() } }
            }
        } while ($added)
        foreach ($item in @($owned | Sort-Object { $_.Identity.CreationDate } -Descending)) {
            $child = $item.Process
            try {
                if (-not $child.HasExited) { $child.Kill() }
                $left = [Math]::Max(0, 2000 - [int]$timer.ElapsedMilliseconds)
                if (-not $child.WaitForExit($left)) { throw "ProcessCleanupFailed: descendant $($child.Id) ($($item.Identity.Name)) did not exit" }
            }
            catch { if (-not $child.HasExited) { $failures += $_.Exception.Message } }
        }
        if (-not $Process.WaitForExit([Math]::Max(0, 2000 - [int]$timer.ElapsedMilliseconds))) {
            $failures += "ProcessCleanupFailed: process $($Process.Id) did not exit"
        }
        if ($failures.Count) { throw ($failures -join '; ') }
    }
    finally { foreach ($item in $owned) { $item.Process.Dispose() } }
}
function Invoke-BoundedProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [double]$TimeoutSeconds,
        [Diagnostics.Stopwatch]$DeadlineTimer,
        [int]$StdoutLimit = 4MB,
        [int]$StderrLimit = 1MB,
        [string]$InputText,
        [string]$TimeoutMessage = 'ProcessTimeout',
        [string]$StartFailureMessage = 'ProcessStartFailed',
        [scriptblock]$Complete,
        [scriptblock]$Progress,
        [string]$Activity = 'executing child'
    )
    if (-not $DeadlineTimer) { $DeadlineTimer = [Diagnostics.Stopwatch]::StartNew() }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $StartInfo
    $duration = [Diagnostics.Stopwatch]::StartNew()
    $streams = @()
    $primaryError = $null
    $started = $false
    try {
        $null = Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage
        $inputEncoding = [Console]::InputEncoding
        try {
            if ($StartInfo.RedirectStandardInput) { [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) }
            $started = $process.Start()
        }
        finally { if ($StartInfo.RedirectStandardInput) { [Console]::InputEncoding = $inputEncoding } }
        if (-not $started) { throw $StartFailureMessage }
        $startedAt = $process.StartTime
        if (-not $StartInfo.RedirectStandardOutput) {
            if (-not $process.WaitForExit((Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage))) { throw $TimeoutMessage }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $null; Stderr = $null; StdoutTruncated = $false; StderrTruncated = $false; DurationMilliseconds = $duration.ElapsedMilliseconds }
        }
        foreach ($description in @(@{ Stream = $process.StandardOutput.BaseStream; Limit = $StdoutLimit }, @{ Stream = $process.StandardError.BaseStream; Limit = $StderrLimit })) {
            $buffer = New-Object byte[] 8192
            $streams += @{ Stream = $description.Stream; Buffer = $buffer; Limit = $description.Limit; Capture = (New-Object IO.MemoryStream); Done = $false; Truncated = $false; Task = $description.Stream.ReadAsync($buffer, 0, $buffer.Length) }
        }
        $inputTask = if ($StartInfo.RedirectStandardInput) { $process.StandardInput.WriteAsync($InputText) } else { $null }
        $flushing = $false
        $nextProgress = $DeadlineTimer.Elapsed.TotalSeconds + 1
        if ($Progress) { $null = & $Progress $Activity 0 $TimeoutSeconds }
        while ($true) {
            $null = Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage
            if ($Progress -and $DeadlineTimer.Elapsed.TotalSeconds -ge $nextProgress) {
                $null = & $Progress $Activity $DeadlineTimer.Elapsed.TotalSeconds $TimeoutSeconds
                $nextProgress = $DeadlineTimer.Elapsed.TotalSeconds + 2
            }
            if ($inputTask -and $inputTask.IsCompleted) {
                $null = $inputTask.GetAwaiter().GetResult()
                if (-not $flushing) { $inputTask = $process.StandardInput.FlushAsync(); $flushing = $true }
                else { $process.StandardInput.Close(); $inputTask = $null }
            }
            $ready = $false
            foreach ($stream in $streams) {
                if ($stream.Done -or -not $stream.Task.IsCompleted) { continue }
                $ready = $true
                $count = $stream.Task.GetAwaiter().GetResult()
                if ($count -eq 0) { $stream.Done = $true; continue }
                $keep = [Math]::Min($count, [Math]::Max(0, $stream.Limit - [int]$stream.Capture.Length))
                if ($keep -gt 0) { $stream.Capture.Write($stream.Buffer, 0, $keep) }
                if ($keep -lt $count) { $stream.Truncated = $true }
                $stream.Task = $stream.Stream.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
            }
            if ($streams[0].Done -and $streams[1].Done -and -not $inputTask -and $process.HasExited) { break }
            if (-not $ready) {
                $wait = Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage
                if ($Progress) {
                    $untilProgress = [Math]::Max(1, [Math]::Ceiling(($nextProgress - $DeadlineTimer.Elapsed.TotalSeconds) * 1000))
                    $wait = [Math]::Min($wait, $untilProgress)
                }
                $pending = @()
                foreach ($stream in $streams) { if (-not $stream.Done) { $pending += $stream.Task } }
                if ($inputTask) { $pending += $inputTask }
                # Wait for any live pipe/input task, not a fixed polling sleep
                # or the quiet stream. EOF alone does not finish the process.
                if ($pending.Count) { $null = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending, [int]$wait) }
                else { $null = $process.WaitForExit([int]$wait) }
            }
        }
        $encoding = New-Object Text.UTF8Encoding($false)
        $null = Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $encoding.GetString($streams[0].Capture.GetBuffer(), 0, [int]$streams[0].Capture.Length)
            Stderr = $encoding.GetString($streams[1].Capture.GetBuffer(), 0, [int]$streams[1].Capture.Length)
            StdoutTruncated = $streams[0].Truncated
            StderrTruncated = $streams[1].Truncated
            DurationMilliseconds = $duration.ElapsedMilliseconds
        }
        if ($Complete) { $result = & $Complete $result }
        $null = Get-ProcessRemainingMilliseconds $DeadlineTimer $TimeoutSeconds $TimeoutMessage
        return $result
    }
    catch { $primaryError = $_; throw }
    finally {
        $cleanupMessages = @()
        try {
            if ($started -and ($primaryError -or -not $process.HasExited)) { Stop-ProviderProcessTree $process -StartedAt $startedAt }
        }
        catch { $cleanupMessages += $_.Exception.Message }
        # Close the raw pipe, not a writer that could synchronously flush a
        # request to a child which stopped consuming input.
        try { if ($inputTask) { $process.StandardInput.BaseStream.Close() } }
        catch { $cleanupMessages += $_.Exception.Message }
        foreach ($stream in $streams) { $stream.Capture.Dispose() }
        try { $process.Dispose() }
        catch { $cleanupMessages += $_.Exception.Message }
        if ($cleanupMessages.Count) {
            if ($primaryError) { $primaryError.Exception.Data['ProcessCleanupError'] = $cleanupMessages -join '; ' }
            else { throw ('ProcessCleanupFailed: ' + ($cleanupMessages -join '; ')) }
        }
    }
}

function Remove-ProviderTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($fullPath) -ine $tempRoot -or
        [IO.Path]::GetFileName($fullPath) -notmatch '^winspec-provider-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        throw "InvalidProviderTemporaryDirectory: '$Path' is not an invocation directory"
    }
    if ([IO.Directory]::Exists($fullPath) -and
        ([IO.File]::GetAttributes($fullPath) -band [IO.FileAttributes]::ReparsePoint)) {
        throw "InvalidProviderTemporaryDirectory: '$Path' is a reparse point"
    }
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

function Invoke-ExternalProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][string]$Operation,
        [Alias('Input')][hashtable]$RequestInput = @{},
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [scriptblock]$Progress
    )

    $deadline = [Diagnostics.Stopwatch]::StartNew()
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
    $ownsTemporaryDirectory = $false
    $primaryError = $null
    try {
        $temporaryDirectory = [IO.Path]::Combine(
            [IO.Path]::GetTempPath(), 'winspec-provider-' + $requestId)
        if ([IO.Directory]::Exists($temporaryDirectory)) { throw 'ProviderTemporaryCollision' }
        $null = [IO.Directory]::CreateDirectory($temporaryDirectory)
        $ownsTemporaryDirectory = $true
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
        if ($null -ne $start.PSObject.Properties['StandardInputEncoding']) {
            $start.StandardInputEncoding = $utf8
        }
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8

        $complete = {
            param($streams)
            $stdout = $streams.Stdout
            $stderr = $streams.Stderr
            $stderrSummary = if ([string]::IsNullOrWhiteSpace($stderr)) {
                '<empty>'
            }
            else {
                $stderr.Substring(0, [Math]::Min(2048, $stderr.Length)).Trim()
            }
            if ($streams.StdoutTruncated) {
                throw "ProviderResponseTooLarge: '$($Provider.Name)'"
            }
            if ($streams.ExitCode -ne 0) {
                throw "ProviderProcessFailed: '$($Provider.Name)' exited " +
                "$($streams.ExitCode): $stderr"
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
                "stderr chars: $($stderr.Length)); stderr: $stderrSummary"
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
                "'$requestId', received '$($response.requestId)'; stderr: " +
                $stderrSummary
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
        $timeoutMessage = "ProviderTimeout: '$($Provider.Name)' exceeded $TimeoutSeconds seconds"
        return Invoke-BoundedProcess -StartInfo $start -InputText $requestJson -Complete $complete `
            -TimeoutSeconds $TimeoutSeconds -DeadlineTimer $deadline -Progress $Progress `
            -Activity "provider $($Provider.Name) / $Operation (trusted provider code)" `
            -StdoutLimit $Script:MaximumMessageBytes -StderrLimit $Script:MaximumDiagnosticBytes `
            -StartFailureMessage "ProviderStartFailed: '$($Provider.Name)'" `
            -TimeoutMessage $timeoutMessage
    }
    catch {
        $primaryError = $_
        throw
    }
    finally {
        try {
            if ($ownsTemporaryDirectory) {
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
    'Invoke-BoundedProcess', 'Get-ProcessRemainingMilliseconds',
    'Stop-ProviderProcessTree')
