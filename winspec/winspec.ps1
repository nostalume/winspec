#!/usr/bin/env pwsh
# winspec.ps1 - CLI entry point for WinSpec
# A composable, declarative Windows configuration system

[CmdletBinding(DefaultParameterSetName = "Default")]
param (
    [Parameter(Position = 0)]
    [ValidateSet("apply", "trigger", "status", "rollback", "providers", "validate", "export", "diff", "merge", "sync", "init", "sandbox", "help")]
    [string]$Command = "help",
    
    [Parameter(ParameterSetName = "Apply", Mandatory = $true)]
    [Parameter(ParameterSetName = "Diff", Mandatory = $true)]
    [Parameter(ParameterSetName = "Sync", Mandatory = $true)]
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
    [Parameter(ParameterSetName = "Init")]
    [string]$Output,
    
    [Parameter(ParameterSetName = "Export")]
    [Parameter(ParameterSetName = "Init")]
    [Parameter(ParameterSetName = "Diff")]
    [string[]]$Providers,
    
    [Parameter(ParameterSetName = "Export")]
    [ValidateSet("ps1", "json")]
    [string]$Format = "ps1",
    
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
    [string]$Description
)

$ErrorActionPreference = 'Stop'
$Script:WinspecRoot = $PSScriptRoot

# Import core modules
Import-Module (Join-Path $Script:WinspecRoot "logging.psm1") -Force
Import-Module (Join-Path $Script:WinspecRoot "schema.psm1") -Force
Import-Module (Join-Path $Script:WinspecRoot "checkpoint.psm1") -Force
Import-Module (Join-Path $Script:WinspecRoot "core.psm1") -Force

function Show-Help {
    Write-Host @"

WinSpec - Windows Specification
A composable, declarative Windows configuration system

USAGE:
    .\winspec.ps1 <command> [options]

COMMANDS:
    apply       Apply a specification file
    trigger     Execute a specific trigger
    status      Show current system state
    rollback    Rollback to a checkpoint
    providers   List available providers
    validate    Validate a spec without applying
    export      Export current system state
    diff        Compare system state with a spec
    merge       Merge two specification files
    sync        Interactive sync between system and config
    init        Initialize a new configuration from system state
    help        Show this help message

APPLY OPTIONS:
    -Spec           Path to specification file (required)
    -DryRun         Preview changes without applying
    -Checkpoint     Create restore point before applying
    -WithTriggers   Include trigger execution

TRIGGER OPTIONS:
    -Trigger        Specifies triggers to execute and their options.
                    Hashtable: Map trigger names to their specific options
                    Example: @{ activation = "KMS38"; debloat = @{ Silent = $true } }
                    
                    Array: List of triggers to run with default options
                    Example: @("activation", "debloat")
                    
                    String: Single trigger to run with default option
                    Example: "activation"
                    
                    Omit: Run all discovered triggers with default options

ROLLBACK OPTIONS:
    -SequenceNumber Restore point sequence number
    -Last           Rollback to most recent WinSpec checkpoint

EXPORT OPTIONS:
    -Output         Path to write exported configuration
    -Providers      Array of providers to export (default: all)
    -Format         Output format: ps1 or json (default: ps1)

DIFF OPTIONS:
    -Spec           Path to specification file to compare (required)
    -Against        Path to compare against (default: live system)
    -Providers      Array of providers to compare (default: all)

MERGE OPTIONS:
    -Base           Path to base configuration file (required)
    -Incoming       Path to incoming configuration file (required)
    -MergeOutput    Path to write merged configuration
    -Strategy       Merge strategy: auto, union, ours, theirs (default: auto)
    -Interactive    Enable interactive conflict resolution

SYNC OPTIONS:
    -Spec           Path to specification file (required)
    -SyncInteractive   Enable interactive prompts for sync decisions

INIT OPTIONS:
    -Output         Path to write generated configuration (default: winspec.ps1)
    -Providers      Array of providers to include (default: all)
    -Interactive    Prompt for each item to include
    -Template       Include helpful comments and structure
    -Minimal        Only include non-default settings
    -Name           Configuration name
    -Description    Configuration description

GLOBAL OPTIONS:
    -ConfigPath     Path to configuration directory (for user providers/triggers)

EXAMPLES:
    # Apply a specification (declarative only)
    .\winspec.ps1 apply -Spec .\specs\developer.ps1

    # Apply with triggers (runs everything)
    .\winspec.ps1 apply -Spec .\specs\developer.ps1 -WithTriggers

    # Dry run (preview changes)
    .\winspec.ps1 apply -Spec .\specs\developer.ps1 -DryRun

    # Apply with checkpoint
    .\winspec.ps1 apply -Spec .\specs\developer.ps1 -Checkpoint

    # Show current system state
    .\winspec.ps1 status

    # Run triggers with specific options (hashtable)
    .\winspec.ps1 trigger @{ activation = "KMS38"; debloat = @{ Silent = $true } }
    
    # Run multiple triggers with default options (array)
    .\winspec.ps1 trigger -Trigger @("activation", "debloat")
    
    # Run single trigger (string)
    .\winspec.ps1 trigger "activation"
    
    # Run all available triggers
    .\winspec.ps1 trigger

    # Rollback to last checkpoint
    .\winspec.ps1 rollback -Last

    # Validate a spec
    .\winspec.ps1 validate -Spec .\specs\developer.ps1

    # Initialize a new configuration
    .\winspec.ps1 init

    # Initialize with specific options
    .\winspec.ps1 init -Output my-config.ps1 -Template

    # Initialize with interactive selection
    .\winspec.ps1 init -Interactive

"@
}

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
        if (-not $Spec) {
            Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
            exit 1
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
        Invoke-TriggerCommand -Trigger $Trigger -ConfigPath $ConfigPath -SpecPath $null
    }
    
    "status" {
        Get-SystemStatus
    }
    
    "rollback" {
        if (-not $SequenceNumber -and -not $Last) {
            Write-Log -Level "ERROR" -Message "Specify -SequenceNumber or -Last for rollback target"
            exit 1
        }
        
        Invoke-Rollback -SequenceNumber $SequenceNumber -Last:$Last
    }
    
    "providers" {
        Show-Providers -ConfigPath $ConfigPath
    }
    
    "validate" {
        if (-not $Spec) {
            Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
            exit 1
        }
        
        $valid = Invoke-Validate -SpecPath $Spec -ConfigPath $ConfigPath
        if (-not $valid) { exit 1 }
    }
    
    "export" {
        Import-Module (Join-Path $Script:WinspecRoot "export.psm1") -Force
        $exportParams = @{
            Format = $Format
        }
        if ($Output) { $exportParams['OutputPath'] = $Output }
        if ($Providers) { $exportParams['Providers'] = $Providers }
        
        Export-SystemState @exportParams
    }
    
    "diff" {
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
        if (-not $Spec) {
            Write-Log -Level "ERROR" -Message "Specification path required: -Spec <path>"
            exit 1
        }
        
        Import-Module (Join-Path $Script:WinspecRoot "sync.psm1") -Force
        $syncParams = @{
            SpecPath = $Spec
            Interactive = $SyncInteractive
        }
        
        $result = Invoke-Sync @syncParams
        if (-not $result.Success) {
            exit 1
        }
    }
    
    "init" {
        Import-Module (Join-Path $Script:WinspecRoot "init.psm1") -Force -DisableNameChecking
        Import-Module (Join-Path $Script:WinspecRoot "core.psm1") -Force
        
        $initParams = @{}
        
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
