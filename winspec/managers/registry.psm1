# providers/registry.psm1 - Declarative registry provider

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\schema.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\registry-maps.psm1") -Force

# Import sandbox module once at module load time (consistent with service.psm1)
Import-Module (Join-Path $PSScriptRoot "..\sandbox.psm1") -Force -ErrorAction SilentlyContinue

function Get-ProviderInfo {
    return @{
        Name = "Registry"
        Type = "Declarative"
    }
}

function Get-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Property,
        
        [Parameter(Mandatory = $false)]
        $Default = $null
    )
    
    try {
        $result = Get-ItemProperty -Path $Path -Name $Property -ErrorAction SilentlyContinue
        if ($result) {
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
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Property,
        
        [Parameter(Mandatory = $true)]
        [string]$Type,
        
        [Parameter(Mandatory = $true)]
        $Value
    )
    
    # Create path if it doesn't exist
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    
    Set-ItemProperty -Path $Path -Name $Property -Type $Type -Value $Value -Force
}

function Get-RegistryStateFromMap {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$StateMap,
        
        [Parameter(Mandatory = $true)]
        $RegistryValue
    )
    
    $reverseMap = @{}
    foreach ($key in $StateMap.Keys) {
        $reverseMap[$StateMap[$key]] = $key
    }
    
    return $reverseMap[$RegistryValue]
}

# Helper function to build reverse map (used by Export-RegistryState to avoid duplication)
function New-ReverseStateMap {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$StateMap
    )
    
    $reverseMap = @{}
    foreach ($key in $StateMap.Keys) {
        $reverseMap[$StateMap[$key].ToString()] = $key
    }
    return $reverseMap
}

function Test-RegistryState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $registryMap = Get-RegistryMaps
    $allInDesiredState = $true
    
    foreach ($category in $Desired.Keys) {
        $catConfig = $registryMap[$category]
        if (-not $catConfig) {
            Write-Log -Level "WARN" -Message "Unknown registry category: $category"
            continue
        }
        
        foreach ($propName in $Desired[$category].Keys) {
            $propConfig = $catConfig.Properties[$propName]
            if (-not $propConfig) {
                Write-Log -Level "WARN" -Message "Unknown property: $propName in $category"
                continue
            }
            
            $currentValue = Get-RegistryValue -Path $catConfig.Path -Property $propConfig.Name -Default $propConfig.Default
            
            if ($propConfig.Map) {
                $currentState = Get-RegistryStateFromMap -StateMap $propConfig.Map -RegistryValue $currentValue
            }
            else {
                $currentState = $currentValue
            }
            
            $desiredValue = $Desired[$category][$propName]
            
            if ($currentState -ne $desiredValue) {
                $allInDesiredState = $false
            }
        }
    }
    
    return $allInDesiredState
}

function Set-RegistryState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Desired
    )
    
    $results = @{}
    $registryMap = Get-RegistryMaps
    
    foreach ($category in $Desired.Keys) {
        $catConfig = $registryMap[$category]
        if (-not $catConfig) {
            Write-Log -Level "WARN" -Message "Unknown registry category: $category"
            $results[$category] = @{ Status = "Error"; Message = "Unknown category" }
            continue
        }
        
        Write-Log -Level "INFO" -Message "Processing category: $category"
        $categoryResults = @{}
        
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
    <#
    .SYNOPSIS
        Exports the current registry state for bidirectional sync.
    .DESCRIPTION
        Captures current registry settings based on the registry maps.
        Only exports values that are defined in the registry maps.
    .OUTPUTS
        Hashtable with registry categories and their values
    #>
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
                # Apply reverse map if exists (convert registry value to friendly value)
                # Use helper function to avoid duplicate reverse map logic
                if ($propDef.Map) {
                    $reverseMap = New-ReverseStateMap -StateMap $propDef.Map
                    if ($reverseMap.ContainsKey($value.ToString())) {
                        $value = $reverseMap[$value.ToString()]
                    }
                }
                
                $categoryResult[$propName] = $value
                $hasValues = $true
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
        returns differences (changed values).
    .PARAMETER System
        Current system state (from Export-RegistryState)
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
    
    foreach ($categoryName in $Desired.Keys) {
        $desiredCategory = $Desired[$categoryName]
        $systemCategory = if ($System.ContainsKey($categoryName)) { $System[$categoryName] } else { @{} }
        
        foreach ($propName in $desiredCategory.Keys) {
            $desiredValue = $desiredCategory[$propName]
            $systemValue = if ($systemCategory.ContainsKey($propName)) { $systemCategory[$propName] } else { $null }
            
            $path = "Registry.$categoryName.$propName"
            
            if ($null -eq $systemValue) {
                # Property not in system
                $differences += @{
                    Type = "Added"
                    Path = $path
                    SystemValue = $null
                    ConfigValue = $desiredValue
                }
            }
            elseif ($systemValue -ne $desiredValue) {
                # Value changed
                $differences += @{
                    Type = "Changed"
                    Path = $path
                    SystemValue = $systemValue
                    ConfigValue = $desiredValue
                }
            }
            # Skip "Equal" entries - only Added, Changed, Removed for cleaner diffs
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
        Status = "Success"
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
                    Key = $key
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
