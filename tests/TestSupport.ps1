# The shared test-process boundary owns independent pipes, outer timeout and
# teardown. Fixtures and semantic assertions remain in their respective suites.
function Invoke-TestProcess {
    param(
        [string]$Executable = (Get-CurrentPowerShellPath),
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory,
        [string]$Profile
    )
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = ((@('-NoProfile', '-NonInteractive', '-File', $Path) + $Arguments |
                ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    if ($Profile) { $start.EnvironmentVariables['USERPROFILE'] = $Profile }
    if ([IO.Path]::GetFileName($Executable) -ieq 'powershell.exe') {
        $start.EnvironmentVariables['PSModulePath'] = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;" + $env:PSModulePath
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        $left = [Math]::Max(0, [int]($TimeoutSeconds * 1000 - $timer.ElapsedMilliseconds))
        if (-not $exited -or -not [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), $left)) {
            throw "TestProcessTimeout: '$Path' exceeded $TimeoutSeconds seconds"
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
    }
    finally {
        try { if ($started -and (-not $process.HasExited -or -not $stdout.IsCompleted -or -not $stderr.IsCompleted)) { Stop-ProviderProcessTree $process } }
        finally { $process.Dispose() }
    }
}
