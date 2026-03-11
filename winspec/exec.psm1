# exec.psm1 - Execution engine for WinSpec
# Focused on: spec resolution, provider execution, trigger execution

# Import dependent modules
$ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $ModuleRoot "logging.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "schema.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "registry-maps.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "checkpoint.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "sandbox.psm1") -ErrorAction SilentlyContinue
Import-Module (Join-Path $ModuleRoot "utils.psm1") -ErrorAction Stop

# =============================================================================
# SPEC RESOLUTION - Process Import array in config
# =============================================================================

function Resolve-Spec {
    <#
    .SYNOPSIS
        Resolves a configuration by processing imports and merging them recursively.
    .DESCRIPTION
        Processes the Import array in a configuration, loading and merging imported
        configuration files recursively. The current configuration takes precedence
        over imported configurations.
    .PARAMETER Config
        The configuration hashtable to resolve.
    .PARAMETER BasePath
        The base path for resolving relative import paths. Defaults to current directory.
    .OUTPUTS
        [hashtable] The resolved configuration with all imports merged.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $false)]
        [string]$BasePath = $PWD
    )
    
    $resolved = @{}
    
    # Process imports first (recursive)
    if ($Config.Import) {
        Write-Log -Level "INFO" -Message "Processing imports..."
        
        foreach ($importPath in $Config.Import) {
            $fullPath = if ([System.IO.Path]::IsPathRooted($importPath)) {
                $importPath
            } else {
                Join-Path $BasePath $importPath
            }
            
            # Use utils.psm1 Import-Configuration
            $importConfig = Import-Configuration -Path $fullPath
            if ($importConfig) {
                $resolvedImport = Resolve-Spec -Config $importConfig -BasePath (Split-Path $fullPath -Parent)
                # Use utils.psm1 Merge-Hashtables
                $resolved = Merge-Hashtables -Base $resolved -Override $resolvedImport
            }
        }
    }
    
    # Merge current config (current takes precedence)
    $resolved = Merge-Hashtables -Base $resolved -Override $Config
    
    # Remove Import key from resolved config
    $resolved.Remove("Import")
    
    return $resolved
}

# =============================================================================
# PROVIDER DISCOVERY
# =============================================================================

function Get-DiscoveredProviders {
    <#
    .SYNOPSIS
        Dynamically discovers providers from a directory.
    .DESCRIPTION
        Scans the specified path for .psm1 files and returns provider names
        that match the specified type.
    .PARAMETER Path
        The directory path to scan for provider modules.
    .PARAMETER Type
        The provider type to filter by ("Declarative" or "Trigger").
    .PARAMETER Display
        When set, outputs formatted provider information to the console.
    .PARAMETER Prefix
        Optional prefix to display before each provider name.
    .OUTPUTS
        Array of provider names that match the specified type.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Declarative", "Trigger")]
        [string]$Type,

        [Parameter(Mandatory = $false)]
        [switch]$Display,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = ""
    )

    $providers = @()

    if (-not (Test-Path $Path)) {
        Write-Verbose "Provider path not found: $Path"
        return $providers
    }

    $files = Get-ChildItem -Path $Path -Filter "*.psm1" -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        try {
            $importedModule = Import-Module $file.FullName -PassThru -ErrorAction Stop
            $info = & $importedModule Get-ProviderInfo
            
            if ($null -ne $info -and $info.Name -and $info.Type -eq $Type) {
                if ($Display) {
                    $description = if ($info.Description) { $info.Description } else { "$Type provider" }
                    Write-Log -Level "INFO" -Message "$Prefix$($info.Name) - $description"
                }
                else {
                    $providers += $info.Name
                }
                Write-Verbose "Discovered $Type provider: $($info.Name) from $($file.Name)"
            }
        }
        catch {
            Write-Verbose "Failed to discover provider from $($file.Name): $_"
        }
    }

    return $providers
}

