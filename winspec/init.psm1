# init.psm1 - WinSpec configuration initialization module
# Bootstraps a new WinSpec configuration by capturing current system state

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "export.psm1") -Force

# Constants
$DefaultConfigFilename = ".winspec.ps1"
$UserConfigDir = Join-Path $env:USERPROFILE ".config\winspec"

<#
.SYNOPSIS
    Resolves the output path for the init command.
.DESCRIPTION
    Determines where to save the generated config file. Priority:
    1. Explicit OutputPath parameter
    2. WINSPEC_CONFIG environment variable
    3. User config directory (~/.config/winspec/)
    4. Current directory
#>
function Resolve-InitOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    # If explicit path provided, use it
    if ($OutputPath) {
        return $OutputPath
    }
    
    # Check environment variable
    if ($env:WINSPEC_CONFIG) {
        $configPath = $env:WINSPEC_CONFIG
        if (Test-Path $configPath -PathType Container) {
            return Join-Path $configPath $DefaultConfigFilename
        }
        if ([System.IO.Path]::HasExtension($configPath)) {
            return $configPath
        }
        return Join-Path $configPath $DefaultConfigFilename
    }
    
    # Use user config directory (create if needed)
    if (-not (Test-Path $UserConfigDir)) {
        try {
            New-Item -ItemType Directory -Path $UserConfigDir -Force | Out-Null
        }
        catch {
            Write-Log -Level "WARN" -Message "Cannot create user config directory. Using current directory."
            return Join-Path (Get-Location) $DefaultConfigFilename
        }
    }
    
    return Join-Path $UserConfigDir $DefaultConfigFilename
}

function Initialize-WinSpecConfig {
    <#
    .SYNOPSIS
        Bootstraps a new WinSpec configuration from current system state.
    .DESCRIPTION
        Captures the current system state and generates a WinSpec configuration file.
        Supports interactive mode, template generation, and minimal output options.
    .PARAMETER OutputPath
        Path to write the generated configuration (default: winspec.ps1)
    .PARAMETER Providers
        Array of provider names to include (default: all available)
    .PARAMETER Interactive
        Prompt for each item to include in the configuration
    .PARAMETER Template
        Include helpful comments and structured formatting
    .PARAMETER Minimal
        Only include non-default settings
    .PARAMETER Name
        Configuration name (default: "My WinSpec Configuration")
    .PARAMETER Description
        Configuration description
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Providers = @(),
        
        [Parameter(Mandatory = $false)]
        [switch]$Interactive,
        
        [Parameter(Mandatory = $false)]
        [switch]$Template,
        
        [Parameter(Mandatory = $false)]
        [switch]$Minimal,
        
        [Parameter(Mandatory = $false)]
        [string]$Name = "My WinSpec Configuration",
        
        [Parameter(Mandatory = $false)]
        [string]$Description = "Generated from current system state"
    )
    
    # Resolve default output path if not provided
    $OutputPath = Resolve-InitOutputPath -OutputPath $OutputPath
    
    Write-Host ""
    Write-Log -Level "INFO" -Message "Starting WinSpec configuration initialization..."
    
    # Check if output file exists
    if (Test-Path $OutputPath) {
        if ($Interactive -or -not $Minimal) {
            $response = Read-Host "File '$OutputPath' already exists. Overwrite? [Y/n]"
            if ($response -and $response -notmatch '^[Yy]') {
                Write-Log -Level "WARN" -Message "Initialization cancelled by user"
                return $false
            }
        }
        else {
            Write-Log -Level "ERROR" -Message "Output file already exists: $OutputPath"
            Write-Log -Level "INFO" -Message "Use -Interactive mode to prompt for overwrite, or specify a different -Output path"
            return $false
        }
    }
    
    # 1. Export current system state
    Write-Host ""
    Write-Host "Scanning system state..." -ForegroundColor Cyan
    $systemState = Export-SystemState -Providers $Providers
    
    if (-not $systemState -or $systemState.Count -le 2) {
        Write-Log -Level "WARN" -Message "No system state data captured"
    }
    else {
        # Show summary of found items
        Show-StateSummary -State $systemState
    }
    
    # 2. If interactive, filter based on user input
    if ($Interactive) {
        Write-Host ""
        $systemState = Invoke-InitInteractive -State $systemState
    }
    
    # 3. If minimal, filter to non-defaults
    if ($Minimal) {
        Write-Host ""
        Write-Log -Level "INFO" -Message "Filtering to non-default settings only..."
        $systemState = Filter-MinimalConfig -State $systemState
    }
    
    # 4. Generate config content
    $systemState.Name = $Name
    $systemState.Description = $Description
    
    if ($Template) {
        $content = ConvertTo-TemplateConfig -State $systemState -Name $Name -Description $Description
    }
    else {
        $content = ConvertTo-SimpleConfig -State $systemState -Name $Name -Description $Description
    }
    
    # 5. Write to file
    try {
        $directory = Split-Path -Parent $OutputPath
        if ($directory -and -not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        
        $content | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Host ""
        Write-Log -Level "OK" -Message "Initialized WinSpec config: $OutputPath"
        
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to write configuration file: $($_.Exception.Message)"
        return $false
    }
}

