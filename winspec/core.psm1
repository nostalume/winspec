# core.psm1 - Core engine for WinSpec: resolve, plan, execute

# Import dependent modules - do NOT re-import logging.psm1 with -Force as it causes scope issues
$ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $ModuleRoot "schema.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "checkpoint.psm1") -ErrorAction Stop
Import-Module (Join-Path $ModuleRoot "sandbox.psm1") -ErrorAction SilentlyContinue
Import-Module (Join-Path $ModuleRoot "utils.psm1") -ErrorAction Stop

function Import-Spec {
    <#
    .SYNOPSIS
    Imports a WinSpec configuration file.

    .DESCRIPTION
    Loads and executes a PowerShell script that returns a hashtable configuration.
    Validates that the file exists and returns a valid hashtable.

    .PARAMETER Path
    The path to the specification file to import.

    .OUTPUTS
    [hashtable] The configuration hashtable, or $null if import fails.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        Write-Log -Level "ERROR" -Message "Specification file not found: $Path"
        return $null
    }
    
    try {
        $config = & $Path
        
        if ($config -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Specification must return a hashtable: $Path"
            return $null
        }
        
        Write-Log -Level "OK" -Message "Loaded specification: $Path"
        return $config
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to parse specification: $Path"
        Write-Log -Level "ERROR" -Message $_.Exception.Message
        return $null
    }
}

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
            
            $importConfig = Import-Spec -Path $fullPath
            if ($importConfig) {
                $resolvedImport = Resolve-Spec -Config $importConfig -BasePath (Split-Path $fullPath -Parent)
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

function Import-Provider {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("managers", "triggers")]
        [string]$Type
    )
    
    $providerPath = Get-ModulePath -Type $Type -Name $Name
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

# Aliases for backward compatibility
function Import-Manager {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return Import-Provider -Name $Name -Type "managers"
}

