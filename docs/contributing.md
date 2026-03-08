# WinSpec Contributing Guide

Contributions are welcome! Here's how to get started:

## Development Setup

1. Clone the repository
2. Run tests to ensure everything works:
   ```powershell
   .\winspec\tests\run-tests.ps1
   ```

## Creating a New Declarative Provider

1. Create a new file in `winspec/managers/` following the naming convention `{name}.psm1`
2. Implement the required functions:

```powershell
# managers/myprovider.psm1
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{ 
        Name = "MyProvider"
        Type = "Declarative" 
    }
}

function Test-MyProviderState {
    param ([hashtable]$Desired)
    # Returns $true if in desired state
}

function Set-MyProviderState {
    param ([hashtable]$Desired, [switch]$WhatIf)
    # Apply desired state
}

Export-ModuleMember Get-ProviderInfo, Test-MyProviderState, Set-MyProviderState
```

## Creating a New Trigger Provider

1. Create a new file in `winspec/triggers/` following the naming convention `{name}.psm1`
2. Implement the required functions:

```powershell
# triggers/mytrigger.psm1
Import-Module (Join-Path $PSScriptRoot "..\logging.psm1") -Force

function Get-ProviderInfo {
    return @{ 
        Name = "MyTrigger"
        Type = "Trigger" 
    }
}

function Invoke-MyTriggerTrigger {
    param ($Option, [switch]$WhatIf)
    # Execute trigger action
}

Export-ModuleMember Get-ProviderInfo, Invoke-MyTriggerTrigger
```

3. Add tests in `winspec/tests/`
4. Update documentation in [spec.md](spec.md)

## Guidelines

- Follow existing code style and naming conventions
- Use the logging module for consistent output
- Support `-WhatIf` for preview functionality
- Return consistent result hashtables with `Status` key
- Handle errors gracefully with meaningful messages
