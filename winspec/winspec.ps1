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
$Force = $false
$Json = $false
$DryRun = $false
$Checkpoint = $false
$Interactive = $false
$Sha256 = $null
$Last = $false
$SequenceNumber = 0
$Help = $false
$PreviewActions = $false
$RemainingArguments = @()
$RunSelection = $null
$RunIsRemote = $false

# Type and repetition belong to the option; command applicability belongs to
# the command inventory below. Presence is independent of a default value.
$Script:Options = [ordered]@{
    '-json' = @{ Type = 'Switch'; Variable = 'Json'; Display = '-Json'; Description = 'Return one result document on stdout; no progress/log lines are added. Default: human-readable output. Incompatible with Interactive.' }
    '-help' = @{ Type = 'Switch'; Variable = 'Help'; Display = '-Help'; Description = 'Show command help without reading a specification or starting a provider. Use without operands or execution options; Json is allowed.' }
    '-dryrun' = @{ Type = 'Switch'; Variable = 'DryRun'; Display = '-DryRun'; Description = 'Do not request the actual apply/run/restore operation. Provider previews may execute trusted code; Script previews are opaque. Default: actual operation.' }
    '-previewactions' = @{ Type = 'Switch'; Variable = 'PreviewActions'; Display = '-PreviewActions'; Description = 'Explicitly run declared external Action-provider previews and report coverage. Default: structural validation only.' }
    '-spec' = @{ Type = 'String'; Variable = 'SpecPath'; Display = '-Spec <path>'; Description = 'Select the specification for a named Action or Workflow. Default: user specification; not valid for a direct provider or Script.' }
    '-provider' = @{ Type = 'String'; Variable = 'Provider'; Display = '-Provider <name>'; Description = 'Select one Action implementation with empty With configuration. Cannot be combined with a target, Spec, Interactive or Sha256.' }
    '-providers' = @{ Type = 'List'; Variable = 'Providers'; Display = '-Providers <names>'; Description = 'Select State providers by name; comma-separated/repeatable. Empty items fail and duplicates are removed. This does not select Actions.' }
    '-providerpath' = @{ Type = 'List'; Variable = 'ProviderPath'; Display = '-ProviderPath <roots>'; Description = 'Add static package discovery roots; comma-separated/repeatable. Relative roots resolve from the current directory. Does not execute or install a provider.' }
    '-against' = @{ Type = 'String'; Variable = 'Against'; Display = '-Against <path>'; Description = 'Compare the desired spec with this observed/reference spec instead of the current machine. Default: live comparison.' }
    '-output' = @{ Type = 'String'; Variable = 'Output'; Display = '-Output <path>'; Description = 'Publish the merged data-only specification at this path. Default: return a merge result without writing a file.' }
    '-strategy' = @{ Type = 'String'; Variable = 'Strategy'; Display = '-Strategy <name>'; Description = 'auto, union, ours or theirs; default {0}. auto reports scalar/array conflicts, ours/theirs choose a side, union combines arrays and otherwise chooses incoming values.'; Default = 'auto' }
    '-force' = @{ Type = 'Switch'; Variable = 'Force'; Display = '-Force'; Description = 'Allow replacing the selected capture/merge output file. Does not bypass validation, trust, privileges or unresolved merge conflicts. Default: refuse existing output.' }
    '-checkpoint' = @{ Type = 'Switch'; Variable = 'Checkpoint'; Display = '-Checkpoint'; Description = 'Request one Windows restore point before a changing apply. Default: no checkpoint. Requires already-available System Restore and privileges.' }
    '-interactive' = @{ Type = 'Switch'; Variable = 'Interactive'; Display = '-Interactive'; Description = 'Direct local Script only; inherit its terminal. Cannot use Json or DryRun. Named Scripts declare With.Interactive instead. Default: captured noninteractive execution.' }
    '-sha256' = @{ Type = 'String'; Variable = 'Sha256'; Display = '-Sha256 <64 hex chars>'; Description = 'Direct remote Script only; exactly 64 hexadecimal characters. Verify received bytes against this independently obtained pin. Named Scripts declare With.Sha256. Required for HTTP; optional for HTTPS.' }
    '-timeoutseconds' = @{ Type = 'Integer'; Variable = 'TimeoutSeconds'; Display = '-TimeoutSeconds <int>'; Description = '1..3600, default {0}; per managed operation, not a whole Workflow or every synchronous Windows API.'; Default = 300 }
    '-last' = @{ Type = 'Switch'; Variable = 'Last'; Display = '-Last'; Description = 'Choose the latest available Windows restore point during actual rollback. Exactly one of Last or SequenceNumber is required; no default target.' }
    '-sequencenumber' = @{ Type = 'Integer'; Variable = 'SequenceNumber'; Display = '-SequenceNumber <positive-int>'; Description = 'Choose this positive Windows restore-point sequence. Exactly one of Last or SequenceNumber is required; no default target.' }
}
$Strategy = $Script:Options['-strategy'].Default
$TimeoutSeconds = $Script:Options['-timeoutseconds'].Default
$Script:RetiredOptions = @(
    '-verbose', '-debug', '-enter', '-exit', '-list', '-mode', '-snapshot')
$Script:RetiredSandboxMessage = 'RetiredCommand: sandbox was removed; use the selected command -DryRun for a bounded preview; existing sandbox files are not changed'

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

