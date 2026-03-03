#!/usr/bin/env pwsh
# winspec.ps1 - CLI entry point for WinSpec
# A composable, declarative Windows configuration system

[CmdletBinding(DefaultParameterSetName = "Default")]
param (
    [Parameter(Position = 0)]
    [ValidateSet("apply", "trigger", "status", "rollback", "providers", "validate", "help")]
    [string]$Command = "help",
    
    [Parameter(ParameterSetName = "Apply")]
    [string]$Spec,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$DryRun,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$Checkpoint,
    
    [Parameter(ParameterSetName = "Apply")]
    [switch]$WithTriggers,
    
    [Parameter(ParameterSetName = "Trigger")]
    [string[]]$Name,
    
    [Parameter(ParameterSetName = "Trigger")]
    $Option,
    
    [Parameter(ParameterSetName = "Rollback")]
    [int]$SequenceNumber,
    
    [Parameter(ParameterSetName = "Rollback")]
    [switch]$Last,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
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
    help        Show this help message

APPLY OPTIONS:
    -Spec           Path to specification file (required)
    -DryRun         Preview changes without applying
    -Checkpoint     Create restore point before applying
    -WithTriggers   Include trigger execution

TRIGGER OPTIONS:
    -Name           Trigger name(s) - single string or array
                    Omit to run all available triggers
                    Examples: "activation", @("activation", "debloat")
    -Option         Trigger-specific option (applied to all specified triggers)

ROLLBACK OPTIONS:
    -SequenceNumber Restore point sequence number
    -Last           Rollback to most recent WinSpec checkpoint

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

    # Run specific trigger(s)
    .\winspec.ps1 trigger -Name activation
    .\winspec.ps1 trigger -Name debloat -Option "silent"
    .\winspec.ps1 trigger -Name @("activation", "debloat")
    
    # Run all available triggers
    .\winspec.ps1 trigger

    # Rollback to last checkpoint
    .\winspec.ps1 rollback -Last

    # Validate a spec
    .\winspec.ps1 validate -Spec .\specs\developer.ps1

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
        [string[]]$TriggerNames,
        
        # TODO: option is apply to all trigger.
        [Parameter(Mandatory = $false)]
        $TriggerOption,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [string]$SpecPath
    )
    
    # Resolve config location if not provided
    $resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Resolve-ConfigLocation }
    
    # If no trigger names specified, discover all available triggers
    if (-not $TriggerNames -or $TriggerNames.Count -eq 0) {
        $TriggerNames = Get-AllTriggers -ConfigPath $resolvedConfigPath
        
        if ($TriggerNames.Count -eq 0) {
            Write-Log -Level "ERROR" -Message "No triggers found"
            return
        }
        
        Write-Log -Level "INFO" -Message "Running all available triggers: $($TriggerNames -join ', ')"
    }
    
    # Build trigger config array
    $triggerConfig = @()
    foreach ($name in $TriggerNames) {
        $triggerConfig += @{ Name = $name; Value = $TriggerOption }
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
        
        $result = Invoke-WinSpec -Spec $Spec -ConfigPath $ConfigPath -DryRun:$DryRun -Checkpoint:$Checkpoint -WithTriggers:$WithTriggers
        
        if (-not $result.Success) {
            exit 1
        }
    }
    
    "trigger" {
        Invoke-TriggerCommand -TriggerNames $Name -TriggerOption $Option -ConfigPath $ConfigPath -SpecPath $null
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
    
    "help" {
        Show-Help
    }
}
