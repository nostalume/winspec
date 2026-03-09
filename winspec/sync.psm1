# sync.psm1 - Bidirectional synchronization for WinSpec
# Provides interactive sync between system state and configuration

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "export.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "diff.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "core.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -Force

function Invoke-Sync {
    <#
    .SYNOPSIS
        Performs bidirectional synchronization between system state and configuration.
    .DESCRIPTION
        Compares current system state with a configuration spec and provides
        interactive or automatic reconciliation of differences.
    .PARAMETER SpecPath
        Path to the configuration specification file.
    .PARAMETER Interactive
        Enable interactive prompts for sync decisions.
    .PARAMETER AutoStrategy
        Strategy for automatic sync: export, import, or mirror.
    .OUTPUTS
        Hashtable with sync results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SpecPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Interactive,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("export", "import", "mirror")]
        [string]$AutoStrategy = "mirror",
        
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    
    Write-Log -Level "INFO" -Message "Starting bidirectional sync..."
    Write-Log -Level "INFO" -Message "Spec: $SpecPath"
    
    # Load the configuration spec
    $configSpec = $null
    try {
        $configSpec = & $SpecPath
        if ($configSpec -isnot [hashtable]) {
            Write-Log -Level "ERROR" -Message "Spec must return a hashtable: $SpecPath"
            return @{ Success = $false }
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to load spec: $($_.Exception.Message)"
        return @{ Success = $false }
    }
    
    # Get current system state
    Write-Log -Level "INFO" -Message "Exporting current system state..."
    $systemState = Export-SystemState
    
    if (-not $systemState) {
        Write-Log -Level "ERROR" -Message "Failed to export system state"
        return @{ Success = $false }
    }
    
    # Compare and get differences
    Write-Log -Level "INFO" -Message "Comparing system state with configuration..."
    $differences = Compare-ForSync -SystemState $systemState -ConfigSpec $configSpec
    
    if ($differences.Count -eq 0) {
        Write-Log -Level "OK" -Message "System is already in sync with configuration"
        return @{ Success = $true; Changes = @() }
    }
    
    Write-Log -Level "INFO" -Message "Found $($differences.Count) differences to resolve"
    
    # Process differences
    $syncActions = @()
    $updatedConfig = Copy-Hashtable -Source $configSpec
    
    foreach ($diff in $differences) {
        $action = $null
        
        if ($Interactive) {
            $action = Invoke-SyncPrompt -Difference $diff
        }
        else {
            $action = Resolve-SyncAuto -Difference $diff -Strategy $AutoStrategy
        }
        
        if ($action) {
            $syncActions += $action
            
            # Apply action to configuration
            if ($action.Action -eq "AddToConfig") {
                $updatedConfig = Add-ToConfigPath -Config $updatedConfig -Path $diff.Path -Value $diff.SystemValue
            }
            elseif ($action.Action -eq "RemoveFromConfig") {
                $updatedConfig = Remove-FromConfigPath -Config $updatedConfig -Path $diff.Path
            }
            elseif ($action.Action -eq "ApplyToSystem") {
                # Mark for system application (will be applied later)
                $diff.ShouldApply = $true
            }
        }
    }
    
    # Apply changes to system if needed
    $systemResults = @()
    $changesToApply = $syncActions | Where-Object { $_.Action -eq "ApplyToSystem" }
    
    if ($changesToApply.Count -gt 0) {
        Write-Log -Level "INFO" -Message "Applying $($changesToApply.Count) changes to system..."
        $systemResults = Apply-SyncChanges -Changes $changesToApply -ConfigSpec $configSpec
    }
    
    # Save updated configuration
    $configUpdated = $false
    $configChanges = $syncActions | Where-Object { $_.Action -in @("AddToConfig", "RemoveFromConfig") }
    
    if ($configChanges.Count -gt 0 -and -not $DryRun) {
        Write-Log -Level "INFO" -Message "Updating configuration file with $($configChanges.Count) changes..."
        $configUpdated = Save-Configuration -Config $updatedConfig -Path $SpecPath
    }
    
    # Summary
    Write-Log -Level "OK" -Message "Sync completed"
    Write-Log -Level "INFO" -Message "  Actions taken: $($syncActions.Count)"
    Write-Log -Level "INFO" -Message "  Added to config: $($configChanges | Where-Object { $_.Action -eq 'AddToConfig' }).Count"
    Write-Log -Level "INFO" -Message "  Removed from config: $($configChanges | Where-Object { $_.Action -eq 'RemoveFromConfig' }).Count"
    Write-Log -Level "INFO" -Message "  Applied to system: $($changesToApply.Count)"
    
    return @{
        Success = $true
        Actions = $syncActions
        ConfigUpdated = $configUpdated
        SystemResults = $systemResults
    }
}

