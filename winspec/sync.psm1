# sync.psm1 - Bidirectional synchronization for WinSpec
# Provides interactive sync between system state and configuration

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "export.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "diff.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "core.psm1") -Force

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
                $updatedConfig = Add-ToConfig -Config $updatedConfig -Path $diff.Path -Value $diff.SystemValue
            }
            elseif ($action.Action -eq "RemoveFromConfig") {
                $updatedConfig = Remove-FromConfig -Config $updatedConfig -Path $diff.Path
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
        $configUpdated = Save-SyncConfig -Config $updatedConfig -Path $SpecPath
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
        
        # Load provider module for comparison
        $modulePath = Join-Path $PSScriptRoot "managers\$($provider.ToLower()).psm1"
        if (Test-Path $modulePath) {
            try {
                Import-Module $modulePath -Force
                $compareFunction = "Compare-${provider}State"
                
                if (Get-Command $compareFunction -ErrorAction SilentlyContinue) {
                    $providerDiffs = & $compareFunction -System $systemProvider -Desired $configProvider
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
            Write-Host "Config value: $(Format-SyncValue $Difference.ConfigValue)" -ForegroundColor Gray
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
            Write-Host "System value: $(Format-SyncValue $Difference.SystemValue)" -ForegroundColor Gray
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
            Write-Host "System: $(Format-SyncValue $Difference.SystemValue)" -ForegroundColor Gray
            Write-Host "Config: $(Format-SyncValue $Difference.ConfigValue)" -ForegroundColor Gray
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

function Format-SyncValue {
    <#
    .SYNOPSIS
        Formats a value for sync display.
    #>
    param($Value)
    
    if ($null -eq $Value) {
        return "<null>"
    }
    
    if ($Value -is [hashtable]) {
        $entries = $Value.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        return "{ $($entries -join ', ') }"
    }
    
    if ($Value -is [array]) {
        if ($Value.Count -gt 5) {
            return "@($($Value[0..4] -join ', ')... and $($Value.Count - 5) more)"
        }
        return "@($($Value -join ', '))"
    }
    
    return $Value.ToString()
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

function Copy-Hashtable {
    <#
    .SYNOPSIS
        Creates a deep copy of a hashtable.
    #>
    param([hashtable]$Source)
    
    $copy = @{}
    foreach ($key in $Source.Keys) {
        $value = $Source[$key]
        if ($value -is [hashtable]) {
            $copy[$key] = Copy-Hashtable -Source $value
        }
        elseif ($value -is [array]) {
            $copy[$key] = @($value)
        }
        else {
            $copy[$key] = $value
        }
    }
    return $copy
}

function Add-ToConfig {
    <#
    .SYNOPSIS
        Adds a value to the configuration at the specified path.
    #>
    param(
        [hashtable]$Config,
        [string]$Path,
        $Value
    )
    
    $parts = $Path.Split('.')
    $current = $Config
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $current.ContainsKey($part)) {
            $current[$part] = @{}
        }
        $current = $current[$part]
    }
    
    $current[$parts[-1]] = $Value
    return $Config
}

function Remove-FromConfig {
    <#
    .SYNOPSIS
        Removes a value from the configuration at the specified path.
    #>
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    $parts = $Path.Split('.')
    $current = $Config
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $current.ContainsKey($part)) {
            return $Config
        }
        $current = $current[$part]
    }
    
    if ($current.ContainsKey($parts[-1])) {
        $current.Remove($parts[-1])
    }
    
    return $Config
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

function Save-SyncConfig {
    <#
    .SYNOPSIS
        Saves the updated configuration to file.
    #>
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    try {
        $extension = [System.IO.Path]::GetExtension($Path).ToLower()
        
        if ($extension -eq ".json") {
            $json = $Config | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $Path -Encoding UTF8
        }
        else {
            # PowerShell hashtable format
            $content = ConvertTo-SyncHashtableString -Hashtable $Config -IndentLevel 0
            $content | Out-File -FilePath $Path -Encoding UTF8
        }
        
        Write-Log -Level "OK" -Message "Configuration saved to: $Path"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to save configuration: $($_.Exception.Message)"
        return $false
    }
}

function ConvertTo-SyncHashtableString {
    <#
    .SYNOPSIS
        Converts a hashtable to PowerShell code string.
    #>
    param(
        [hashtable]$Hashtable,
        [int]$IndentLevel = 0
    )
    
    $indent = "    " * $IndentLevel
    $lines = @()
    
    if ($IndentLevel -eq 0) {
        $lines += "@{"
    }
    
    foreach ($key in $Hashtable.Keys) {
        $value = $Hashtable[$key]
        $formattedValue = Format-SyncValueForExport -Value $value -IndentLevel ($IndentLevel + 1)
        $lines += "$indent    $key = $formattedValue"
    }
    
    if ($IndentLevel -eq 0) {
        $lines += "}"
    }
    
    return $lines -join "`n"
}

function Format-SyncValueForExport {
    <#
    .SYNOPSIS
        Formats a value for PowerShell export.
    #>
    param($Value, [int]$IndentLevel)
    
    $indent = "    " * $IndentLevel
    
    if ($null -eq $Value) {
        return '$null'
    }
    
    if ($Value -is [bool]) {
        return '$' + $Value.ToString().ToLower()
    }
    
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }
    
    if ($Value -is [string]) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return '@()'
        }
        $items = $Value | ForEach-Object { Format-SyncValueForExport -Value $_ -IndentLevel $IndentLevel }
        return "@($($items -join ', '))"
    }
    
    if ($Value -is [hashtable]) {
        $lines = @("@{`n")
        foreach ($key in $Value.Keys) {
            $formattedValue = Format-SyncValueForExport -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
            $lines += "$indent    $key = $formattedValue`n"
        }
        $lines += "$indent}"
        return $lines -join ""
    }
    
    return '"' + $Value.ToString() + '"'
}

Export-ModuleMember -Function @(
    "Invoke-Sync"
)
