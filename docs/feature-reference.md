# WinSpec Feature Provider

This document describes the Feature provider, which manages Windows optional features in a declarative manner.

---

## Overview

The Feature provider manages Windows optional features (like WSL, Hyper-V, Containers). It is **idempotent** - running it multiple times produces the same result.

---

## Finding Feature Names

Use PowerShell to list all optional features and find the proper names:

```powershell
# List all optional features
Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State

# Find specific features
Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -like "*Linux*" }
Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -like "*Hyper*" }
```

---

## Configuration Format

```powershell
Feature = @{
    "FeatureName" = "enabled" | "disabled"
}
```

| Value | Description |
|-------|-------------|
| `"enabled"` | Enable the feature |
| `"disabled"` | Disable the feature |

---

## Value Translation

| Config Value | Windows State |
|--------------|---------------|
| `"enabled"` | `Enabled` |
| `"disabled"` | `Disabled` |

---

## Common Features

| Feature Name | Description |
|--------------|-------------|
| `Microsoft-Windows-Subsystem-Linux` | Windows Subsystem for Linux (WSL) |
| `VirtualMachinePlatform` | WSL 2 support |
| `HypervisorPlatform` | Hyper-V |
| `Containers` | Windows Containers |
| `Microsoft-Hyper-V-All` | Hyper-V (full) |
| `Microsoft-Hyper-V` | Hyper-V (management) |

---

## Example

```powershell
Feature = @{
    "Microsoft-Windows-Subsystem-Linux" = "enabled"
    "VirtualMachinePlatform" = "enabled"
}
```

---

## Provider Contract

The Feature provider implements the declarative provider contract:

| Function | Purpose |
|----------|---------|
| `Get-ProviderMetadata` | Returns provider metadata |
| `Test-FeatureState` | Checks if current state matches desired state |
| `Set-FeatureState` | Applies desired state changes |

---

*WinSpec Feature Provider Documentation v1.0*
