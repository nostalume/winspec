# providers/service.psm1 - Declarative Windows services provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\windows.psm1")
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -ErrorAction SilentlyContinue

$servicePolicy = Import-PowerShellDataFile `
(Join-Path $PSScriptRoot 'service-policy.psd1')
$WindowsConfigurableServices = @($servicePolicy.Services)

function Test-ServiceManaged {
    param([Parameter(Mandatory)][string]$Name)

    return $WindowsConfigurableServices -contains $Name
}

function Resolve-ManagedServiceNames {
    param([string[]]$ServiceNames)

    if (-not $ServiceNames -or $ServiceNames.Count -eq 0) {
        return $WindowsConfigurableServices
    }

    return @($ServiceNames | Where-Object { Test-ServiceManaged -Name $_ })
}

function Get-ProviderInfo {
    return @{
        Name = "Service"
        Type = "Declarative"
    }
}
function Convert-ServiceObject {
    param($Service)

    [pscustomobject]@{
        Name = $Service.Name.ToString()
        State = $Service.Status.ToString()
        Startup = $Service.StartType.ToString()
    }
}

function ConvertTo-ServiceSpecState {
    param($State)

    if ($null -eq $State) { return $null }
    switch ($State.ToString().ToLowerInvariant()) {
        "running" { return "running" }
        "stopped" { return "stopped" }
        default { return $State }
    }
}

function ConvertTo-ServiceSpecStartup {
    param($Startup)

    if ($null -eq $Startup) { return $null }
    switch ($Startup.ToString().ToLowerInvariant()) {
        "auto" { return "automatic" }
        "automatic" { return "automatic" }
        "manual" { return "manual" }
        "disabled" { return "disabled" }
        default { return $Startup }
    }
}

function Get-ServiceState {
    [CmdletBinding()]
    param(
        [string[]]$ServiceNames
    )

    $services = Get-Service -ErrorAction SilentlyContinue

    Write-Verbose "Services: $($services | Format-Table | Out-String)"
    if ($ServiceNames) {
        $services = $services | Where-Object Name -In $ServiceNames
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
            return $false
        }

        $target = $Desired[$name]

        if ($target.State -and (ConvertTo-ServiceSpecState $current.State) -ne (ConvertTo-ServiceSpecState $target.State)) {
            return $false
        }

        if ($target.Startup -and (ConvertTo-ServiceSpecStartup $current.Startup) -ne (ConvertTo-ServiceSpecStartup $target.Startup)) {
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
        return @{ Status = "Error"; Reason = "RequiresAdministrator"; Message = "Service changes require Administrator privileges" }
    }

    $states = Get-ServiceState -ServiceNames $Desired.Keys
    $results = @{}

    foreach ($name in $Desired.Keys) {

        if (-not (Test-ServiceManaged -Name $name)) {
            $results[$name] = @{ Status = "Error"; Reason = "ServiceNotManaged"; Message = "Service is not managed by WinSpec" }
            continue
        }

        $current = $states[$name]

        if (-not $current) {
            $results[$name] = @{ Status = "Error"; Message = "Service not found" }
            continue
        }

        $target = $Desired[$name]
        $result = @{}

        # --- Startup ---
        if ($target.Startup -and (ConvertTo-ServiceSpecStartup $current.Startup) -ne (ConvertTo-ServiceSpecStartup $target.Startup)) {
            if ($PSCmdlet.ShouldProcess($name, "Startup -> $($target.Startup)")) {
                try {
                    Set-Service -Name $name -StartupType $target.Startup -ErrorAction Stop
                    $result.Startup = @{ Status = "Applied" }
                }
                catch {
                    $result.Startup = @{ Status = "Error"; Message = $_.Exception.Message }
                }
            }
        }

        # --- State ---
        if ($target.State) {
            $shouldRun = (ConvertTo-ServiceSpecState $target.State) -eq "running"
            $isRunning = (ConvertTo-ServiceSpecState $current.State) -eq "running"

            if ($shouldRun -eq $isRunning) {
                $results[$name] = $result
                continue
            }

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

                $result.State = @{ Status = "Applied" }

            }
            catch {
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

    $ServiceNames = Resolve-ManagedServiceNames -ServiceNames $ServiceNames

    Write-Verbose "Exporting service state for: $($ServiceNames -join ', ')"

    $states = Get-ServiceState -ServiceNames $ServiceNames
    $result = @{}

    foreach ($name in $states.Keys) {
        $svc = $states[$name]

        $result[$name] = @{
            State = $svc.State
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

    $diffs = [System.Collections.ArrayList]::new()

    foreach ($name in $Desired.Keys) {
        $path = "Service.$name"
        $systemConfig = $System[$name]
        $desiredConfig = $Desired[$name]

        if (-not $systemConfig) {
            [void]$diffs.Add([pscustomobject]@{
                    Type = "Added"
                    Path = $path
                    SystemValue = $null
                    ConfigValue = $desiredConfig
                })

            continue
        }

        $stateEqual = (ConvertTo-ServiceSpecState $systemConfig.State) -eq (ConvertTo-ServiceSpecState $desiredConfig.State)
        $startupEqual = (ConvertTo-ServiceSpecStartup $systemConfig.Startup) -eq (ConvertTo-ServiceSpecStartup $desiredConfig.Startup)

        if ($stateEqual -and $startupEqual) {
            [void]$diffs.Add([pscustomobject]@{
                    Type = "Equal"
                    Path = $path
                    SystemValue = $systemConfig
                    ConfigValue = $desiredConfig
                })

            continue
        }

        if (-not $stateEqual) {
            [void]$diffs.Add([pscustomobject]@{
                    Type = "Changed"
                    Path = "$path.State"
                    SystemValue = $systemConfig.State
                    ConfigValue = $desiredConfig.State
                })
        }

        if (-not $startupEqual) {
            [void]$diffs.Add([pscustomobject]@{
                    Type = "Changed"
                    Path = "$path.Startup"
                    SystemValue = $systemConfig.Startup
                    ConfigValue = $desiredConfig.Startup
                })
        }
    }

    return $diffs.ToArray()
}

function Invoke-ServiceSandbox {
    <#
.SYNOPSIS
Simulates Windows service configuration changes inside sandbox.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    if (-not (Test-SandboxActive)) {
        throw "Sandbox not active"
    }

    $results = @{
        Status = "Success"
        Changed = @()
    }

    Update-SandboxState "Service" {

        param($state)

        if (-not $state) { $state = @{} }
        foreach ($service in $Desired.Keys) {
            if (-not $state[$service]) { $state[$service] = @{} }

            foreach ($field in @("State", "Startup")) {
                $desiredValue = $Desired[$service][$field]
                if ($null -eq $desiredValue) { continue }

                $currentValue = $state[$service][$field]
                if ($currentValue -eq $desiredValue) { continue }

                $results.Changed += @{
                    Name = $service
                    Field = $field
                    OldValue = $currentValue
                    NewValue = $desiredValue
                }
                $state[$service][$field] = $desiredValue
            }
        }

        return $state
    }

    Update-SandboxChanges "Service" "Apply" $results

    return $results
}

function Invoke-ServiceSandboxApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Desired
    )

    return Invoke-ServiceSandbox -Desired $Desired
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Get-ServiceState"
    "Test-ServiceManaged"
    "Resolve-ManagedServiceNames"
    "ConvertTo-ServiceSpecState"
    "ConvertTo-ServiceSpecStartup"
    "Test-ServiceState"
    "Set-ServiceState"
    "Export-ServiceState"
    "Compare-ServiceState"
    "Invoke-ServiceSandbox"
    "Invoke-ServiceSandboxApply"
)
