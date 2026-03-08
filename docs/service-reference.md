# WinSpec Service Provider

This document describes the Service provider, which manages Windows services in a declarative manner.

---

## Overview

The Service provider manages Windows service states and startup types. It is **idempotent** - running it multiple times produces the same result.

---

## Finding Service Names

Use PowerShell to list all services and find the proper names:

```powershell
# List all services with their names and status
Get-Service | Select-Object Name, Status, StartType | Sort-Object Name

# Find a specific service by display name
Get-Service | Where-Object { $_.DisplayName -like "*Windows*" }

# Get detailed service info (includes StartMode)
Get-WmiObject -Class Win32_Service | Select-Object Name, DisplayName, State, StartMode
```

---

## Configuration Format

```powershell
Service = @{
    ServiceName = @{ 
        State = "running" | "stopped"
        Startup = "automatic" | "manual" | "disabled"
    }
}
```

| Field | Type | Values |
|-------|------|--------|
| `State` | string | `"running"`, `"stopped"` |
| `Startup` | string | `"automatic"`, `"manual"`, `"disabled"` |

---

## Available Values Translation

The configuration uses simplified values that map to Windows service values:

| Config Value | Windows State | Windows StartMode |
|--------------|---------------|-------------------|
| `State = "running"` | `Running` | - |
| `State = "stopped"` | `Stopped` | - |
| `Startup = "automatic"` | - | `Auto` |
| `Startup = "manual"` | - | `Manual` |
| `Startup = "disabled"` | - | `Disabled` |

---

## Common Services

| Service Name | Display Name | Common Use |
|--------------|--------------|------------|
| `wuauserv` | Windows Update | Disable to stop updates |
| `WinDefend` | Windows Defender | Manage antivirus |
| `Spooler` | Print Spooler | Disable if no printer |
| `WSearch` | Windows Search | Disable for performance |
| `BITS` | Background Intelligent Transfer | May need for updates |

---

## Example

```powershell
Service = @{
    wuauserv = @{ State = "stopped"; Startup = "disabled" }
    WinDefend = @{ State = "running"; Startup = "automatic" }
}
```

---

## Provider Contract

The Service provider implements the declarative provider contract:

| Function | Purpose |
|----------|---------|
| `Get-ProviderMetadata` | Returns provider metadata |
| `Test-ServiceState` | Checks if current state matches desired state |
| `Set-ServiceState` | Applies desired state changes |

---

*WinSpec Service Provider Documentation v1.0*
