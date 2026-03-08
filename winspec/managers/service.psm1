# providers/service.psm1 - Declarative Windows services provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{
        Name = "Service"
        Type = "Declarative"
    }
}

function Get-ServiceState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service) {
            $startup = (Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).StartMode
            return @{
                State   = $service.Status.ToString().ToLower()
                Startup = $startup.ToLower()
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-ServiceState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $allInDesiredState = $true
    
    foreach ($serviceName in $Desired.Keys) {
        $desiredConfig = $Desired[$serviceName]
        $currentState = Get-ServiceState -ServiceName $serviceName
        
        if ($null -eq $currentState) {
            Write-Log -Level "WARN" -Message "Service not found: $serviceName"
            continue
        }
        
        if ($desiredConfig.State -and $currentState.State -ne $desiredConfig.State) {
            $allInDesiredState = $false
        }
        
        if ($desiredConfig.Startup -and $currentState.Startup -ne $desiredConfig.Startup) {
            $allInDesiredState = $false
        }
    }
    
    return $allInDesiredState
}

function Set-ServiceState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    
    foreach ($serviceName in $Desired.Keys) {
        $desiredConfig = $Desired[$serviceName]
        $currentState = Get-ServiceState -ServiceName $serviceName
        
        if ($null -eq $currentState) {
            Write-Log -Level "ERROR" -Message "Service not found: $serviceName"
            $results[$serviceName] = @{ Status = "Error"; Message = "Service not found" }
            continue
        }
        
        $serviceResults = @{}
        
        # Handle Startup configuration
        if ($desiredConfig.Startup) {
            if ($currentState.Startup -eq $desiredConfig.Startup) {
                Write-LogOk -Name "$serviceName.Startup" -DesiredValue $desiredConfig.Startup
                $serviceResults["Startup"] = @{ Status = "AlreadySet" }
            }
            else {
                Write-LogChange -Name "$serviceName.Startup" -CurrentValue $currentState.Startup -DesiredValue $desiredConfig.Startup
                
                if ($PSCmdlet.ShouldProcess("$serviceName Startup", "Set to '$($desiredConfig.Startup)'")) {
                    try {
                        Set-Service -Name $serviceName -StartupType $desiredConfig.Startup -ErrorAction Stop
                        Write-LogApplied -Name "$serviceName.Startup" -DesiredValue $desiredConfig.Startup
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
            $isRunning = $currentStateValue -eq "running"
            $shouldBeRunning = $desiredState -eq "running"
            
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
        $interestingServices = Get-Service | Where-Object { 
            $_.StartType -ne 'Automatic' -or $_.Status -ne 'Running'
        } | Select-Object -ExpandProperty Name -First 50
        $ServiceNames = $interestingServices
    }
    
    foreach ($serviceName in $ServiceNames) {
        $state = Get-ServiceState -ServiceName $serviceName
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
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
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
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
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
    
    Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue
    
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
    "Test-ServiceState"
    "Set-ServiceState"
    "Export-ServiceState"
    "Compare-ServiceState"
    "Get-ServiceMockState"
    "Set-ServiceMockState"
    "Invoke-ServiceSandboxApply"
)
