# schema.psm1 - Type definitions and validation for WinSpec

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Global
Import-Module (Join-Path $PSScriptRoot "registry-maps.psm1") -Global

# Provider type enumeration
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
    Scoop       = @{ Type = "hashtable"; Required = $false }
    Winget      = @{ Type = "hashtable"; Required = $false }
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
        [hashtable]$Config
    )
    
    $errors = @()
    
    # Validate known keys
    $validKeys = $Script:SpecSchema.Keys
    foreach ($key in $Config.Keys) {
        if ($key -notin $validKeys) {
            $errors += "Unknown specification key: '$key'"
        }
    }
    
    # Validate Registry keys are known categories
    if ($Config.Registry) {
        $registryMaps = Get-RegistryMaps
        $validCategories = $registryMaps.Keys
        foreach ($category in $Config.Registry.Keys) {
            if ($category -notin $validCategories) {
                $errors += "Unknown Registry category: '$category'. Valid: $($validCategories -join ', ')"
            }
        }
    }
    
    # Validate Package/Scoop structure
    if ($Config.Scoop) {
        if ($Config.Scoop.Installed -and -not ($Config.Scoop.Installed -is [array])) {
            $errors += "Scoop.Installed must be an array"
        }
    }
    
    # Validate Winget structure
    if ($Config.Winget) {
        if ($Config.Winget.Installed -and -not ($Config.Winget.Installed -is [array])) {
            $errors += "Winget.Installed must be an array"
        }
    }
    
    # Validate Feature structure
    if ($Config.Feature) {
        foreach ($feature in $Config.Feature.Keys) {
            $value = $Config.Feature[$feature]
            if ($value -notin @("enabled", "disabled")) {
                $errors += "Feature '$feature' has invalid value '$value'. Must be 'enabled' or 'disabled'"
            }
        }
    }
    
    # Validate Service structure
    if ($Config.Service) {
        foreach ($service in $Config.Service.Keys) {
            $svcConfig = $Config.Service[$service]
            if ($svcConfig.State -and $svcConfig.State -notin @("running", "stopped")) {
                $errors += "Service '$service' has invalid State '$($svcConfig.State)'. Must be 'running' or 'stopped'"
            }
            if ($svcConfig.Startup -and $svcConfig.Startup -notin @("automatic", "manual", "disabled")) {
                $errors += "Service '$service' has invalid Startup '$($svcConfig.Startup)'. Must be 'automatic', 'manual', or 'disabled'"
            }
        }
    }
    
    # Validate Trigger structure
    if ($Config.Trigger) {
        # Check if Trigger is an array
        if ($Config.Trigger -isnot [array]) {
            $errors += "Trigger must be an array of hashtables"
        }
        else {
            foreach ($trigger in $Config.Trigger) {
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
