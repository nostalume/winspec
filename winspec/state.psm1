# state.psm1 - Common state manipulation functions for WinSpec
# Provides shared functionality for pull, push, diff, merge, and sync commands

# Import dependent modules
$ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $ModuleRoot "logging.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "utils.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "checkpoint.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "schema.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "sandbox.psm1") -ErrorAction SilentlyContinue

# =============================================================================
# PROVIDER RESOLUTION
# =============================================================================

# =============================================================================
# PROVIDER DISCOVERY
# =============================================================================

function Get-Providers {
    <#
    .SYNOPSIS
        Discover provider modules.

    .DESCRIPTION
        Scans provider directories and returns structured provider metadata.
        If BasePath is not specified, the module root will be used.

    .PARAMETER BasePath
        Optional root directory to scan. Defaults to $ModuleRoot.

    .PARAMETER Type
        Provider type to filter by. If omitted, all provider types are scanned.

    .OUTPUTS
        PSCustomObject with properties:
            Type
            Name
            Path
#>
    [CmdletBinding()]
    param(
        [string]$BasePath = $ModuleRoot,
        
        [ValidateSet("Declarative", "Trigger")]
        [string]$Type
    )

    $results = @()
    if (-not (Test-Path $BasePath)) {
        Write-Verbose "Provider base path not found: $BasePath"
        return $results
    }

    # Resolve which directories to scan
    $typeMap = @{
        Declarative = "managers"
        Trigger     = "triggers"
    }

    $typeDirs = if ($Type) {
        @($typeMap[$Type])
    }
    else {
        $typeMap.Values
    }

    foreach ($dir in $typeDirs) {
        $providerDir = Join-Path $BasePath $dir
        if (-not (Test-Path $providerDir)) {
            continue
        }

        $files = Get-ChildItem -Path $providerDir -Filter "*.psm1" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $module = Import-Module $file.FullName -PassThru -ErrorAction Stop
                $info = & $module Get-ProviderInfo

                if ($null -ne $info -and $info.Name) {

                    $results += [PSCustomObject]@{
                        Type = $info.Type
                        Name = $info.Name
                        Path = $file.FullName
                    }

                    Write-Verbose "Discovered provider: $($info.Name) ($($info.Type))"
                }
            }
            catch {
                Write-Verbose "Skipping provider file $($file.Name): $_"
            }
        }
    }

    return $results
}

function Get-Managers {
    param([string]$ConfigPath)

    $providers = Get-Providers -Type Declarative

    if ($ConfigPath) {
        $providers += Get-Providers -Type Declarative -BasePath $ConfigPath
    }

    return $providers
}

function Get-Triggers {
    param([string]$ConfigPath)

    $providers = Get-Providers -Type Trigger 

    if ($ConfigPath) {
        $providers += Get-Providers -Type Trigger -BasePath $ConfigPath
    }

    return $providers
}

function Resolve-Triggers {
    param(
        $Config,
        $UserTriggers,
        [string]$ConfigPath
    )

    $providers = Get-Triggers -ConfigPath $ConfigPath
    $resolved = @()

    # determine execution set
    if (-not $UserTriggers) {
        if (-not $Config -or -not $Config.ContainsKey("Trigger")) {
            return $resolved
        }
        $names = $Config.Trigger
    }
    elseif ($UserTriggers -eq "*") {
        $names = $providers.Name
    }
    elseif ($UserTriggers -is [string]) {
        $names = @($UserTriggers)
    }
    elseif ($UserTriggers -is [array]) {
        $names = $UserTriggers
    }

    $providerMap = @{}
    foreach ($p in $providers) {
        $providerMap[$p.Name] = $p
        $providerMap[$p.Name.ToString().ToLowerInvariant()] = $p
    }
    foreach ($name in $names) {
        $lookupName = "$name"
        $provider = $providerMap[$lookupName]
        if (-not $provider) {
            $provider = $providerMap[$lookupName.ToLowerInvariant()]
        }
        if (-not $provider) {
            Write-Log -Level ERROR -Message "Trigger not found: $name"
            continue
        }

        $value = @{}
        if ($Config -and $Config.ContainsKey("TriggerConfig") -and $Config.TriggerConfig -is [hashtable]) {
            if ($Config.TriggerConfig.ContainsKey($lookupName)) {
                $value = $Config.TriggerConfig[$lookupName]
            }
            elseif ($Config.TriggerConfig.ContainsKey($provider.Name)) {
                $value = $Config.TriggerConfig[$provider.Name]
            }
        }

        $resolved += [pscustomobject]@{
            Name     = $provider.Name
            Provider = $provider
            Value    = $value
        }
    }

    return $resolved
}