function Get-DiscoveredProviders {
    <#
    .SYNOPSIS
    Dynamically discovers providers from a directory.

    .DESCRIPTION
    Scans the specified path for .psm1 files and returns provider names that match the specified type.
    When -Display is specified, outputs formatted provider information to the console instead.

    .PARAMETER Path
    The directory path to scan for provider modules.

    .PARAMETER Type
    The provider type to filter by ("Declarative" or "Trigger").

    .PARAMETER Display
    When set, outputs formatted provider information to the console instead of returning an array.

    .PARAMETER Prefix
    Optional prefix to display before each provider name (e.g., "[User] ").

    .OUTPUTS
    Array of provider names that match the specified type, or formatted console output if -Display is set.
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
            # Import the module temporarily
            $importedModule = Import-Module $file.FullName -PassThru -ErrorAction Stop
            
            # Get provider metadata via the exported function
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

function Invoke-DeclarativeProviders {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $results = @{}

    # Dynamically discover declarative providers from managers directory
    $managersPath = Join-Path $ModuleRoot "managers"
    $declarativeProviders = Get-DiscoveredProviders -Path $managersPath -Type "Declarative"
    
    # Check sandbox mode
    $isSandbox = Test-SandboxActive
    $sandboxMode = if ($isSandbox) { Get-SandboxMode } else { "Live" }

    foreach ($providerName in $declarativeProviders) {
        # Skip if provider not configured
        if ($null -eq $Config.$providerName) {
            continue
        }

        Write-LogSection -Name $providerName

        # Load the manager
        if (-not (Import-Manager -Name $providerName)) {
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

        # Apply configuration - use sandbox apply if in sandbox mode
        if ($PSCmdlet.ShouldProcess($providerName, "Apply configuration")) {
            try {
                if ($sandboxApplyCmd) {
                    # Use sandbox apply in mock mode
                    $results[$providerName] = & $sandboxApplyCmd -Desired $desired
                    Write-Log -Level "INFO" -Message "[SANDBOX] Applied $providerName changes"
                }
                else {
                    # Use real apply
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

function Get-ModulePath {
    <#
    .SYNOPSIS
    Constructs a full path to a module file.

    .DESCRIPTION
    Combines the module root directory with the type subdirectory and module name
    to create a full path to a .psm1 file.

    .PARAMETER Type
    The type of module (e.g., "managers", "triggers").

    .PARAMETER Name
    The name of the module (without extension).

    .OUTPUTS
    [string] The full path to the module file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return Join-Path $ModuleRoot "$Type\$Name.psm1"
}

function Resolve-ConfigLocation {
    <#
    .SYNOPSIS
    Resolves the configuration directory location.

    .DESCRIPTION
    Searches for the WinSpec configuration directory using the following precedence:
    1. Explicit ConfigPath parameter
    2. WINSPEC_CONFIG environment variable
    3. ~/.config/winspec/ directory
    4. .winspec.ps1 in current directory

    .PARAMETER ConfigPath
    Optional explicit path to the configuration directory.

    .OUTPUTS
    [string] The resolved configuration path, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # 1. Explicit argument (highest priority)
    if ($ConfigPath) {
        if (Test-Path $ConfigPath) {
            return $ConfigPath
        }
    }
    
    # 2. Environment variable
    if ($env:WINSPEC_CONFIG -and (Test-Path $env:WINSPEC_CONFIG)) {
        return $env:WINSPEC_CONFIG
    }
    
    # 3. .config/winspec/ directory in user home
    $userConfigPath = Join-Path $env:USERPROFILE ".config\winspec"
    if (Test-Path $userConfigPath) {
        return $userConfigPath
    }
    
    # 4. .winspec.ps1 in current directory (default fallback)
    $defaultPath = Join-Path $PWD ".winspec.ps1"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }
    
    return $null
}

function Resolve-SpecPath {
    <#
    .SYNOPSIS
    Resolves the specification file path.

    .DESCRIPTION
    Searches for the WinSpec specification file using the following precedence:
    1. Explicit Spec parameter
    2. WINSPEC_SPEC environment variable
    3. Config directory with default name (default.ps1, config.ps1, winspec.ps1)
    4. .winspec.ps1 in current directory

    .PARAMETER SpecPath
    Optional explicit path to the specification file.

    .PARAMETER ConfigPath
    Optional path to the configuration directory to search in.

    .OUTPUTS
    [string] The resolved specification path, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SpecPath,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # 1. Explicit argument (highest priority)
    if ($SpecPath) {
        if (Test-Path $SpecPath) {
            return $SpecPath
        }
    }
    
    # 2. Environment variable
    if ($env:WINSPEC_SPEC -and (Test-Path $env:WINSPEC_SPEC)) {
        return $env:WINSPEC_SPEC
    }
    
    # 3. Check config directory for default spec files
    $resolvedConfigPath = $ConfigPath
    if (-not $resolvedConfigPath) {
        $resolvedConfigPath = Resolve-ConfigLocation
    }
    
    if ($resolvedConfigPath) {
        # Check if configPath is a file (.winspec.ps1) or directory
        if ((Test-Path $resolvedConfigPath) -and (Get-Item $resolvedConfigPath).PSIsContainer) {
            $configDir = $resolvedConfigPath
        } elseif (Test-Path $resolvedConfigPath) {
            $configDir = Split-Path $resolvedConfigPath -Parent
        }
        
        if ($configDir) {
            # Look for common spec file names (including dot-prefixed)
            $defaultSpecs = @(".winspec.ps1", "default.ps1", "config.ps1", "winspec.ps1", "main.ps1")
            foreach ($specName in $defaultSpecs) {
                $specFile = Join-Path $configDir $specName
                if (Test-Path $specFile) {
                    return $specFile
                }
            }
        }
    }
    
    # 4. .winspec.ps1 in current directory
    $defaultPath = Join-Path $PWD ".winspec.ps1"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }
    
    return $null
}

# Find trigger script in multiple locations
function Find-TriggerScript {
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
    
    # 1. Check for explicit path first
    if (-not [string]::IsNullOrEmpty($Path)) {
        # Resolve relative to spec directory
        if (-not [System.IO.Path]::IsPathRooted($Path) -and -not [string]::IsNullOrEmpty($SpecPath)) {
            $specDir = Split-Path $SpecPath -Parent
            $Path = Join-Path $specDir $Path
        }

        if (Test-Path $Path) {
            return $Path
        }
    }
    
    # 2. Check for built-in trigger in winspec/triggers/
    $builtinPath = Join-Path $ModuleRoot "triggers\$Name.psm1"
    if (Test-Path $builtinPath) {
        return $builtinPath
    }
    
    # 3. Check for trigger in spec directory (triggers/ subdirectory)
    if (-not [string]::IsNullOrEmpty($SpecPath)) {
        $specDir = Split-Path $SpecPath -Parent
        $specTriggerPath = Join-Path $specDir "triggers\$Name.ps1"
        if (Test-Path $specTriggerPath) {
            return $specTriggerPath
        }
    }

    # 4. Check for trigger in config directory (triggers/ subdirectory)
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
    Executes a custom trigger script with standardized parameters.

    .DESCRIPTION
    Loads and executes a custom trigger script (.ps1), passing the required
    parameters -Value and -WhatIf automatically. The script must accept these
    parameters to work correctly.

    .PARAMETER ScriptPath
    The full path to the trigger script to execute. Must be a .ps1 file.

    .PARAMETER Value
    The configuration value to pass to the trigger script. Can be any type
    (string, hashtable, boolean, etc.). Defaults to $true.

    .OUTPUTS
    [hashtable] Returns a standardized result hashtable with keys:
    - Status: "Success", "Error", or "DryRun"
    - Message: Detailed message about the execution result

    .NOTES
    The custom trigger script must accept the following parameters:
    - [Parameter(Mandatory=$false)] $Value
    - [switch] $WhatIf
    
    Example trigger script structure:
    param(
        [Parameter(Mandatory=$false)]
        $Value,
        
        [switch]
        $WhatIf
    )
    
    # Your trigger logic here
    # Return a hashtable with Status and Message keys
    return @{
        Status = "Success"
        Message = "Trigger executed successfully"
    }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        $Value = $true
    )

    if (-not (Test-Path $ScriptPath)) {
        return @{
            Status = "Error"
            Message = "Trigger script not found: $ScriptPath"
        }
    }

    try {
        Write-Log -Level "INFO" -Message "Executing custom trigger: $([System.IO.Path]::GetFileName($ScriptPath))"

        # Execute the script with parameters
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

# Alias for backward compatibility
function Import-BuiltInTrigger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return Import-Provider -Name $Name -Type "triggers"
}

function Get-AllTriggers {
    <#
    .SYNOPSIS
    Discovers all available triggers from built-in and user locations.

    .DESCRIPTION
    Combines built-in triggers from winspec/triggers/ with user triggers
    from the config directory, returning unique trigger names.

    .PARAMETER ConfigPath
    Optional path to configuration directory containing user triggers.

    .OUTPUTS
    Array of unique trigger names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    # Discover built-in triggers from winspec/triggers/
    $builtInPath = Join-Path $ModuleRoot "triggers"
    $triggers = Get-DiscoveredProviders -Path $builtInPath -Type "Trigger"
    
    # Discover user triggers from config directory
    if ($ConfigPath) {
        $userPath = Join-Path $ConfigPath "triggers"
        $userTriggers = Get-DiscoveredProviders -Path $userPath -Type "Trigger"
        $triggers = @($triggers + $userTriggers | Select-Object -Unique)
    }
    
    return $triggers
}

function Invoke-Triggers {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [array]$TriggerConfig,
        
        [Parameter(Mandatory = $false)]
        [string]$SpecPath,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )
    
    $results = @{}
    
    foreach ($trigger in $TriggerConfig) {
        # Validate trigger entry
        if ($trigger -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Invalid trigger entry: must be a hashtable"
            continue
        }
        
        # Check required Name field
        if (-not $trigger.Name) {
            Write-Log -Level "ERROR" -Message "Trigger entry missing required 'Name' field"
            continue
        }
        
        $triggerName = $trigger.Name
        $triggerValue = if ($trigger.ContainsKey('Value')) { $trigger.Value } else { $true }
        $triggerPath = $trigger.Path
        $enabled = if ($trigger.ContainsKey('Enabled')) { $trigger.Enabled } else { $true }
        
        Write-LogSection -Name "Trigger: $triggerName"
        
        # Skip if disabled
        if (-not $enabled) {
            Write-Log -Level "INFO" -Message "Trigger '$triggerName' is disabled"
            $results[$triggerName] = @{ Status = "Skipped"; Reason = "Disabled" }
            continue
        }
        
        # Find trigger script
        $scriptPath = Find-TriggerScript -Name $triggerName -Path $triggerPath -SpecPath $SpecPath -ConfigPath $ConfigPath
        
        if ($null -eq $scriptPath) {
            Write-Log -Level "ERROR" -Message "Trigger '$triggerName' not found in any location"
            $results[$triggerName] = @{ Status = "Error"; Message = "Trigger not found" }
            continue
        }

        # Handle WhatIf scenario
        if ($WhatIf) {
            Write-Log -Level "INFO" -Message "Would execute trigger '$triggerName' (dry run)"
            $results[$triggerName] = @{ Status = "DryRun"; Value = $triggerValue }
            continue
        }

        if ($scriptPath.EndsWith('.psm1')) {
            # Built-in trigger
            if (-not (Import-BuiltInTrigger -Name $triggerName)) {
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
        elseif ($scriptPath.EndsWith('.ps1')) {
            # Custom trigger script
            if ($PSCmdlet.ShouldProcess($triggerName, "Execute custom trigger")) {
                $results[$triggerName] = Invoke-CustomTrigger -ScriptPath $scriptPath -Value $triggerValue -WhatIf:$WhatIf
            }
        }
    }
    
    return $results
}

function Write-Report {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Results
    )
    
    Write-LogHeader -Title "Execution Report"
    
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

        if (-not [string]::IsNullOrEmpty($result.Message)) {
            Write-Log -Level "INFO" -Message "  Message: $($result.Message)"
        }
        if (-not [string]::IsNullOrEmpty($result.Changes)) {
            Write-Log -Level "INFO" -Message "  Changes: $($result.Changes)"
        }
    }
}

function Invoke-WinSpec {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Spec,
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$DryRun,
        
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
    
    # 1. Parse specification
    $config = Import-Spec -Path $Spec
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
    
    # 4. Resolve configuration location
    $configLocation = Resolve-ConfigLocation -ConfigPath $ConfigPath
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
    
    # 8. Report
    Write-Report -Results $results
    
    $results.Success = $true
    return $results
}

function Get-SystemStatus {
    <#
    .SYNOPSIS
    Displays the current system status for all managed components.

    .DESCRIPTION
    Retrieves and displays the current state of the system including:
    - Registry settings
    - Installed packages (via scoop)
    - Available checkpoints
    
    This operation may take some time as it queries multiple system components.

    .OUTPUTS
    None. Outputs status information to the log.
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
        $catConfig = $registryMap[$category]
        foreach ($prop in $catConfig.Properties.Keys) {
            $propConfig = $catConfig.Properties[$prop]
            $value = Get-ItemProperty -Path $catConfig.Path -Name $propConfig.Name -ErrorAction SilentlyContinue
            if ($null -ne $value) {
                Write-Log -Level "INFO" -Message "  $($propConfig.Name) = $($value.$($propConfig.Name))"
            }
        }
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

Export-ModuleMember -Function @(
    "Import-Spec"
    "Resolve-Spec"
    "Resolve-SpecPath"
    "Merge-Hashtables"
    "Import-Manager"
    "Import-BuiltInTrigger"
    "Invoke-DeclarativeProviders"
    "Invoke-Triggers"
    "Invoke-CustomTrigger"
    "Resolve-ConfigLocation"
    "Find-TriggerScript"
    "Write-Report"
    "Invoke-WinSpec"
    "Get-SystemStatus"
    "Get-DiscoveredProviders"
    "Get-ModulePath"
    "Get-AllTriggers"
)
