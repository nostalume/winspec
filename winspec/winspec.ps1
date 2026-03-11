#!/usr/bin/env pwsh
# winspec.ps1 - CLI entry point for WinSpec
# A composable, declarative Windows configuration system

[CmdletBinding(DefaultParameterSetName = "Default")]
param (
    [Parameter(Position = 0, ParameterSetName = "Export")]
    [Parameter(Position = 0, ParameterSetName = "Init")]
    [Parameter(Position = 0, ParameterSetName = "Diff")]
    [Parameter(Position = 0, ParameterSetName = "Apply")]
    [Parameter(Position = 0, ParameterSetName = "Merge")]
    [Parameter(Position = 0, ParameterSetName = "Sync")]
    [Parameter(Position = 0, ParameterSetName = "Trigger")]
    [Parameter(Position = 0, ParameterSetName = "Rollback")]
    [Parameter(Position = 0, ParameterSetName = "Sandbox")]
    [Parameter(Position = 0, ParameterSetName = "Default")]
    [ValidateSet("apply", "trigger", "status", "rollback", "providers", "validate", "export", "diff", "merge", "sync", "init", "sandbox", "help", "pull", "push")]
    [string]$Command = "help",
    
    # Spec file path for apply, diff, sync commands
    [Parameter(Mandatory = $false)]
    [string]$Spec,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$DryRun,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$Checkpoint,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$WithTriggers,
    
    # Sandbox parameters
    [Parameter(ParameterSetName = "Apply")]
    [Parameter(ParameterSetName = "Sandbox")]
    [switch]$Sandbox,
    
    [Parameter(ParameterSetName = "Apply")]
    [Parameter(ParameterSetName = "Sandbox")]
    [ValidateSet("DryRun", "Mock")]
    [string]$SandboxMode = "Mock",
    
    [Parameter(ParameterSetName = "Apply")]
    [Parameter(ParameterSetName = "Sandbox")]
    [string]$Profile = "default",
    
    [Parameter(ParameterSetName = "Trigger", Position = 1)]
    [object]$Trigger,
    
    [Parameter(ParameterSetName = "Rollback")]
    [int]$SequenceNumber,
    
    [Parameter(ParameterSetName = "Rollback")]
    [switch]$Last,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,
    
    [Parameter(ParameterSetName = "Export")]
    [ValidateSet("ps1", "json")]
    [string]$Format = "ps1",
    
    # Output path for export and init commands
    [Parameter(Mandatory = $false)]
    [string]$Output,
    
    # Providers to include (for export, init, diff commands)
    [Parameter(Mandatory = $false)]
    [string[]]$Providers,
    
    [Parameter(ParameterSetName = "Diff")]
    [string]$Against,
    
    # Merge command parameters
    [Parameter(ParameterSetName = "Merge", Mandatory = $true)]
    [string]$Base,
    
    [Parameter(ParameterSetName = "Merge", Mandatory = $true)]
    [string]$Incoming,
    
    [Parameter(ParameterSetName = "Merge")]
    [string]$MergeOutput,
    
    [Parameter(ParameterSetName = "Merge")]
    [ValidateSet("auto", "union", "ours", "theirs")]
    [string]$Strategy = "auto",
    
    [Parameter(ParameterSetName = "Merge")]
    [Parameter(ParameterSetName = "Init")]
    [switch]$Interactive,
    
    # Sync command parameters
    [Parameter(ParameterSetName = "Sync")]
    [switch]$SyncInteractive,
    
    # Init command parameters
    [Parameter(ParameterSetName = "Init")]
    [switch]$Template,
    
    [Parameter(ParameterSetName = "Init")]
    [switch]$Minimal,
    
    [Parameter(ParameterSetName = "Init")]
    [string]$Name,
    
    [Parameter(ParameterSetName = "Init")]
    [string]$Description,
    
    # Help parameter for subcommand help
    [Parameter(Mandatory = $false)]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Script:WinspecRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $PSCommandPath -Parent }

# Import core modules first so functions can use them
Import-Module (Join-Path $Script:WinspecRoot "logging.psm1") -Force -Global
Import-Module (Join-Path $Script:WinspecRoot "schema.psm1") -Force -Global
Import-Module (Join-Path $Script:WinspecRoot "checkpoint.psm1") -Force -Global
Import-Module (Join-Path $Script:WinspecRoot "exec.psm1") -Force -Global

