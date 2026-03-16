# providers/registry.psm1 - Declarative registry provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1")
Import-Module (Join-Path $PSScriptRoot "..\schema.psm1")
Import-Module (Join-Path $PSScriptRoot "..\registry-maps.psm1")
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -ErrorAction SilentlyContinue

function Get-ProviderInfo {
    return @{
        Name = "Registry"
        Type = "Declarative"
    }
}

function Get-ProviderInfo {
    return @{ Name = "Registry"; Type = "Declarative" }
}

function Get-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Property,
        [Parameter()]$Default = $null
    )

    try {
        $result = Get-ItemProperty -Path $Path -Name $Property -ErrorAction SilentlyContinue
        if ($null -ne $result) {
            return $result.$Property
        }

        return $Default
    }
    catch {
        return $Default
    }
}

function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Property,
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] $Value
    )

    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Property -Type $Type -Value $Value -Force
}

function Get-RegistryStateFromMap {
    param (
        [Parameter(Mandatory)] [hashtable]$StateMap,
        [Parameter(Mandatory)] $RegistryValue
    )

    return $StateMap[$RegistryValue]
}

function New-ReverseStateMap {
    param (
        [Parameter(Mandatory)] [hashtable]$StateMap
    )

    $reverseMap = @{}
    foreach ($key in $StateMap.Keys) {
        $reverseMap[$StateMap[$key].ToString()] = $key
    }
    return $reverseMap
}

function Test-RegistryState {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [hashtable]$Desired)

    $registryMap = Get-RegistryMaps
    $allInDesiredState = $true

    foreach ($category in $Desired.Keys) {
        if (-not $registryMap.ContainsKey($category)) {
            Write-Log -Level "WARN" -Message "Unknown registry category: $category"
            continue
        }

        $catConfig = $registryMap[$category]
        foreach ($propName in $Desired[$category].Keys) {
            if (-not $catConfig.Properties.ContainsKey($propName)) {
                Write-Log -Level "WARN" -Message "Unknown property: $propName in $category"
                continue
            }

            $propConfig = $catConfig.Properties[$propName]
            $currentValue = Get-RegistryValue -Path $catConfig.Path -Property $propConfig.Name -Default $propConfig.Default
            if ($propConfig.Map) {
                $currentState = Get-RegistryStateFromMap -StateMap $propConfig.Map -RegistryValue $currentValue
            }
            else {
                $currentState = $currentValue
            }
            if ($currentState -ne $Desired[$category][$propName]) {
                $allInDesiredState = $false
            }
        }
    }

    return $allInDesiredState
}

function Set-RegistryState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ([Parameter(Mandatory)] [hashtable]$Desired)

    $registryMap = Get-RegistryMaps
    $results = @{}

    foreach ($category in $Desired.Keys) {
        $categoryResults = @{}
        $catConfig = $registryMap[$category]

        if (-not $catConfig) {
            Write-Log -Level "WARN" -Message "Unknown registry category: $category"
            $results[$category] = @{ Status = "Error"; Message = "Unknown category" }
            continue
        }

        Write-Log -Level "INFO" -Message "Processing category: $category"

        foreach ($propName in $Desired[$category].Keys) {
            $propConfig = $catConfig.Properties[$propName]

            if (-not $propConfig) {
                Write-Log -Level "WARN" -Message "Unknown property: $propName in $category"
                $categoryResults[$propName] = @{ Status = "Error"; Message = "Unknown property" }
                continue
            }

            $desiredValue = $Desired[$category][$propName]
            $currentRaw = Get-RegistryValue -Path $catConfig.Path -Property $propConfig.Name -Default $propConfig.Default

            if ($propConfig.Map) {
                $currentState = Get-RegistryStateFromMap -StateMap $propConfig.Map -RegistryValue $currentRaw
                $valueToSet = $propConfig.Map[$desiredValue]
            }
            else {
                $currentState = $currentRaw
                $valueToSet = $desiredValue
            }

            if ($currentState -eq $desiredValue) {
                Write-LogOk -Name "$category.$propName" -DesiredValue $desiredValue
                $categoryResults[$propName] = @{ Status = "AlreadySet"; Value = $desiredValue }
                continue
            }

            Write-LogChange -Name "$category.$propName" -CurrentValue $currentState -DesiredValue $desiredValue

            if ($PSCmdlet.ShouldProcess("$($catConfig.Path)\$($propConfig.Name)", "Set to '$desiredValue'")) {
                try {
                    Set-RegistryValue -Path $catConfig.Path -Property $propConfig.Name -Type $propConfig.Type -Value $valueToSet
                    Write-LogApplied -Name "$category.$propName" -DesiredValue $desiredValue
                    $categoryResults[$propName] = @{ Status = "Applied"; Value = $desiredValue }
                }
                catch {
                    Write-LogError -Name "$category.$propName" -Details $_.Exception.Message
                    $categoryResults[$propName] = @{ Status = "Error"; Message = $_.Exception.Message }
                }
            }
        }

        $results[$category] = $categoryResults
    }

    return $results
}

