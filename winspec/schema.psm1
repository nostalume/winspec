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
    
    # Validate Trigger structure
    if ($Spec.Trigger) {
        # Check if Trigger is an array
        if ($Spec.Trigger -isnot [array]) {
            $errors += "Trigger must be an array of hashtables"
        }
        else {
            foreach ($trigger in $Spec.Trigger) {
                # Check each trigger entry is a hashtable with Name field
                if ($trigger -isnot [hashtable]) {
                    $errors += "Each trigger entry must be a hashtable"
                    continue
                }
                if (-not $trigger.Name) {
                    $errors += "Each trigger entry must have a 'Name' field"
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