function Show-Help {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Command
    )
    
    # If a specific command is requested, show only that command's help
    if ($Command -and $Command -ne "help") {
        switch ($Command) {
            "apply" {
                Write-Host @"

WinSpec Apply - Apply a specification file
============================================

USAGE:
    winspec apply -Spec <path> [options]

DESCRIPTION:
    Applies a specification file to configure the Windows system.
    By default, only declarative providers are executed (idempotent).
    Use -WithTriggers to include non-idempotent trigger execution.

OPTIONS:
    -Spec <path>          Path to specification file (required)
    -DryRun               Preview changes without applying
    -Checkpoint           Create restore point before applying
    -WithTriggers         Include trigger execution
    -Sandbox              Run in sandbox mode
    -SandboxMode <mode>   Sandbox mode: DryRun or Mock (default: Mock)
    -Profile <name>       Sandbox profile name (default: default)
    -ConfigPath <path>     Path to configuration directory

EXAMPLES:
    # Apply a specification (declarative only)
    winspec apply -Spec .\specs\developer.ps1

    # Apply with triggers (runs everything)
    winspec apply -Spec .\specs\developer.ps1 -WithTriggers

    # Dry run (preview changes)
    winspec apply -Spec .\specs\developer.ps1 -DryRun

    # Apply with checkpoint
    winspec apply -Spec .\specs\developer.ps1 -Checkpoint

    # Run in sandbox mode
    winspec apply -Spec .\specs\developer.ps1 -Sandbox -SandboxMode Mock

"@
            }
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
                         - Hashtable: @{ name = options }
                         - Array: @("name1", "name2")
                         - String: "name"
                         - Omit: run all discovered triggers
    -Spec <path>          Path to specification file
    -ConfigPath <path>   Path to configuration directory

EXAMPLES:
    # Run all available triggers
    winspec trigger

    # Run specific triggers with options (hashtable)
    winspec trigger -Trigger @{ activation = "KMS38"; debloat = @{ Silent = $true } }
    
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
    -ConfigPath <path>   Path to configuration directory

EXAMPLES:
    winspec status
    winspec status -ConfigPath .\config

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
    - Declarative (idempotent): Registry, Scoop, Winget, Service, Feature
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
            "export" {
                Write-Host @"

WinSpec Export - Export current system state
=============================================

USAGE:
    winspec export [options]

DESCRIPTION:
    Exports the current system state to a configuration file.

OPTIONS:
    -Output <path>        Path to write exported configuration
    -Providers <array>    Array of providers to export (default: all)
    -Format <format>      Output format: ps1 or json (default: ps1)
    -ConfigPath <path>    Path to configuration directory

EXAMPLES:
    # Export to default file
    winspec export

    # Export specific providers
    winspec export -Providers Registry,Scoop

    # Export as JSON
    winspec export -Format json -Output state.json

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
    -Output <path>        Path to write configuration file
    -Providers <array>    Array of providers to include (default: all)
    -Format <format>      Output format: ps1 or json (default: ps1)
    -ConfigPath <path>   Path to configuration directory
    -DryRun              Preview what would be captured

EXAMPLES:
    # Pull to default file
    winspec pull

    # Pull specific providers
    winspec pull -Providers Registry,Scoop

    # Pull as JSON
    winspec pull -Output state.json -Format json

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
    -WithTriggers        Include triggers in the apply
    -Providers <array>   Array of providers to apply (default: all)
    -ConfigPath <path>   Path to configuration directory

EXAMPLES:
    # Push config to system
    winspec push -Spec config.ps1

    # Preview changes
    winspec push -Spec config.ps1 -DryRun

    # Push with restore point
    winspec push -Spec config.ps1 -Checkpoint

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
    -ConfigPath <path>    Path to configuration directory

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
    -MergeOutput <path>    Path to write merged configuration
    -Strategy <strategy>    Merge strategy: auto, union, ours, theirs (default: auto)
    -Interactive           Enable interactive conflict resolution

EXAMPLES:
    # Auto merge
    winspec merge -Base base.ps1 -Incoming changes.ps1

    # Union merge (keep all keys)
    winspec merge -Base base.ps1 -Incoming changes.ps1 -Strategy union

    # Interactive merge
    winspec merge -Base base.ps1 -Incoming changes.ps1 -Interactive

"@
            }
            "sync" {
                Write-Host @"

WinSpec Sync - Interactive sync between system and config
==========================================================

USAGE:
    winspec sync -Spec <path> [options]

DESCRIPTION:
    Interactive synchronization between the system state and
    a specification file.

OPTIONS:
    -Spec <path>             Path to specification file (required)
    -SyncInteractive        Enable interactive prompts for sync decisions
    -ConfigPath <path>       Path to configuration directory

EXAMPLES:
    winspec sync -Spec .\specs\developer.ps1

    winspec sync -Spec .\specs\developer.ps1 -SyncInteractive

"@
            }
            "init" {
                Write-Host @"

WinSpec Init - Initialize a new configuration
================================================

USAGE:
    winspec init [options]

DESCRIPTION:
    Initializes a new configuration from the current system state.

OPTIONS:
    -Output <path>         Path to write generated configuration
    -Providers <array>     Array of providers to include (default: all)
    -Interactive           Prompt for each item to include
    -Template              Include helpful comments and structure
    -Minimal               Only include non-default settings
    -Name <name>           Configuration name
    -Description <desc>    Configuration description
    -ConfigPath <path>     Path to configuration directory

EXAMPLES:
    # Initialize with defaults
    winspec init

    # Initialize with specific options
    winspec init -Output my-config.ps1 -Template

    # Initialize with interactive selection
    winspec init -Interactive

    # Initialize specific providers
    winspec init -Providers Scoop,Registry

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
    -Sandbox              Enter sandbox mode
    -SandboxMode <mode>   Sandbox mode: DryRun or Mock (default: Mock)
    -Profile <name>       Sandbox profile name (default: default)
    -ConfigPath <path>    Path to configuration directory

EXAMPLES:
    # Show sandbox status
    winspec sandbox

    # Enter sandbox mode
    winspec sandbox -Sandbox -SandboxMode Mock

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

GIT-LIKE COMMANDS (Primary):
    pull        Pull system state to config file (export/init)
    push        Push config to system (apply)
    diff        Compare system state with a spec
    merge       Merge two specification files
    status      Show current system state

LEGACY COMMANDS:
    apply       Apply a specification file
    trigger     Execute a specific trigger
    rollback    Rollback to a checkpoint
    providers   List available providers
    validate    Validate a spec without applying
    export      Export current system state (alias for pull)
    init        Initialize a new configuration (alias for pull)
    sync        Interactive sync between system and config
    sandbox     Test changes in a sandbox environment
    help        Show this help message

GLOBAL OPTIONS:
    -ConfigPath     Path to configuration directory (for user providers/triggers)
    -Help           Show help for a specific command

EXAMPLES:
    # Git-like workflow
    winspec pull                              # Capture system state
    winspec push -Spec config.ps1            # Apply config to system
    winspec diff -Spec config.ps1            # Compare system vs config
    winspec merge -Base base.ps1 -Incoming changes.ps1

    # Show help for a specific command
    winspec pull --help
    winspec push --help
    winspec diff --help

    # Apply a specification
    winspec apply -Spec .\specs\developer.ps1

    # Show current system state
    winspec status

    # Initialize a new configuration
    winspec init

Run 'winspec <command> --help' for detailed help on a specific command.
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
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # Resolve config location if not provided
    $resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Resolve-ConfigLocation }
    
    Write-Host ""
    Write-Host "Available Providers" -ForegroundColor Cyan
    Write-Host "===================" -ForegroundColor Cyan
    
    # Discover declarative providers from managers/
    Write-Host ""
    Write-Host "Declarative (Idempotent):" -ForegroundColor Yellow
    
    # Built-in managers
    $managersPath = Join-Path $Script:WinspecRoot "managers"
    $builtInDeclarative = Get-DiscoveredProviders -Path $managersPath -Type "Declarative"
    foreach ($provider in $builtInDeclarative) {
        Write-Host "  $provider" -ForegroundColor White
    }
    
    # User managers from config
    if ($resolvedConfigPath) {
        $userManagersPath = Join-Path $resolvedConfigPath "managers"
        $userDeclarative = Get-DiscoveredProviders -Path $userManagersPath -Type "Declarative"
        foreach ($provider in $userDeclarative) {
            Write-Host "  $provider [User]" -ForegroundColor Gray
        }
    }
    
    # Discover trigger providers from triggers/
    Write-Host ""
    Write-Host "Trigger (Non-Idempotent):" -ForegroundColor Yellow
    
    # Built-in triggers
    $triggersPath = Join-Path $Script:WinspecRoot "triggers"
    $builtInTriggers = Get-DiscoveredProviders -Path $triggersPath -Type "Trigger"
    foreach ($trigger in $builtInTriggers) {
        Write-Host "  $trigger" -ForegroundColor White
    }
    
    # User triggers from config
    if ($resolvedConfigPath) {
        $userTriggersPath = Join-Path $resolvedConfigPath "triggers"
        $userTriggers = Get-DiscoveredProviders -Path $userTriggersPath -Type "Trigger"
        foreach ($trigger in $userTriggers) {
            Write-Host "  $trigger [User]" -ForegroundColor Gray
        }
    }
    
    Write-Host ""
}

function Invoke-Validate {
    param (
        [string]$SpecPath,
        [string]$ConfigPath
    )
    
    if (-not $SpecPath) {
        Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
        return $false
    }
    
    $config = Import-Spec -Path $SpecPath
    if (-not $config) {
        return $false
    }
    
    $resolved = Resolve-Spec -Config $config -BasePath (Split-Path $SpecPath -Parent)
    
    # Resolve config location for validation context
    $configLocation = Resolve-ConfigLocation -ConfigPath $ConfigPath
    if ($configLocation) {
        Write-Log -Level "INFO" -Message "Using configuration location: $configLocation"
    }
    
    if (Test-SpecSchema -Config $resolved) {
        Write-Log -Level "OK" -Message "Specification is valid"
        Write-Host ""
        Write-Host "Resolved configuration:" -ForegroundColor Cyan
        $resolved | ConvertTo-Json -Depth 5
        return $true
    }
    
    return $false
}

function Invoke-TriggerCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object]$Trigger,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [string]$SpecPath
    )
    
    # Resolve config location if not provided
    $resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Resolve-ConfigLocation }
    
    # Build trigger config array based on input type
    $triggerConfig = @()
    
    if ($Trigger -is [hashtable]) {
        # Hashtable: keys are trigger names, values are options
        foreach ($triggerName in $Trigger.Keys) {
            $triggerConfig += @{
                Name = $triggerName
                Value = $Trigger[$triggerName]
            }
        }
    }
    elseif ($Trigger -is [array]) {
        # Array: list of trigger names with default option
        foreach ($triggerName in $Trigger) {
            $triggerConfig += @{
                Name = $triggerName
                Value = $true
            }
        }
    }
    elseif ($Trigger -is [string]) {
        # String: single trigger name with default option
        $triggerConfig += @{
            Name = $Trigger
            Value = $true
        }
    }
    elseif ($null -eq $Trigger) {
        # No input: discover and run all available triggers
        $allTriggers = Get-AllTriggers -ConfigPath $resolvedConfigPath
        
        if ($allTriggers.Count -eq 0) {
            Write-Log -Level "ERROR" -Message "No triggers found"
            return
        }
        
        Write-Log -Level "INFO" -Message "Running all available triggers: $($allTriggers -join ', ')"
        
        foreach ($triggerName in $allTriggers) {
            $triggerConfig += @{
                Name = $triggerName
                Value = $true
            }
        }
    }
    else {
        Write-Log -Level "ERROR" -Message "Invalid trigger input type: $($Trigger.GetType().Name). Expected hashtable, array, string, or null."
        return
    }
    
    if ($triggerConfig.Count -eq 0) {
        Write-Log -Level "ERROR" -Message "No triggers to execute"
        return
    }
    
    $results = Invoke-Triggers -TriggerConfig $triggerConfig -SpecPath $SpecPath -ConfigPath $resolvedConfigPath
    Write-Report -Results $results
}

