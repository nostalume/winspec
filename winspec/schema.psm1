# schema.psm1 - Type definitions and validation for WinSpec

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "registry-maps.psm1") -Force

enum ProviderType {
    Declarative
    Trigger
}

# Specification schema definition
$Script:SpecSchema = @{
    Name        = @{ Type = "string"; Required = $false }
    Description = @{ Type = "string"; Required = $false }
    Import      = @{ Type = "array"; Required = $false }
    Providers   = @{ Type = "array"; Required = $false }
    Registry    = @{ Type = "hashtable"; Required = $false }
    Service     = @{ Type = "hashtable"; Required = $false }
    Feature     = @{ Type = "hashtable"; Required = $false }
    Trigger     = @{ Type = "array"; Required = $false }
    TriggerConfig = @{ Type = "hashtable"; Required = $false }
}

function Get-SpecSchema {
    return $Script:SpecSchema
}

function Test-SpecSchema {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Spec
    )
    
    $errors = @()
    
    # Validate known keys
    $validKeys = $Script:SpecSchema.Keys
    foreach ($key in $Spec.Keys) {
        if ($key -notin $validKeys) {
            $errors += "Unknown specification key: '$key'"
        }
    }
    
    # Validate Registry categories, properties, and mapped values
    if ($Spec.Registry) {
        $registryMaps = Get-RegistryMaps
        $validCategories = $registryMaps.Keys
        foreach ($category in $Spec.Registry.Keys) {
            if ($category -notin $validCategories) {
                $errors += "Unknown Registry category: '$category'. Valid: $($validCategories -join ', ')"
                continue
            }

            $categorySpec = $Spec.Registry[$category]
            if ($categorySpec -isnot [hashtable]) {
                $errors += "Registry category '$category' must be a hashtable"
                continue
            }

            $categoryMap = $registryMaps[$category]
            $validProperties = $categoryMap.Properties.Keys
            foreach ($property in $categorySpec.Keys) {
                if ($property -notin $validProperties) {
                    $errors += "Unknown Registry property: '$category.$property'. Valid: $($validProperties -join ', ')"
                    continue
                }

                $propertyMap = $categoryMap.Properties[$property]
                $value = $categorySpec[$property]

                if ($propertyMap.AllowedValues) {
                    $matched = $false
                    foreach ($allowed in $propertyMap.AllowedValues) {
                        if ($allowed -eq $value) {
                            $matched = $true
                            break
                        }
                    }
                    if (-not $matched) {
                        $errors += "Registry property '$category.$property' has invalid value '$value'. Valid: $($propertyMap.AllowedValues -join ', ')"
                    }
                    continue
                }

                if ($propertyMap.Type -eq "DWord" -and $value -isnot [int]) {
                    $errors += "Registry property '$category.$property' must be an integer for DWord values"
                }
                elseif ($propertyMap.Type -eq "String" -and $value -isnot [string]) {
                    $errors += "Registry property '$category.$property' must be a string"
                }
            }
        }
    }

    # Validate Feature structure
    if ($Spec.Feature) {
        foreach ($feature in $Spec.Feature.Keys) {
            $value = $Spec.Feature[$feature]
            if ($value -notin @("enabled", "disabled")) {
                $errors += "Feature '$feature' has invalid value '$value'. Must be 'enabled' or 'disabled'"
            }
        }
    }
    
    # Validate Service structure
    if ($Spec.Service) {
        foreach ($service in $Spec.Service.Keys) {
            $svcConfig = $Spec.Service[$service]
            if ($svcConfig.State -and $svcConfig.State -notin @("running", "stopped")) {
                $errors += "Service '$service' has invalid State '$($svcConfig.State)'. Must be 'running' or 'stopped'"
            }
            if ($svcConfig.Startup -and $svcConfig.Startup -notin @("automatic", "manual", "disabled")) {
                $errors += "Service '$service' has invalid Startup '$($svcConfig.Startup)'. Must be 'automatic', 'manual', or 'disabled'"
            }
        }
    }
    
    # Validate Trigger selection and TriggerConfig parameter maps
    if ($Spec.ContainsKey("Trigger")) {
        $triggerSelection = $Spec.Trigger
        if ($triggerSelection -is [string]) {
            if ([string]::IsNullOrWhiteSpace($triggerSelection)) {
                $errors += "Trigger names must not be empty"
            }
        }
        elseif ($triggerSelection -is [array]) {
            foreach ($triggerName in $triggerSelection) {
                if ($triggerName -isnot [string] -or [string]::IsNullOrWhiteSpace($triggerName)) {
                    $errors += "Trigger must be a string or an array of trigger-name strings"
                    break
                }
            }
        }
        else {
            $errors += "Trigger must be a string or an array of trigger-name strings"
        }
    }

    if ($Spec.ContainsKey("TriggerConfig")) {
        if ($Spec.TriggerConfig -isnot [hashtable]) {
            $errors += "TriggerConfig must be a hashtable keyed by trigger name"
        }
        else {
            foreach ($triggerName in $Spec.TriggerConfig.Keys) {
                if ([string]::IsNullOrWhiteSpace([string]$triggerName)) {
                    $errors += "TriggerConfig keys must be non-empty trigger names"
                    continue
                }
                if ($Spec.TriggerConfig[$triggerName] -isnot [hashtable]) {
                    $errors += "TriggerConfig '$triggerName' must be a hashtable of Invoke-Trigger parameters"
                }
            }
        }
    }
    
    if ($errors.Count -gt 0) {
        # Try to log errors, but continue if logging is not available
        try {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Level "ERROR" -Message "Specification validation failed:"
                foreach ($err in $errors) {
                    Write-Log -Level "ERROR" -Message "  - $err"
                }
            }
        } catch { }
        return $false
    }
    
    return $true
}

Export-ModuleMember -Function @(
    "Get-SpecSchema"
    "Test-SpecSchema"
)
