#!/usr/bin/env pwsh

$Command = 'help'
$Target = $null
$Second = $null
$SpecPath = $null
$Providers = @()
$ProviderPath = @()
$Against = $null
$Output = $null
$Strategy = 'auto'
$Force = $false
$Json = @($args) -icontains '-Json'
$DryRun = $false
$Checkpoint = $false
$Interactive = $false
$Sha256 = $null
$TimeoutSeconds = 300
$Enter = $false
$Exit = $false
$List = $false
$Mode = 'Mock'
$Snapshot = 'default'
$Last = $false
$SequenceNumber = 0
$Help = $false
$RemainingArguments = @()

try {
    $raw = @($args)
    $positionals = @()
    $index = 0
    $forward = $false
    while ($index -lt $raw.Count) {
        $token = [string]$raw[$index]
        if ($forward) {
            $RemainingArguments += $token
            $index++
            continue
        }
        if ($token -eq '--') {
            $forward = $true
            $index++
            continue
        }
        if ($token.StartsWith('-')) {
            $option = $token.ToLowerInvariant()
            if ($option -in @(
                    '-force', '-json', '-dryrun', '-checkpoint',
                    '-interactive', '-enter', '-exit',
                    '-list', '-last', '-help')) {
                Set-Variable -Name ($option.TrimStart('-')) -Value $true
                $index++
                continue
            }
            if ($option -in @(
                    '-spec', '-providers', '-providerpath', '-against',
                    '-output', '-strategy', '-sha256', '-timeoutseconds',
                    '-mode', '-snapshot', '-sequencenumber')) {
                if ($index + 1 -ge $raw.Count) {
                    throw "MissingOptionValue: '$token'"
                }
                $value = $raw[$index + 1]
                switch ($option) {
                    '-spec' { $SpecPath = [string]$value }
                    '-providers' { $Providers += @([string]$value -split ',') }
                    '-providerpath' { $ProviderPath += @([string]$value -split ',') }
                    '-against' { $Against = [string]$value }
                    '-output' { $Output = [string]$value }
                    '-strategy' { $Strategy = [string]$value }
                    '-sha256' { $Sha256 = [string]$value }
                    '-timeoutseconds' { $TimeoutSeconds = [int]$value }
                    '-mode' { $Mode = [string]$value }
                    '-snapshot' { $Snapshot = [string]$value }
                    '-sequencenumber' { $SequenceNumber = [int]$value }
                }
                $index += 2
                continue
            }
            if ($option -in @('-verbose', '-debug')) {
                $index++
                continue
            }
            throw "UnknownOption: '$token'"
        }
        $positionals += $token
        $index++
    }
    if ($positionals.Count -gt 0) { $Command = $positionals[0] }
    if ($positionals.Count -gt 1) { $Target = $positionals[1] }
    if ($positionals.Count -gt 2) { $Second = $positionals[2] }
    if ($positionals.Count -gt 3) {
        throw "UnexpectedOperand: '$($positionals[3])'"
    }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 3600) {
        throw 'InvalidTimeout: expected 1..3600'
    }
    if ($Strategy -notin @('auto', 'union', 'ours', 'theirs')) {
        throw "InvalidStrategy: '$Strategy'"
    }
    if ($Mode -notin @('Mock', 'DryRun')) {
        throw "InvalidSandboxMode: '$Mode'"
    }
}
catch {
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            command = $Command
            status = 'Failed'
            results = @{}
            diagnostics = @(@{
                    severity = 'error'
                    code = ($_.Exception.Message -split ':')[0]
                    message = $_.Exception.Message
                })
        } | ConvertTo-Json -Depth 8 -Compress
    }
    else {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    exit 2
}

$Script:Commands = @(
    'capture', 'status', 'validate', 'diff', 'apply', 'run', 'workflow',
    'merge', 'providers', 'sandbox', 'rollback', 'help')
$Command = $Command.ToLowerInvariant()

