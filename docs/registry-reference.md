# WinSpec Registry Provider

This document describes the Registry provider, which manages Windows registry settings in a declarative manner.

---

## Overview

The Registry provider applies configuration changes to the Windows Registry based on predefined categories and properties. It is **idempotent** - running it multiple times produces the same result.

---

## Available Categories

| Category | Description | Registry Path |
|----------|-------------|---------------|
| `Clipboard` | Clipboard history settings | `HKCU:\Software\Microsoft\Clipboard` |
| `Explorer` | File Explorer behavior | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` |
| `Theme` | Windows theme (light/dark) | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` |
| `Desktop` | Desktop behavior settings | `HKCU:\Control Panel\Desktop` |

---

## Category: Clipboard

Controls clipboard history functionality.

### Properties

| Property | Type | Values | Default | Description |
|----------|------|--------|---------|-------------|
| `EnableHistory` | bool | `$true`, `$false` | `$false` | Enable Windows clipboard history |

### Registry Details

- **Path**: `HKCU:\Software\Microsoft\Clipboard`
- **Property**: `EnableClipboardHistory`
- **Type**: `DWord`

### Example

```powershell
Registry = @{
    Clipboard = @{
        EnableHistory = $true
    }
}
```

---

## Category: Explorer

Controls File Explorer behavior.

### Properties

| Property | Type | Values | Default | Description |
|----------|------|--------|---------|-------------|
| `ShowHidden` | bool | `$true`, `$false` | `$false` | Show hidden files and folders |
| `ShowFileExt` | bool | `$true`, `$false` | `$true` | Show file extensions |

### Registry Details

- **Path**: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`
- **Properties**:
  - `Hidden` (`DWord`): `$true` = 1, `$false` = 2
  - `HideFileExt` (`DWord`): `$true` = 0, `$false` = 1

### Example

```powershell
Registry = @{
    Explorer = @{
        ShowHidden = $true
        ShowFileExt = $true
    }
}
```

---

## Category: Theme

Controls Windows light/dark theme.

### Properties

| Property | Type | Values | Default | Description |
|----------|------|--------|---------|-------------|
| `AppTheme` | string | `"light"`, `"dark"` | `"light"` | Application theme |
| `SystemTheme` | string | `"light"`, `"dark"` | `"light"` | System theme |

### Registry Details

- **Path**: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
- **Properties**:
  - `AppsUseLightTheme` (`DWord`): `"light"` = 1, `"dark"` = 0
  - `SystemUsesLightTheme` (`DWord`): `"light"` = 1, `"dark"` = 0

### Example

```powershell
Registry = @{
    Theme = @{
        AppTheme = "dark"
        SystemTheme = "dark"
    }
}
```

---

## Category: Desktop

Controls desktop behavior settings.

### Properties

| Property | Type | Values | Default | Description |
|----------|------|--------|---------|-------------|
| `MenuShowDelay` | string | milliseconds | `"400"` | Delay before showing menu (0 = instant) |
| `ForegroundLockTimeout` | int | milliseconds | `200000` | Foreground lock timeout |

### Registry Details

- **Path**: `HKCU:\Control Panel\Desktop`
- **Properties**:
  - `MenuShowDelay` (`String`): Menu delay in milliseconds
  - `ForegroundLockTimeout` (`DWord`): Foreground lock timeout

### Example

```powershell
Registry = @{
    Desktop = @{
        MenuShowDelay = "0"     # Instant menu display
        ForegroundLockTimeout = 0
    }
}
```

---

## Complete Example

```powershell
# specs/my-spec.ps1
@{
    Name = "my-spec"
    Description = "My Windows configuration"
    
    Registry = @{
        Clipboard = @{
            EnableHistory = $true
        }
        
        Explorer = @{
            ShowHidden = $true
            ShowFileExt = $true
        }
        
        Theme = @{
            AppTheme = "dark"
            SystemTheme = "dark"
        }
        
        Desktop = @{
            MenuShowDelay = "0"
        }
    }
}
```

---

## Adding Registry Categories

Registry categories are defined in `winspec/registry-maps.ps1`. Each category specifies:

- `Path`: The registry path
- `Properties`: A hashtable of property configurations

### Property Configuration

Each property within a category can have:

| Field | Type | Description |
|-------|------|-------------|
| `Name` | string | The actual registry value name |
| `Type` | string | Registry value type (`DWord`, `String`, etc.) |
| `Map` | hashtable | Optional value mapping (e.g., `$true` → `1`) |
| `Default` | any | Default value if registry key doesn't exist |

### Example Property Definition

```powershell
$Script:RegistryMaps = @{
    MyCategory = @{
        Path = "HKCU:\Software\MyApp"
        Properties = @{
            MySetting = @{
                Name = "MySettingName"
                Type = "DWord"
                Map = @{ $true = 1; $false = 0 }
                Default = 0
            }
        }
    }
}
```

---

## Provider Contract

The Registry provider implements the declarative provider contract:

| Function | Purpose |
|----------|---------|
| `Get-ProviderMetadata` | Returns provider metadata |
| `Test-RegistryState` | Checks if current state matches desired state |
| `Set-RegistryState` | Applies desired state changes |

---

## Error Handling

- Unknown categories are logged as warnings
- Unknown properties within a category are logged as warnings
- Registry access errors are logged as errors
- The provider continues execution on non-fatal errors

---

*WinSpec Registry Provider Documentation v1.0*
