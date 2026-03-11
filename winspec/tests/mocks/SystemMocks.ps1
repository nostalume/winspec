# tests/mocks/SystemMocks.ps1 - System operation mocking helpers for WinSpec tests
# Provides reusable mocks for Windows system operations

# =============================================================================
# Registry Mocks
# =============================================================================

function Mock-RegistryValueExists {
    <#
    .SYNOPSIS
        Mocks registry value that exists
    .PARAMETER Path
        Registry path
    .PARAMETER Name
        Value name
    .PARAMETER Value
        Value data
    #>
    param(
        [string]$Path = "HKCU:\Test",
        [string]$Name = "TestValue",
        $Value = 1
    )
    
    Mock Get-ItemProperty {
        return @{
            $Name = $Value
            PSPath = $Path
            PSParentPath = "Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER"
            PSChildName = "Test"
            PSDrive = "HKCU"
        }
    } -ParameterFilter { $Path -eq $Path -and $Name -eq $Name }
}

function Mock-RegistryValueNotFound {
    <#
    .SYNOPSIS
        Mocks registry value that doesn't exist
    #>
    param(
        [string]$Path = "HKCU:\Missing"
    )
    
    Mock Get-ItemProperty {
        return $null
    } -ParameterFilter { $Path -eq $Path }
}

function Mock-RegistryKeyNotFound {
    <#
    .SYNOPSIS
        Mocks registry key that doesn't exist
    #>
    param(
        [string]$Path = "HKCU:\Missing"
    )
    
    Mock Get-ItemProperty {
        throw [System.Management.Automation.ItemNotFoundException]::new("Cannot find path '$Path'")
    } -ParameterFilter { $Path -eq $Path }
}

function Mock-RegistryAccessDenied {
    <#
    .SYNOPSIS
        Mocks registry access denied error
    #>
    param(
        [string]$Path = "HKLM:\System\Restricted"
    )
    
    Mock Get-ItemProperty {
        throw [System.UnauthorizedAccessException]::new("Access is denied.")
    } -ParameterFilter { $Path -match $Path }
}

# =============================================================================
# Service Mocks
# =============================================================================

function Mock-ServiceRunning {
    <#
    .SYNOPSIS
        Mocks a running service
    .PARAMETER Name
        Service name
    #>
    param(
        [string]$Name = "TestService"
    )
    
    Mock Get-Service {
        return [PSCustomObject]@{
            Name = $Name
            Status = "Running"
            StartType = "Automatic"
        }
    } -ParameterFilter { $Name -eq $Name }
}

function Mock-ServiceStopped {
    <#
    .SYNOPSIS
        Mocks a stopped service
    #>
    param(
        [string]$Name = "TestService"
    )
    
    Mock Get-Service {
        return [PSCustomObject]@{
            Name = $Name
            Status = "Stopped"
            StartType = "Disabled"
        }
    } -ParameterFilter { $Name -eq $Name }
}

function Mock-ServiceNotFound {
    <#
    .SYNOPSIS
        Mocks a service that doesn't exist
    #>
    param(
        [string]$Name = "NonExistentService"
    )
    
    Mock Get-Service {
        throw [System.ServiceProcess.ServiceNotFoundException]::new("Cannot find service '$Name'")
    } -ParameterFilter { $Name -eq $Name }
}

function Mock-ServiceAccessDenied {
    <#
    .SYNOPSIS
        Mocks service access denied error
    #>
    param(
        [string]$Name = "ProtectedService"
    )
    
    Mock Get-Service {
        throw [System.ServiceProcess.ServiceControllerPermissionException]::new("Access is denied.")
    } -ParameterFilter { $Name -eq $Name }
}

function Mock-ServiceAllRunning {
    <#
    .SYNOPSIS
        Mocks getting all running services
    #>
    Mock Get-Service {
        return @(
            [PSCustomObject]@{ Name = "Service1"; Status = "Running"; StartType = "Automatic" },
            [PSCustomObject]@{ Name = "Service2"; Status = "Running"; StartType = "Manual" }
        )
    }
}

# =============================================================================
# Windows Feature Mocks
# =============================================================================