function Compare-ForSync {
    <#
    .SYNOPSIS
        Compares system state with config spec for sync purposes.
    #>
    param(
        [hashtable]$SystemState,
        [hashtable]$ConfigSpec
    )
    
    $differences = @()
    
    # Get all provider names
    $providers = @("Package", "Registry", "Service", "Feature") | Where-Object {
        $SystemState.ContainsKey($_) -or $ConfigSpec.ContainsKey($_)
    }
    
    foreach ($provider in $providers) {
        $systemProvider = $SystemState[$provider]
        $configProvider = $ConfigSpec[$provider]
        
        # Skip if neither system nor config has this provider
        if ($null -eq $systemProvider -and $null -eq $configProvider) {
            continue
        }
        
        # Load provider module for comparison
        $modulePath = Join-Path $PSScriptRoot "managers\$($provider.ToLower()).psm1"
        if (Test-Path $modulePath) {
            try {
                Import-Module $modulePath -Force
                $compareFunction = "Compare-${provider}State"
                
                if (Get-Command $compareFunction -ErrorAction SilentlyContinue) {
                    # Only pass Desired if it's not null
                    if ($null -ne $configProvider) {
                        $providerDiffs = & $compareFunction -System $systemProvider -Desired $configProvider
                    }
                    else {
                        # Config doesn't have this provider - treat as empty config
                        $providerDiffs = & $compareFunction -System $systemProvider -Desired @{}
                    }
                    $differences += $providerDiffs
                }
            }
            catch {
                Write-Log -Level "WARN" -Message "Failed to compare $provider state: $($_.Exception.Message)"
            }
        }
    }
    
    return $differences
}

function Invoke-SyncPrompt {
    <#
    .SYNOPSIS
        Interactive prompt for sync conflict resolution.
    #>
    param(
        [hashtable]$Difference
    )
    
    Write-Host ""
    Write-Host "=== SYNC DECISION ===" -ForegroundColor Cyan
    
    switch ($Difference.Type) {
        "Added" {
            # Item in config but not in system
            Write-Host "Item in config, not installed: $($Difference.Path)" -ForegroundColor Yellow
            Write-Host "Config value: $(ConvertTo-DisplayValue -Value $Difference.ConfigValue -Compact)" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Green
            Write-Host "  [I] Install to system" -ForegroundColor White
            Write-Host "  [R] Remove from config" -ForegroundColor White
            Write-Host "  [S] Skip" -ForegroundColor White
            Write-Host ""
            
            do {
                $choice = Read-Host "Choice"
                switch ($choice.ToLower()) {
                    "i" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue } }
                    "install" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue } }
                    "r" { return @{ Action = "RemoveFromConfig"; Path = $Difference.Path } }
                    "remove" { return @{ Action = "RemoveFromConfig"; Path = $Difference.Path } }
                    "s" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    "skip" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    default { Write-Host "Invalid choice. Enter I, R, or S" -ForegroundColor Red }
                }
            } while ($true)
        }
        
        "Removed" {
            # Item in system but not in config
            Write-Host "Item installed, not in config: $($Difference.Path)" -ForegroundColor Yellow
            Write-Host "System value: $(ConvertTo-DisplayValue -Value $Difference.SystemValue -Compact)" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Green
            Write-Host "  [A] Add to config" -ForegroundColor White
            Write-Host "  [R] Remove from system" -ForegroundColor White
            Write-Host "  [S] Skip" -ForegroundColor White
            Write-Host ""
            
            do {
                $choice = Read-Host "Choice"
                switch ($choice.ToLower()) {
                    "a" { return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue } }
                    "add" { return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue } }
                    "r" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Remove = $true } }
                    "remove" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Remove = $true } }
                    "s" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    "skip" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    default { Write-Host "Invalid choice. Enter A, R, or S" -ForegroundColor Red }
                }
            } while ($true)
        }
        
        "Changed" {
            # Different values
            Write-Host "Value mismatch: $($Difference.Path)" -ForegroundColor Yellow
            Write-Host "System: $(ConvertTo-DisplayValue -Value $Difference.SystemValue -Compact)" -ForegroundColor Gray
            Write-Host "Config: $(ConvertTo-DisplayValue -Value $Difference.ConfigValue -Compact)" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Green
            Write-Host "  [U] Update system (apply config)" -ForegroundColor White
            Write-Host "  [C] Update config (apply system)" -ForegroundColor White
            Write-Host "  [S] Skip" -ForegroundColor White
            Write-Host ""
            
            do {
                $choice = Read-Host "Choice"
                switch ($choice.ToLower()) {
                    "u" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue } }
                    "update" { return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue } }
                    "c" { return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue } }
                    "config" { return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue } }
                    "s" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    "skip" { return @{ Action = "Skip"; Path = $Difference.Path } }
                    default { Write-Host "Invalid choice. Enter U, C, or S" -ForegroundColor Red }
                }
            } while ($true)
        }
    }
    
    return @{ Action = "Skip"; Path = $Difference.Path }
}

