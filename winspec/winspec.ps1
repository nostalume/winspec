#!/usr/bin/env pwsh
# winspec.ps1 - CLI entry point for WinSpec
# A composable, declarative Windows configuration system

[CmdletBinding(DefaultParameterSetName = "Help")]
param (
    # Subcommand (positional, determines operation)
    [Parameter(Position = 0)]
    [ValidateSet("pull", "push", "diff", "merge", "status", "rollback", "providers", "validate", "trigger", "sandbox", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    $Triggers,

    # Common parameters (available with any command)
    [Parameter()]
    [string]$Spec,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$Output,

    [Parameter()]
    [string[]]$Providers,

    [Parameter()]
    [switch]$Help,                       # Show help for the selected command

    # Push-specific
    [Parameter(ParameterSetName = "Push")]
    [switch]$Checkpoint,

    # Rollback-specific
    [Parameter(ParameterSetName = "Rollback")]
    [int]$SequenceNumber,

    [Parameter(ParameterSetName = "Rollback")]
    [switch]$Last,

    # Diff-specific
    [Parameter(ParameterSetName = "Diff")]
    [string]$Against,

    # Merge-specific
    [Parameter(ParameterSetName = "Merge", Mandatory = $true)]
    [string]$Base,

    [Parameter(ParameterSetName = "Merge", Mandatory = $true)]
    [string]$Incoming,

    [Parameter(ParameterSetName = "Merge")]
    [ValidateSet("auto", "union", "ours", "theirs")]
    [string]$Strategy = "auto",

    # Pull-specific (and also used by Merge)
    [Parameter(ParameterSetName = "Pull")]
    [Parameter(ParameterSetName = "Merge")]
    [switch]$Interactive = $false,

    # Apply flag (can be used with multiple commands)
    [Parameter()]
    [switch]$Apply = $false,

    # Sandbox-specific
    [Parameter(ParameterSetName = "Sandbox")]
    [switch]$Enter = $false,

    [Parameter(ParameterSetName = "Sandbox")]
    [switch]$Exit = $false,

    [Parameter(ParameterSetName = "Sandbox")]
    [switch]$List = $false,

    [Parameter(ParameterSetName = "Sandbox")]
    [ValidateSet("DryRun", "Mock")]
    [string]$Mode = "Mock",

    [Parameter(ParameterSetName = "Sandbox")]
    [string]$Snapshot = "default"
)

$ErrorActionPreference = 'Stop'
$Script:WinspecRoot = $PSScriptRoot
$ExplicitSpec = $PSBoundParameters.ContainsKey('Spec')

$global:VerbosePreference = if ($PSBoundParameters['Verbose']) { 'Continue' } else { 'SilentlyContinue' }
$global:DebugPreference = if ($PSBoundParameters['Debug']) { 'Continue' } else { 'SilentlyContinue' }

# Import core modules first so functions can use them
$modules = @(
    "logging.psm1"
    "utils.psm1"
    "state.psm1"
    "schema.psm1"
    "checkpoint.psm1"
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Script:WinspecRoot $m) -ErrorAction Stop -Force -Scope Local
}

$Script:LoggingModule = Import-Module (Join-Path $Script:WinspecRoot "logging.psm1") -ErrorAction Stop -Force -Scope Local -PassThru
$Script:WriteLogCommand = $Script:LoggingModule.ExportedCommands["Write-Log"]
$Script:WriteLogHeaderCommand = $Script:LoggingModule.ExportedCommands["Write-LogHeader"]
$Script:WriteLogSectionCommand = $Script:LoggingModule.ExportedCommands["Write-LogSection"]
function Write-Log { param([string]$Level, [string]$Message) & $Script:WriteLogCommand -Level $Level -Message $Message }
function Write-LogHeader { param([string]$Title) & $Script:WriteLogHeaderCommand -Title $Title }
function Write-LogSection { param([string]$Name) & $Script:WriteLogSectionCommand -Name $Name }

if ($Command -eq "pull" -and -not $Spec -and $Output) {
    if (Test-Path $Output -PathType Container) {
        $ConfigPath = (Resolve-Path $Output).Path
        $Spec = Join-Path $ConfigPath ".winspec.ps1"
    }
    else {
        $ConfigPath = Split-Path $Output -Parent
        if (-not $ConfigPath) { $ConfigPath = (Get-Location).Path }
        $Spec = $Output
    }
}
else {
    $Spec = Resolve-SpecPath $Spec
    $ConfigPath = Split-Path $Spec -Parent
}

function Show-Help {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Command
    )
    
    # If a specific command is requested, show only that command's help
    if ($Command -and $Command -ne "help") {
        switch ($Command) {
            "trigger" {
                Write-Host @"

WinSpec Trigger - Execute a specific trigger
============================================

USAGE:
    winspec trigger [options]

DESCRIPTION:
    Executes one or more triggers. Triggers are non-idempotent actions
    that run every time they're invoked (e.g., activation, debloating).

OPTIONS:
    -Trigger <input>      Trigger configuration:
                          - Array: @("name1", "name2")
                          - String: "name"
                          - "*": run all discovered triggers
    -Spec <path>          Path to specification file

EXAMPLES:
    # Run all available triggers
    winspec trigger *
    
    # Run multiple triggers with default options (array)
    winspec trigger -Trigger @("activation", "debloat")
    
    # Run single trigger (string)
    winspec trigger "activation"

"@
            }
            "status" {
                Write-Host @"

WinSpec Status - Show current system state
==========================================

USAGE:
    winspec status [options]

DESCRIPTION:
    Displays the current state of the Windows system as seen by
    WinSpec providers.

OPTIONS:
    -Spec <path>          Path to specification file
    -Providers <array>   Array of providers to include (default: all)
    -DryRun              Preview what would be captured

EXAMPLES:
    winspec status
    winspec status -Providers Registry,Feature

"@
            }
            "rollback" {
                Write-Host @"

WinSpec Rollback - Rollback to a checkpoint
============================================

USAGE:
    winspec rollback [options]

DESCRIPTION:
    Restores the system to a previous checkpoint state.

OPTIONS:
    -SequenceNumber <n>   Restore point sequence number
    -Last                 Rollback to most recent WinSpec checkpoint
    -ConfigPath <path>    Path to configuration directory

EXAMPLES:
    # Rollback to last checkpoint
    winspec rollback -Last

    # Rollback to specific checkpoint
    winspec rollback -SequenceNumber 5

"@
            }
            "providers" {
                Write-Host @"

WinSpec Providers - List available providers
==============================================

USAGE:
    winspec providers [options]

DESCRIPTION:
    Lists all available providers:
    - Declarative (idempotent): Registry, Service, Feature
    - Trigger (non-idempotent): Activation, Debloat, Office

OPTIONS:
    -ConfigPath <path>   Path to configuration directory

EXAMPLES:
    winspec providers
    winspec providers -ConfigPath .\config

"@
            }
            "validate" {
                Write-Host @"

WinSpec Validate - Validate a spec without applying
====================================================

USAGE:
    winspec validate -Spec <path> [options]

DESCRIPTION:
    Validates a specification file without applying it.
    Checks PowerShell syntax, field types, and provider schema.

OPTIONS:
    -Spec <path>         Path to specification file (required)
    -ConfigPath <path>   Path to configuration directory

EXAMPLES:
    winspec validate -Spec .\specs\developer.ps1

"@
            }
            "pull" {
                Write-Host @"

WinSpec Pull - Pull system state to configuration file
=====================================================

USAGE:
    winspec pull [options]

DESCRIPTION:
    Pulls (exports) the current system state to a configuration file.
    This is equivalent to 'export' - captures current system state.

OPTIONS:
    -Spec <path>          Path to specification file (for provider hints or merging)
    -Output <path>        Path to write configuration file (else resolve to Spec path)
    -Providers <array>    Array of providers to include (default: all)
    -DryRun              Preview what would be captured
    -Apply               Merge with existing spec if output file already exists
    -Interactive         Interactive item selection

 EXAMPLES:
    # Pull to default file
    winspec pull

    # Pull specific providers
    winspec pull -Providers Registry,Feature

    # Pull to specific output file
    winspec pull -Output config.ps1

    # Pull with interactive selection
    winspec pull -Interactive

    # Pull with dry run
    winspec pull -DryRun

"@
            }
            "push" {
                Write-Host @"

WinSpec Push - Push configuration to system
==========================================

USAGE:
    winspec push -Spec <path> [options]

DESCRIPTION:
    Pushes (applies) a configuration specification to the system.
    This is equivalent to 'apply' - applies config to system.

OPTIONS:
    -Spec <path>          Path to specification file (required)
    -DryRun              Preview changes without applying
    -Checkpoint          Create restore point before applying
    -Providers <array>   Array of providers to apply (default: all)
    -Triggers <input>    Trigger configuration:
                          - Array: @("name1", "name2")
                          - String: "name"
                          - Hashtable: @{ activation = "KMS38"; debloat = @{ Silent = $true } }

EXAMPLES:
    # Push config to system
    winspec push -Spec config.ps1

    # Preview changes
    winspec push -Spec config.ps1 -DryRun

    # Push with restore point
    winspec push -Spec config.ps1 -Checkpoint

    # Push with specific triggers
    winspec push -Spec config.ps1 -Triggers @("activation", "debloat")

"@
            }
            "diff" {
                Write-Host @"

WinSpec Diff - Compare system state with a spec
================================================

USAGE:
    winspec diff -Spec <path> [options]

DESCRIPTION:
    Compares the current system state against a specification file
    and shows the differences.

OPTIONS:
    -Spec <path>          Path to specification file to compare (required)
    -Against <path>       Path to compare against (default: live system)
    -Providers <array>    Array of providers to compare (default: all)

EXAMPLES:
    # Compare spec against live system
    winspec diff -Spec .\specs\developer.ps1

    # Compare two specs
    winspec diff -Spec .\specs\developer.ps1 -Against .\specs\base.ps1

    # Compare specific providers
    winspec diff -Spec .\specs\developer.ps1 -Providers Registry

"@
            }
            "merge" {
                Write-Host @"

WinSpec Merge - Merge two specification files
==============================================

USAGE:
    winspec merge -Base <path> -Incoming <path> [options]

DESCRIPTION:
    Merges two specification files together.

OPTIONS:
    -Base <path>           Path to base configuration file (required)
    -Incoming <path>       Path to incoming configuration file (required)
    -Output <path>         Path to write merged configuration
    -Strategy <strategy>    Merge strategy: auto, union, ours, theirs (default: auto)
    -Interactive           Enable interactive conflict resolution
    -DryRun               Preview merge without writing

EXAMPLES:
    # Auto merge
    winspec merge -Base base.ps1 -Incoming changes.ps1

    # Union merge (keep all keys)
    winspec merge -Base base.ps1 -Incoming changes.ps1 -Strategy union

    # Interactive merge
    winspec merge -Base base.ps1 -Incoming changes.ps1 -Interactive

    # Dry run merge (preview only)
    winspec merge -Base base.ps1 -Incoming changes.ps1 -DryRun

"@
            }
            "sandbox" {
                Write-Host @"

WinSpec Sandbox - Test changes in a sandbox environment
=========================================================

USAGE:
    winspec sandbox [options]

DESCRIPTION:
    Manages sandbox mode for testing changes without affecting
    the live system.

OPTIONS:
    -Enter              Enter sandbox mode
    -Exit               Exit sandbox mode
    -List               List available sandbox snapshots
    -Mode <mode>        Sandbox mode: DryRun or Mock (default: Mock)
    -Snapshot <name>    Sandbox snapshot name (default: default)

EXAMPLES:
    # Show sandbox status
    winspec sandbox

    # Enter sandbox mode
    winspec sandbox -Enter

    # List available snapshots
    winspec sandbox -List

    # Exit sandbox mode
    winspec sandbox -Exit

"@
            }
            default {
                Write-Host "Unknown command: $Command" -ForegroundColor Red
                Write-Host "Run 'winspec help' for available commands."
            }
        }
        return
    }
    
    # Show main help (default)
    Write-Host @"
WinSpec - Windows Specification
A composable, declarative Windows configuration system

USAGE:
    winspec <command> [options]

AVAILABLE COMMANDS:
    pull        Pull system state to a configuration file
    push        Push configuration to the system
    diff        Compare system state with a spec
    merge       Merge two specification files
    status      Show current system state
    rollback    Rollback to a checkpoint
    providers   List available providers
    validate    Validate a spec without applying
    trigger     Execute a trigger
    sandbox     Run in sandbox mode
    help        Show this help message

GLOBAL OPTIONS:
    -Spec           Configuration file path
    -DryRun         Preview changes without applying
    -Output         Output file path
    -Providers      Array of providers to include
    -Apply          Apply changes (for merge operations)
    -Help           Show help for a specific command

EXAMPLES:
    # Git-like workflow
    winspec pull                              # Capture system state
    winspec push -Spec config.ps1            # Apply config to system
    winspec diff -Spec config.ps1            # Compare system vs config
    winspec merge -Base base.ps1 -Incoming changes.ps1

    # Show system state
    winspec status

    # Show help for a specific command
    winspec pull -Help
    winspec push -Help

Run 'winspec <command> -Help' for detailed help on a specific command.
"@
}


