# providers/service.psm1 - Declarative Windows services provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

# Import sandbox module once at module load time
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue

function Get-ProviderInfo {
    return @{
        Name = "Service"
        Type = "Declarative"
    }
}

function Get-ServiceState {
    <#
    .SYNOPSIS
        Gets the state of a specific service.
    .DESCRIPTION
        Uses cached service data when available to avoid redundant queries.
    .PARAMETER ServiceName
        Name of the service to query.
    .PARAMETER ServiceCache
        Optional hashtable of pre-fetched services for batch operations.
    .OUTPUTS
        Hashtable with State and Startup properties, or null if not found.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$ServiceCache
    )
    
    try {
        # Use cache if provided, otherwise query directly
        if ($null -ne $ServiceCache -and $ServiceCache.ContainsKey($ServiceName)) {
            $service = $ServiceCache[$ServiceName]
        }
        else {
            $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        }
        
        if ($service) {
            # Get-Service already has StartType property - no need for WMI!
            # Maintain lowercase for backward compatibility
            return @{
                State   = $service.Status.ToString().ToLower()
                Startup = $service.StartType.ToString().ToLower()
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-AllServiceStates {
    <#
    .SYNOPSIS
        Gets states of multiple services in a single query.
    .DESCRIPTION
        Fetches all services once and returns a hashtable of service states.
        This is the efficient batch operation - O(1) instead of O(n) queries.
    .PARAMETER ServiceNames
        Array of service names to fetch. If empty, returns all services.
    .OUTPUTS
        Hashtable with service names as keys and state objects as values.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ServiceNames = @()
    )
    
    $result = @{}
    
    try {
        # Get all services in ONE call - this is the key optimization
        $allServices = @{}
        foreach ($svc in Get-Service) {
            $allServices[$svc.Name] = $svc
        }
        
        # If specific services requested, filter; otherwise return all
        if ($ServiceNames.Count -gt 0) {
            foreach ($serviceName in $ServiceNames) {
                if ($allServices.ContainsKey($serviceName)) {
                    $service = $allServices[$serviceName]
                    $result[$serviceName] = @{
                        State   = $service.Status.ToString().ToLower()
                        Startup = $service.StartType.ToString().ToLower()
                    }
                }
            }
        }
        else {
            # Return all services
            foreach ($serviceName in $allServices.Keys) {
                $service = $allServices[$serviceName]
                $result[$serviceName] = @{
                    State   = $service.Status.ToString().ToLower()
                    Startup = $service.StartType.ToString().ToLower()
                }
            }
        }
    }
    catch {
        # Return empty hashtable on error
    }
    
    return $result
}

function Test-ServiceState {
    <#
    .SYNOPSIS
        Tests if services match desired configuration.
    .DESCRIPTION
        Uses batch query to get all service states efficiently.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $allInDesiredState = $true
    
    # OPTIMIZATION: Fetch all services in ONE query, then lookup
    $allServiceStates = Get-AllServiceStates -ServiceNames $Desired.Keys
    
    foreach ($serviceName in $Desired.Keys) {
        $desiredConfig = $Desired[$serviceName]
        $currentState = $allServiceStates[$serviceName]
        
        if ($null -eq $currentState) {
            Write-Log -Level "WARN" -Message "Service not found: $serviceName"
            continue
        }
        
        # Use case-insensitive comparison - no ToLower() needed
        if ($desiredConfig.State -and -not ($currentState.State -eq $desiredConfig.State -or $currentState.State.ToLower() -eq $desiredConfig.State.ToLower())) {
            $allInDesiredState = $false
        }
        
        if ($desiredConfig.Startup -and -not ($currentState.Startup -eq $desiredConfig.Startup -or $currentState.Startup.ToLower() -eq $desiredConfig.Startup.ToLower())) {
            $allInDesiredState = $false
        }
    }
    
    return $allInDesiredState
}

function Set-ServiceState {
    <#
    .SYNOPSIS
        Sets service state and startup configuration.
    .DESCRIPTION
        Uses batch query to get current states efficiently.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    # OPTIMIZATION: Fetch all services in ONE query
    $allServiceStates = Get-AllServiceStates -ServiceNames $Desired.Keys
    
    foreach ($serviceName in $Desired.Keys) {
        $desiredConfig = $Desired[$serviceName]
        $currentState = $allServiceStates[$serviceName]
        
        if ($null -eq $currentState) {
            Write-Log -Level "ERROR" -Message "Service not found: $serviceName"
            $results[$serviceName] = @{ Status = "Error"; Message = "Service not found" }
            continue
        }
        
        $serviceResults = @{}
        
        # Handle Startup configuration
        if ($desiredConfig.Startup) {
            $currentStartup = $currentState.Startup
            $desiredStartup = $desiredConfig.Startup
            
            # Case-insensitive comparison
            $startupMatch = $currentStartup -eq $desiredStartup -or $currentStartup.ToLower() -eq $desiredStartup.ToLower()
            
            if ($startupMatch) {
                Write-LogOk -Name "$serviceName.Startup" -DesiredValue $desiredConfig.Startup
                $serviceResults["Startup"] = @{ Status = "AlreadySet" }
            }
            else {
                Write-LogChange -Name "$serviceName.Startup" -CurrentValue $currentStartup -DesiredValue $desiredStartup
                
                if ($PSCmdlet.ShouldProcess("$serviceName Startup", "Set to '$desiredStartup'")) {
                    try {
                        Set-Service -Name $serviceName -StartupType $desiredStartup -ErrorAction Stop
                        Write-LogApplied -Name "$serviceName.Startup" -DesiredValue $desiredStartup
                        $serviceResults["Startup"] = @{ Status = "Applied" }
                    }
                    catch {
                        Write-LogError -Name "$serviceName.Startup" -Details $_.Exception.Message
                        $serviceResults["Startup"] = @{ Status = "Error"; Message = $_.Exception.Message }
                    }
                }
            }
        }
        
        # Handle State configuration
        if ($desiredConfig.State) {
            $desiredState = $desiredConfig.State
            $currentStateValue = $currentState.State
            
            # Map running/stopped to PowerShell service status
            $isRunning = $currentStateValue -eq "Running"
            $shouldBeRunning = $desiredState -eq "running"
            
            # Case-insensitive check
            if ($currentStateValue.ToLower() -eq "running") { $isRunning = $true }
            if ($desiredState.ToLower() -eq "running") { $shouldBeRunning = $true }
            
            if ($isRunning -eq $shouldBeRunning) {
                Write-LogOk -Name "$serviceName.State" -DesiredValue $desiredState
                $serviceResults["State"] = @{ Status = "AlreadySet" }
            }
            else {
                Write-LogChange -Name "$serviceName.State" -CurrentValue $currentStateValue -DesiredValue $desiredState
                
                if ($PSCmdlet.ShouldProcess("$serviceName State", "Set to '$desiredState'")) {
                    try {
                        if ($shouldBeRunning) {
                            Start-Service -Name $serviceName -ErrorAction Stop
                        }
                        else {
                            Stop-Service -Name $serviceName -Force -ErrorAction Stop
                        }
                        Write-LogApplied -Name "$serviceName.State" -DesiredValue $desiredState
                        $serviceResults["State"] = @{ Status = "Applied" }
                    }
                    catch {
                        Write-LogError -Name "$serviceName.State" -Details $_.Exception.Message
                        $serviceResults["State"] = @{ Status = "Error"; Message = $_.Exception.Message }
                    }
                }
            }
        }
        
        $results[$serviceName] = $serviceResults
    }
    
    return $results
}

function Export-ServiceState {
    <#
    .SYNOPSIS
        Exports the current service states for bidirectional sync.
    .DESCRIPTION
        Captures current state and startup configuration for services.
        By default exports services with non-automatic startup or stopped state.
        OPTIMIZATION: Uses single batch query instead of per-service queries.
    .PARAMETER ServiceNames
        Optional array of specific service names to export.
    .OUTPUTS
        Hashtable with service configurations
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$ServiceNames = @()
    )
    
    $result = @{}
    
    # If no specific services requested, export interesting ones
    # (those that are not running with automatic startup)
    if ($ServiceNames.Count -eq 0) {
        # OPTIMIZATION: Single query to get all services
        $allServices = Get-Service | Where-Object { 
            $_.StartType -ne 'Automatic' -or $_.Status -ne 'Running'
        }
        
        # Build list from filtered services
        $ServiceNames = @()
        $count = 0
        foreach ($svc in $allServices) {
            if ($count -ge 50) { break }
            $ServiceNames += $svc.Name
            $count++
        }
    }
    
    # OPTIMIZATION: Single batch query for all requested services
    $allServiceStates = Get-AllServiceStates -ServiceNames $ServiceNames
    
    foreach ($serviceName in $ServiceNames) {
        $state = $allServiceStates[$serviceName]
        if ($state) {
            $result[$serviceName] = @{
                State = $state.State
                Startup = $state.Startup
            }
        }
    }
    
    return $result
}

function Compare-ServiceState {
    <#
    .SYNOPSIS
        Compares system service state with desired configuration.
    .DESCRIPTION
        Compares current service configurations with desired and
        returns differences (added, removed, changed services).
    .PARAMETER System
        Current system state (from Export-ServiceState)
    .PARAMETER Desired
        Desired configuration state
    .OUTPUTS
        Array of difference objects with Type, Path, SystemValue, ConfigValue
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$System,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $differences = @()
    
    foreach ($serviceName in $Desired.Keys) {
        $desiredConfig = $Desired[$serviceName]
        $systemConfig = if ($System.ContainsKey($serviceName)) { $System[$serviceName] } else { $null }
        
        $path = "Service.$serviceName"
        
        if ($null -eq $systemConfig) {
            # Service not in system
            $differences += @{
                Type = "Added"
                Path = $path
                SystemValue = $null
                ConfigValue = $desiredConfig
            }
        }
        elseif ($systemConfig.State -ne $desiredConfig.State -or $systemConfig.Startup -ne $desiredConfig.Startup) {
            # Configuration changed
            $differences += @{
                Type = "Changed"
                Path = $path
                SystemValue = $systemConfig
                ConfigValue = $desiredConfig
            }
        }
        else {
            # Configuration matches
            $differences += @{
                Type = "Equal"
                Path = $path
                SystemValue = $systemConfig
                ConfigValue = $desiredConfig
            }
        }
    }
    
    # Check for removed services (in system but not in desired)
    foreach ($serviceName in $System.Keys) {
        if (-not $Desired.ContainsKey($serviceName)) {
            $differences += @{
                Type = "Removed"
                Path = "Service.$serviceName"
                SystemValue = $System[$serviceName]
                ConfigValue = $null
            }
        }
    }
    
    return $differences
}

function Get-ServiceMockState {
    <#
    .SYNOPSIS
        Gets the service mock state from sandbox.
    .DESCRIPTION
        Returns the current service state from the sandbox context.
    .OUTPUTS
        Hashtable with service names and startup types
    #>
    [CmdletBinding()]
    param()
    
    # Module already imported at module scope - no need to import again
    
    if (Test-SandboxActive) {
        return Get-SandboxState -Provider "Service"
    }
    
    return @{}
}

function Set-ServiceMockState {
    <#
    .SYNOPSIS
        Sets the service mock state in sandbox.
    .DESCRIPTION
        Updates the current service state in the sandbox context.
    .PARAMETER State
        Hashtable with service names and startup types
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    # Module already imported at module scope
    
    if (Test-SandboxActive) {
        Set-SandboxState -Provider "Service" -State $State
    }
}

function Invoke-ServiceSandboxApply {
    <#
    .SYNOPSIS
        Applies service state changes in sandbox mode.
    .DESCRIPTION
        Simulates service changes in the sandbox context.
    .PARAMETER Desired
        Desired service state hashtable
    .OUTPUTS
        Hashtable with Status and Changed arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    # Module already imported at module scope
    
    if (-not (Test-SandboxActive)) {
        throw "Not in sandbox mode"
    }
    
    $currentState = Get-SandboxState -Provider "Service"
    
    $results = @{
        Status = "Success"
        Changed = @()
    }
    
    foreach ($service in $Desired.Keys) {
        $currentStartup = if ($currentState[$service]) { $currentState[$service].Startup } else { $null }
        $desiredStartup = $Desired[$service].Startup
        
        if ($currentStartup -ne $desiredStartup) {
            $results.Changed += @{
                Name = $service
                OldStartup = $currentStartup
                NewStartup = $desiredStartup
            }
            $currentState[$service] = @{ Startup = $desiredStartup }
        }
    }
    
    Set-SandboxState -Provider "Service" -State $currentState
    Add-SandboxChange -Provider "Service" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Get-ServiceState"
    "Get-AllServiceStates"
    "Test-ServiceState"
    "Set-ServiceState"
    "Export-ServiceState"
    "Compare-ServiceState"
    "Get-ServiceMockState"
    "Set-ServiceMockState"
    "Invoke-ServiceSandboxApply"
)