function Write-AdmissionFailure {
    param([string]$Message)
    if ($Json) {
        New-CommandResult 'Failed' @{} @(@{
                severity = 'error'
                code = ($Message -split ':')[0]
                message = $Message
            }) | ConvertTo-Json -Depth 8 -Compress
    }
    else {
        Import-Module (Join-Path $PSScriptRoot 'console.psm1') -Force
        $failure = New-CommandResult 'Failed' @{} @(@{
                severity = 'error'; code = ($Message -split ':')[0]; message = $Message
            })
        $admissionContext = @{ Target = $Target }
        if ($index + 1 -lt $raw.Count) { $admissionContext.MissingValueBefore = [string]$raw[$index + 1] }
        Write-WinSpecHumanResult $failure $admissionContext -ExitCode 2
    }
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

$Script:CommandHelp = [ordered]@{
    capture = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-providers', '-providerpath', '-force', '-timeoutseconds', '-json')
        Purpose = 'Observe selected State and publish it as a data-only specification.'
        Usage = @('winspec capture [output] [-Providers names] [-ProviderPath roots] [-Force] [-Json]')
        Effects = 'Reads machine State and writes one specification; it never applies State or runs Actions.'
        Default = 'Observes core State and writes the user .winspec.psd1 path.'
        Example = 'winspec capture .\observed.winspec.psd1 -Providers Registry'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'observe State and publish a specification'
            Usage = @('winspec capture [output] [options]')
            Selection = @('Select State providers with -Providers; otherwise observe core State. Output defaults to the user .winspec.psd1 path.',
                'Default output: %USERPROFILE%\.config\winspec\.winspec.psd1 (not the JSON fallback).')
            Effects = @('Reads selected State and writes one data-only specification. Existing output requires -Force. Does not run Actions or back up arbitrary files.',
                'Without Force, a destination that appears during publication is not replaced. Concurrent changes or file permissions can still prevent publication.')
            Examples = @('winspec capture .\observed.psd1 -Providers Registry')
            Exit = @('0: published. 2: admission or unclassified boundary error.',
                '3: provider failure or existing output refused. 4: command-boundary timeout.')
            Group = 'Files'
            Inventory = 'Observe State and publish a specification.'
            DisplayOrder = '8'
        }
    }
    status = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-providers', '-providerpath', '-timeoutseconds', '-json')
        Purpose = 'Observe selected State without publishing or changing it.'
        Usage = @('winspec status [spec] [-Providers names] [-ProviderPath roots] [-Json]')
        Effects = 'Reads machine State only.'
        Default = 'Uses State sections in a spec, or core State when no spec is supplied.'
        Example = 'winspec status .\machine.winspec.psd1 -Providers Registry'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'observe State without comparing or publishing it'
            Usage = @('winspec status [spec] [options]')
            Selection = @('A supplied spec selects its State sections. Without a spec, select core State. -Providers overrides the provider selection, not the desired values.',
                'An omitted spec does not load the default specification; it observes core State.')
            Effects = @('Reads selected State. Does not prove compliance with a specification; use diff for comparison.')
            Examples = @('winspec status .\machine.json -Providers Registry')
            Exit = @('0: observed. 2: admission failed. 3: observation failed. 4: command-boundary timeout.')
            Group = 'Inspect'
            Inventory = 'Observe selected State; does not compare it with desired State.'
            DisplayOrder = '2'
        }
    }
    validate = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-providerpath', '-previewactions', '-timeoutseconds', '-json')
        Purpose = 'Check a specification and report provider-validation coverage.'
        Usage = @('winspec validate [spec] [-ProviderPath roots] [-PreviewActions] [-Json]')
        Effects = 'Structural mode reads data only; -PreviewActions starts trusted Action-provider previews.'
        Default = 'Uses the default spec and performs structural validation without provider execution.'
        Example = 'winspec validate .\machine.winspec.psd1 -PreviewActions'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'check structure and expose validation coverage'
            Usage = @('winspec validate [spec] [options]')
            Selection = @('Use the explicit/default spec. Structural checks are the default; -PreviewActions explicitly starts declared external Action previews.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('Structural validation starts no provider code. Valid preview means accepted preview, not proven execution success. External State semantics may remain NotRun.',
                'Core Script source existence and runtime dependencies are not checked by validate.',
                'Use run <action> -DryRun to check a local Script source; remote Script previews do not download.')
            Examples = @('winspec validate .\machine.json',
                'winspec validate .\machine.json -PreviewActions')
            Exit = @('0: checks passed within reported coverage. 2: invalid input/configuration. 3: provider execution failed. 4: command-boundary timeout.')
            Group = 'Inspect'
            Inventory = 'Check specification structure and report validation coverage.'
            DisplayOrder = '3'
        }
    }
    diff = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-against', '-providers', '-providerpath', '-timeoutseconds', '-json')
        Purpose = 'Compare declarative State only; Actions are never part of a diff.'
        Usage = @('winspec diff [spec] [-Against spec] [-Providers names] [-ProviderPath roots] [-Json]')
        Effects = 'Reads State and returns Different with exit 1; it never changes the machine.'
        Default = 'Compares the selected/default spec with current machine State.'
        Example = 'winspec diff .\machine.winspec.psd1 -Providers Registry'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'compare declarative State, not Actions'
            Usage = @('winspec diff [spec] [-Against <spec>] [options]')
            Selection = @('Use the explicit/default desired spec. Compare with the machine unless -Against selects another spec. Limit State providers with -Providers.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('Observes/compares State but does not apply it. Exit 1 is a successful comparison with differences, not a failure.')
            Examples = @('winspec diff .\machine.json -Providers Registry',
                'winspec diff .\desired.json -Against .\observed.json')
            Exit = @('0: no differences or no selected work. 1: differences. 2: admission failed. 3: provider failed. 4: command-boundary timeout.')
            Group = 'Inspect'
            Inventory = 'Compare State; exit 1 means differences were found.'
            DisplayOrder = '4'
        }
    }
    apply = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-providers', '-providerpath', '-dryrun', '-checkpoint', '-timeoutseconds', '-json')
        Purpose = 'Converge selected declarative State without running Actions.'
        Usage = @('winspec apply [spec] [-Providers names] [-ProviderPath roots] [-DryRun] [-Checkpoint] [-Json]')
        Effects = 'May change selected machine State; -DryRun only observes and compares.'
        Default = 'Uses State sections in the selected/default spec.'
        Example = 'winspec apply .\machine.winspec.psd1 -DryRun'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'converge selected State without running Actions'
            Usage = @('winspec apply [spec] [options]')
            Selection = @('Use State sections from the explicit/default spec, or restrict them with -Providers.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('May change selected State. -DryRun observes/compares but never calls apply. -Checkpoint requests a restore point only before changing work; it does not elevate or guarantee rollback.')
            Examples = @('winspec apply .\machine.json -DryRun',
                'winspec apply .\machine.json -Providers Registry')
            Exit = @('0: succeeded, unchanged, or planned. 2: admission failed. 3: execution/checkpoint failed. 4: command-boundary timeout.')
            Group = 'Change'
            Inventory = 'Converge selected State; never runs Actions.'
            DisplayOrder = '5'
        }
    }
    run = @{
        MinOperands = 1
        MaxOperands = 1
        Options = @('-spec', '-provider', '-providerpath', '-interactive', '-sha256', '-dryrun', '-timeoutseconds', '-json')
        Purpose = 'Execute or preview exactly one named, direct-provider, or Script Action.'
        Usage = @(
            'winspec run <name> [-Spec spec] [-DryRun] [-Json] [-- arguments]',
            'winspec run -Provider name [-ProviderPath roots] [-DryRun] [-Json] [-- arguments]',
            'winspec run <path|uri> [-Interactive] [-Sha256 hex] [-DryRun] [-Json] [-- arguments]')
        Effects = 'May execute provider or script code; -DryRun uses preview or returns an opaque plan.'
        Default = 'A name selects a configured Action; -Provider selects an ephemeral empty configuration.'
        Example = 'winspec run -Provider MicrosoftActivation -DryRun -- /HWID'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'execute or preview exactly one Action.'
            Usage = @('Named Action:    winspec run <action> [-Spec <spec>] [options] [-- <args>]',
                'Direct provider: winspec run -Provider <name> [options] [-- <args>]',
                'Direct Script:   winspec run <file.ps1|http(s)-uri> [options] [-- <args>]')
            Selection = @('A name selects Actions.<name> in the explicit or default specification.',
                '-Provider selects one Action implementation with empty With configuration.',
                'A file/URI selects the core Script provider, without loading a specification.',
                'A provider name is never inferred from a named Action.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('Normal execution starts trusted code with the caller''s privileges.',
                'Script DryRun checks selection/source, but does not run/download the Script',
                'or predict its internal changes. Provider DryRun may start preview code;',
                'if preview is unavailable, only an opaque plan is returned.',
                'Interactive cannot use Json or DryRun. Named Actions configure interaction',
                'and remote digest in With; CLI options do not override those choices.',
                'HTTPS without a digest permits current unpinned content. HTTP requires Sha256.',
                'Process isolation is not an OS security sandbox.',
                'Timeout/cancellation may leave external effects; nothing is retried or undone.')
            Examples = @('winspec run hello -Spec .\machine.json -DryRun',
                'winspec run -Provider MicrosoftActivation -DryRun -- /HWID',
                'winspec run .\scripts\hello.ps1 -DryRun -- "two words"')
            Exit = @('0: succeeded or planned. 2: admission failed. 3: execution failed.',
                '4: timeout/cancellation at the command boundary.',
                'Child exit codes are reported separately, not returned as WinSpec exit codes.')
            Group = 'Change'
            Inventory = 'Run one named Action, direct provider, or Script.'
            DisplayOrder = '6'
        }
    }
    workflow = @{
        MinOperands = 1
        MaxOperands = 1
        Options = @('-spec', '-providerpath', '-dryrun', '-timeoutseconds', '-json')
        Purpose = 'Execute or preview one configured ordered multi-step Workflow.'
        Usage = @('winspec workflow <name> [-Spec spec] [-DryRun] [-Json]')
        Effects = 'May apply State, run Actions, and publish captures in declared order.'
        Default = 'Uses the named Workflow in the selected/default spec.'
        Example = 'winspec workflow setup -Spec .\machine.winspec.psd1 -DryRun'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'run one declared sequence, stopping after failure'
            Usage = @('winspec workflow <name> [-Spec <spec>] [options]')
            Selection = @('Select one Workflow name from the explicit/default spec. Steps reference configured Actions and State selections.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('Preflight may start trusted provider previews. Normal execution may apply State, run Actions and publish captures. Completed steps are not automatically undone. Timeout is per managed operation, not a Workflow-wide budget.')
            Examples = @('winspec workflow setup -Spec .\machine.json -DryRun')
            Exit = @('0: succeeded or planned. 2: admission/preflight selection failed. 3: completed Failed receipt, including a captured step timeout. 4: timeout at the command boundary.')
            Group = 'Change'
            Inventory = 'Execute one configured sequence; stops after a failed step.'
            DisplayOrder = '7'
        }
    }
    merge = @{
        MinOperands = 2
        MaxOperands = 2
        Options = @('-output', '-strategy', '-force', '-json')
        Purpose = 'Combine two data-only specifications without touching machine State.'
        Usage = @('winspec merge <base> <incoming> [-Output path] [-Strategy auto|union|ours|theirs] [-Force]')
        Effects = 'Reads two specs and optionally writes one merged spec.'
        Default = 'Uses auto strategy and writes the merged data to stdout.'
        Example = 'winspec merge .\base.psd1 .\incoming.psd1 -Output .\merged.psd1'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'combine two data-only specifications'
            Usage = @('winspec merge <base> <incoming> [options]')
            Selection = @('Provide base and incoming specs. Strategy defaults to auto; -Output selects publication, otherwise no file is written.')
            Effects = @('Does not observe/change machine State. auto reports conflicts; Force allows replacement of an output file but does not resolve conflicts.')
            Examples = @('winspec merge .\base.psd1 .\incoming.psd1 -Output .\merged.psd1')
            Exit = @('0: merged. 2: admission/conflict or unclassified boundary error. 3: existing output refused.')
            Group = 'Files'
            Inventory = 'Merge two specifications; report conflicts or publish a result.'
            DisplayOrder = '9'
        }
    }
    providers = @{
        MinOperands = 0
        MaxOperands = 0
        Options = @('-providerpath', '-json')
        Purpose = 'List discovered provider implementations without reading configured Actions.'
        Usage = @('winspec providers [-ProviderPath roots] [-Json]')
        Effects = 'Reads static manifests only and never starts a provider.'
        Default = 'Includes core, bundled, user, and explicitly rooted providers.'
        Example = 'winspec providers -Json'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'list discovered implementations, not configured Actions'
            Usage = @('winspec providers [options]')
            Selection = @('Core, bundled, user and explicit -ProviderPath roots are discovered statically.')
            Effects = @('Reads manifests and checks static package shape; never starts a provider or checks runtime readiness. Use actions to inspect named instances in a spec.')
            Examples = @('winspec providers')
            Exit = @('0: listed. 2: catalog admission failed.')
            Group = 'Inspect'
            Inventory = 'List discovered implementations; no provider code is started.'
            DisplayOrder = '0'
        }
    }
    actions = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-providerpath', '-json')
        Purpose = 'List configured Action instances and their provider bindings.'
        Usage = @('winspec actions [spec] [-ProviderPath roots] [-Json]')
        Effects = 'Reads and validates a spec; it never starts or runs an Action provider.'
        Default = 'Uses the default spec and returns an empty list when it has no Actions.'
        Example = 'winspec actions .\machine.winspec.psd1 -Json'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'list named Action bindings in a specification'
            Usage = @('winspec actions [spec] [options]')
            Selection = @('Use Actions from the explicit/default spec. List names, providers, origins and declared operations, not With payloads.',
                'Default specification, where required: %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json.',
                'Both present is an error; no parent-directory search. An explicit path avoids default selection.')
            Effects = @('Reads/validates static configuration. Does not run or preview Actions. An empty Action map is a successful empty result.')
            Examples = @('winspec actions .\machine.json')
            Exit = @('0: listed, including empty. 2: spec/catalog admission failed.')
            Group = 'Inspect'
            Inventory = 'List named Actions in a specification; nothing is run.'
            DisplayOrder = '1'
        }
    }
    rollback = @{
        MinOperands = 0
        MaxOperands = 0
        Options = @('-last', '-sequencenumber', '-dryrun', '-json')
        Purpose = 'Preview or request one explicit Windows restore operation.'
        Usage = @('winspec rollback (-Last|-SequenceNumber n) [-DryRun]')
        Effects = 'May request Windows System Restore; WinSpec never elevates implicitly.'
        Default = 'Requires exactly one restore target.'
        Example = 'winspec rollback -Last -DryRun'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'request one Windows System Restore operation'
            Usage = @('winspec rollback (-Last|-SequenceNumber <positive-int>) [options]')
            Selection = @('Choose exactly one of -Last or a positive -SequenceNumber. -Last resolves the latest available restore point during actual execution.')
            Effects = @('May request system recovery with the caller''s existing privileges. DryRun does not resolve/prove the target. Not an undo mechanism for arbitrary Actions; accepted request does not mean recovery has completed.')
            Examples = @('winspec rollback -Last -DryRun',
                'winspec rollback -SequenceNumber 42 -DryRun')
            Exit = @('0: planned or request accepted. 2: invalid selector. 3: restore request failed.')
            Group = 'Recovery'
            Inventory = 'Request Windows System Restore; not an Action undo.'
            DisplayOrder = '10'
        }
    }
    help = @{
        MinOperands = 0
        MaxOperands = 1
        Options = @('-json')
        Purpose = 'Show the command inventory or detailed help for one command.'
        Usage = @('winspec help [command]', 'winspec <command> -Help')
        Effects = 'Writes documentation to stdout without loading a spec or provider catalog.'
        Default = 'Shows the complete command inventory.'
        Example = 'winspec help run'
        # Human prose is presentation-only; legacy Help JSON fields above stay unchanged.
        Human = @{
            Summary = 'explain the public command contract without loading configuration'
            Usage = @('winspec help [command] [-Json]',
                'winspec <command> -Help [-Json]')
            Selection = @('No topic shows the command inventory; one topic shows that command. <command> -Help selects the same page.')
            Effects = @('Reads no spec/catalog and starts no provider. Json returns the static help document, not runtime readiness.')
            Examples = @('winspec help run')
            Exit = @('0: shown. 2: unknown/retired topic or invalid help invocation.')
            Group = 'Help'
            Inventory = 'Show this page or help for one command.'
            DisplayOrder = '11'
        }
    }
}

