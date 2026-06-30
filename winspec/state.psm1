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

# Provider cache for performance
$script:CachedProviders = $null

# State cache for performance (avoids repeated external command calls)
$script:ProviderStateCache = @{}
$script:StateCacheTimestamp = $null
$script:StateCacheTTLSeconds = 30  # Cache state for 30 seconds

function Clear-SystemStateCache {
    <#
    .SYNOPSIS
        Clears the system state cache.
    .DESCRIPTION
        Forces the next Get-SystemState call to fetch fresh data instead of
        returning cached values. Useful after making system changes.
    #>
    [CmdletBinding()]
    param()
    
    $script:ProviderStateCache = @{}
    $script:StateCacheTimestamp = $null
}
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

    # read config triggers
    $configTriggers = @{}
    if ($Config.Trigger) {
        $configTriggers = $Config.Trigger
    }

    # determine execution set
    if (-not $UserTriggers) {
        return $resolved
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
    }
    foreach ($name in $names) {
        $provider = $providerMap["$name"]
        if (-not $provider) {
            Write-Log -Level ERROR -Message "Trigger not found: $name"
            continue
        }

        $value = $true

        if ($configTriggers.ContainsKey($name)) {
            $value = $configTriggers[$name]
        }

        if ($UserTriggers -is [hashtable] -and $UserTriggers.ContainsKey($name)) {
            $value = $UserTriggers[$name]
        }

        $resolved += [pscustomobject]@{
            Name     = $name
            Provider = $provider
            Value    = $value
        }
    }

    return $resolved
}

