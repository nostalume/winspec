#!/usr/bin/env pwsh

$Command = 'help'
$Target = $null
$Second = $null
$SpecPath = $null
$Provider = $null
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
$PreviewActions = $false
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
                    '-list', '-last', '-help', '-previewactions')) {
                Set-Variable -Name ($option.TrimStart('-')) -Value $true
                $index++
                continue
            }
            if ($option -in @(
                    '-spec', '-provider', '-providers', '-providerpath', '-against',
                    '-output', '-strategy', '-sha256', '-timeoutseconds',
                    '-mode', '-snapshot', '-sequencenumber')) {
                if ($index + 1 -ge $raw.Count) {
                    throw "MissingOptionValue: '$token'"
                }
                $value = $raw[$index + 1]
                switch ($option) {
                    '-spec' { $SpecPath = [string]$value }
                    '-provider' { $Provider = [string]$value }
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

$Script:CommandHelp = [ordered]@{
    capture = @{
        Purpose = 'Observe selected State and publish it as a data-only specification.'
        Usage = @('winspec capture [output] [-Providers names] [-ProviderPath roots] [-Force] [-Json]')
        Effects = 'Reads machine State and writes one specification; it never applies State or runs Actions.'
        Default = 'Observes core State and writes the user .winspec.psd1 path.'
        Example = 'winspec capture .\observed.winspec.psd1 -Providers Registry'
    }
    status = @{
        Purpose = 'Observe selected State without publishing or changing it.'
        Usage = @('winspec status [spec] [-Providers names] [-ProviderPath roots] [-Json]')
        Effects = 'Reads machine State only.'
        Default = 'Uses State sections in a spec, or core State when no spec is supplied.'
        Example = 'winspec status .\machine.winspec.psd1 -Providers Registry'
    }
    validate = @{
        Purpose = 'Check a specification and report provider-validation coverage.'
        Usage = @('winspec validate [spec] [-ProviderPath roots] [-PreviewActions] [-Json]')
        Effects = 'Structural mode reads data only; -PreviewActions starts trusted Action-provider previews.'
        Default = 'Uses the default spec and performs structural validation without provider execution.'
        Example = 'winspec validate .\machine.winspec.psd1 -PreviewActions'
    }
    diff = @{
        Purpose = 'Compare declarative State only; Actions are never part of a diff.'
        Usage = @('winspec diff [spec] [-Against spec] [-Providers names] [-ProviderPath roots] [-Json]')
        Effects = 'Reads State and returns Different with exit 1; it never changes the machine.'
        Default = 'Compares the selected/default spec with current machine State.'
        Example = 'winspec diff .\machine.winspec.psd1 -Providers Registry'
    }
    apply = @{
        Purpose = 'Converge selected declarative State without running Actions.'
        Usage = @('winspec apply [spec] [-Providers names] [-ProviderPath roots] [-DryRun] [-Checkpoint] [-Json]')
        Effects = 'May change selected machine State; -DryRun only observes and compares.'
        Default = 'Uses State sections in the selected/default spec.'
        Example = 'winspec apply .\machine.winspec.psd1 -DryRun'
    }
    run = @{
        Purpose = 'Execute or preview exactly one named, direct-provider, or Script Action.'
        Usage = @(
            'winspec run <name> [-Spec spec] [-DryRun] [-Json] [-- arguments]',
            'winspec run -Provider name [-ProviderPath roots] [-DryRun] [-Json] [-- arguments]',
            'winspec run <path|uri> [-Interactive] [-Sha256 hex] [-DryRun] [-Json] [-- arguments]')
        Effects = 'May execute provider or script code; -DryRun uses preview or returns an opaque plan.'
        Default = 'A name selects a configured Action; -Provider selects an ephemeral empty configuration.'
        Example = 'winspec run -Provider MicrosoftActivation -DryRun -- /HWID'
    }
    workflow = @{
        Purpose = 'Execute or preview one configured ordered multi-step Workflow.'
        Usage = @('winspec workflow <name> [-Spec spec] [-DryRun] [-Json]')
        Effects = 'May apply State, run Actions, and publish captures in declared order.'
        Default = 'Uses the named Workflow in the selected/default spec.'
        Example = 'winspec workflow setup -Spec .\machine.winspec.psd1 -DryRun'
    }
    merge = @{
        Purpose = 'Combine two data-only specifications without touching machine State.'
        Usage = @('winspec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]')
        Effects = 'Reads two specs and optionally writes one merged spec.'
        Default = 'Uses auto strategy and writes the merged data to stdout.'
        Example = 'winspec merge .\base.psd1 .\incoming.psd1 -Output .\merged.psd1'
    }
    providers = @{
        Purpose = 'List discovered provider implementations without reading configured Actions.'
        Usage = @('winspec providers [-ProviderPath roots] [-Json]')
        Effects = 'Reads static manifests only and never starts a provider.'
        Default = 'Includes core, bundled, user, and explicitly rooted providers.'
        Example = 'winspec providers -Json'
    }
    actions = @{
        Purpose = 'List configured Action instances and their provider bindings.'
        Usage = @('winspec actions [spec] [-ProviderPath roots] [-Json]')
        Effects = 'Reads and validates a spec; it never starts or runs an Action provider.'
        Default = 'Uses the default spec and returns an empty list when it has no Actions.'
        Example = 'winspec actions .\machine.winspec.psd1 -Json'
    }
    sandbox = @{
        Purpose = 'Inspect or change the local WinSpec sandbox context.'
        Usage = @('winspec sandbox [-Enter|-Exit|-List] [-Mode Mock|DryRun] [-Snapshot name]')
        Effects = 'Changes only local sandbox context files when entering or exiting.'
        Default = 'Displays the current context when no operation switch is supplied.'
        Example = 'winspec sandbox -Enter -Mode Mock'
    }
    rollback = @{
        Purpose = 'Preview or request one explicit Windows restore operation.'
        Usage = @('winspec rollback (-Last|-SequenceNumber n) [-DryRun]')
        Effects = 'May request Windows System Restore; WinSpec never elevates implicitly.'
        Default = 'Requires exactly one restore target.'
        Example = 'winspec rollback -Last -DryRun'
    }
    help = @{
        Purpose = 'Show the command inventory or detailed help for one command.'
        Usage = @('winspec help [command]', 'winspec <command> -Help')
        Effects = 'Writes documentation to stdout without loading a spec or provider catalog.'
        Default = 'Shows the complete command inventory.'
        Example = 'winspec help run'
    }
}
$Script:Commands = @($Script:CommandHelp.Keys)
$Command = $Command.ToLowerInvariant()

function Show-Help {
    param([string]$Topic)
    if (-not $Topic) {
        $lines = @'
WinSpec - declarative Windows state and explicit actions

State is declarative and converged by apply. An Action is one explicit effect
executed by run. A Workflow is the only ordered multi-step owner.

Commands:
'@
        $lines += [Environment]::NewLine
        foreach ($name in $Script:Commands) {
            $lines += ('  {0} - {1}' -f $name.PadRight(10),
                $Script:CommandHelp[$name].Purpose) + [Environment]::NewLine
        }
        $lines += @'

Run "winspec help <command>" or "winspec <command> -Help" for details.
Specifications are data-only .psd1 or .json files. Provider discovery reads
static manifests and never starts provider code.
'@
        $lines
        return
    }
    if (-not $Script:CommandHelp.Contains($Topic)) {
        throw "UnknownCommand: '$Topic'"
    }
    $item = $Script:CommandHelp[$Topic]
    $usage = @($item.Usage | ForEach-Object { "  $_" }) -join
    [Environment]::NewLine
    @"
WinSpec $Topic

Purpose: $($item.Purpose)
Usage:
$usage
Effects: $($item.Effects)
Default: $($item.Default)
Example:
  $($item.Example)
See: docs/api.md and docs/usage.md
"@
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
        $helpTopic = if ($Command -ne 'help') {
            $Command
        }
        elseif ($Target) {
            $Target
        }
        elseif ($Help) {
            'help'
        }
        else {
            $null
        }
        Show-Help $helpTopic
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
            $code = [string]$diagnostic.code
            $message = [string]$diagnostic.message
            $prefix = $code + ':'
            $line = if ($message.StartsWith(
                    $prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $message
            }
            else {
                "${code}: $message"
            }
            [Console]::Error.WriteLine($line)
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

function Get-ProviderValidationSubjects {
    param([hashtable]$Spec, [object[]]$Catalog)

    $subjects = @()
    foreach ($provider in @($Catalog | Where-Object {
                $_.Execution -eq 'Protocol' -and $_.Kind -eq 'State'
            })) {
        if ($Spec.ContainsKey($provider.Name)) {
            $subjects += [pscustomobject][ordered]@{
                path = [string]$provider.Name
                provider = [string]$provider.Name
                status = 'NotRun'
            }
        }
    }
    if ($Spec.ContainsKey('Actions') -and $Spec.Actions -is [hashtable]) {
        foreach ($name in @($Spec.Actions.Keys | Sort-Object)) {
            $action = $Spec.Actions[$name]
            if ($action -isnot [hashtable] -or
                $action.Use -isnot [string]) {
                continue
            }
            $provider = @($Catalog | Where-Object {
                    $_.Execution -eq 'Protocol' -and
                    $_.Kind -eq 'Action' -and $_.Name -ieq $action.Use
                })[0]
            if ($provider) {
                $subjects += [pscustomobject][ordered]@{
                    path = "Actions.$name"
                    provider = [string]$provider.Name
                    status = 'NotRun'
                }
            }
        }
    }
    return @($subjects | Sort-Object path)
}

function Get-CommandFailureExitCode {
    param([string]$Code)

    if ($Code -match 'Timeout|Cancel') { return 4 }
    if ($Code -match 'ProviderFailed|ProcessFailed|ScriptStart|Checkpoint|Rollback|OutputExists') {
        return 3
    }
    return 2
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
    if ($Provider -and $Command -ne 'run') {
        throw "InvalidOption: -Provider is not valid for '$Command'"
    }
    if ($PreviewActions -and $Command -ne 'validate') {
        throw "InvalidOption: -PreviewActions is not valid for '$Command'"
    }
    if ($Provider -and ($Target -or $SpecPath -or $Interactive -or $Sha256)) {
        throw 'InvalidSelection: direct provider execution cannot use a target, -Spec, -Interactive, or -Sha256'
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
            'run', 'workflow', 'actions')) {
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
        'actions' {
            $document = Get-SpecDocument -Path $Target
            $null = Assert-Specification $document.Spec $catalog
            $items = @()
            if ($document.Spec.ContainsKey('Actions')) {
                foreach ($name in @($document.Spec.Actions.Keys | Sort-Object)) {
                    $action = $document.Spec.Actions[$name]
                    $selected = @($catalog | Where-Object {
                            $_.Kind -eq 'Action' -and
                            $_.Name -ieq $action.Use
                        })[0]
                    $items += [pscustomobject][ordered]@{
                        name = [string]$name
                        provider = [string]$selected.Name
                        origin = [string]$selected.Origin
                        operations = @($selected.Operations)
                    }
                }
            }
            $result = New-CommandResult 'Succeeded' @{ actions = @($items) }
        }
        'validate' {
            $path = if ($Target) { $Target } else { $SpecPath }
            $document = Get-SpecDocument -Path $path
            $spec = $document.Spec
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
            $subjects = @(Get-ProviderValidationSubjects $spec $catalog)
            $valid = [bool]$validation.Valid
            $providerExitCode = 0
            if ($PreviewActions -and $validation.Valid) {
                Import-Module (Join-Path $root 'actions.psm1') -Force
                foreach ($subject in @($subjects | Where-Object {
                            $_.path.StartsWith('Actions.')
                        })) {
                    $name = $subject.path.Substring('Actions.'.Length)
                    $action = $spec.Actions[$name]
                    $selected = @($catalog | Where-Object {
                            $_.Kind -eq 'Action' -and
                            $_.Name -ieq $action.Use
                        })[0]
                    if ('preview' -notin @($selected.Operations)) {
                        $subject.status = 'Unavailable'
                        continue
                    }
                    try {
                        $preview = Invoke-WinSpecAction -Action $action `
                            -Provider $selected -DryRun `
                            -BasePath ([IO.Path]::GetDirectoryName($document.Path)) `
                            -TimeoutSeconds $TimeoutSeconds
                    }
                    catch {
                        $subject.status = 'Unavailable'
                        $message = $_.Exception.Message
                        $code = ($message -split ':')[0]
                        $diagnostics += @{
                            severity = 'error'
                            code = $code
                            message = $message
                            subject = $subject.path
                        }
                        $valid = $false
                        $providerExitCode = Get-CommandFailureExitCode $code
                        break
                    }
                    if ($preview.Status -eq 'Failed') {
                        $subject.status = 'Invalid'
                        $valid = $false
                        $previewDiagnostics = @($preview.Diagnostics)
                        if ($previewDiagnostics.Count -eq 0) {
                            $previewDiagnostics = @([pscustomobject]@{
                                    code = 'ProviderValidationFailed'
                                    message = "Action '$name' was rejected by '$($selected.Name)'"
                                })
                        }
                        foreach ($item in $previewDiagnostics) {
                            $diagnostics += @{
                                severity = 'error'
                                code = [string]$item.code
                                message = [string]$item.message
                                subject = $subject.path
                            }
                        }
                    }
                    else {
                        $subject.status = 'Valid'
                    }
                }
            }
            $results = @{
                valid = $valid
                validation = [ordered]@{
                    mode = if ($PreviewActions) {
                        'ActionPreview'
                    }
                    else {
                        'Structural'
                    }
                    subjects = @($subjects)
                }
            }
            if ($providerExitCode -gt 0) {
                $result = New-CommandResult 'Failed' $results $diagnostics
                $exitCode = $providerExitCode
            }
            elseif ($valid) {
                $result = New-CommandResult 'Succeeded' $results $diagnostics
            }
            else {
                $result = New-CommandResult 'Failed' $results $diagnostics
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
            if (-not $Target -and -not $Provider) {
                throw 'MissingAction: run requires one target or -Provider'
            }
            Import-Module (Join-Path $root 'actions.psm1') -Force
            $forwarded = @($RemainingArguments)
            if ($Provider) {
                $matches = @($catalog | Where-Object Name -ieq $Provider)
                if ($matches.Count -ne 1) {
                    throw "UnknownProvider: '$Provider'"
                }
                $selected = $matches[0]
                if ($selected.Kind -ne 'Action') {
                    throw "WrongProviderKind: '$Provider' is not an Action provider"
                }
                if ($selected.Name -ieq 'Script') {
                    throw 'InvalidSelection: direct Script execution requires a path or URI'
                }
                $action = @{ Use = $selected.Name; With = @{} }
                $runValue = Invoke-WinSpecAction -Action $action `
                    -Provider $selected -BasePath ([IO.Path]::GetFullPath($PWD)) `
                    -Arguments $forwarded -DryRun:$DryRun `
                    -TimeoutSeconds $TimeoutSeconds
                if ($runValue.Status -eq 'Failed') { $exitCode = 3 }
                $result = New-CommandResult $runValue.Status @{
                    actions = @([pscustomobject][ordered]@{
                            provider = [string]$selected.Name
                            result = $runValue
                        })
                }
            }
            elseif (Test-DirectActionTarget $Target) {
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
    $exitCode = Get-CommandFailureExitCode $code
    $result = New-CommandResult 'Failed' @{} @(@{
            severity = 'error'
            code = $code
            message = $message
        })
}
Write-CommandResult $result
exit $exitCode