# Handle -Help flag before command processing
# This allows "winspec -Help" to show help
if ($Help) {
    Show-Help -Command $Command
    exit 0
}

# Import core modules
# Already imported at the top of the script
function Show-Providers {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )
    
    Write-Debug "Config Path: $ConfigPath"
    Write-LogHeader "Available Providers"
    $categories = @(
        @{ Name = "Declarative (Idempotent):"; Type = "Declarative"; Folder = "managers" }
        @{ Name = "Trigger (Non-Idempotent):"; Type = "Trigger"; Folder = "triggers" }
    )

    foreach ($cat in $categories) {
        Write-Log -Level INFO -Message $cat.Name

        # Built-in providers
        $providers = Get-Providers -Type $cat.Type
        $providers += Get-Providers -Type $cat.Type -BasePath $ConfigPath

        Write-Debug "Providers: $($providers | Out-String)"
        foreach ($provider in $providers) {
            $name = $provider.Name
            $path = $provider.Path
            $info = $null
            try {
                $module = Import-Module $path -PassThru -ErrorAction Stop
                $info = & $module Get-ProviderInfo
            }
            catch {
                Write-Log -Level WARN -Message "Failed to load provider info: $name"
            }

            $description = if ($info.Description) {
                $info.Description
            }
            else {
                "$($cat.Type) provider"
            }

            $isUser = $ConfigPath -and $path.StartsWith($ConfigPath)
            if ($isUser) {
                Write-Log -Level INFO -Message "    $name - $description [User]"
            }
            else {
                Write-Log -Level INFO -Message "    $name - $description"
            }
        }
    }
}