function Get-ForwardedCommonParameters {
    [CmdletBinding()]
    param([hashtable]$BoundParameters)

    $common = @{}
    foreach ($name in @("WhatIf", "Confirm", "Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction")) {
        if ($BoundParameters.ContainsKey($name)) {
            $common[$name] = $BoundParameters[$name]
        }
    }
    return $common
}

function Test-WinSpecSandboxActive {
    $cmd = Get-Command Test-SandboxActive -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    return & $cmd
}

function Get-WinSpecSandboxMode {
    $cmd = Get-Command Get-SandboxMode -ErrorAction SilentlyContinue
    if (-not $cmd) { return "Live" }
    return & $cmd
}

function Get-ProviderExportedCommand {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo]$Module,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Module.ExportedCommands.ContainsKey($Name)) {
        return $Module.ExportedCommands[$Name]
    }
    return $null
}

function Resolve-ProviderList {
    param([string[]]$Providers = @())
    
    $defaultProviders = @("Registry", "Feature", "Service")
    
    if ($providers -and $Providers.Count -gt 0) { return $Providers }
    
    return $defaultProviders
}

function Resolve-ProviderCommand {
    [CmdletBinding()]
    param(
        [pscustomobject]$Provider,
        [ValidateSet("Export", "Merge", "Compare", "Test", "Set")]
        [string]$Operation
    )

    $cmdName = "$Operation-$($Provider.Name)State"
    Write-Verbose "Resolving provider command: $cmdName"

    $module = Import-Module $Provider.Path -PassThru -ErrorAction Stop
    return Get-ProviderExportedCommand -Module $module -Name $cmdName
}

# =============================================================================
# STATE CAPTURE
# =============================================================================

function Export-ProviderState {
    [CmdletBinding()]
    param(
        [pscustomobject]$Provider
    )

    try {
        $cmd = Resolve-ProviderCommand -Provider $Provider -Operation Export
        if (-not $cmd) {
            Write-Log -Level WARN -Message "Provider $($Provider.Name) missing export function"
            return $null
        }

        Write-Verbose "Executing provider export: $($cmd.Name)"
        return & $cmd
    }
    catch {
        Write-Debug $_
        Write-Log -Level WARN -Message "Failed exporting provider $($Provider.Name)"
        return $null
    }
}

function Get-SystemState {
    [CmdletBinding()]
    param(
        [string[]]$Providers = @(),
        [string]$ConfigPath
    )

    $allProviders = Get-Managers -ConfigPath $ConfigPath
    Write-Debug "Available providers:`n$($allProviders | Out-String)"

    $Providers = Resolve-ProviderList $Providers

    if ($Providers.Count -gt 0) {
        $providersToCapture = $allProviders | Where-Object { $Providers -contains $_.Name }
    }
    else {
        $providersToCapture = $allProviders
    }

    $state = @{}

    foreach ($provider in $providersToCapture) {
        $providerState = Export-ProviderState -Provider $provider
        Write-Debug "Provider [$($provider.Name)] state:`n$($providerState | Out-String)"
        if ($providerState) {
            $state[$provider.Name] = $providerState
        }
    }

    return $state
}

# =============================================================================
# STATE COMPARISON
# =============================================================================

