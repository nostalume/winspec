# Sample WinSpec Configuration for Testing
# This file demonstrates the configuration format

@{
    # Registry settings
    Registry = @{
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" = @{
            "Hidden" = 1
            "ShowSuperHidden" = 1
            "HideFileExt" = 0
        }
        
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" = @{
            "TestApp" = "C:\Test\TestApp.exe"
        }
    }
    
    # Windows Features
    Feature = @{
        "Microsoft-Hyper-V-All" = "Enabled"
        "Windows-Defender" = "Enabled"
    }
    
    # Services
    Service = @{
        "Spooler" = @{
            StartupType = "Automatic"
            Status = "Running"
        }
        
        "WSearch" = @{
            StartupType = "Automatic"
            Status = "Running"
        }
    }
    
    # Triggers
    Triggers = @(
        @{
            Name = "Activation"
            Product = "Windows"
        }
        
        @{
            Name = "Debloat"
            Silent = $true
        }
    )
}