function Show-StateSummary {
    <#
    .SYNOPSIS
        Displays a summary of the captured system state.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    Write-Host "Found:" -ForegroundColor Green
    
    # Package summary
    if ($State.ContainsKey("Package") -and $State.Package.ContainsKey("Installed")) {
        $count = $State.Package.Installed.Count
        Write-Host "  - $count packages installed" -ForegroundColor White
    }
    
    # Registry summary
    if ($State.ContainsKey("Registry")) {
        $count = 0
        foreach ($category in $State.Registry.Keys) {
            $count += $State.Registry[$category].Count
        }
        Write-Host "  - $count registry settings customized" -ForegroundColor White
    }
    
    # Service summary
    if ($State.ContainsKey("Service")) {
        $count = $State.Service.Count
        Write-Host "  - $count services configured" -ForegroundColor White
    }
    
    # Feature summary
    if ($State.ContainsKey("Feature")) {
        $count = $State.Feature.Count
        Write-Host "  - $count features enabled" -ForegroundColor White
    }
}

function Invoke-InitInteractive {
    <#
    .SYNOPSIS
        Interactive mode - prompts user to select which items to include.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    $filteredState = @{
        Name = $State.Name
        Description = $State.Description
    }
    
    # Helper function for prompting user with yes/no/skip-all
    function Get-UserSelection {
        param([string]$Prompt)
        $response = Read-Host $Prompt
        if ($response -eq "skip all") { return "skip" }
        if (-not $response -or $response -match '^[Yy]') { return "yes" }
        return "no"
    }
    
    # Helper function for processing a collection interactively
    function Select-ItemsFromList {
        param(
            [string]$Title,
            [array]$Items,
            [scriptblock]$GetPrompt
        )
        Write-Host ""
        Write-Host "=== $Title ===" -ForegroundColor Cyan
        $selected = @()
        foreach ($item in $Items) {
            $prompt = & $GetPrompt $item
            $choice = Get-UserSelection -Prompt $prompt
            if ($choice -eq "skip") { break }
            if ($choice -eq "yes") { $selected += $item }
        }
        return $selected
    }
    
    # Package selection
    if ($State.Package?.Installed) {
        $selected = Select-ItemsFromList -Title "Package Selection" -Items $State.Package.Installed -GetPrompt { "Include '$args'? [Y/n/skip all]" }
        if ($selected.Count -gt 0) {
            $filteredState["Package"] = @{ Installed = $selected }
        }
    }
    
    # Registry selection
    if ($State.Registry) {
        $filteredRegistry = @{}
        foreach ($category in $State.Registry.Keys) {
            $settings = $State.Registry[$category]
            $selected = @{}
            foreach ($settingName in $settings.Keys) {
                $value = $settings[$settingName]
                $valueStr = if ($value -is [bool]) { $value.ToString() } else { $value }
                $choice = Read-UserChoice -Prompt "Include $category.$settingName = $valueStr? [Y/n/skip all]"
                if ($choice -eq "skip") { break }
                if ($choice -eq "yes") { $selected[$settingName] = $value }
            }
            if ($selected.Count -gt 0) { $filteredRegistry[$category] = $selected }
        }
        if ($filteredRegistry.Count -gt 0) { $filteredState["Registry"] = $filteredRegistry }
    }
    
    # Service selection
    if ($State.Service) {
        $filteredServices = @{}
        foreach ($serviceName in $State.Service.Keys) {
            $config = $State.Service[$serviceName]
            $startup = $config.Startup ?? $config
            $choice = Read-UserChoice -Prompt "Include service '$serviceName' (startup: $startup)? [Y/n/skip all]"
            if ($choice -eq "skip") { break }
            if ($choice -eq "yes") { $filteredServices[$serviceName] = $config }
        }
        if ($filteredServices.Count -gt 0) { $filteredState["Service"] = $filteredServices }
    }
    
    # Feature selection
    if ($State.Feature) {
        $filteredFeatures = @{}
        foreach ($featureName in $State.Feature.Keys) {
            $choice = Read-UserChoice -Prompt "Include feature '$featureName' (state: $($State.Feature[$featureName]))? [Y/n/skip all]"
            if ($choice -eq "skip") { break }
            if ($choice -eq "yes") { $filteredFeatures[$featureName] = $State.Feature[$featureName] }
        }
        if ($filteredFeatures.Count -gt 0) { $filteredState["Feature"] = $filteredFeatures }
    }
    
    return $filteredState
}