function Mock-FeatureEnabled {
    <#
    .SYNOPSIS
        Mocks an enabled Windows optional feature
    .PARAMETER FeatureName
        Feature name
    #>
    param(
        [string]$FeatureName = "TestFeature"
    )
    
    Mock Get-WindowsOptionalFeature {
        return [PSCustomObject]@{
            FeatureName = $FeatureName
            State = "Enabled"
        }
    } -ParameterFilter { $FeatureName -eq $FeatureName }
}

function Mock-FeatureDisabled {
    <#
    .SYNOPSIS
        Mocks a disabled Windows optional feature
    #>
    param(
        [string]$FeatureName = "TestFeature"
    )
    
    Mock Get-WindowsOptionalFeature {
        return [PSCustomObject]@{
            FeatureName = $FeatureName
            State = "Disabled"
        }
    } -ParameterFilter { $FeatureName -eq $FeatureName }
}

function Mock-FeatureNotFound {
    <#
    .SYNOPSIS
        Mocks a Windows feature that doesn't exist
    #>
    param(
        [string]$FeatureName = "NonExistentFeature"
    )
    
    Mock Get-WindowsOptionalFeature {
        throw [System.Exception]::new("Feature $FeatureName not found")
    } -ParameterFilter { $FeatureName -eq $FeatureName }
}

function Mock-FeatureEnableSuccess {
    <#
    .SYNOPSIS
        Mocks successful feature enable
    #>
    Mock Enable-WindowsOptionalFeature { }
}

function Mock-FeatureDisableSuccess {
    <#
    .SYNOPSIS
        Mocks successful feature disable
    #>
    Mock Disable-WindowsOptionalFeature { }
}

function Mock-FeatureEnableFailure {
    <#
    .SYNOPSIS
        Mocks failed feature enable
    #>
    Mock Enable-WindowsOptionalFeature {
        throw [System.Exception]::new("Failed to enable feature")
    }
}

# =============================================================================
# Computer Info Mocks
# =============================================================================

function Mock-SystemRestoreEnabled {
    <#
    .SYNOPSIS
        Mocks System Restore as enabled
    #>
    Mock Get-ComputerInfo {
        return [PSCustomObject]@{
            RestoreStatus = "Enabled"
        }
    }
}

function Mock-SystemRestoreDisabled {
    <#
    .SYNOPSIS
        Mocks System Restore as disabled
    #>
    Mock Get-ComputerInfo {
        return [PSCustomObject]@{
            RestoreStatus = "Disabled"
        }
    }
}

function Mock-SystemRestoreError {
    <#
    .SYNOPSIS
        Mocks System Restore error
    #>
    Mock Get-ComputerInfo {
        throw [System.UnauthorizedAccessException]::new("Access denied")
    }
}

# =============================================================================
# Checkpoint Mocks
# =============================================================================

function Mock-CheckpointExists {
    <#
    .SYNOPSIS
        Mocks existing system restore points
    #>
    param(
        [int]$Count = 2
    )
    
    Mock Get-ComputerRestorePoint {
        $points = @()
        for ($i = 1; $i -le $Count; $i++) {
            $points += [PSCustomObject]@{
                SequenceNumber = 100 + $i
                CreationTime = (Get-Date).AddDays(-$i)
                Description = "WinSpec-Test$i"
            }
        }
        return $points
    }
}

function Mock-CheckpointEmpty {
    <#
    .SYNOPSIS
        Mocks no system restore points
    #>
    Mock Get-ComputerRestorePoint {
        return @()
    }
}

function Mock-CheckpointCreateSuccess {
    <#
    .SYNOPSIS
        Mocks successful checkpoint creation
    #>
    Mock Checkpoint-Computer { }
}

function Mock-CheckpointCreateFailure {
    <#
    .SYNOPSIS
        Mocks failed checkpoint creation
    #>
    Mock Checkpoint-Computer {
        throw [System.Exception]::new("Failed to create restore point")
    }
}

# =============================================================================
# File System Mocks
# =============================================================================