$Script:Commands = @($Script:CommandHelp.Keys)
$raw = @($args)
# Error output selection obeys the same -- boundary as ordinary parsing.
# A known option cannot be consumed as another option's string value.
foreach ($token in $raw) {
    if ([string]$token -eq '--') { break }
    if ([string]$token -ieq '-Json') { $Json = $true }
}
$specified = New-Object 'Collections.Generic.HashSet[string]' (
    [StringComparer]::OrdinalIgnoreCase)
$positionals = @()
$separator = $false

try {
    $index = 0
    while ($index -lt $raw.Count) {
        $token = [string]$raw[$index]
        if ($token -eq '--') {
            $separator = $true
            if ($index + 1 -lt $raw.Count) {
                $RemainingArguments = @($raw[($index + 1)..($raw.Count - 1)])
            }
            break
        }
        if (-not $token.StartsWith('-')) {
            if ([string]::IsNullOrWhiteSpace($token)) {
                throw 'InvalidOperand: operands cannot be empty'
            }
            $positionals += $token
            if ($positionals.Count -eq 1) {
                $Command = $token.ToLowerInvariant()
            }
            $index++
            continue
        }
        $option = $token.ToLowerInvariant()
        if ($option -in $Script:RetiredOptions) {
            throw "RetiredOption: '$token' was removed; use command help for supported options"
        }
        if (-not $Script:Options.Contains($option)) {
            throw "UnknownOption: '$token'. Run 'winspec help $Command'."
        }
        $definition = $Script:Options[$option]
        if (-not $specified.Add($option) -and $definition.Type -ne 'List') {
            throw "DuplicateOption: '$token' may be supplied only once"
        }
        if ($definition.Type -eq 'Switch') {
            Set-Variable -Name $definition.Variable -Value $true
            $index++
            continue
        }
        if ($index + 1 -ge $raw.Count) {
            throw "MissingOptionValue: '$token'"
        }
        $value = [string]$raw[$index + 1]
        $nextOption = $value.ToLowerInvariant()
        if ($value -eq '--' -or $Script:Options.Contains($nextOption) -or
            $nextOption -in $Script:RetiredOptions) {
            throw "MissingOptionValue: '$token'"
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "InvalidOptionValue: '$token' cannot be empty"
        }
        if ($definition.Type -eq 'Integer') {
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number)) {
                throw "InvalidOptionValue: '$token' requires an integer"
            }
            Set-Variable -Name $definition.Variable -Value $number
        }
        elseif ($definition.Type -eq 'List') {
            $items = @()
            $current = Get-Variable -Name $definition.Variable -ValueOnly
            foreach ($existing in $current) { $items += [string]$existing }
            foreach ($part in @($value -split ',')) {
                $item = $part.Trim()
                if (-not $item) {
                    throw "InvalidOptionValue: '$token' contains an empty item"
                }
                if ($item -notin $items) { $items += $item }
            }
            Set-Variable -Name $definition.Variable -Value @($items)
        }
        else {
            Set-Variable -Name $definition.Variable -Value $value
        }
        $index += 2
    }
    if ($Command -eq 'sandbox') {
        throw $Script:RetiredSandboxMessage
    }
    if (-not $Script:CommandHelp.Contains($Command)) {
        throw "UnknownCommand: '$Command'. Run 'winspec help'."
    }
    if ($positionals.Count -gt 1) { $Target = $positionals[1] }
    if ($positionals.Count -gt 2) { $Second = $positionals[2] }
    $operandCount = [Math]::Max(0, $positionals.Count - 1)
    if ($Help) {
        if ($operandCount -gt 0 -or $separator) {
            throw "UnexpectedOperand: use 'winspec $Command -Help' without operands"
        }
        foreach ($option in $specified) {
            if ($option -notin @('-help', '-json')) {
                throw "InvalidOption: '$option' cannot be combined with -Help"
            }
        }
    }
    else {
        $commandDefinition = $Script:CommandHelp[$Command]
        foreach ($option in $specified) {
            if ($option -notin $commandDefinition.Options) {
                throw "InvalidOption: '$option' is not valid for '$Command'"
            }
        }
        $maximum = $commandDefinition.MaxOperands
        $minimum = $commandDefinition.MinOperands
        if ($Command -eq 'run' -and $specified.Contains('-provider')) {
            $minimum = 0
            $maximum = 0
            if ($operandCount -gt 0) {
                throw 'InvalidSelection: direct provider execution cannot use a target'
            }
        }
        if ($operandCount -gt $maximum) {
            throw "UnexpectedOperand: '$($positionals[$maximum + 1])'"
        }
        if ($operandCount -lt $minimum) {
            $code = switch ($Command) {
                'run' { 'MissingAction' }
                'workflow' { 'MissingWorkflow' }
                default { 'MissingOperand' }
            }
            throw "${code}: '$Command' requires $minimum operand(s)"
        }
        if ($separator -and $Command -ne 'run') {
            throw "UnexpectedArguments: '$Command' does not accept -- arguments"
        }
        if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 3600) {
            throw 'InvalidTimeout: expected 1..3600'
        }
        if ($Strategy -notin @('auto', 'union', 'ours', 'theirs')) {
            throw "InvalidStrategy: '$Strategy'"
        }
        if ($specified.Contains('-sequencenumber') -and $SequenceNumber -lt 1) {
            throw 'InvalidSequenceNumber: expected a positive integer'
        }
        if ($Command -eq 'rollback' -and
            $specified.Contains('-last') -eq $specified.Contains('-sequencenumber')) {
            throw 'InvalidRollbackTarget: choose exactly one of -Last or -SequenceNumber'
        }
        if ($Command -eq 'validate' -and
            $specified.Contains('-timeoutseconds') -and -not $PreviewActions) {
            throw 'InvalidOption: validate -TimeoutSeconds requires -PreviewActions'
        }
        if ($Provider -and ($SpecPath -or $Interactive -or $Sha256)) {
            throw 'InvalidSelection: direct provider execution cannot use -Spec, -Interactive, or -Sha256'
        }
        if ($Command -eq 'run' -and -not $Provider) {
            $direct = Test-DirectActionTarget $Target
            $uri = $null
            $remote = $direct -and [Uri]::TryCreate(
                $Target, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -in @('http', 'https')
            $RunSelection = if ($direct) { 'Script' } else { 'Named' }
            $RunIsRemote = $remote
            if ($direct -and $SpecPath) {
                throw 'InvalidSelection: -Spec is valid only for a named Action'
            }
            if ($Interactive -and (-not $direct -or $remote)) {
                throw 'InvalidSelection: -Interactive is for a direct local Script; named Scripts declare With.Interactive'
            }
            if ($Sha256 -and -not $remote) {
                throw 'InvalidOption: -Sha256 is valid only for a direct remote Script; named Actions store it in With'
            }
        }
        elseif ($Command -eq 'run') {
            $RunSelection = 'Provider'
        }
        if ($Sha256 -and $Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'InvalidSha256: expected 64 hexadecimal characters'
        }
        if ($Interactive -and ($Json -or $DryRun)) {
            throw 'InteractiveOutputConflict: -Interactive cannot be combined with -Json or -DryRun'
        }
    }
}
catch {
    Write-AdmissionFailure $_.Exception.Message
    exit 2
}