# Main command dispatcher
switch ($Command) {
    "apply" {
        # Check if help is requested via -Help flag
        if ($Help) {
            Show-Help -Command "apply"
            return
        }
        
        # Auto-resolve spec path if not provided
        if (-not $Spec) {
            $resolvedSpec = Resolve-SpecPath -ConfigPath $ConfigPath
            if ($resolvedSpec) {
                $Spec = $resolvedSpec
                Write-Log -Level "INFO" -Message "Using auto-resolved spec: $Spec"
            } else {
                Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path> (or set WINSPEC_SPEC env var, or place default.ps1/config.ps1 in config directory)"
                exit 1
            }
        }
        
        # Handle sandbox mode
        $sandboxMode = "Live"
        if ($Sandbox) {
            $sandboxMode = $SandboxMode
        }
        elseif ($DryRun) {
            $sandboxMode = "DryRun"
        }
        
        # Enter sandbox if needed
        if ($sandboxMode -ne "Live") {
            Import-Module (Join-Path $Script:WinspecRoot "sandbox.psm1") -Force
            Enter-Sandbox -Mode $sandboxMode -Profile $Profile
            Write-Log -Level "INFO" -Message "=== SANDBOX MODE: $sandboxMode ==="
            if ($sandboxMode -eq "Mock") {
                Write-Log -Level "INFO" -Message "Using sandbox profile: $Profile"
            }
        }
        
        $result = Invoke-WinSpec -Spec $Spec -ConfigPath $ConfigPath -DryRun:$DryRun -Checkpoint:$Checkpoint -WithTriggers:$WithTriggers -SandboxMode:$Sandbox -SandboxProfile $Profile
        
        if (-not $result.Success) {
            exit 1
        }
        
        # Exit sandbox if entered
        if ($sandboxMode -ne "Live") {
            $changes = Get-SandboxChanges
            if ($changes.Count -gt 0) {
                Write-Host ""
                Write-Host "=== Sandbox Changes Summary ==="
                foreach ($change in $changes) {
                    Write-Host "$($change.Provider): $($change.Details.Status)"
                }
            }
            Exit-Sandbox -DiscardChanges:($sandboxMode -eq "DryRun")
        }
    }
    
    "trigger" {
        # Check if help is requested via -Help flag
        if ($Help) {
            Show-Help -Command "trigger"
            return
        }
        
        Invoke-TriggerCommand -Trigger $Trigger -ConfigPath $ConfigPath -SpecPath $null
    }
    
    "status" {
        if ($Help) {
            Show-Help -Command "status"
            return
        }
        
        Get-SystemStatus
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
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "validate"
            return
        }
        
        # Auto-resolve spec path if not provided
        if (-not $Spec) {
            $resolvedSpec = Resolve-SpecPath -ConfigPath $ConfigPath
            if ($resolvedSpec) {
                $Spec = $resolvedSpec
                Write-Log -Level "INFO" -Message "Using auto-resolved spec: $Spec"
            } else {
                Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
                exit 1
            }
        }
        
        $valid = Invoke-Validate -SpecPath $Spec -ConfigPath $ConfigPath
        if (-not $valid) { exit 1 }
    }
    
    "export" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "export"
            return
        }
        
        # export is now an alias for pull - delegate to pull
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -Force
        $pullParams = @{
            Format = $Format
        }
        if ($Output) { $pullParams['Output'] = $Output }
        if ($Providers) { $pullParams['Providers'] = $Providers }
        if ($Interactive) { $pullParams['Interactive'] = $true }
        if ($Template) { $pullParams['Template'] = $true }
        if ($Minimal) { $pullParams['Minimal'] = $true }
        if ($Name) { $pullParams['Name'] = $Name }
        if ($Description) { $pullParams['Description'] = $Description }
        
        Invoke-Pull @pullParams
    }
    
    "pull" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "pull"
            return
        }
        
        # pull - captures system state to file
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -Force
        $pullParams = @{
            Format = $Format
        }
        if ($Output) { $pullParams['Output'] = $Output }
        if ($Providers) { $pullParams['Providers'] = $Providers }
        if ($Interactive) { $pullParams['Interactive'] = $true }
        if ($Template) { $pullParams['Template'] = $true }
        if ($Minimal) { $pullParams['Minimal'] = $true }
        if ($DryRun) { $pullParams['DryRun'] = $true }
        if ($Name) { $pullParams['Name'] = $Name }
        if ($Description) { $pullParams['Description'] = $Description }
        
        Invoke-Pull @pullParams
    }
    
    "push" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "push"
            return
        }
        
        # push - applies config to system
        Import-Module (Join-Path $Script:WinspecRoot "push.psm1") -Force
        $pushParams = @{
            Spec = $Spec
        }
        if ($ConfigPath) { $pushParams['ConfigPath'] = $ConfigPath }
        if ($DryRun) { $pushParams['DryRun'] = $true }
        if ($Checkpoint) { $pushParams['Checkpoint'] = $true }
        if ($WithTriggers) { $pushParams['WithTriggers'] = $true }
        if ($Providers) { $pushParams['Providers'] = $Providers }
        
        $result = Invoke-Push @pushParams
        if (-not $result.Success) { exit 1 }
    }
    
    "diff" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "diff"
            return
        }
        
        # Auto-resolve spec path if not provided
        if (-not $Spec) {
            $resolvedSpec = Resolve-SpecPath -ConfigPath $ConfigPath
            if ($resolvedSpec) {
                $Spec = $resolvedSpec
                Write-Log -Level "INFO" -Message "Using auto-resolved spec: $Spec"
            } else {
                Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
                exit 1
            }
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "diff.psm1") -Force
        $diffParams = @{
            SpecPath = $Spec
        }
        if ($Against) { $diffParams['Against'] = $Against }
        if ($Providers) { $diffParams['Providers'] = $Providers }
        
        $differences = Compare-SystemState @diffParams
        if ($differences) {
            Write-Host (Format-DiffOutput -Differences $differences)
        }
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
        
        Import-Module (Join-Path $Script:WinspecRoot "merge.psm1") -Force
        $mergeParams = @{
            BasePath = $Base
            IncomingPath = $Incoming
            Strategy = $Strategy
            Interactive = $Interactive
        }
        if ($MergeOutput) { $mergeParams['OutputPath'] = $MergeOutput }
        
        $result = Merge-Configuration @mergeParams
        if ($result) {
            Write-Host (Format-MergeReport -MergeResult $result)
            if (-not $result.Success) {
                exit 1
            }
        }
    }
    
    "sync" {
        # Check if help is requested
        if ($Help) {
            Show-Help -Command "sync"
            return
        }
        
        # Auto-resolve spec path if not provided
        if (-not $Spec) {
            $resolvedSpec = Resolve-SpecPath -ConfigPath $ConfigPath
            if ($resolvedSpec) {
                $Spec = $resolvedSpec
                Write-Log -Level "INFO" -Message "Using auto-resolved spec: $Spec"
            } else {
                Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
                exit 1
            }
        }
        
        # sync uses pull + push workflow - first pull system state, then push changes
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -Force
        Import-Module (Join-Path $Script:WinspecRoot "push.psm1") -Force
        
        # Get system state
        $systemState = Get-SystemState
        
        # Load config spec
        $configSpec = Import-Configuration -Path $Spec
        
        # Compare
        $differences = Compare-SystemState -SpecPath $Spec -Against $null -Providers $Providers
        
        if ($differences.Count -eq 0) {
            Write-Log -Level "OK" -Message "System is already in sync with configuration"
            return
        }
        
        Write-Log -Level "INFO" -Message "Found $($differences.Count) differences to resolve"
        
        if ($SyncInteractive) {
            # Interactive mode - prompt for each difference
            foreach ($diff in $differences) {
                Write-Host ""
                switch ($diff.Type) {
                    "Added" {
                        Write-Host "Item in config, not in system: $($diff.Path)" -ForegroundColor Yellow
                    }
                    "Removed" {
                        Write-Host "Item in system, not in config: $($diff.Path)" -ForegroundColor Yellow
                    }
                    "Changed" {
                        Write-Host "Value mismatch: $($diff.Path)" -ForegroundColor Yellow
                    }
                }
                
                $choice = Read-Host "Resolve? [A]pply to system, [S]kip (or Enter for apply)"
                if ($choice -eq "s" -or $choice -eq "skip") {
                    continue
                }
                # Default: apply to system (push)
                $null = Invoke-Push -Spec $Spec -Providers $Providers
            }
        }
        else {
            # Non-interactive: show differences and prompt to push
            Write-Host "Run 'winspec push -Spec $Spec' to apply changes" -ForegroundColor Cyan
        }
    }
    
    "init" {
        # init is now an alias for pull
        if ($Help) {
            Show-Help -Command "init"
            return
        }
        
        # Delegate to pull (same functionality as init)
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -Force
        $pullParams = @{
            Format = $Format
        }
        if ($Output) { $pullParams['Output'] = $Output }
        if ($Providers) { $pullParams['Providers'] = $Providers }
        if ($Interactive) { $pullParams['Interactive'] = $true }
        if ($Template) { $pullParams['Template'] = $true }
        if ($Minimal) { $pullParams['Minimal'] = $true }
        if ($Name) { $pullParams['Name'] = $Name }
        if ($Description) { $pullParams['Description'] = $Description }
        if ($DryRun) { $pullParams['DryRun'] = $true }
        
        Invoke-Pull @pullParams
    }
    
    "sandbox" {
        
        # Resolve output path using config location resolution
        if ($Output) {
            $initParams['OutputPath'] = $Output
        }
        else {
            # Use WinSpec config location resolution:
            # 1. ConfigPath argument, 2. WINSPEC_CONFIG env, 3. ~/.config/winspec/, 4. current directory
            $configLocation = Resolve-ConfigLocation -ConfigPath $ConfigPath
            
            # Determine the config directory
            $configDir = $null
            if ($configLocation) {
                if (Test-Path $configLocation) {
                    $item = Get-Item $configLocation
                    if ($item -is [System.IO.FileInfo]) {
                        $configDir = Split-Path -Parent $configLocation
                    }
                    else {
                        $configDir = $configLocation
                    }
                }
                else {
                    if ([System.IO.Path]::HasExtension($configLocation)) {
                        $configDir = Split-Path -Parent $configLocation
                    }
                    else {
                        $configDir = $configLocation
                    }
                }
            }
            
            # Ensure directory exists
            if ($configDir -and -not (Test-Path $configDir)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            }
            
            # Determine default output filename - avoid overwriting the script itself
            $defaultFilename = ".winspec.ps1"
            $scriptDir = $Script:WinspecRoot
            
            if ($configDir) {
                # Check if the target directory is the same as where the script lives
                # to avoid overwriting the script itself
                $resolvedConfigDir = (Resolve-Path $configDir -ErrorAction SilentlyContinue).Path
                $resolvedScriptDir = (Resolve-Path $scriptDir -ErrorAction SilentlyContinue).Path
                
                if ($resolvedConfigDir -and $resolvedScriptDir -and 
                    $resolvedConfigDir.Equals($resolvedScriptDir, [StringComparison]::OrdinalIgnoreCase)) {
                    # We're in the WinSpec installation directory - use user config instead
                    $userConfigDir = Join-Path $env:USERPROFILE ".config\winspec"
                    if (-not (Test-Path $userConfigDir)) {
                        New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
                    }
                    $configDir = $userConfigDir
                    Write-Log -Level "INFO" -Message "Using user config directory: $userConfigDir"
                }
                
                $initParams['OutputPath'] = Join-Path $configDir $defaultFilename
            }
            else {
                $initParams['OutputPath'] = $defaultFilename
            }
        }
        
        if ($Providers) { $initParams['Providers'] = $Providers }
        if ($Interactive) { $initParams['Interactive'] = $true }
        if ($Template) { $initParams['Template'] = $true }
        if ($Minimal) { $initParams['Minimal'] = $true }
        if ($Name) { $initParams['Name'] = $Name }
        if ($Description) { $initParams['Description'] = $Description }
        
        $result = Initialize-WinSpecConfig @initParams
        if (-not $result) {
            exit 1
        }
    }
    
    "sandbox" {
        if ($Help) {
            Show-Help -Command "sandbox"
            return
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "sandbox.psm1") -Force
        
        # If -Sandbox flag is used with apply, this will be handled in apply command
        # This command is for direct sandbox management
        if ($Sandbox) {
            # Enter sandbox mode
            Enter-Sandbox -Mode $SandboxMode -Profile $Profile
            Write-Log -Level "INFO" -Message "Sandbox mode: $SandboxMode (Profile: $Profile)"
        }
        else {
            # Show sandbox status
            if (Test-SandboxActive) {
                $ctx = Get-SandboxContext
                Write-Log -Level "INFO" -Message "Sandbox is active"
                Write-Host "Mode: $($ctx.Mode)"
                Write-Host "Profile: $($ctx.Profile)"
                Write-Host "Changes: $($ctx.Changes.Count)"
            }
            else {
                Write-Log -Level "INFO" -Message "Sandbox is not active"
                
                # List available profiles
                $profiles = Get-SandboxProfiles
                if ($profiles.Count -gt 0) {
                    Write-Host "Available profiles:"
                    foreach ($p in $profiles) {
                        Write-Host "  - $p"
                    }
                }
                else {
                    Write-Host "No sandbox profiles found. Use 'sandbox -Sandbox -Profile <name>' to create one."
                }
            }
        }
    }
    
    "help" {
        Show-Help
    }
}