function Compare-ProviderState {
    param(
        [pscustomobject]$Provider,
        [hashtable]$Desired,
        [hashtable]$Current
    )

    $differences = @()
    try {
        $cmd = Resolve-ProviderCommand -Provider $Provider -Operation Compare
        if ($cmd) {
            $differences = & $cmd -System $Current -Desired $Desired
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Failed to compare $($Provider.Name) state: $($_.Exception.Message)"
        return @()
    }
    return $differences
}

function Compare-SystemState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Spec,
        [hashtable]$Against,
        [string[]]$Providers = @(),
        [string]$ConfigPath
    )
    
    $desiredConfig = $Spec
    $systemConfig = if ($null -eq $Against) { @{} } else { $Against }
    $providersToCompare = Resolve-ProviderList -Providers $Providers | Where-Object {
        $desiredConfig.ContainsKey($_) -or $systemConfig.ContainsKey($_)
    }

    $providerMap = @{}
    foreach ($provider in Get-Managers -ConfigPath $ConfigPath) {
        $providerMap[$provider.Name] = $provider
        $providerMap[$provider.Name.ToString().ToLowerInvariant()] = $provider
    }
    
    $allDifferences = @{
        Added   = @()
        Removed = @()
        Changed = @()
        Equal   = @()
    }
    
    foreach ($providerName in $providersToCompare) {
        $provider = $providerMap[$providerName]
        if (-not $provider) {
            $provider = $providerMap[$providerName.ToLowerInvariant()]
        }
        if (-not $provider) {
            Write-Log -Level "WARN" -Message "Provider not found for comparison: $providerName"
            continue
        }

        $name = $provider.Name
        $systemState = if ($systemConfig.ContainsKey($name)) { $systemConfig[$name] } else { @{} }
        $desiredState = if ($desiredConfig.ContainsKey($name)) { $desiredConfig[$name] } else { @{} }
        
        if ($systemState.Count -eq 0 -and $desiredState.Count -eq 0) { continue }
        
        Write-Log -Level "INFO" -Message "Comparing $name state..."
        
        $diffs = Compare-ProviderState -Provider $provider -Desired $desiredState -Current $systemState
        
        foreach ($diff in $diffs) {
            switch ($diff.Type) {
                "Added" { $allDifferences.Added += $diff }
                "Removed" { $allDifferences.Removed += $diff }
                "Changed" { $allDifferences.Changed += $diff }
                "Equal" { $allDifferences.Equal += $diff }
            }
        }
        
        Write-Log -Level "OK" -Message "Found $($diffs.Count) differences in $name"
    }
    
    return $allDifferences
}