function Find-ProviderModule {
    <#
    .SYNOPSIS
        Finds a provider module path.
    .DESCRIPTION
        Internal helper to find provider module paths.
    #>
    param(
        [string]$Name,
        [string]$Type
    )
    return Join-Path $ModuleRoot "$Type\$Name.psm1"
}

function Import-Provider {
    <#
    .SYNOPSIS
        Loads a provider module.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("managers", "triggers")]
        [string]$Type
    )
    
    $providerPath = Find-ProviderModule -Name $Name -Type $Type
    if (-not (Test-Path $providerPath)) {
        Write-Log -Level "ERROR" -Message "$($Type.TrimEnd('s')) not found: $Name"
        return $false
    }
    
    try {
        Import-Module $providerPath -ErrorAction Stop
        Write-Log -Level "OK" -Message "Loaded $($Type.TrimEnd('s')): $Name"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to load $($Type.TrimEnd('s')): $Name - $($_.Exception.Message)"
        return $false
    }
}

# =============================================================================
# DECLARATIVE PROVIDER EXECUTION
# =============================================================================

function Invoke-DeclarativeProviders {
    <#
    .SYNOPSIS
        Executes declarative providers to apply configuration.
    .PARAMETER Config
        The resolved configuration hashtable.
    .PARAMETER Providers
        Optional array of provider names to restrict to. If not provided, uses Config.Providers if present.
    .OUTPUTS
        Hashtable with results per provider.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers = @()
    )

    $results = @{}

    # Dynamically discover declarative providers from managers directory
    $managersPath = Join-Path $ModuleRoot "managers"
    $declarativeProviders = Get-DiscoveredProviders -Path $managersPath -Type "Declarative"
    
    # Check if Providers field is specified in config to restrict providers
    $restrictedProviders = $Providers
    if ($Providers.Count -eq 0 -and $Config.ContainsKey('Providers') -and $Config.Providers -is [array]) {
        $restrictedProviders = $Config.Providers
    }
    
    # Check sandbox mode
    $isSandbox = Test-SandboxActive
    $sandboxMode = if ($isSandbox) { Get-SandboxMode } else { "Live" }

    foreach ($providerName in $declarativeProviders) {
        # Skip if provider not configured
        if ($null -eq $Config.$providerName) {
            continue
        }
        
        # Skip if Providers field restricts this provider
        if ($restrictedProviders.Count -gt 0 -and $providerName -notin $restrictedProviders) {
            Write-Log -Level "INFO" -Message "Skipping $providerName (not in specified Providers list)"
            continue
        }

        Write-LogSection -Name $providerName

        # Load the manager
        if (-not (Import-Provider -Name $providerName -Type "managers")) {
            $results[$providerName] = @{ Status = "Error"; Message = "Failed to load provider" }
            continue
        }

        $desired = $Config.$providerName

        # Get provider functions
        $testStateCmd = Get-Command "Test-$($providerName)State" -ErrorAction SilentlyContinue
        $setStateCmd = Get-Command "Set-$($providerName)State" -ErrorAction SilentlyContinue
        
        # Get sandbox functions if in sandbox mode
        $sandboxApplyCmd = $null
        if ($isSandbox -and $sandboxMode -eq "Mock") {
            $sandboxApplyCmd = Get-Command "Invoke-$($providerName)SandboxApply" -ErrorAction SilentlyContinue
        }

        if ($null -eq $testStateCmd -or $null -eq $setStateCmd) {
            Write-Log -Level "ERROR" -Message "Provider $providerName is missing required functions"
            $results[$providerName] = @{ Status = "Error"; Message = "Missing provider functions" }
            continue
        }

        try {
            $inDesiredState = & $testStateCmd -Desired $desired
        }
        catch {
            Write-Log -Level "ERROR" -Message "Provider $providerName test failed: $_"
            $results[$providerName] = @{ Status = "Error"; Message = "Test failed: $_" }
            continue
        }

        if ($inDesiredState) {
            Write-Log -Level "OK" -Message "$providerName is already in desired state"
            $results[$providerName] = @{ Status = "AlreadyInDesiredState" }
            continue
        }

        # Handle WhatIf or DryRun scenario
        if ($WhatIf -or $sandboxMode -eq "DryRun") {
            Write-Log -Level "INFO" -Message "Would apply $providerName changes (dry run)"
            $results[$providerName] = @{ Status = "DryRun"; Changes = "Pending" }
            continue
        }

        # Apply configuration
        if ($PSCmdlet.ShouldProcess($providerName, "Apply configuration")) {
            try {
                if ($sandboxApplyCmd) {
                    $results[$providerName] = & $sandboxApplyCmd -Desired $desired
                    Write-Log -Level "INFO" -Message "[SANDBOX] Applied $providerName changes"
                }
                else {
                    $results[$providerName] = & $setStateCmd -Desired $desired
                }
            }
            catch {
                Write-Log -Level "ERROR" -Message "Provider $providerName set failed: $_"
                $results[$providerName] = @{ Status = "Error"; Message = "Set failed: $_" }
                continue
            }
        }
    }

    return $results
}

