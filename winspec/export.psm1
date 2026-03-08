# export.psm1 - System state export functionality for bidirectional sync

# Import dependent modules
Import-Module (Join-Path $PSScriptRoot "logging.psm1") -Force

function Export-SystemState {
    <#
    .SYNOPSIS
        Exports current system state to a WinSpec configuration.
    .DESCRIPTION
        Captures the current system state using all declarative providers
        and generates a WinSpec configuration hashtable or file.
    .PARAMETER Providers
        Array of provider names to export. If not specified, exports all.
    .PARAMETER OutputPath
        Optional path to write the exported configuration.
    .PARAMETER Format
        Output format: "ps1" (PowerShell hashtable) or "json".
    .OUTPUTS
        Hashtable representing the system state
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Providers = @(),
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("ps1", "json")]
        [string]$Format = "ps1"
    )
    
    Write-Log -Level "INFO" -Message "Starting system state export..."
    
    $export = @{
        Name = "exported-state"
        Description = "Auto-exported system state"
    }
    
    # Import all manager modules
    $managersPath = Join-Path $PSScriptRoot "managers"
    $availableProviders = @{}
    
    if (Test-Path $managersPath) {
        Get-ChildItem -Path $managersPath -Filter "*.psm1" | ForEach-Object {
            try {
                Import-Module $_.FullName -Force
                $info = & { $_.BaseName }
                # Try to get provider info from module
                $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                $info = & (Get-Module $moduleName) { Get-ProviderInfo }
                if ($info -and $info.Type -eq "Declarative") {
                    $availableProviders[$info.Name] = $moduleName
                }
            }
            catch {
                Write-Log -Level "WARN" -Message "Failed to import manager: $($_.Name)"
            }
        }
    }
    
    # Determine which providers to export
    # Handle null or empty providers array properly
    $providersToExport = if ($null -ne $Providers -and $Providers.Count -gt 0) { 
        $Providers 
    } else { 
        $availableProviders.Keys 
    }
    
    # Export each provider
    foreach ($providerName in $providersToExport) {
        if (-not $availableProviders.ContainsKey($providerName)) {
            Write-Log -Level "WARN" -Message "Provider not found: $providerName"
            continue
        }
        
        $moduleName = $availableProviders[$providerName]
        $exportFunction = "Export-${providerName}State"
        
        try {
            $module = Get-Module $moduleName
            if ($module.ExportedCommands.ContainsKey($exportFunction) -or 
                $module.ExportedFunctions.ContainsKey($exportFunction)) {
                
                Write-Log -Level "INFO" -Message "Exporting $providerName state..."
                $state = & $module $exportFunction
                
                if ($state -and $state.Count -gt 0) {
                    $export[$providerName] = $state
                    Write-Log -Level "OK" -Message "Exported $providerName state"
                }
                else {
                    Write-Log -Level "INFO" -Message "No $providerName state to export"
                }
            }
            else {
                Write-Log -Level "WARN" -Message "Export function not found: $exportFunction"
            }
        }
        catch {
            Write-Log -Level "ERROR" -Message "Failed to export $providerName state: $($_.Exception.Message)"
        }
    }
    
    # Output to file if path specified
    if ($OutputPath) {
        try {
            $directory = Split-Path -Parent $OutputPath
            if ($directory -and -not (Test-Path $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            
            if ($Format -eq "json") {
                $export | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8
            }
            else {
                $content = ConvertTo-PowerShellHashtable $export
                $content | Out-File -FilePath $OutputPath -Encoding UTF8
            }
            
            Write-Log -Level "OK" -Message "Exported state to: $OutputPath"
        }
        catch {
            Write-Log -Level "ERROR" -Message "Failed to write export file: $($_.Exception.Message)"
        }
    }
    
    return $export
}

function ConvertTo-PowerShellHashtable {
    <#
    .SYNOPSIS
        Converts a hashtable to PowerShell hashtable syntax string.
    .DESCRIPTION
        Recursively converts a hashtable to a string representation
        that can be saved as a .ps1 file and imported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Value,
        
        [Parameter(Mandatory = $false)]
        [int]$Indent = 0
    )
    
    $indentStr = "    " * $Indent
    $nextIndentStr = "    " * ($Indent + 1)
    
    if ($Value -is [hashtable]) {
        if ($Value.Count -eq 0) {
            return "@{}"
        }
        
        $lines = @("@{")
        foreach ($key in $Value.Keys | Sort-Object) {
            $val = $Value[$key]
            $valStr = ConvertTo-PowerShellHashtable -Value $val -Indent ($Indent + 1)
            
            # Check if key needs quotes
            $keyStr = if ($key -match '^[a-zA-Z_][a-zA-Z0-9_]*$') { $key } else { "'$key'" }
            $lines += "$nextIndentStr$keyStr = $valStr"
        }
        $lines += "$indentStr}"
        return $lines -join "`n"
    }
    elseif ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "@()"
        }
        
        $lines = @("@(")
        foreach ($item in $Value) {
            $itemStr = ConvertTo-PowerShellHashtable -Value $item -Indent ($Indent + 1)
            $lines += "$nextIndentStr$itemStr"
        }
        $closing = ')'
        $lines += "$indentStr$closing"
        return $lines -join "`n"
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [int] -or $Value -is [double]) {
        return $Value.ToString()
    }
    elseif ($Value -is [string]) {
        # Escape single quotes
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }
    else {
        return "'$Value'"
    }
}

Export-ModuleMember -Function @(
    "Export-SystemState"
    "ConvertTo-PowerShellHashtable"
)