function Filter-MinimalConfig {
    <#
    .SYNOPSIS
        Filters system state to only include non-default settings.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    $filteredState = @{
        Name = $State.Name
        Description = $State.Description
    }
    
    # Package - all installed packages are considered "custom"
    if ($State.Package?.Installed.Count -gt 0) {
        $filteredState["Package"] = $State.Package
    }
    
    # Registry - filter out default values
    if ($State.Registry) {
        $registryDefaults = Get-RegistryDefaults
        $filteredRegistry = @{}
        
        foreach ($category in $State.Registry.Keys) {
            $filteredSettings = @{}
            
            foreach ($setting in $State.Registry[$category].Keys) {
                $currentValue = $State.Registry[$category][$setting]
                $defaultValue = $null
                
                if ($registryDefaults.ContainsKey($category) -and
                    $registryDefaults[$category].ContainsKey($setting)) {
                    $defaultValue = $registryDefaults[$category][$setting]
                }
                
                if ($null -eq $defaultValue -or $currentValue -ne $defaultValue) {
                    $filteredSettings[$setting] = $currentValue
                }
            }
            
            if ($filteredSettings.Count -gt 0) {
                $filteredRegistry[$category] = $filteredSettings
            }
        }
        
        if ($filteredRegistry.Count -gt 0) {
            $filteredState["Registry"] = $filteredRegistry
        }
    }
    
    # Service - filter out default startup types
    if ($State.Service) {
        $serviceDefaults = Get-ServiceDefaults
        $filteredServices = @{}
        
        foreach ($serviceName in $State.Service.Keys) {
            $config = $State.Service[$serviceName]
            $startup = $config.Startup ?? $config
            $defaultStartup = $serviceDefaults[$serviceName]
            
            if ($null -eq $defaultStartup -or $startup -ne $defaultStartup) {
                $filteredServices[$serviceName] = $config
            }
        }
        
        if ($filteredServices.Count -gt 0) {
            $filteredState["Service"] = $filteredServices
        }
    }
    
    # Feature - only include enabled features
    if ($State.Feature) {
        $filteredFeatures = @{}
        foreach ($featureName in $State.Feature.Keys) {
            if ($State.Feature[$featureName] -eq "enabled") {
                $filteredFeatures[$featureName] = "enabled"
            }
        }
        if ($filteredFeatures.Count -gt 0) {
            $filteredState["Feature"] = $filteredFeatures
        }
    }
    
    return $filteredState
}

function Get-RegistryDefaults {
    <#
    .SYNOPSIS
        Returns a hashtable of default Windows registry values.
    #>
    return @{
        Explorer = @{
            ShowHidden = $false
            HideFileExt = $true
            Hidden = 2
            HideIcons = 0
            LaunchTo = 1
        }
        Taskbar = @{
            SearchboxTaskbarMode = 1
            TaskbarAl = 0
        }
        Clipboard = @{
            ClipboardHistory = 0
        }
        Theme = @{
            AppsUseLightTheme = 1
            SystemUsesLightTheme = 1
        }
    }
}

function Get-ServiceDefaults {
    <#
    .SYNOPSIS
        Returns a hashtable of default Windows service startup types.
    #>
    return @{
        # Common services with non-default configurations
        bits = "Automatic"
        wuauserv = "Automatic"
        SysMain = "Automatic"
        DiagTrack = "Automatic"
        dmwappushservice = "Manual"
        WerSvc = "Manual"
    }
}

function ConvertTo-SimpleConfig {
    <#
    .SYNOPSIS
        Converts system state to simple PowerShell hashtable syntax.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    
    $config = @{
        Name = $Name
        Description = $Description
    }
    
    # Add each provider's data
    foreach ($key in $State.Keys | Where-Object { $_ -notin @("Name", "Description") } | Sort-Object) {
        $config[$key] = $State[$key]
    }
    
    return ConvertTo-PowerShellHashtable -Value $config -Indent 0
}