function Mock-FileExists {
    <#
    .SYNOPSIS
        Mocks Test-Path returning true
    #>
    param(
        [string]$Path = "C:\Test\File.txt"
    )
    
    Mock Test-Path {
        return $true
    } -ParameterFilter { $Path -eq $Path }
}

function Mock-FileNotFound {
    <#
    .SYNOPSIS
        Mocks Test-Path returning false
    #>
    param(
        [string]$Path = "C:\Missing\File.txt"
    )
    
    Mock Test-Path {
        return $false
    } -ParameterFilter { $Path -eq $Path }
}

function Mock-FileReadSuccess {
    <#
    .SYNOPSIS
        Mocks successful file read
    #>
    param(
        [string]$Content = "test content"
    )
    
    Mock Get-Content {
        return $Content
    }
}

function Mock-FileWriteSuccess {
    <#
    .SYNOPSIS
        Mocks successful file write
    #>
    Mock Set-Content { }
    Mock Out-File { }
}

function Mock-FileWriteFailure {
    <#
    .SYNOPSIS
        Mocks file write failure
    #>
    Mock Set-Content {
        throw [System.UnauthorizedAccessException]::new("Access to the path is denied.")
    }
    Mock Out-File {
        throw [System.UnauthorizedAccessException]::new("Access to the path is denied.")
    }
}

# =============================================================================
# Process Mocks
# =============================================================================

function Mock-ProcessStartSuccess {
    <#
    .SYNOPSIS
        Mocks successful process start
    #>
    Mock Start-Process {
        return [PSCustomObject]@{
            Id = 1234
            ProcessName = "TestProcess"
        }
    }
}

function Mock-ProcessStartFailure {
    <#
    .SYNOPSIS
        Mocks failed process start
    #>
    Mock Start-Process {
        throw [System.ComponentModel.Win32Exception]::new("The system cannot find the file specified")
    }
}

# =============================================================================
# PowerShell Version Mocks
# =============================================================================

function Mock-PowerShellVersion {
    <#
    .SYNOPSIS
        Mocks PowerShell version
    .PARAMETER Version
        Version string
    #>
    param(
        [string]$Version = "7.4.0"
    )
    
    Mock Get-Host {
        return [PSCustomObject]@{
            Version = [PSCustomObject]@{
                Major = [int]($Version.Split('.')[0])
                Minor = [int]($Version.Split('.')[1])
                Build = [int]($Version.Split('.')[2])
            }
        }
    }
}

# =============================================================================
# Admin Privilege Mocks
# =============================================================================

function Mock-IsAdmin {
    <#
    .SYNOPSIS
        Mocks running as administrator
    #>
    Mock Test-Administrator {
        return $true
    }
}

function Mock-IsNotAdmin {
    <#
    .SYNOPSIS
        Mocks not running as administrator
    #>
    Mock Test-Administrator {
        return $false
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Mock-RegistryValueExists',
    'Mock-RegistryValueNotFound',
    'Mock-RegistryKeyNotFound',
    'Mock-RegistryAccessDenied',
    'Mock-ServiceRunning',
    'Mock-ServiceStopped',
    'Mock-ServiceNotFound',
    'Mock-ServiceAccessDenied',
    'Mock-ServiceAllRunning',
    'Mock-FeatureEnabled',
    'Mock-FeatureDisabled',
    'Mock-FeatureNotFound',
    'Mock-FeatureEnableSuccess',
    'Mock-FeatureDisableSuccess',
    'Mock-FeatureEnableFailure',
    'Mock-SystemRestoreEnabled',
    'Mock-SystemRestoreDisabled',
    'Mock-SystemRestoreError',
    'Mock-CheckpointExists',
    'Mock-CheckpointEmpty',
    'Mock-CheckpointCreateSuccess',
    'Mock-CheckpointCreateFailure',
    'Mock-FileExists',
    'Mock-FileNotFound',
    'Mock-FileReadSuccess',
    'Mock-FileWriteSuccess',
    'Mock-FileWriteFailure',
    'Mock-ProcessStartSuccess',
    'Mock-ProcessStartFailure',
    'Mock-PowerShellVersion',
    'Mock-IsAdmin',
    'Mock-IsNotAdmin'
)
