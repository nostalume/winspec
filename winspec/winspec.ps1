#!/usr/bin/env pwsh
# winspec.ps1 - CLI entry point for WinSpec
# A composable, declarative Windows configuration system

[CmdletBinding(DefaultParameterSetName = "Default")]
param (
    [Parameter(Position = 0, ParameterSetName = "Diff")]
    [Parameter(Position = 0, ParameterSetName = "Merge")]
    [Parameter(Position = 0, ParameterSetName = "Rollback")]
    [Parameter(Position = 0, ParameterSetName = "Sandbox")]
    [Parameter(Position = 0, ParameterSetName = "Default")]
    [ValidateSet("pull", "push", "diff", "merge", "status", "rollback", "providers", "validate", "trigger", "sandbox", "help")]
    [string]$Command = "help",
    
    [Parameter(Mandatory = $false)]
    [string]$Spec,
    
    [switch]$DryRun,
    
    [Parameter(ParameterSetName = "Push")]
    [switch]$Checkpoint,

    [switch]$NoCache = $False,
    
    # "*", string, array
    [Parameter(ParameterSetName = "Push")]
    [Parameter(ParameterSetName = "Trigger", Position = 1)]
    $Triggers,
    
    [Parameter(ParameterSetName = "Rollback")]
    [int]$SequenceNumber,
    
    [Parameter(ParameterSetName = "Rollback")]
    [switch]$Last,
    
    [Parameter(ParameterSetName = "Export")]
    [ValidateSet("ps1", "json")]
    [string]$Format = "ps1",
    
    [Parameter(Mandatory = $false)]
    [string]$Output,
    
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
    [ValidateSet("auto", "union", "ours", "theirs")]
    [string]$Strategy = "auto",
    
    [Parameter(ParameterSetName = "Merge")]
    [Parameter(ParameterSetName = "Pull")]
    [switch]$Interactive,
    
    [switch]$Apply = $False,

    # Sandbox parameters
    [Parameter(ParameterSetName = "Sandbox")]
    [switch]$Sandbox,
    
    [Parameter(ParameterSetName = "Sandbox")]
    [ValidateSet("DryRun", "Mock")]
    [string]$SandboxMode = "Mock",
    
    # Help parameter for subcommand help
    [Parameter(Mandatory = $false)]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Script:WinspecRoot = $PSScriptRoot

# Import core modules first so functions can use them
$modules = @(
    "utils.psm1"
    "state.psm1"
    "logging.psm1"
    "schema.psm1"
    "checkpoint.psm1"
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Script:WinspecRoot $m) -ErrorAction Stop
}

$Spec = Resolve-SpecPath $Spec
$ConfigPath = Split-Path $Spec -Parent

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
                          - Omit: run all discovered triggers
    -Spec <path>          Path to specification file

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
    -Output <path>       Output Path
    -Format <format>      Output format: ps1 or json (default: ps1)

EXAMPLES:
    winspec status
    winspec status -Output .\config -Format json

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
    -Format <format>      Output format: ps1 or json (default: ps1)
    -DryRun              Preview what would be captured
    -Apply               Merge with existing spec if output file already exists
    -Interactive         Interactive item selection
    -Minimal             Exclude empty/default values
    -NoCache             Skip caching of provider data
    -Name <string>       Spec name (default: 'WinSpec Configuration')
    -Description <string> Spec description (default: 'Generated by WinSpec')

EXAMPLES:
    # Pull to default file
    winspec pull

    # Pull specific providers
    winspec pull -Providers Registry,Scoop

    # Pull as JSON
    winspec pull -Output state.json -Format json

    # Pull with interactive selection
    winspec pull -Interactive

    # Pull minimal config (exclude empty values)
    winspec pull -Minimal

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
    -OutputFormat <format> Output format: text, json, or simple (default: text)
    -ShowEqual            Include equal items in output (default: false)