function ConvertTo-TemplateConfig {
    <#
    .SYNOPSIS
        Converts system state to a templated PowerShell configuration with comments.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Description
    )
    
    $lines = @()
    $lines += "# WinSpec Configuration"
    $lines += "# Generated: $(Get-Date -Format 'yyyy-MM-dd')"
    $lines += "# Edit this file to customize your Windows configuration"
    $lines += ""
    $lines += "@{"
    $lines += "    # Configuration metadata"
    $lines += "    Name = '$($Name -replace "'", "''")'"
    $lines += "    Description = '$($Description -replace "'", "''")'"
    
    # Package section
    if ($State.ContainsKey("Package") -and $State.Package.ContainsKey("Installed") -and $State.Package.Installed.Count -gt 0) {
        $lines += ""
        $lines += "    # ============================================================================"
        $lines += "    # Package Management (Scoop)"
        $lines += "    # ============================================================================"
        $lines += "    # Installed packages will be ensured present"
        $lines += "    # Run: scoop install <package>"
        $lines += "    Package = @{"
        $lines += "        Installed = @("
        
        foreach ($package in $State.Package.Installed | Sort-Object) {
            $lines += "            '$($package -replace "'", "''")'"
        }
        
        $lines += "        )"
        $lines += "    }"
    }
    
    # Registry section
    if ($State.ContainsKey("Registry") -and $State.Registry.Count -gt 0) {
        $lines += ""
        $lines += "    # ============================================================================"
        $lines += "    # Windows Registry"
        $lines += "    # ============================================================================"
        $lines += "    # Registry settings control Windows behavior and appearance"
        $lines += "    # WARNING: Incorrect registry settings can cause system issues"
        $lines += "    Registry = @{"
        
        foreach ($category in ($State.Registry.Keys | Sort-Object)) {
            $lines += "        # $category settings"
            $lines += "        $category = @{"
            
            foreach ($setting in ($State.Registry[$category].Keys | Sort-Object)) {
                $value = $State.Registry[$category][$setting]
                $valueStr = ConvertTo-PowerShellValue -Value $value
                $lines += "            $setting = $valueStr"
            }
            
            $lines += "        }"
        }
        
        $lines += "    }"
    }
    
    # Service section
    if ($State.ContainsKey("Service") -and $State.Service.Count -gt 0) {
        $lines += ""
        $lines += "    # ============================================================================"
        $lines += "    # Windows Services"
        $lines += "    # ============================================================================"
        $lines += "    # Service configurations control startup behavior"
        $lines += "    Service = @{"
        
        foreach ($serviceName in ($State.Service.Keys | Sort-Object)) {
            $config = $State.Service[$serviceName]
            $lines += "        # $serviceName service"
            $lines += "        $serviceName = @{"
            
            if ($config -is [hashtable]) {
                foreach ($prop in $config.Keys | Sort-Object) {
                    $valueStr = ConvertTo-PowerShellValue -Value $config[$prop]
                    $lines += "            $prop = $valueStr"
                }
            }
            else {
                $valueStr = ConvertTo-PowerShellValue -Value $config
                $lines += "            Startup = $valueStr"
            }
            
            $lines += "        }"
        }
        
        $lines += "    }"
    }
    
    # Feature section
    if ($State.ContainsKey("Feature") -and $State.Feature.Count -gt 0) {
        $lines += ""
        $lines += "    # ============================================================================"
        $lines += "    # Windows Features"
        $lines += "    # ============================================================================"
        $lines += "    # Optional Windows components"
        $lines += "    Feature = @{"
        
        foreach ($featureName in ($State.Feature.Keys | Sort-Object)) {
            $featureState = $State.Feature[$featureName]
            $lines += "        # $featureName"
            $lines += "        '$featureName' = '$featureState'"
        }
        
        $lines += "    }"
    }
    
    $lines += "}"
    
    return $lines -join "`n"
}

function ConvertTo-PowerShellValue {
    <#
    .SYNOPSIS
        Converts a value to PowerShell syntax string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Value
    )
    
    if ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [int] -or $Value -is [double]) {
        return $Value.ToString()
    }
    elseif ($Value -is [string]) {
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }
    else {
        return "'$Value'"
    }
}

Export-ModuleMember -Function @(
    "Resolve-InitOutputPath",
    "Initialize-WinSpecConfig",
    "Show-StateSummary",
    "Invoke-InitInteractive",
    "Filter-MinimalConfig",
    "Get-RegistryDefaults",
    "Get-ServiceDefaults",
    "ConvertTo-SimpleConfig",
    "ConvertTo-TemplateConfig",
    "ConvertTo-PowerShellValue"
)