function Format-HelpParagraph {
    param([string]$Text, [string]$FirstPrefix = '  ', [string]$ContinuationPrefix = '  ')
    $line = $FirstPrefix
    foreach ($word in @($Text -split ' ')) {
        if ($line.Length + $word.Length -gt 100 -and $line.Length -gt $FirstPrefix.Length) {
            $line.TrimEnd()
            $line = $ContinuationPrefix
        }
        $line += $word + ' '
    }
    $line.TrimEnd()
}

function Show-Help {
    param([string]$Topic)
    if ($Topic -ieq 'sandbox') { throw $Script:RetiredSandboxMessage }
    if ($Topic -and -not $Script:CommandHelp.Contains($Topic)) {
        throw "UnknownCommand: '$Topic'"
    }
    if ($Json) {
        $item = if ($Topic) { $Script:CommandHelp[$Topic] } else { $Script:CommandHelp.help }
        $optionNames = @($item.Options) + @('-help')
        $optionItems = @($optionNames | ForEach-Object {
                $definition = $Script:Options[$_]
                [ordered]@{
                    name = $_
                    valueType = $definition.Type
                    repeatable = $definition.Type -eq 'List'
                }
            })
        $helpResult = [ordered]@{
            topic = $Topic
            summary = $item.Purpose
            usage = @($item.Usage)
            options = @($optionItems)
            defaults = @{ selection = $item.Default }
            effects = $item.Effects
            examples = @($item.Example)
            related = @('docs/api.md', 'docs/usage.md')
        }
        if (-not $Topic) {
            $helpResult['commands'] = @($Script:Commands | ForEach-Object {
                    [ordered]@{ name = $_; summary = $Script:CommandHelp[$_].Purpose }
                })
        }
        New-CommandResult 'Succeeded' @{ help = $helpResult } |
            ConvertTo-Json -Depth 16 -Compress
        return
    }

    $lines = New-Object 'Collections.Generic.List[string]'
    if (-not $Topic) {
        $lines.Add('WinSpec -- inspect State, apply changes, and run explicit Actions.')
        foreach ($group in @('Inspect', 'Change', 'Files', 'Recovery', 'Help')) {
            $lines.Add('')
            $lines.Add($group)
            foreach ($name in @($Script:Commands | Sort-Object { [int]$Script:CommandHelp[$_].Human.DisplayOrder })) {
                $human = $Script:CommandHelp[$name].Human
                if ($human.Group -eq $group) {
                    $lines.Add(('  {0} {1}' -f $name.PadRight(10), $human.Inventory))
                }
            }
        }
        $lines.Add('')
        $lines.Add('Start safely')
        $lines.Add('  winspec validate <spec>')
        $lines.Add('  winspec diff <spec>')
        $lines.Add('  winspec apply <spec> -DryRun')
        $lines.Add('')
        $lines.Add('Default specification, where required:')
        $lines.Add('  %USERPROFILE%\.config\winspec\.winspec.psd1 or .winspec.json')
        $lines.Add('  Both present is an error. status without a spec observes core State.')
        $lines.Add('')
        $lines.Add('More: winspec help <command> or winspec <command> -Help')
    }
    else {
        $item = $Script:CommandHelp[$Topic]
        $human = $item.Human
        $lines.Add("WinSpec $Topic -- $($human.Summary)")
        foreach ($section in @('Usage', 'Selection', 'Options', 'Effects and limits', 'Arguments', 'Examples', 'Exit')) {
            if ($section -eq 'Arguments' -and $Topic -ne 'run') { continue }
            $lines.Add('')
            $lines.Add($section)
            if ($section -eq 'Options') {
                foreach ($name in @($item.Options) + @('-help')) {
                    $option = $Script:Options[$name]
                    $description = $option.Description
                    if ($option.ContainsKey('Default')) { $description = $description -f $option.Default }
                    if ($name -eq '-timeoutseconds' -and $Topic -eq 'validate') {
                        $description += ' Requires PreviewActions.'
                    }
                    $prefix = '  ' + $option.Display.PadRight(28) + ' '
                    foreach ($line in @(Format-HelpParagraph $description $prefix (' ' * $prefix.Length))) {
                        $lines.Add($line)
                    }
                }
                $lines.Add('  All other options may occur only once; only list options are repeatable.')
                $lines.Add('  Options/commands are case-insensitive. [options] means only the options above.')
            }
            elseif ($section -eq 'Arguments') {
                $lines.Add('  -- ends WinSpec parsing. Everything after it is one literal argument per token.')
                $lines.Add('  Named Script arguments from the CLI are appended after With.Args.')
                $lines.Add('  -Provider selects one Action provider; -Providers belongs to State commands.')
            }
            else {
                $key = if ($section -eq 'Effects and limits') { 'Effects' } else { $section }
                foreach ($paragraph in $human[$key]) {
                    if ($section -in @('Examples', 'Usage')) { $lines.Add("  $paragraph") }
                    else {
                        foreach ($line in @(Format-HelpParagraph $paragraph)) { $lines.Add($line) }
                    }
                }
                if ($section -eq 'Exit' -and $Topic -in @('capture', 'apply', 'run', 'workflow', 'merge', 'rollback')) {
                    foreach ($line in @(Format-HelpParagraph 'Unclassified command-boundary errors can exit 2; an exit code alone does not prove no effects.')) {
                        $lines.Add($line)
                    }
                }
            }
        }
    }
    $lines.Add('')
    $lines.Add('See: ' + [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../docs/usage.md')))
    $lines.Add('     ' + [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../docs/api.md')))
    $lines -join [Environment]::NewLine
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
        Write-AdmissionFailure $_.Exception.Message
        exit 2
    }
}

$root = $PSScriptRoot
Import-Module (Join-Path $root 'spec.psm1') -Force
Import-Module (Join-Path $root 'schema.psm1') -Force
Import-Module (Join-Path $root 'provider-runtime.psm1') -Force

function Write-CommandResult {
    param($Result)
    if ($Json) {
        $Result | ConvertTo-Json -Depth 64 -Compress
    }
    else {
        Write-WinSpecHumanResult $Result $humanContext -ExitCode $exitCode
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

# This side channel contains identities already resolved for this invocation,
# never additional machine-result fields or new observations.
$humanContext = @{
    Target = $Target; RunSelection = $RunSelection; TimeoutSeconds = $TimeoutSeconds
    ExplicitProviders = ($Providers.Count -gt 0); Force = $Force; Checkpoint = $Checkpoint
}
if (-not $Json) { Import-Module (Join-Path $root 'console.psm1') -Force }
$humanProgress = $null
if (-not $Json -and -not [Console]::IsOutputRedirected -and -not [Console]::IsErrorRedirected) {
    $humanProgress = {
        param($Activity, $Elapsed, $Budget)
        $identity = $Command
        if ($Target -and $RunSelection -ne 'Script') { $identity += " $Target" }
        Write-WinSpecHumanWait -Identity $identity -Activity $Activity -Elapsed $Elapsed -Budget $Budget
    }
}
$exitCode = 0
try {
    $catalog = Get-ProviderCatalog -ProviderPath $ProviderPath
    switch ($Command) {
        'providers' {
            $items = @($catalog | Select-Object Name, Kind, ProtocolVersion,
                Operations, EntryPointType, Origin)
            $result = New-CommandResult 'Succeeded' @{ providers = $items }
        }
        'actions' {
            $document = Get-SpecDocument -Path $Target
            $humanContext.Spec = $document.Path
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
            $humanContext.NextAction = @($items | Where-Object {
                    -not $_.name.StartsWith('-') -and -not (Test-DirectActionTarget $_.name)
                } | Select-Object -Last 1).name
            $result = New-CommandResult 'Succeeded' @{ actions = @($items) }
        }
        'validate' {
            $path = if ($Target) { $Target } else { $SpecPath }
            $document = Get-SpecDocument -Path $path
            $humanContext.Spec = $document.Path
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
                            -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
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
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
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
                $document = Get-SpecDocument $path
                $spec = $document.Spec
                $humanContext.Spec = $document.Path
                $null = Assert-Specification $spec $catalog
                $state = Get-WinSpecObservedState -Catalog $catalog `
                    -Spec $spec -Providers $Providers `
                    -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
            }
            else {
                $state = Get-WinSpecObservedState -Catalog $catalog `
                    -Providers $Providers -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
            }
            $result = New-CommandResult 'Succeeded' @{ state = $state }
        }
        'diff' {
            Import-Module (Join-Path $root 'state.psm1') -Force
            $path = if ($Target) { $Target } else { $SpecPath }
            $document = Get-SpecDocument $path
            $spec = $document.Spec
            $humanContext.Spec = $document.Path
            $null = Assert-Specification $spec $catalog
            $againstValue = if ($Against) {
                $againstDocument = Get-SpecDocument $Against
                $humanContext.Against = $againstDocument.Path
                $againstDocument.Spec
            } else { $null }
            $comparison = Compare-WinSpecState -Spec $spec -Catalog $catalog `
                -Against $againstValue -Providers $Providers `
                -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
            $result = New-CommandResult $comparison.Status $comparison
            if ($comparison.Status -eq 'Different') { $exitCode = 1 }
        }
        'apply' {
            Import-Module (Join-Path $root 'state.psm1') -Force
            $path = if ($Target) { $Target } else { $SpecPath }
            $document = Get-SpecDocument $path
            $spec = $document.Spec
            $humanContext.Spec = $document.Path
            $null = Assert-Specification $spec $catalog
            $comparison = Compare-WinSpecState -Spec $spec -Catalog $catalog `
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
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
                -Providers $Providers -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
            if ($applied.Status -eq 'Failed') { $exitCode = 3 }
            $result = New-CommandResult $applied.Status @{
                comparison = $comparison
                checkpoint = $checkpointValue
                providers = $applied.Providers
            }
        }
        'run' {

            Import-Module (Join-Path $root 'actions.psm1') -Force
            $forwarded = @($RemainingArguments)
            if ($RunSelection -eq 'Provider') {
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
                $humanContext.ActionProvider = $selected.Name
                $action = @{ Use = $selected.Name; With = @{} }
                $runValue = Invoke-WinSpecAction -Action $action `
                    -Provider $selected -BasePath ([IO.Path]::GetFullPath($PWD)) `
                    -Arguments $forwarded -DryRun:$DryRun `
                    -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
                if ($runValue.Status -eq 'Failed') { $exitCode = 3 }
                $result = New-CommandResult $runValue.Status @{
                    actions = @([pscustomobject][ordered]@{
                            provider = [string]$selected.Name
                            result = $runValue
                        })
                }
            }
            elseif ($RunSelection -eq 'Script') {
                $with = if ($RunIsRemote) {
                    @{ Uri = $Target }
                }
                else {
                    @{ File = $Target }
                }
                $humanContext.ActionProvider = 'Script'
                $humanContext.Source = $Target
                $action = @{ Use = 'Script'; With = $with }
                $provider = @($catalog | Where-Object Name -ieq 'Script')[0]
                $runResult = Invoke-WinSpecAction -Action $action `
                    -Provider $provider -Arguments $forwarded -DryRun:$DryRun `
                    -Interactive:$Interactive -Sha256 $Sha256 `
                    -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
                if ($runResult.Status -eq 'Failed') { $exitCode = 3 }
                $result = New-CommandResult $runResult.Status @{
                    actions = @($runResult)
                }
            }
            else {
                $document = Get-SpecDocument -Path $SpecPath
                $humanContext.Spec = $document.Path
                $spec = $document.Spec
                $null = Assert-Specification $spec $catalog
                if (-not $spec.ContainsKey('Actions') -or
                    -not $spec.Actions.ContainsKey($Target)) {
                    throw "UnknownAction: '$Target'"
                }
                $action = $spec.Actions[$Target]
                $humanContext.ActionName = $Target
                $humanContext.ActionProvider = $action.Use
                if ($action.Use -ieq 'Script') {
                    if ($action.With.Uri) { $humanContext.Source = $action.With.Uri }
                    elseif ($action.With.File) {
                        $humanContext.Source = if ([IO.Path]::IsPathRooted($action.With.File)) {
                            [IO.Path]::GetFullPath($action.With.File)
                        } else { [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($document.Path)) $action.With.File)) }
                    }
                }
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
                    -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
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

            $document = Get-SpecDocument -Path $SpecPath
            $humanContext.Spec = $document.Path
            $null = Assert-Specification $document.Spec $catalog
            if ($document.Spec.Workflows -and $document.Spec.Workflows.ContainsKey($Target)) {
                $humanContext.Steps = @($document.Spec.Workflows[$Target].Steps | ForEach-Object {
                        $step = $_
                        $kind = [string]@($_.Keys)[0]
                        $identity = switch ($kind) {
                            'Run' { [string]$step.Run }
                            'Apply' { @($step.Apply.Providers) -join ', ' }
                            'Capture' { [string]$step.Capture.Output }
                        }
                        [pscustomobject]@{ Identity = $identity }
                    })
            }
            Import-Module (Join-Path $root 'workflow.psm1') -Force
            $workflowValue = Invoke-WinSpecWorkflow -Document $document `
                -Name $Target -Catalog $catalog -DryRun:$DryRun `
                -MachineOutput:$Json `
                -TimeoutSeconds $TimeoutSeconds -Progress $humanProgress
            if ($workflowValue.Status -eq 'Failed') { $exitCode = 3 }
            $result = New-CommandResult $workflowValue.Status $workflowValue
        }
        'merge' {

            $baseDocument = Get-SpecDocument $Target
            $incomingDocument = Get-SpecDocument $Second
            $humanContext.Base = $baseDocument.Path
            $humanContext.Incoming = $incomingDocument.Path
            if ($Output) { $humanContext.Output = [IO.Path]::GetFullPath($Output) }
            Import-Module (Join-Path $root 'merge.psm1') -Force
            $merged = Merge-Configuration -Base $baseDocument.Spec `
                -Incoming $incomingDocument.Spec -Output $Output `
                -Strategy $Strategy -Force:$Force
            if (-not $merged.Success) {
                $result = New-CommandResult 'Failed' $merged
                $exitCode = 2
            }
            else {
                $result = New-CommandResult 'Succeeded' $merged
            }
        }
        'rollback' {

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
    foreach ($key in @('ProcessCleanupError', 'TemporaryCleanupError', 'RemoteScriptCleanupError', 'DownloadCleanupError')) {
        if ($_.Exception.Data.Contains($key)) { $humanContext.CleanupFailed = $true }
    }
    $exitCode = Get-CommandFailureExitCode $code
    $diagnostics = @(@{
            severity = 'error'
            code = $code
            message = $message
        })
    foreach ($key in @('ProcessCleanupError', 'TemporaryCleanupError', 'RemoteScriptCleanupError', 'DownloadCleanupError')) {
        if ($_.Exception.Data.Contains($key)) { $diagnostics += @{ severity = 'error'; code = $key; message = [string]$_.Exception.Data[$key] } }
    }
    $result = New-CommandResult 'Failed' @{} $diagnostics
}
Write-CommandResult $result
exit $exitCode