function Export-RegistryState {
    [CmdletBinding()]
    param()

    $registryMaps = Get-RegistryMaps
    $result = @{}

    foreach ($categoryName in $registryMaps.Keys) {
        $category = $registryMaps[$categoryName]
        $categoryResult = @{}
        $hasValues = $false

        foreach ($propName in $category.Properties.Keys) {
            $propDef = $category.Properties[$propName]
            $value = Get-RegistryValue -Path $category.Path -Property $propDef.Name

            if ($null -ne $value) {
                if ($propDef.Map) {
                    $reverseMap = New-ReverseStateMap -StateMap $propDef.Map
                    if ($reverseMap.ContainsKey($value.ToString())) {
                        $value = $reverseMap[$value.ToString()]
                    }
                }

                $categoryResult[$propName] = $value
                $hasValues = $true

                Write-Debug "Registry Value Extraction: $propName = $value"
            }
        }

        if ($hasValues) {
            $result[$categoryName] = $categoryResult
        }
    }

    return $result
}

function Compare-RegistryState {
    <#
    .SYNOPSIS
        Compares system registry state with desired configuration.
    .DESCRIPTION
        Compares current registry values with desired configuration and
        returns differences (added or changed values).
    .PARAMETER System
        Current system state (from Export-RegistryState)
    .PARAMETER Desired
        Desired configuration state
    .OUTPUTS
        Array of PSCustomObject with Type, Path, SystemValue, ConfigValue
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$System,
        [Parameter(Mandatory)] [hashtable]$Desired
    )

    $differences = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($categoryName in $Desired.Keys) {
        $desiredCategory = $Desired[$categoryName]
        if ($System[$categoryName]) {
            $systemCategory = $System[$categoryName]
        }
        else {
            $systemCategory = @{}
        }

        foreach ($propName in $desiredCategory.Keys) {
            $desiredValue = $desiredCategory[$propName]
            $systemValue = $systemCategory[$propName]

            if ($systemValue -eq $desiredValue) { continue }

            $type = if ($null -eq $systemValue) { "Added" } else { "Changed" }
            $path = "Registry.$categoryName.$propName"

            $differences.Add([PSCustomObject]@{
                    Type        = $type
                    Path        = $path
                    SystemValue = $systemValue
                    ConfigValue = $desiredValue
                })
        }
    }

    return $differences
}

function Get-RegistryMockState {
    <#
    .SYNOPSIS
        Gets the registry mock state from sandbox.
    .DESCRIPTION
        Returns the current registry state from the sandbox context.
    .OUTPUTS
        Hashtable with registry categories
    #>
    [CmdletBinding()]
    param()
    
    # Module already imported at module scope - no need to import again
    
    if (Test-SandboxActive) {
        return Get-SandboxState -Provider "Registry"
    }
    
    # Not in sandbox - return empty default
    return @{}
}

function Set-RegistryMockState {
    <#
    .SYNOPSIS
        Sets the registry mock state in sandbox.
    .DESCRIPTION
        Updates the current registry state in the sandbox context.
    .PARAMETER State
        Hashtable with registry categories
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )
    
    # Module already imported at module scope
    
    if (Test-SandboxActive) {
        Set-SandboxState -Provider "Registry" -State $State
    }
}

function Invoke-RegistrySandboxApply {
    <#
    .SYNOPSIS
        Applies registry state changes in sandbox mode.
    .DESCRIPTION
        Simulates registry changes in the sandbox context.
    .PARAMETER Desired
        Desired registry state hashtable
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
    
    $currentState = Get-SandboxState -Provider "Registry"
    
    $results = @{
        Status  = "Success"
        Changed = @()
    }
    
    foreach ($category in $Desired.Keys) {
        if (-not $currentState.ContainsKey($category)) {
            $currentState[$category] = @{}
        }
        
        foreach ($key in $Desired[$category].Keys) {
            $oldValue = $currentState[$category][$key]
            $newValue = $Desired[$category][$key]
            
            if ($oldValue -ne $newValue) {
                $results.Changed += @{
                    Category = $category
                    Key      = $key
                    OldValue = $oldValue
                    NewValue = $newValue
                }
                $currentState[$category][$key] = $newValue
            }
        }
    }
    
    # Update sandbox state
    Set-SandboxState -Provider "Registry" -State $currentState
    
    # Record change
    Add-SandboxChange -Provider "Registry" -Change $results
    
    return $results
}

Export-ModuleMember -Function @(
    "Get-ProviderInfo"
    "Get-RegistryValue"
    "Set-RegistryValue"
    "Get-RegistryStateFromMap"
    "New-ReverseStateMap"
    "Test-RegistryState"
    "Set-RegistryState"
    "Export-RegistryState"
    "Compare-RegistryState"
    "Get-RegistryMockState"
    "Set-RegistryMockState"
    "Invoke-RegistrySandboxApply"
)