# =============================================================================
# DECLARATIVE PROVIDER EXECUTION
# =============================================================================
# 
function Invoke-Manager {
<#
.SYNOPSIS
    Executes a single declarative provider.
#>

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Provider,

        [Parameter(Mandatory)]
        $Config,

        [hashtable]$CommonParameters = @{}
    )

    $providerName = $Provider.Name
    $providerPath = $Provider.Path

    Write-LogSection -Name $providerName

    try {
        $module = Import-Module $providerPath -PassThru -ErrorAction Stop
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to load provider: $providerName"
        return @{ Status = "Error"; Message = "Provider load failed" }
    }

    try {
        $desired = $Config.$providerName

        $testStateCmd = Get-ProviderExportedCommand -Module $module -Name "Test-$($providerName)State"
        $setStateCmd  = Get-ProviderExportedCommand -Module $module -Name "Set-$($providerName)State"
        $sandboxCmd   = Get-ProviderExportedCommand -Module $module -Name "Invoke-$($providerName)SandboxApply"

        if (!$testStateCmd -or !$setStateCmd) {
            Write-Log -Level ERROR -Message "Provider $providerName missing required functions"
            return @{ Status = "Error"; Message = "Missing provider functions" }
        }

        $mode = "Live"
        if (Test-WinSpecSandboxActive) {
            $mode = Get-WinSpecSandboxMode
        }

        try {
            $inDesiredState = & $testStateCmd -Desired $desired
        }
        catch {
            Write-Log -Level ERROR -Message "$providerName test failed: $_"
            return @{ Status = "Error"; Message = "Test failed" }
        }

        if ($inDesiredState) {
            Write-Log -Level OK -Message "$providerName already in desired state"
            return @{ Status = "AlreadyInDesiredState" }
        }

        if ($mode -eq "DryRun") {
            Write-Log -Level INFO -Message "DryRun: $providerName would apply changes"
            return @{
                Status  = "DryRun"
                Pending = $true
            }
        }

        if ($PSCmdlet.ShouldProcess($providerName, "Apply configuration")) {
            try {
                if ($mode -eq "Mock" -and $sandboxCmd) {
                    $result = & $sandboxCmd -Desired $desired @CommonParameters
                    Write-Log -Level INFO -Message "[SANDBOX] $providerName applied"
                    return $result
                }

                return & $setStateCmd -Desired $desired @CommonParameters
            }
            catch {
                Write-Log -Level ERROR -Message "$providerName set failed: $_"
                return @{ Status = "Error"; Message = "Set failed" }
            }
        }

        return @{ Status = "DryRun" }
    }
    finally {
        if ($module) {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}

function Invoke-Managers {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string[]]$Providers = @(),

        [string]$ConfigPath,

        [hashtable]$CommonParameters = @{}
    )

    $results = @{}

    $providerObjects = Get-Managers -ConfigPath $ConfigPath

    $restrictedProviders = $Providers
    if ($Providers.Count -eq 0 -and $Config.ContainsKey('Providers')) {
        $restrictedProviders = $Config.Providers
    }

    foreach ($provider in $providerObjects) {
        $name = $provider.Name

        if ($null -eq $Config.$name) {
            continue
        }

        if ($restrictedProviders.Count -gt 0 -and $name -notin $restrictedProviders) {
            Write-Log -Level "INFO" -Message "Skipping $name (not in Providers list)"
            continue
        }

        $results[$name] = Invoke-Manager `
            -Provider $provider `
            -Config $Config `
            -CommonParameters $CommonParameters
    }

    return $results
}

# =============================================================================
# TRIGGER EXECUTION
# =============================================================================

# Avoid name confliction
function Invoke-TriggerProvider {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Provider,

        [hashtable]$Value = @{},

        [hashtable]$CommonParameters = @{}
    )

    $name = $Provider.Name
    $path = $Provider.Path

    # Sandbox handling (triggers are non-idempotent)
    if (Test-WinSpecSandboxActive) {
        $mode = Get-WinSpecSandboxMode
        Write-Log -Level "INFO" -Message "Sandbox ($mode): Trigger '$name' would execute"

        $change = @{
            Status  = "Simulated"
            Trigger = $name
            Value   = $Value
            Mode    = $mode
        }

        Update-SandboxChanges -Provider "Trigger" -Data $change -Action "Trigger Simulated"
        return $change
    }

    try {
        $module = Import-Module $path -PassThru -ErrorAction Stop
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to load trigger: $name"
        return @{ Status = "Error"; Message = "Failed to load trigger" }
    }

    try {
        $cmd = Get-ProviderExportedCommand -Module $module -Name "Invoke-Trigger"

        if (-not $cmd) {
            Write-Log -Level "ERROR" -Message "Trigger $name missing invoke function"
            return @{ Status = "Error"; Message = "Missing trigger function" }
        }

        try {
            return & $cmd @Value @CommonParameters
        }
        catch {
            Write-Log -Level "ERROR" -Message "Trigger $name failed: $_"
            return @{ Status = "Error"; Message = $_.Exception.Message }
        }
    }
    finally {
        # Remove module after execution to free resources (bypass WhatIf - cleanup must always happen)
        if ($module) {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}

function Invoke-Triggers {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Config,
        $Triggers,
        [string]$ConfigPath,
        [hashtable]$CommonParameters
    )

    $triggers = Resolve-Triggers `
        -Config $Config `
        -UserTriggers $Triggers `
        -ConfigPath $ConfigPath

    $commonParameters = if ($CommonParameters) {
        $CommonParameters
    }
    else {
        Get-ForwardedCommonParameters -BoundParameters $PSBoundParameters
    }

    Write-Debug "Triggers: $($triggers | Out-String)"
    $results = @{}

    foreach ($t in $triggers) {
        $name = $t.Name
        $provider = $t.Provider
        $value = $t.Value

        $results[$name] = Invoke-TriggerProvider `
            -Provider $provider `
            -Value $value `
            -CommonParameters $commonParameters
    }

    return $results
}


# =============================================================================
# MAIN EXECUTION
# =============================================================================

function Get-ResultLogLevel {
    param([string]$Status)

    switch ($Status) {
        "AlreadyInDesiredState" { "OK" }
        "DryRun" { "INFO" }
        "Error" { "ERROR" }
        default { "APPLIED" }
    }
}

function Write-WinSpecResultSummary {
    param([hashtable]$Results)

    Write-LogHeader "Push Results"
    foreach ($name in $Results.Keys) {
        if ($name -in @("Success", "Triggers")) { continue }
        $result = $Results[$name]
        $status = if ($result.Status) { $result.Status } else { "Completed" }
        Write-Log -Level (Get-ResultLogLevel -Status $status) -Message "[$name]: $status"
    }

    if ($Results.ContainsKey("Triggers")) {
        foreach ($triggerName in $Results.Triggers.Keys) {
            $triggerResult = $Results.Triggers[$triggerName]
            $status = if ($triggerResult.Status) { $triggerResult.Status } else { "Completed" }
            Write-Log -Level (Get-ResultLogLevel -Status $status) -Message "[Trigger:$triggerName]: $status"
        }
    }
}

function Invoke-WinSpec {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers = @(),

        [Parameter(Mandatory = $false)]
        $Triggers,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [switch]$Checkpoint
    )

    Write-LogHeader -Title "WinSpec Execution"
    Write-Log -Level "INFO" -Message "Validating specification..."

    if (-not (Test-SpecSchema -Spec $Spec)) {
        Write-Log -Level "ERROR" -Message "Specification validation failed"
        return @{ Success = $false }
    }
    if ($Checkpoint) {
        $checkpoint = New-Checkpoint -Name "WinSpec-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (-not $checkpoint.Success) {
            Write-Log -Level "WARN" -Message "Checkpoint creation failed"
        }
    }

    $commonParameters = Get-ForwardedCommonParameters -BoundParameters $PSBoundParameters

    Write-LogSection -Name "Providers"
    $results = Invoke-Managers `
        -Config $Spec `
        -Providers $Providers `
        -ConfigPath $ConfigPath `
        -CommonParameters $commonParameters

    Write-LogSection -Name "Triggers"
    $results["Triggers"] = Invoke-Triggers `
        -Config $Spec `
        -ConfigPath $ConfigPath `
        -Triggers $Triggers `
        -CommonParameters $commonParameters

    $results["Success"] = $true
    Write-WinSpecResultSummary -Results $results

    return $results
}

# =============================================================================
# EXPORTS
# =============================================================================

Export-ModuleMember -Function @(
    # get
    "Get-Providers"
    "Get-Managers"
    "Get-Triggers"
    "Resolve-ProviderList"
    "Resolve-ProviderCommand"
    "Resolve-Triggers"
    "Get-ForwardedCommonParameters"
    "Get-ProviderExportedCommand"
    "Test-WinSpecSandboxActive"
    "Get-WinSpecSandboxMode"
    # execution
    "Invoke-WinSpec"
    "Invoke-Managers"
    "Invoke-Triggers"
    "Invoke-TriggerProvider"
    # export state
    "Get-SystemState"
    "Export-ProviderState"
    # compare
    "Compare-ProviderState"
    "Compare-SystemState"
)