# =============================================================================
# TRIGGER EXECUTION
# =============================================================================

function Find-TriggerScript {
    <#
    .SYNOPSIS
        Finds a trigger script in multiple locations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [string]$Path,
        
        [Parameter(Mandatory = $false)]
        [string]$SpecPath,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # Check for explicit path first
    if (-not [string]::IsNullOrEmpty($Path)) {
        if (-not [System.IO.Path]::IsPathRooted($Path) -and -not [string]::IsNullOrEmpty($SpecPath)) {
            $specDir = Split-Path $SpecPath -Parent
            $Path = Join-Path $specDir $Path
        }
        if (Test-Path $Path) {
            return $Path
        }
    }
    
    # Check for built-in trigger in winspec/triggers/
    $builtinPath = Join-Path $ModuleRoot "triggers\$Name.psm1"
    if (Test-Path $builtinPath) {
        return $builtinPath
    }
    
    # Check for trigger in spec directory
    if (-not [string]::IsNullOrEmpty($SpecPath)) {
        $specDir = Split-Path $SpecPath -Parent
        $specTriggerPath = Join-Path $specDir "triggers\$Name.ps1"
        if (Test-Path $specTriggerPath) {
            return $specTriggerPath
        }
    }
    
    # Check for trigger in config directory
    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        $configTriggerPath = Join-Path $ConfigPath "triggers\$Name.ps1"
        if (Test-Path $configTriggerPath) {
            return $configTriggerPath
        }
    }
    
    return $null
}

function Invoke-CustomTrigger {
    <#
    .SYNOPSIS
        Executes a custom trigger script.
    .PARAMETER ScriptPath
        Path to the trigger script.
    .PARAMETER Value
        Configuration value to pass to trigger.
    .PARAMETER WhatIf
        If specified, preview without executing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        $Value = $true,
        
        [switch]$WhatIf
    )

    if (-not (Test-Path $ScriptPath)) {
        return @{
            Status = "Error"
            Message = "Trigger script not found: $ScriptPath"
        }
    }

    try {
        Write-Log -Level "INFO" -Message "Executing custom trigger: $([System.IO.Path]::GetFileName($ScriptPath))"
        $result = & $ScriptPath -Value $Value -WhatIf:$WhatIf

        if ($null -eq $result) {
            return @{
                Status = "Success"
                Message = "Custom trigger executed"
            }
        }
        return $result
    }
    catch {
        Write-Log -Level "ERROR" -Message "Custom trigger failed: $_"
        return @{
            Status = "Error"
            Message = $_.Exception.Message
        }
    }
}

