# providers/service.psm1 - Declarative Windows services provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1")
Import-Module (Join-Path $PSScriptRoot "..\utils.psm1")
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -ErrorAction SilentlyContinue

$WindowsConfigurableServices = @(
    "WinDefend"
    "WdNisSvc"
    "SecurityHealthService"

    "DiagTrack"
    "dmwappushservice"

    "WSearch"

    "wuauserv"
    "UsoSvc"
    "BITS"

    "Dnscache"
    "Dhcp"
    "NlaSvc"

    "RemoteRegistry"
    "TermService"
    "WinRM"

    "SysMain"
    "WerSvc"

    "Spooler"
)

function Get-ProviderInfo {
    return @{
        Name = "Service"
        Type = "Declarative"
    }
}
function Convert-ServiceObject {
    param($Service)

    [pscustomobject]@{
        Name    = $Service.Name.ToString()
        State   = $Service.Status.ToString()
        Startup = $Service.StartType.ToString()
    }
}

function Get-ServiceState {
    [CmdletBinding()]
    param(
        [string[]]$ServiceNames
    )

    $services = Get-Service -ErrorAction SilentlyContinue
    
    Write-Host "Services: $($servicesa | Format-Table | Out-String)"
    if ($ServiceNames) {
        $services = $services | Where-Object Name -in $ServiceNames
    }

    $result = @{}

    foreach ($svc in $services) {
        $result[$svc.Name] = Convert-ServiceObject $svc
    }

    return $result
}

function Test-ServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    $states = Get-ServiceState -ServiceNames $Desired.Keys

    foreach ($name in $Desired.Keys) {
        $current = $states[$name]

        if (-not $current) {
            Write-Log -Level WARN -Message "Service not found: $name"
            continue
        }

        $target = $Desired[$name]

        if ($target.State -and $current.State -ne $target.State) {
            return $false
        }

        if ($target.Startup -and $current.Startup -ne $target.Startup) {
            return $false
        }
    }

    return $true
}

function Set-ServiceState {

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    if (-not (Test-IsAdmin)) {
        return Invoke-AdminCommand {
            Set-ServiceState -Desired $using:Desired
        }
    }

    $states = Get-ServiceState -ServiceNames $Desired.Keys
    $results = @{}

    foreach ($name in $Desired.Keys) {

        $current = $states[$name]

        if (-not $current) {
            Write-Log -Level ERROR -Message "Service not found: $name"
            $results[$name] = @{ Status = "Error"; Message = "Service not found" }
            continue
        }

        $target = $Desired[$name]
        $result = @{}

        # --- Startup ---
        if ($target.Startup -and $current.Startup -ne $target.Startup) {
            Write-LogChange -Name "$name.Startup" `
                -CurrentValue $current.Startup `
                -DesiredValue $target.Startup

            if ($PSCmdlet.ShouldProcess($name, "Startup -> $($target.Startup)")) {
                try {
                    Set-Service -Name $name -StartupType $target.Startup -ErrorAction Stop
                    Write-LogApplied -Name "$name.Startup" -DesiredValue $target.Startup
                    $result.Startup = @{ Status = "Applied" }
                }
                catch {
                    Write-LogError -Name "$name.Startup" -Details $_.Exception.Message
                    $result.Startup = @{ Status = "Error"; Message = $_.Exception.Message }
                }
            }
        }

        # --- State ---
        if ($target.State) {
            $shouldRun = $target.State -eq "Running"
            $isRunning = $current.State -eq "Running"

            if ($shouldRun -eq $isRunning) {
                $results[$name] = $result
                continue
            }

            Write-LogChange -Name "$name.State" `
                -CurrentValue $current.State `
                -DesiredValue $target.State

            if (-not $PSCmdlet.ShouldProcess($name, "State -> $($target.State)")) {
                $results[$name] = $result
                continue
            }

            try {

                if ($shouldRun) {
                    Start-Service $name -ErrorAction Stop
                }
                else {
                    Stop-Service $name -Force -ErrorAction Stop
                }

                Write-LogApplied -Name "$name.State" -DesiredValue $target.State
                $result.State = @{ Status = "Applied" }

            }
            catch {
                Write-LogError -Name "$name.State" -Details $_.Exception.Message
                $result.State = @{ Status = "Error"; Message = $_.Exception.Message }
            }
        }

        $results[$name] = $result
    }

    return $results
}

function Export-ServiceState {
    [CmdletBinding()]
    param(
        [string[]]$ServiceNames
    )

    if (-not $ServiceNames) {
        $ServiceNames = $WindowsConfigurableServices
    }
    
    Write-Host "$ServiceNames"
    
    $states = Get-ServiceState -ServiceNames $ServiceNames
    $result = @{}

    foreach ($name in $states.Keys) {
        $svc = $states[$name]

        $result[$name] = @{
            State   = $svc.State
            Startup = $svc.Startup
        }
    }

    return $result
}

function Compare-ServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$System,

        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    $diffs = @()

    foreach ($name in $Desired.Keys) {
        $path = "Service.$name"
        $system = $System[$name]
        $config = $Desired[$name]

        if (-not $system) {

            $diffs += @{
                Type        = "Added"
                Path        = $path
                SystemValue = $null
                ConfigValue = $config
            }

            continue
        }

        if ($system.State -eq $config.State -and
            $system.Startup -eq $config.Startup) {

            $diffs += @{
                Type        = "Equal"
                Path        = $path
                SystemValue = $system
                ConfigValue = $config
            }

            continue
        }

        $diffs += @{
            Type        = "Changed"
            Path        = $path
            SystemValue = $system
            ConfigValue = $config
        }
    }

    foreach ($name in $System.Keys) {
        if ($Desired.ContainsKey($name)) { continue }

        $diffs += @{
            Type        = "Removed"
            Path        = "Service.$name"
            SystemValue = $System[$name]
            ConfigValue = $null
        }
    }

    return $diffs
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
        Status  = "Success"
        Changed = @()
    }
    
    foreach ($service in $Desired.Keys) {
        $currentStartup = if ($currentState[$service]) { $currentState[$service].Startup } else { $null }
        $desiredStartup = $Desired[$service].Startup
        
        if ($currentStartup -ne $desiredStartup) {
            $results.Changed += @{
                Name       = $service
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
