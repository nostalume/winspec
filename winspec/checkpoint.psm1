# checkpoint.psm1 - Restore point management for WinSpec

Import-Module (Join-Path $PSScriptRoot "logging.psm1") -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot "utils.psm1") -ErrorAction Stop

function Test-SystemRestoreEnabled {
    [CmdletBinding()]
    param()
    
    try {
        $status = Get-ComputerInfo -Property "RestoreStatus" -ErrorAction SilentlyContinue
        return ($status.RestoreStatus -eq "Enabled")
    }
    catch {
        return $false
    }
}

function Enable-SystemRestore {
    [CmdletBinding()]
    param()
    
    if (Test-SystemRestoreEnabled) {
        Write-Log -Level "OK" -Message "System Restore is already enabled."
        return $true
    }
    
    Write-Log -Level "INFO" -Message "Enabling System Restore..."
    
    try {
        Enable-ComputerRestore -Drive "C:\"
        Write-Log -Level "APPLIED" -Message "System Restore enabled on C:\"
        return $true
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to enable System Restore: $($_.Exception.Message)"
        return $false
    }
}

function New-Checkpoint {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = "WinSpec-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
        
        [Parameter(Mandatory = $false)]
        [string]$Description = "WinSpec configuration checkpoint"
    )
    
    Write-Log -Level "INFO" -Message "Creating restore point: $Name"
    
    if (-not (Test-SystemRestoreEnabled)) {
        Write-Log -Level "WARN" -Message "Cannot create checkpoint because System Restore is disabled."
        return @{
            Name    = $Name
            Success = $false
            Reason  = "SystemRestoreDisabled"
            Message = "Enable System Restore before creating a checkpoint."
        }
    }

    if (-not (Test-IsAdmin)) {
        Write-Log -Level "ERROR" -Message "Administrator privileges are required to create a restore point."
        return @{
            Name    = $Name
            Success = $false
            Reason  = "RequiresAdministrator"
            Message = "Run WinSpec as Administrator to create a checkpoint."
        }
    }
    
    try {
        Checkpoint-Computer -Description $Name -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Log -Level "APPLIED" -Message "Restore point created: $Name"
        
        return @{
            Name        = $Name
            Description = $Description
            CreatedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Success     = $true
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to create restore point: $($_.Exception.Message)"
        return @{
            Name    = $Name
            Success = $false
            Reason  = "CheckpointFailed"
            Error   = $_.Exception.Message
        }
    }
}

function Get-Checkpoints {
    [CmdletBinding()]
    param()
    
    Write-Log -Level "INFO" -Message "Listing available restore points..."
    
    try {
        $restorePoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
        
        if (-not $restorePoints) {
            Write-Log -Level "WARN" -Message "No restore points found."
            return @()
        }
        
        # Filter WinSpec checkpoints
        $winSpecPoints = $restorePoints | 
            Where-Object { $_.Description -like "WinSpec*" } |
            Select-Object SequenceNumber, CreationTime, Description |
            Sort-Object CreationTime -Descending
        
        return $winSpecPoints
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to list restore points: $($_.Exception.Message)"
        return @()
    }
}

function Invoke-Rollback {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [int]$SequenceNumber,
        
        [Parameter(Mandatory = $false)]
        [switch]$Last
    )
    
    if (-not (Test-SystemRestoreEnabled)) {
        Write-Log -Level "ERROR" -Message "System Restore is not enabled. Cannot rollback."
        return @{
            Success = $false
            Reason  = "SystemRestoreDisabled"
            Message = "System Restore is not enabled. Cannot rollback."
        }
    }
    
    $restorePoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
    
    if (-not $restorePoints) {
        Write-Log -Level "ERROR" -Message "No restore points available for rollback."
        return @{
            Success = $false
            Reason  = "NoRestorePoints"
            Message = "No restore points available for rollback."
        }
    }
    
    if ($Last) {
        # Get the most recent WinSpec restore point
        $target = $restorePoints | 
            Where-Object { $_.Description -like "WinSpec*" } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
    }
    elseif ($SequenceNumber) {
        $target = $restorePoints | Where-Object { $_.SequenceNumber -eq $SequenceNumber }
    }
    else {
        Write-Log -Level "ERROR" -Message "Specify -SequenceNumber or -Last for rollback target."
        return @{
            Success = $false
            Reason  = "RollbackTargetRequired"
            Message = "Specify -SequenceNumber or -Last for rollback target."
        }
    }
    
    if (-not $target) {
        Write-Log -Level "ERROR" -Message "Target restore point not found."
        return @{
            Success = $false
            Reason  = "RestorePointNotFound"
            Message = "Target restore point not found."
        }
    }
    
    Write-Log -Level "WARN" -Message "This will restore the system to: $($target.Description)"
    Write-Log -Level "WARN" -Message "A system restart will be required."
    
    if ($PSCmdlet.ShouldProcess($target.Description, "Restore system")) {
        try {
            Restore-Computer -RestorePoint $target.SequenceNumber -ErrorAction Stop
            Write-Log -Level "APPLIED" -Message "System restore initiated. Restart required."
            return @{
                Success        = $true
                SequenceNumber = $target.SequenceNumber
                Description    = $target.Description
                Message        = "System restore initiated. Restart required."
            }
        }
        catch {
            Write-Log -Level "ERROR" -Message "Rollback failed: $($_.Exception.Message)"
            return @{
                Success        = $false
                Reason         = "RestoreFailed"
                SequenceNumber = $target.SequenceNumber
                Description    = $target.Description
                Error          = $_.Exception.Message
            }
        }
    }
    
    return @{
        Success        = $false
        Reason         = "WhatIf"
        SequenceNumber = $target.SequenceNumber
        Description    = $target.Description
    }
}

function Test-CheckpointCapability {
    [CmdletBinding()]
    param()
    
    $capabilities = @{
        SystemRestoreEnabled = Test-SystemRestoreEnabled
        AdminPrivileges      = Test-IsAdmin
    }
    
    $capabilities.CanCreateCheckpoint = $capabilities.SystemRestoreEnabled -and $capabilities.AdminPrivileges
    
    return $capabilities
}

Export-ModuleMember -Function @(
    "Test-SystemRestoreEnabled"
    "Enable-SystemRestore"
    "New-Checkpoint"
    "Get-Checkpoints"
    "Invoke-Rollback"
    "Test-CheckpointCapability"
)