EXAMPLES:
    # Compare spec against live system
    winspec diff -Spec .\specs\developer.ps1

    # Compare two specs
    winspec diff -Spec .\specs\developer.ps1 -Against .\specs\base.ps1

    # Compare specific providers
    winspec diff -Spec .\specs\developer.ps1 -Providers Registry

    # Output as JSON
    winspec diff -Spec .\specs\developer.ps1 -OutputFormat json

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
    -Sandbox              Enter sandbox mode
    -SandboxMode <mode>   Sandbox mode: DryRun or Mock (default: Mock)
    -Profile <name>       Sandbox profile name (default: default)

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
        Write-Log -Level INFO $cat.Name

        # Built-in providers
        $providers = Get-Providers -Type $cat.Type
        $providers += Get-Providers -Type $cat.Type -BasePath $ConfigPath

        foreach ($provider in $providers) {
            $name = $provider.Name
            $path = $provider.Path
            $info = $null
            try {
                $module = Import-Module $path -PassThru -ErrorAction Stop
                $info = & $module Get-ProviderInfo
            }
            catch {
                Write-Log -Level WARN "Failed to load provider info: $name"
            }

            $description = if ($info.Description) {
                $info.Description
            }
            else {
                "$($cat.Type) provider"
            }

            $isUser = $ConfigPath -and $path.StartsWith($ConfigPath)
            if ($isUser) {
                Write-Log -Level INFO "    $name - $description [User]"
            }
            else {
                Write-Log -Level INFO "    $name - $description"
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
        
        Import-Module (Join-Path $PSScriptRoot "state.psm1") -Force
        Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force
        Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force

        Write-Log INFO "Capturing system state..."

        $systemState = Get-SystemState -Providers $Providers -NoCache:$NoCache
        if (-not $systemState -or $systemState.Count -eq 0) {
            Write-Log WARN "No system state captured"
            return
        }
        Write-Log INFO "Captured providers: $($systemState.Keys -join ', ')"
        if ($outputPath) {
            if ($PSCmdlet.ShouldProcess($outputPath, "Save spec")) {
                Save-Configuration `
                    -Config $systemState `
                    -Path $outputPath `
                    -Format $Format
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
        
        Import-Module (Join-Path $Script:WinspecRoot "utils.psm1") -Force
        Import-Module (Join-Path $Script:WinspecRoot "logging.psm1") -Force
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
        
        $spec = Get-Spec -Path $Spec
        $results = Invoke-Triggers `
            -Config $spec `
            -Triggers $Triggers `
            -ConfigPath $ConfigPath

        Write-Report -Results $results
    }
    
    
    "pull" {
        if ($Help) {
            Show-Help -Command "pull"
            return
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "pull.psm1") -Force
        Import-Module (Join-Path $Script:WinspecRoot "utils.psm1") -Force
        if (Test-Path ($Spec)) {
            $specContent = Get-Spec $Spec
        } else {
            $specContent = @{}
        }
        $pullParams = @{
            Spec    = $specContent
            Format  = $Format
            NoCache = $NoCache
            Apply   = $Apply
        }
        if ($Output) { $pullParams['Output'] = $Output }
        else { $pullParams['Output'] = $Spec }
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
        if ($Help) {
            Show-Help -Command "push"
            return
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "push.psm1") -Force
        $pushParams = @{
            Spec = $Spec
        }
        if ($Providers) { $pushParams['Providers'] = $Providers }
        if ($Triggers) { $pushParams['Triggers'] = $Triggers }
        if ($DryRun) { $pushParams['DryRun'] = $true }
        if ($Checkpoint) { $pushParams['Checkpoint'] = $true }
        
        $result = Invoke-Push @pushParams
        if (-not $result.Success) { exit 1 }
    }
    
    "diff" {
        if ($Help) {
            Show-Help -Command "diff"
            return
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "diff.psm1") -Force
        Import-Module (Join-Path $Script:WinspecRoot "utils.psm1") -Force
        Import-Module (Join-Path $Script:WinspecRoot "state.psm1") -Force
        $specContent = Get-Spec -Path $Spec
        if ($Against) {
            $againstContent = Get-Spec -Path $Against
        }
        else {
            $againstContent = Get-SystemState -Providers $Providers -NoCache:$NoCache
        }
        $diffParams = @{
            Spec = $specContent
        }
        if ($Against) { $diffParams['Against'] = $againstContent }
        if ($Providers) { $diffParams['Providers'] = $Providers }
        
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
        
        Import-Module (Join-Path $Script:WinspecRoot "merge.psm1") -Force
        $mergeParams = @{
            BasePath     = $Base
            IncomingPath = $Incoming
            Strategy     = $Strategy
            Interactive  = $Interactive
        }
        if ($Output) { $mergeParams['OutputPath'] = $Output }
        
        $result = Merge-Configuration @mergeParams
        if ($result) {
            Write-Host (Format-MergeReport -MergeResult $result)
            if (-not $result.Success) {
                exit 1
            }
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