# Main command dispatcher
switch ($Command) {
    "status" {
        if ($Help) {
            Show-Help -Command "status"
            return
        }
        
        Write-Log -Level INFO -Message "Capturing system state..."

        $systemState = Get-SystemState -Providers $Providers
        if (-not $systemState -or $systemState.Count -eq 0) {
            Write-Log -Level WARN -Message "No system state captured"
            return
        }
        Write-Log -Level INFO -Message "Captured providers: $($systemState.Keys -join ', ')"
        if ($Output) {
            if ($PSCmdlet.ShouldProcess($Output, "Save spec")) {
                Save-Configuration `
                    -Config $systemState `
                    -Path $Output
            }
        }
        Write-LogHeader "System Status(JSON)"
        $systemState | ConvertTo-Json -Depth 10
    }
    
    "rollback" {
        if ($Help) {
            Show-Help -Command "rollback"
            return
        }
        
        if (-not $SequenceNumber -and -not $Last) {
            Write-Log -Level "ERROR" -Message "Specify -SequenceNumber or -Last for rollback target"
            exit 1
        }
        
        Invoke-Rollback -SequenceNumber $SequenceNumber -Last:$Last
    }
    
    "providers" {
        if ($Help) {
            Show-Help -Command "providers"
            return
        }
        
        Show-Providers -ConfigPath $ConfigPath
    }
    
    "validate" {
        if ($Help) {
            Show-Help -Command "validate"
            return
        }
        
        $specContent = Get-Spec -Path $Spec
        if (Test-SpecSchema -Spec $specContent) {
            Write-Log -Level OK -Message "Specification is valid"
        }
        else {
            Write-Log -Level ERROR -Message "Specification is invalid"
            exit 1
        }
    }

    "trigger" {
        if ($Help) {
            Show-Help -Command "trigger"
            return
        }
        
        $specContent = Get-Spec -Path $Spec
        $results = Invoke-Triggers `
            -Config $specContent `
            -Triggers $Triggers `
            -ConfigPath $ConfigPath

        $results
    }
    
    
    "pull" {
        if ($Help) {
            Show-Help -Command "pull"
            return
        }
        
        if (($Apply -or $ExplicitSpec) -and (Test-Path ($Spec))) {
            $specContent = Get-Spec $Spec
        }
        else {
            $specContent = @{}
        }
        $pullParams = @{
            Spec    = $specContent
            Apply   = $Apply
        }
        if ($Output) { $pullParams['Output'] = $Output }
        else { $pullParams['Output'] = $Spec }
        if ($Providers) { $pullParams['Providers'] = $Providers }
        if ($Interactive) { $pullParams['Interactive'] = $true }
        if ($DryRun) { $pullParams['DryRun'] = $true }
        if ($Name) { $pullParams['Name'] = $Name }
        if ($Description) { $pullParams['Description'] = $Description }
        if ($ConfigPath) { $pullParams['ConfigPath'] = $ConfigPath }
        
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -ErrorAction Stop -Force -Scope Local
        Invoke-Pull @pullParams
    }
    
    "push" {
        if ($Help) {
            Show-Help -Command "push"
            return
        }
        
        $specContent = Get-Spec $Spec
        if ($null -eq $specContent) {
            Write-Log -Level "ERROR" -Message "The spec is empty"
            exit 1
        }
        $pushParams = @{
            Spec       = $specContent
            ConfigPath = $ConfigPath
        }
        if ($Providers) { $pushParams['Providers'] = $Providers }
        if ($Triggers) { $pushParams['Triggers'] = $Triggers }
        if ($DryRun) { $pushParams['DryRun'] = $true }
        if ($Checkpoint) { $pushParams['Checkpoint'] = $true }
        
        Import-Module (Join-Path $Script:WinspecRoot "push.psm1") -Force -Scope Local
        $result = Invoke-Push @pushParams
        if (-not $result.Success) { exit 1 }
    }
    
    "diff" {
        if ($Help) {
            Show-Help -Command "diff"
            return
        }
        
        $specContent = Get-Spec -Path $Spec
        if ($Against) {
            $againstContent = Get-Spec -Path $Against
        }
        else {
            $againstContent = Get-SystemState -Providers $Providers
        }
        $diffParams = @{
            Spec = $specContent
        }
        if ($Against) { $diffParams['Against'] = $againstContent }
        if ($Providers) { $diffParams['Providers'] = $Providers }
        if ($ConfigPath) { $diffParams['ConfigPath'] = $ConfigPath }
        
        Import-Module (Join-Path $Script:WinspecRoot "diff.psm1") -Force -Scope Local
        Invoke-Diff @diffParams
    }
    
    "merge" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "merge"
            return
        }
        
        if (-not $Base) {
            Write-Log -Level "ERROR" -Message "Base path required: -Base <path>"
            exit 1
        }
        if (-not $Incoming) {
            Write-Log -Level "ERROR" -Message "Incoming path required: -Incoming <path>"
            exit 1
        }
        
        $baseContent = Get-Spec -Path $Base
        $incomingContent = Get-Spec -Path $Incoming
        if ($null -eq $baseContent -or $null -eq $incomingContent) {
            Write-Log -Level "ERROR" -Message "Base and Incoming specs must be valid"
            exit 1
        }

        $mergeParams = @{
            Base        = $baseContent
            Incoming    = $incomingContent
            Strategy    = $Strategy
            Interactive = $Interactive
            DryRun      = $DryRun
        }
        if ($Output) { $mergeParams['Output'] = $Output }
        
        $mergeModule = @(Import-Module (Join-Path $Script:WinspecRoot "merge.psm1") -Force -Scope Local -PassThru)[-1]
        $result = & $mergeModule.ExportedCommands["Merge-Configuration"] @mergeParams
        if ($result) {
            if (-not $result.Success) {
                exit 1
            }
        }
    }
    
    "sandbox" {
        Import-Module (Join-Path $Script:WinspecRoot "sandbox.psm1") -Force -Scope Local

        if ($Enter) {
            Enter-Sandbox -Mode $Mode -Snapshot $Snapshot
            return
        }

        if ($Exit) {
            Exit-Sandbox
            return
        }

        if ($List) {
            $snapshots = Get-SandboxSnapshots
            if ($snapshots.Count -eq 0) {
                Write-Log -Level "WARN" "No snapshots found."
            }
            else {
                Write-Log -Level "INFO" "Available snapshots:"
                $snapshots | ForEach-Object { Write-Host "  - $_" }
            }

            return
        }
        $ctx = Get-SandboxContext
        if ($ctx) {
            Write-Host "Sandbox active"
            Write-Host "Mode:     $($ctx.Mode)"
            Write-Host "Snapshot: $($ctx.Snapshot)"
            Write-Host "Changes:  $($ctx.Changes.Count)"
        }
        else {
            Write-Host "Sandbox not active"
        }
        return
    }
    
    "help" {
        Show-Help
    }
}