function Resolve-ProviderList {
    param([string[]]$Providers = @())
    
    # Registry, Feature, Service
    $defaultProviders = @("Registry", "Feature")
    
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

    if (-not (Get-Module -Name $Provider.Name)) {
        Import-Module $Provider.Path -ErrorAction Stop
    }

    return Get-Command -Name $cmdName -Module $Provider.Name -ErrorAction SilentlyContinue
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
        [string]$ConfigPath,
        [switch]$NoCache
    )

    # Cache
    $now = Get-Date
    if (-not $NoCache -and
        $script:StateCacheTimestamp -and
        ($now - $script:StateCacheTimestamp).TotalSeconds -lt $script:StateCacheTTLSeconds -and
        $script:ProviderStateCache.Count -gt 0) {

        $result = @{}
        foreach ($p in Resolve-ProviderList -Providers $Providers) {
            if ($script:ProviderStateCache.ContainsKey($p)) {
                Write-Debug "Provider Cached State: $($script:ProviderStateCache[$p])"
                $result[$p] = $script:ProviderStateCache[$p]
            }
        }
        return $result
    }

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

    $script:ProviderStateCache = $state
    $script:StateCacheTimestamp = Get-Date

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
        [string[]]$Providers = @()
    )
    
    $desiredConfig = $Spec
    $systemConfig = if ($null -eq $Against) { @{} } else { $Against }
    # Determine providers to compare
    $providersToCompare = Resolve-ProviderList -Providers $Providers | Where-Object {
        $desiredConfig.ContainsKey($_) -or $systemConfig.ContainsKey($_)
    }
    
    $allDifferences = @{
        Added   = @()
        Removed = @()
        Changed = @()
        Equal   = @()
    }
    
    # Compare each provider
    foreach ($providerName in $providersToCompare) {
        $systemState = if ($systemConfig.ContainsKey($providerName)) { $systemConfig[$providerName] } else { @{} }
        $desiredState = if ($desiredConfig.ContainsKey($providerName)) { $desiredConfig[$providerName] } else { @{} }
        
        if ($systemState.Count -eq 0 -and $desiredState.Count -eq 0) { continue }
        
        Write-Log -Level "INFO" -Message "Comparing $providerName state..."
        
        $diffs = Compare-ProviderState -Provider $providerName -Desired $desiredState -Current $systemState
        
        foreach ($diff in $diffs) {
            switch ($diff.Type) {
                "Added" { $allDifferences.Added += $diff }
                "Removed" { $allDifferences.Removed += $diff }
                "Changed" { $allDifferences.Changed += $diff }
                "Equal" { $allDifferences.Equal += $diff }
            }
        }
        
        Write-Log -Level "OK" -Message "Found $($diffs.Count) differences in $providerName"
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
        $Config
    )

    $providerName = $Provider.Name
    $providerPath = $Provider.Path

    Write-LogSection -Name $providerName

    # ------------------------------------------------------------
    # Load provider
    # ------------------------------------------------------------

    try {
        Import-Module $providerPath -ErrorAction Stop
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to load provider: $providerName"
        return @{ Status = "Error"; Message = "Provider load failed" }
    }

    try {
        $desired = $Config.$providerName

        $testStateCmd = Get-Command "Test-$($providerName)State" -ErrorAction SilentlyContinue
        $setStateCmd  = Get-Command "Set-$($providerName)State"  -ErrorAction SilentlyContinue
        $sandboxCmd   = Get-Command "Invoke-$($providerName)SandboxApply" -ErrorAction SilentlyContinue

        if (!$testStateCmd -or !$setStateCmd) {
            Write-Log -Level ERROR -Message "Provider $providerName missing required functions"
            return @{ Status = "Error"; Message = "Missing provider functions" }
        }

        $mode = "Live"
        if (Test-SandboxActive) {
            $mode = Get-SandboxMode
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
                    $result = & $sandboxCmd -Desired $desired
                    Write-Log -Level INFO -Message "[SANDBOX] $providerName applied"
                    return $result
                }

                $result = & $setStateCmd -Desired $desired
                return $result
            }
            catch {
                Write-Log -Level ERROR -Message "$providerName set failed: $_"
                return @{ Status = "Error"; Message = "Set failed" }
            }
        }
    }
    finally {
        # Remove module after execution to free resources (bypass WhatIf - cleanup must always happen)
        Remove-Module -Name $providerName -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

function Invoke-Managers {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string[]]$Providers = @()
    )

    $results = @{}

    $providerObjects = Get-Providers -Type Declarative

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
            -Config $Config
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

        $Value
    )

    $name = $Provider.Name
    $path = $Provider.Path

    # Sandbox handling (triggers are non-idempotent)
    if (Test-SandboxActive) {
        $mode = Get-SandboxMode
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
        $cmd = $module.ExportedCommands["Invoke-Trigger"]

        if (-not $cmd) {
            Write-Log -Level "ERROR" -Message "Trigger $name missing invoke function"
            return @{ Status = "Error"; Message = "Missing trigger function" }
        }

        if ($PSCmdlet.ShouldProcess($name, "Execute trigger")) {
            try {
                return & $cmd -Option $Value
            }
            catch {
                Write-Log -Level "ERROR" -Message "Trigger $name failed: $_"
                return @{ Status = "Error"; Message = $_.Exception.Message }
            }
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
        [string]$ConfigPath
    )

    $triggers = Resolve-Triggers `
        -Config $Config `
        -UserTriggers $Triggers `
        -ConfigPath $ConfigPath

    Write-Debug "Triggers: $($triggers | Out-String)"
    $results = @{}

    foreach ($t in $triggers) {
        $name = $t.Name
        $provider = $t.Provider
        $value = $t.Value

        $results[$name] = Invoke-TriggerProvider `
            -Provider $provider `
            -Value $value
    }

    return $results
}


# =============================================================================
# MAIN EXECUTION
# =============================================================================

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

    Write-LogSection -Name "Providers"
    $results = Invoke-Managers -Config $Spec -Providers $Providers
    Write-LogSection -Name "Triggers"
    $results["Triggers"] = Invoke-Triggers -Config $Spec -ConfigPath $ConfigPath -Triggers $Triggers

    foreach ($provider in $results.Keys) {
        $result = $results[$provider]
        $status = if ($result.Status) { $result.Status } else { "Completed" }
        $level = switch ($status) {
            "AlreadyInDesiredState" { "OK" }
            "DryRun" { "INFO" }
            "Error" { "ERROR" }
            default { "APPLIED" }
        }

        Write-LogHeader "Push Results"
        Write-Log -Level $level -Message "[$provider]: $status"
    }

    $results["Success"] = $true

    return $results
}

# =============================================================================
# DIFF OUTPUT FORMATTING
# =============================================================================

function ConvertTo-DisplayValue {
    param($Value)
    if ($null -eq $Value) { return '(null)' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    return $Value.ToString()
}

function Format-DiffOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Differences)
    
    $output = @()
    $output += "`n=== STATE DIFFERENCES ===`n"
    
    # Added
    $addedItems = if ($Differences.Added) { $Differences.Added } else { @() }
    if ($addedItems.Count -gt 0) {
        $output += "`n[+] ADDED (in config, not in system):"
        foreach ($item in $addedItems) {
            $output += "    $($item.Path)"
            $output += "       Value: $(ConvertTo-DisplayValue $item.ConfigValue)"
        }
    }
    
    # Removed
    $removedItems = if ($Differences.Removed) { $Differences.Removed } else { @() }
    if ($removedItems.Count -gt 0) {
        $output += "`n[-] REMOVED (in system, not in config):"
        foreach ($item in $removedItems) {
            $output += "    $($item.Path)"
            $output += "       Current: $(ConvertTo-DisplayValue $item.SystemValue)"
        }
    }
    
    # Changed
    $changedItems = if ($Differences.Changed) { $Differences.Changed } else { @() }
    if ($changedItems.Count -gt 0) {
        $output += "`n[~] CHANGED (different values):"
        foreach ($item in $changedItems) {
            $output += "    $($item.Path)"
            $output += "       System:  $(ConvertTo-DisplayValue $item.SystemValue)"
            $output += "       Config:  $(ConvertTo-DisplayValue $item.ConfigValue)"
        }
    }
    
    $equalCount = if ($Differences.Equal) { $Differences.Equal.Count } else { 0 }
    if ($equalCount -gt 0) {
        $output += "`n[=] EQUAL (matched): $equalCount items"
    }
    
    $totalChanges = $addedItems.Count + $removedItems.Count + $changedItems.Count
    $output += "`n---"
    $output += "Summary: $($addedItems.Count) added, $($removedItems.Count) removed, $($changedItems.Count) changed, $equalCount equal"
    $output += "`nTotal differences: $totalChanges"
    
    return $output -join "`n"
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
    # cache
    "Clear-SystemStateCache"
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
    # diff output
    "ConvertTo-DisplayValue"
    "Format-DiffOutput"
)