function Invoke-Triggers {
    <#
    .SYNOPSIS
        Executes triggers from configuration.
    .PARAMETER TriggerConfig
        Trigger configuration hashtable.
    .PARAMETER SpecPath
        Path to the specification file.
    .PARAMETER ConfigPath
        Path to the configuration directory.
    .PARAMETER WhatIf
        If specified, preview without executing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [array]$TriggerConfig,
        
        [Parameter(Mandatory = $false)]
        [string]$SpecPath,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [switch]$WhatIf
    )
    
    $results = @{}
    
    foreach ($triggerName in $TriggerConfig.Keys) {
        $triggerValue = $TriggerConfig[$triggerName]
        $scriptPath = $null
        
        # Check if it's a built-in trigger
        $builtinPath = Join-Path $ModuleRoot "triggers\$triggerName.psm1"
        if (Test-Path $builtinPath) {
            $scriptPath = $builtinPath
        }
        else {
            # Try to find custom trigger
            $scriptPath = Find-TriggerScript -Name $triggerName -SpecPath $SpecPath -ConfigPath $ConfigPath
        }
        
        if (-not $scriptPath) {
            Write-Log -Level "ERROR" -Message "Trigger not found: $triggerName"
            $results[$triggerName] = @{ Status = "Error"; Message = "Trigger not found" }
            continue
        }
        
        # Built-in trigger
        if ($scriptPath.EndsWith('.psm1')) {
            if (-not (Import-Provider -Name $triggerName -Type "triggers")) {
                $results[$triggerName] = @{ Status = "Error"; Message = "Failed to load trigger" }
                continue
            }
            
            $invokeTriggerCmd = Get-Command "Invoke-$($triggerName)Trigger" -ErrorAction SilentlyContinue
            
            if ($null -eq $invokeTriggerCmd) {
                Write-Log -Level "ERROR" -Message "Trigger $triggerName is missing Invoke-Trigger function"
                $results[$triggerName] = @{ Status = "Error"; Message = "Missing trigger function" }
                continue
            }
            
            if ($PSCmdlet.ShouldProcess($triggerName, "Execute trigger")) {
                $results[$triggerName] = & $invokeTriggerCmd -Option $triggerValue
            }
        }
        # Custom trigger script
        elseif ($scriptPath.EndsWith('.ps1')) {
            if ($PSCmdlet.ShouldProcess($triggerName, "Execute custom trigger")) {
                $results[$triggerName] = Invoke-CustomTrigger -ScriptPath $scriptPath -Value $triggerValue -WhatIf:$WhatIf
            }
        }
    }
    
    return $results
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