function Show-Help {
    param([string]$Topic)
    if (-not $Topic -or $Topic -eq 'help') {
        @'
WinSpec - declarative Windows state and explicit actions

Usage:
  winspec capture [output] [-Providers name[]] [-ProviderPath directory[]] [-Force] [-Json]
  winspec status [spec] [-Providers name[]] [-ProviderPath directory[]] [-Json]
  winspec validate [spec] [-ProviderPath directory[]] [-Json]
  winspec diff [spec] [-Against spec] [-Providers name[]] [-ProviderPath directory[]] [-Json]
  winspec apply [spec] [-Providers name[]] [-ProviderPath directory[]] [-DryRun] [-Checkpoint] [-Json]
  winspec run <name> [-Spec spec] [-DryRun] [-Json] [-- arguments]
  winspec run <path|uri> [-Interactive] [-Sha256 hex] [-DryRun] [-Json] [-- arguments]
  winspec workflow <name> [-Spec spec] [-DryRun] [-Json]
  winspec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]
  winspec providers [-ProviderPath directory[]] [-Json]
  winspec sandbox [-Enter|-Exit|-List] [-Mode Mock|DryRun] [-Snapshot name]
  winspec rollback (-Last|-SequenceNumber n) [-DryRun]

Specifications are data-only .psd1 or .json files. Capture observes, apply
changes state, and run executes exactly one Action. A Workflow is the only
multi-step execution surface. Provider discovery reads manifests but never runs
provider code.
'@
        return
    }
    switch ($Topic) {
        'capture' { 'WinSpec capture [output] [-Providers name[]] [-ProviderPath directory[]] [-Force] [-Json]' }
        'status' { 'WinSpec status [spec] [-Providers name[]] [-ProviderPath directory[]] [-Json]' }
        'validate' { 'WinSpec validate [spec] [-ProviderPath directory[]] [-Json]' }
        'diff' { 'WinSpec diff [spec] [-Against spec] [-Providers name[]] [-ProviderPath directory[]] [-Json]' }
        'apply' { 'WinSpec apply [spec] [-Providers name[]] [-ProviderPath directory[]] [-DryRun] [-Checkpoint] [-Json]' }
        'run' { 'WinSpec run <name> [-Spec spec] | <path|uri> [-Interactive] [-Sha256 hex] [-DryRun] [-Json] [-- arguments]' }
        'workflow' { 'WinSpec workflow <name> [-Spec spec] [-DryRun] [-Json]' }
        'merge' { 'WinSpec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]' }
        'providers' { 'WinSpec providers [-ProviderPath directory[]] [-Json]' }
        'sandbox' { 'WinSpec sandbox [-Enter|-Exit|-List] [-Mode Mock|DryRun] [-Snapshot name]' }
        'rollback' { 'WinSpec rollback (-Last|-SequenceNumber n) [-DryRun]' }
        default { throw "UnknownCommand: '$Topic'" }
    }
}

if ($Command -notin $Script:Commands) {
    $message = "UnknownCommand: '$Command'. Run 'winspec help'."
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            command = $Command
            status = 'Failed'
            results = @{}
            diagnostics = @(@{
                    severity = 'error'
                    code = 'UnknownCommand'
                    message = $message
                })
        } | ConvertTo-Json -Depth 8 -Compress
    }
    else {
        [Console]::Error.WriteLine($message)
    }
    exit 2
}
if ($Help -or $Command -eq 'help') {
    try {
        Show-Help $(if ($Command -eq 'help') { $Target } else { $Command })
        exit 0
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 2
    }
}

$root = $PSScriptRoot
Import-Module (Join-Path $root 'spec.psm1') -Force
Import-Module (Join-Path $root 'schema.psm1') -Force
Import-Module (Join-Path $root 'provider-runtime.psm1') -Force

function New-CommandResult {
    param([string]$Status, $Results, [object[]]$Diagnostics = @())
    return [ordered]@{
        schemaVersion = 1
        command = $Command
        status = $Status
        results = $Results
        diagnostics = @($Diagnostics)
    }
}

function Write-CommandResult {
    param($Result)
    if ($Json) {
        $Result | ConvertTo-Json -Depth 64 -Compress
    }
    else {
        Write-Host ("{0}: {1}" -f $Result.command, $Result.status)
        if ($null -ne $Result.results) {
            $Result.results | ConvertTo-Json -Depth 12
        }
        foreach ($diagnostic in @($Result.diagnostics)) {
            [Console]::Error.WriteLine(
                ("{0}: {1}" -f $diagnostic.code, $diagnostic.message))
        }
    }
}

function Assert-Specification {
    param([hashtable]$Spec, [object[]]$Catalog)
    $validation = Test-WinSpecSchema -Spec $Spec -ProviderCatalog $Catalog
    if (-not $validation.Valid) {
        throw 'InvalidSpecification: ' + ($validation.Errors -join '; ')
    }
    return $validation
}

function Test-DirectActionTarget {
    param([string]$Value)
    if (-not $Value) { return $false }
    $uri = $null
    if ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -in @('http', 'https')) {
        return $true
    }
    return $Value.Contains('\') -or $Value.Contains('/') -or
    $Value.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)
}