function Resolve-SyncAuto {
    <#
    .SYNOPSIS
        Automatic sync resolution based on strategy.
    #>
    param(
        [hashtable]$Difference,
        [string]$Strategy
    )
    
    switch ($Strategy) {
        "export" {
            # System state wins - update config
            if ($Difference.Type -eq "Added") {
                return @{ Action = "RemoveFromConfig"; Path = $Difference.Path }
            }
            elseif ($Difference.Type -eq "Removed") {
                return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue }
            }
            elseif ($Difference.Type -eq "Changed") {
                return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue }
            }
        }
        
        "import" {
            # Config wins - update system
            if ($Difference.Type -eq "Added") {
                return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue }
            }
            elseif ($Difference.Type -eq "Removed") {
                return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Remove = $true }
            }
            elseif ($Difference.Type -eq "Changed") {
                return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue }
            }
        }
        
        "mirror" {
            # Add missing from both sides, remove nothing
            if ($Difference.Type -eq "Added") {
                return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue }
            }
            elseif ($Difference.Type -eq "Removed") {
                return @{ Action = "AddToConfig"; Path = $Difference.Path; Value = $Difference.SystemValue }
            }
            elseif ($Difference.Type -eq "Changed") {
                # For changes, prefer config
                return @{ Action = "ApplyToSystem"; Path = $Difference.Path; Value = $Difference.ConfigValue }
            }
        }
    }
    
    return @{ Action = "Skip"; Path = $Difference.Path }
}

function Apply-SyncChanges {
    <#
    .SYNOPSIS
        Applies sync changes to the system.
    #>
    param(
        [array]$Changes,
        [hashtable]$ConfigSpec
    )
    
    $results = @()
    
    foreach ($change in $Changes) {
        # Extract provider from path (e.g., "Package.git" -> "Package")
        $provider = $change.Path.Split('.')[0]
        
        Write-Log -Level "INFO" -Message "Applying change to $provider`: $($change.Path)"
        
        # Load provider and apply change
        $modulePath = Join-Path $PSScriptRoot "managers\$($provider.ToLower()).psm1"
        if (Test-Path $modulePath) {
            try {
                Import-Module $modulePath -Force
                $setFunction = "Set-${provider}State"
                
                if (Get-Command $setFunction -ErrorAction SilentlyContinue) {
                    # Build the partial config for this change
                    $partialConfig = @{}
                    
                    if ($change.Remove) {
                        # Handle removal
                        $partialConfig[$provider] = @{ Remove = @($change.Path.Split('.')[1]) }
                    }
                    else {
                        # Handle add/update
                        $itemName = $change.Path.Split('.')[1]
                        $partialConfig[$provider] = @{ Install = @($itemName) }
                    }
                    
                    $result = & $setFunction -Config $partialConfig
                    $results += @{
                        Path = $change.Path
                        Success = $result
                        Action = if ($change.Remove) { "Remove" } else { "Install/Update" }
                    }
                }
            }
            catch {
                Write-Log -Level "ERROR" -Message "Failed to apply change to $($change.Path): $($_.Exception.Message)"
                $results += @{
                    Path = $change.Path
                    Success = $false
                    Error = $_.Exception.Message
                }
            }
        }
    }
    
    return $results
}

Export-ModuleMember -Function @(
    "Invoke-Sync"
)