function Invoke-WinSpec {
    <#
    .SYNOPSIS
        Main entry point for applying a specification.
    .DESCRIPTION
        Loads, resolves, validates, and applies a WinSpec configuration.
    .PARAMETER Spec
        Path to the specification file.
    .PARAMETER ConfigPath
        Configuration directory path.
    .PARAMETER Checkpoint
        Create restore point before applying.
    .PARAMETER WithTriggers
        Execute triggers after providers.
    .PARAMETER SandboxMode
        Run in sandbox mode.
    .PARAMETER SandboxProfile
        Sandbox profile name.
    .OUTPUTS
        Hashtable with execution results.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Checkpoint,
        
        [Parameter(Mandatory = $false)]
        [switch]$WithTriggers,
        
        [Parameter(Mandatory = $false)]
        [switch]$SandboxMode,
        
        [Parameter(Mandatory = $false)]
        [string]$SandboxProfile = "default"
    )
    
    Write-LogHeader -Title "WinSpec Execution"
    
    # Check sandbox mode
    $isSandbox = Test-SandboxActive
    $effectiveMode = if ($isSandbox) { Get-SandboxMode } else { "Live" }
    
    if ($isSandbox) {
        Write-Log -Level "INFO" -Message "Running in SANDBOX mode ($effectiveMode)"
    }
    
    # 1. Parse specification (use utils.psm1 Import-Configuration)
    $config = Import-Configuration -Path $Spec
    if (-not $config) {
        Write-Log -Level "ERROR" -Message "Failed to load specification"
        return @{ Success = $false; Error = "Failed to load specification" }
    }
    
    # 2. Resolve imports (recursive merge)
    Write-Log -Level "INFO" -Message "Resolving specification..."
    $resolved = Resolve-Spec -Config $config -BasePath (Split-Path $Spec -Parent)
    
    # 3. Validate against schemas
    Write-Log -Level "INFO" -Message "Validating specification..."
    if (-not (Test-SpecSchema -Config $resolved)) {
        Write-Log -Level "ERROR" -Message "Specification validation failed"
        return @{ Success = $false; Error = "Validation failed" }
    }
    
    # 4. Resolve configuration location (use utils.psm1)
    $configLocation = Resolve-ConfigPath -OutputPath $ConfigPath
    if ($configLocation) {
        Write-Log -Level "INFO" -Message "Using configuration location: $configLocation"
    }
    
    # 5. Create checkpoint if requested
    if ($Checkpoint -and -not $DryRun) {
        $checkpointResult = New-Checkpoint -Name "WinSpec-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (-not $checkpointResult.Success) {
            Write-Log -Level "WARN" -Message "Checkpoint creation failed, continuing anyway..."
        }
    }
    
    # 6. Execute declarative providers (idempotent)
    $results = Invoke-DeclarativeProviders -Config $resolved -WhatIf:$DryRun
    
    # 7. Execute triggers if requested (non-idempotent)
    if ($WithTriggers -and $resolved.Trigger) {
        $triggerParams = @{
            TriggerConfig = $resolved.Trigger
            SpecPath = $Spec
            ConfigPath = $configLocation
            WhatIf = $DryRun
        }
        $results.Triggers = Invoke-Triggers @triggerParams
    }
    
    # 8. Report results
    foreach ($provider in $Results.Keys) {
        $result = $Results[$provider]
        $status = if (-not [string]::IsNullOrEmpty($result.Status)) { $result.Status } else { "Completed" }
        
        $level = switch ($status) {
            "AlreadyInDesiredState" { "OK" }
            "DryRun"                { "INFO" }
            "Error"                 { "ERROR" }
            default                 { "APPLIED" }
        }
        
        Write-Log -Level $level -Message "$provider : $status"
    }
    
    $results.Success = $true
    return $results
}

# =============================================================================
# SYSTEM STATUS
# =============================================================================

function Get-SystemStatus {
    <#
    .SYNOPSIS
        Displays current system status.
    #>
    [CmdletBinding()]
    param()
    
    Write-LogHeader -Title "System Status"
    
    # Registry status
    Write-Log -Level "INFO" -Message "Querying registry settings..."
    Write-LogSection -Name "Registry"
    $registryMap = Get-RegistryMaps
    $categoryCount = 0
    foreach ($category in $registryMap.Keys) {
        $categoryCount++
        Write-Log -Level "INFO" -Message "[$categoryCount/$($registryMap.Count)] Category: $category"
    }
    
    # Package status
    Write-Log -Level "INFO" -Message "Querying package status..."
    Write-LogSection -Name "Packages"
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $installed = scoop list | Select-Object -ExpandProperty Name
        Write-Log -Level "INFO" -Message "Scoop packages: $($installed -join ', ')"
    }
    else {
        Write-Log -Level "WARN" -Message "Scoop not installed"
    }
    
    # Checkpoint status
    Write-Log -Level "INFO" -Message "Querying checkpoint status..."
    Write-LogSection -Name "Checkpoints"
    $checkpoints = Get-Checkpoints
    if ($checkpoints) {
        foreach ($cp in $checkpoints) {
            Write-Log -Level "INFO" -Message "$($cp.Description) - $($cp.CreationTime)"
        }
    }
    else {
        Write-Log -Level "INFO" -Message "No WinSpec checkpoints found"
    }
}

# =============================================================================
# EXPORTS
# =============================================================================

Export-ModuleMember -Function @(
    "Invoke-WinSpec"
    "Resolve-Spec"
    "Invoke-DeclarativeProviders"
    "Invoke-Triggers"
    "Invoke-CustomTrigger"
    "Get-DiscoveredProviders"
    "Find-TriggerScript"
    "Get-SystemStatus"
    "Import-Provider"
)