$exitCode = 0
try {
    if ($RemainingArguments.Count -gt 0 -and $Command -ne 'run') {
        throw "UnexpectedArguments: '$Command' does not accept -- arguments"
    }
    if ($SpecPath -and $Command -notin @('run', 'workflow')) {
        throw "InvalidOption: -Spec is not valid for '$Command'"
    }
    if ($Interactive -and $Command -ne 'run') {
        throw "InvalidOption: -Interactive is not valid for '$Command'"
    }
    if ($Checkpoint -and $Command -ne 'apply') {
        throw "InvalidOption: -Checkpoint is not valid for '$Command'"
    }
    if ($Providers.Count -gt 0 -and
        $Command -notin @('capture', 'status', 'diff', 'apply')) {
        throw "InvalidOption: -Providers is not valid for '$Command'"
    }
    if ($ProviderPath.Count -gt 0 -and $Command -notin @(
            'providers', 'validate', 'capture', 'status', 'diff', 'apply',
            'run', 'workflow')) {
        throw "InvalidOption: -ProviderPath is not valid for '$Command'"
    }
    if ($DryRun -and
        $Command -notin @('apply', 'run', 'workflow', 'rollback')) {
        throw "InvalidOption: -DryRun is not valid for '$Command'"
    }
    if ($Force -and $Command -notin @('capture', 'merge')) {
        throw "InvalidOption: -Force is not valid for '$Command'"
    }
    if ($Against -and $Command -ne 'diff') {
        throw "InvalidOption: -Against is not valid for '$Command'"
    }
    if (($Output -or $Strategy -ne 'auto') -and $Command -ne 'merge') {
        throw "InvalidOption: merge output options are not valid for '$Command'"
    }
    if (($Enter -or $Exit -or $List -or $Mode -ne 'Mock' -or
            $Snapshot -ne 'default') -and $Command -ne 'sandbox') {
        throw "InvalidOption: sandbox options are not valid for '$Command'"
    }
    if (($Last -or $SequenceNumber -gt 0) -and $Command -ne 'rollback') {
        throw "InvalidOption: rollback options are not valid for '$Command'"
    }
    if ($Sha256 -and $Command -ne 'run') {
        throw "InvalidOption: -Sha256 is not valid for '$Command'"
    }
    if ($Interactive -and ($Json -or $DryRun)) {
        throw 'InteractiveOutputConflict: -Interactive cannot be combined with -Json or -DryRun'
    }
    $catalog = Get-ProviderCatalog -ProviderPath $ProviderPath
    switch ($Command) {
        'providers' {
            $items = @($catalog | Select-Object Name, Kind, ProtocolVersion,
                Operations, EntryPointType, Origin)
            $result = New-CommandResult 'Succeeded' @{ providers = $items }
        }
        'validate' {
            $path = if ($Target) { $Target } else { $SpecPath }
            $spec = Get-Spec -Path $path
            $validation = Test-WinSpecSchema -Spec $spec `
                -ProviderCatalog $catalog
            $diagnostics = @()
            foreach ($message in $validation.Errors) {
                $diagnostics += @{
                    severity = 'error'
                    code = ($message -split ':')[0]
                    message = $message
                }
            }
            foreach ($message in $validation.Warnings) {
                $diagnostics += @{
                    severity = 'warning'
                    code = ($message -split ':')[0]
                    message = $message
                }
            }
            if ($validation.Valid) {
                $result = New-CommandResult 'Succeeded' @{ valid = $true } $diagnostics
            }
            else {
                $result = New-CommandResult 'Failed' @{ valid = $false } $diagnostics
                $exitCode = 2
            }
        }
        'capture' {
            $path = Resolve-SpecPath -Path $Target -ForCapture
            if ([IO.File]::Exists($path) -and -not $Force) {
                throw "OutputExists: '$path'"
            }
            Import-Module (Join-Path $root 'state.psm1') -Force
            $state = Get-WinSpecObservedState -Catalog $catalog `
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds
            $state.SchemaVersion = 1
            Save-Configuration -Config $state -Path $path -Force:$Force | Out-Null
            $result = New-CommandResult 'Succeeded' @{
                path = $path
                providers = @($state.Keys | Where-Object { $_ -ne 'SchemaVersion' })
            }
        }
        'status' {
            Import-Module (Join-Path $root 'state.psm1') -Force
            $path = if ($Target) { $Target } else { $SpecPath }
            if ($path) {
                $spec = Get-Spec $path
                $null = Assert-Specification $spec $catalog
                $state = Get-WinSpecObservedState -Catalog $catalog `
                    -Spec $spec -Providers $Providers `
                    -TimeoutSeconds $TimeoutSeconds
            }
            else {
                $state = Get-WinSpecObservedState -Catalog $catalog `
                    -Providers $Providers -TimeoutSeconds $TimeoutSeconds
            }
            $result = New-CommandResult 'Succeeded' @{ state = $state }
        }
        'diff' {
            Import-Module (Join-Path $root 'state.psm1') -Force
            $path = if ($Target) { $Target } else { $SpecPath }
            $spec = Get-Spec $path
            $null = Assert-Specification $spec $catalog
            $againstValue = if ($Against) { Get-Spec $Against } else { $null }
            $comparison = Compare-WinSpecState -Spec $spec -Catalog $catalog `
                -Against $againstValue -Providers $Providers `
                -TimeoutSeconds $TimeoutSeconds
            $result = New-CommandResult $comparison.Status $comparison
            if ($comparison.Status -eq 'Different') { $exitCode = 1 }
        }
        'apply' {
            Import-Module (Join-Path $root 'state.psm1') -Force
            $path = if ($Target) { $Target } else { $SpecPath }
            $spec = Get-Spec $path
            $null = Assert-Specification $spec $catalog
            $comparison = Compare-WinSpecState -Spec $spec -Catalog $catalog `
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds
            if ($comparison.Status -eq 'Unchanged') {
                $result = New-CommandResult 'Unchanged' @{
                    comparison = $comparison
                    providers = @()
                }
                break
            }
            if ($DryRun) {
                $result = New-CommandResult 'Planned' @{
                    comparison = $comparison
                    providers = @()
                }
                break
            }
            $checkpointValue = $null
            if ($Checkpoint) {
                Import-Module (Join-Path $root 'checkpoint.psm1') -Force
                $capability = Test-CheckpointCapability
                if (-not $capability.CanCreateCheckpoint) {
                    throw 'CheckpointUnavailable: system restore and administrator privileges are required'
                }
                $checkpointValue = New-Checkpoint
                if (-not $checkpointValue.Success) {
                    throw "CheckpointFailed: $($checkpointValue.Reason)"
                }
            }
            $applied = Invoke-WinSpecStateApply -Spec $spec -Catalog $catalog `
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds
            if ($applied.Status -eq 'Failed') { $exitCode = 3 }
            $result = New-CommandResult $applied.Status @{
                comparison = $comparison
                checkpoint = $checkpointValue
                providers = $applied.Providers
            }
        }
        'run' {
            if (-not $Target) { throw 'MissingAction: run requires one target' }
            Import-Module (Join-Path $root 'actions.psm1') -Force
            $forwarded = @($RemainingArguments)
            if (Test-DirectActionTarget $Target) {
                if ($SpecPath) {
                    throw 'InvalidSelection: -Spec is valid only for a named Action'
                }
                $uri = $null
                $isUri = [Uri]::TryCreate(
                    $Target, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -in @('http', 'https')
                if ($Sha256 -and -not $isUri) {
                    throw 'InvalidOption: -Sha256 is valid only for a direct remote Script'
                }
                $with = if ($isUri) {
                    @{ Uri = $Target }
                }
                else {
                    @{ File = $Target }
                }
                $action = @{ Use = 'Script'; With = $with }
                $provider = @($catalog | Where-Object Name -ieq 'Script')[0]
                $runResult = Invoke-WinSpecAction -Action $action `
                    -Provider $provider -Arguments $forwarded -DryRun:$DryRun `
                    -Interactive:$Interactive -Sha256 $Sha256 `
                    -TimeoutSeconds $TimeoutSeconds
                if ($runResult.Status -eq 'Failed') { $exitCode = 3 }
                $result = New-CommandResult $runResult.Status @{
                    actions = @($runResult)
                }
            }
            else {
                if ($Sha256) {
                    throw 'InvalidOption: named Actions store Sha256 in With'
                }
                if ($Interactive) {
                    throw 'InvalidSelection: -Interactive is for a direct local Script; named Scripts declare With.Interactive'
                }
                $document = Get-SpecDocument -Path $SpecPath
                $spec = $document.Spec
                $null = Assert-Specification $spec $catalog
                if (-not $spec.ContainsKey('Actions') -or
                    -not $spec.Actions.ContainsKey($Target)) {
                    throw "UnknownAction: '$Target'"
                }
                $action = $spec.Actions[$Target]
                $provider = @($catalog | Where-Object {
                        $_.Kind -eq 'Action' -and $_.Name -ieq $action.Use
                    })[0]
                $configuredInteractive = $action.Use -ieq 'Script' -and
                $action.ContainsKey('With') -and
                $action.With.ContainsKey('Interactive') -and
                $action.With.Interactive
                if ($configuredInteractive -and ($Json -or $DryRun)) {
                    throw 'InteractiveOutputConflict: interactive Actions cannot use -Json or -DryRun'
                }
                $runValue = Invoke-WinSpecAction -Action $action `
                    -Provider $provider `
                    -BasePath ([IO.Path]::GetDirectoryName($document.Path)) `
                    -Arguments $forwarded -DryRun:$DryRun `
                    -Sha256 $Sha256 `
                    -TimeoutSeconds $TimeoutSeconds
                if ($runValue.Status -eq 'Failed') { $exitCode = 3 }
                $result = New-CommandResult $runValue.Status @{
                    actions = @([pscustomobject]@{
                            name = $Target
                            result = $runValue
                        })
                }
            }
        }
        'workflow' {
            if (-not $Target) {
                throw 'MissingWorkflow: workflow requires a name'
            }
            $document = Get-SpecDocument -Path $SpecPath
            $null = Assert-Specification $document.Spec $catalog
            Import-Module (Join-Path $root 'workflow.psm1') -Force
            $workflowValue = Invoke-WinSpecWorkflow -Document $document `
                -Name $Target -Catalog $catalog -DryRun:$DryRun `
                -MachineOutput:$Json `
                -TimeoutSeconds $TimeoutSeconds
            if ($workflowValue.Status -eq 'Failed') { $exitCode = 3 }
            $result = New-CommandResult $workflowValue.Status $workflowValue
        }
        'merge' {
            if (-not $Target -or -not $Second) {
                throw 'MissingOperand: merge requires base and incoming paths'
            }
            Import-Module (Join-Path $root 'merge.psm1') -Force
            $merged = Merge-Configuration -Base (Get-Spec $Target) `
                -Incoming (Get-Spec $Second) -Output $Output `
                -Strategy $Strategy -Force:$Force
            if (-not $merged.Success) {
                $result = New-CommandResult 'Failed' $merged
                $exitCode = 2
            }
            else {
                $result = New-CommandResult 'Succeeded' $merged
            }
        }
        'sandbox' {
            Import-Module (Join-Path $root 'sandbox.psm1') -Force
            if (@($Enter, $Exit, $List | Where-Object { $_ }).Count -gt 1) {
                throw 'InvalidSandboxOperation: choose one switch'
            }
            if ($Snapshot -match '[\\/]' -or $Snapshot -in @('.', '..') -or
                [IO.Path]::IsPathRooted($Snapshot)) {
                throw "InvalidSnapshotName: '$Snapshot'"
            }
            if ($Enter) { $value = Enter-Sandbox -Mode $Mode -Snapshot $Snapshot }
            elseif ($Exit) { $value = Exit-Sandbox }
            elseif ($List) { $value = Get-SandboxSnapshots }
            else { $value = Get-SandboxContext }
            $result = New-CommandResult 'Succeeded' @{ sandbox = $value }
        }
        'rollback' {
            if ([bool]$Last -eq [bool]($SequenceNumber -gt 0)) {
                throw 'InvalidRollbackTarget: choose exactly one target'
            }
            Import-Module (Join-Path $root 'checkpoint.psm1') -Force
            if ($DryRun) {
                $result = New-CommandResult 'Planned' @{
                    last = [bool]$Last
                    sequenceNumber = $SequenceNumber
                }
            }
            else {
                $value = Invoke-Rollback -Last:$Last `
                    -SequenceNumber $SequenceNumber
                if (-not $value.Success) {
                    throw "RollbackFailed: $($value.Reason)"
                }
                $result = New-CommandResult 'Succeeded' @{ rollback = $value }
            }
        }
    }
}
catch {
    $message = $_.Exception.Message
    $code = ($message -split ':')[0]
    $exitCode = if ($code -match 'Timeout|Cancel') {
        4
    }
    elseif ($code -match 'ProviderFailed|ProcessFailed|ScriptStart|Checkpoint|Rollback|OutputExists') {
        3
    }
    else {
        2
    }
    $result = New-CommandResult 'Failed' @{} @(@{
            severity = 'error'
            code = $code
            message = $message
        })
}
Write-CommandResult $result
exit $exitCode
