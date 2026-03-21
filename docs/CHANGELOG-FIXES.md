# WinSpec Code Quality Fixes

## Overview
This document summarizes all code quality fixes applied to the WinSpec codebase based on comprehensive analysis.

## Fixes Applied

### 1. Duplicate Function Definition (Critical)
**File**: `winspec/managers/registry.psm1`
**Issue**: `Get-ProviderInfo` function was defined twice (lines 9-14 and 16-18)
**Fix**: Removed duplicate function definition, keeping only the first one

### 2. Trigger Module Export Issues (Critical)
**Files**: `winspec/triggers/activation.psm1`, `winspec/triggers/debloat.psm1`, `winspec/triggers/office.psm1`
**Issue**: All three trigger modules defined `Invoke-Trigger` but exported `Invoke-{Name}Trigger` (e.g., `Invoke-ActivationTrigger`)
**Fix**: Reverted to use `Invoke-Trigger` as the new API uses this name

### 3. Trigger Logic Bug
**File**: `winspec/triggers/activation.psm1`
**Issue**: Condition `$Option -ne $true` on a string is always true
**Fix**: Changed to `$Option -ne "default"` for proper string comparison

**File**: `winspec/triggers/debloat.psm1`
**Issue**: Same condition bug
**Fix**: Changed to `$Option -ne "default"`

### 4. State Module Variable and Parameter Issues (Critical)
**File**: `winspec/state.psm1`

#### 4.1 Undefined Variable
**Line 331**: Used `$compareFunc` instead of `$cmd`
**Fix**: Changed to `$cmd`

#### 4.2 Undefined Variable in Error Handler
**Line 336**: Returned `$System` (undefined in scope) on error
**Fix**: Changed to `return @()`

#### 4.3 Missing Parameter
**Lines 512-514**: `Invoke-Managers` called `Invoke-Manager` without `-Config` argument
**Fix**: Added `-Config $Config` parameter

#### 4.4 Parameter Name Mismatch
**Line 589**: Called `Resolve-Triggers` with `-UserTrigger` (singular)
**Fix**: Changed to `-UserTriggers` (plural)

**Line 648**: Called `Invoke-Triggers` with `-Trigger` (singular)
**Fix**: Changed to `-Triggers` (plural)

#### 4.5 Undefined Variable Reference
**Line 646**: Passed `-WhatIf:$DryRun` but `$DryRun` is not a parameter of `Invoke-WinSpec`
**Fix**: Removed `-WhatIf:$DryRun` from calls

#### 4.6 Incorrect Property Names
**Lines 683-684**: `Format-DiffOutput` referenced `$item.DesiredValue` and `$item.CurrentValue`
**Fix**: Changed to `$item.ConfigValue` and `$item.SystemValue` to match diff object structure

### 5. Service Module Typos and Logging
**File**: `winspec/managers/service.psm1`

#### 5.1 Variable Typo
**Line 60**: `$servicesa` (extra 'a') instead of `$services`
**Fix**: Changed to `$services`

#### 5.2 Debug Output
**Line 60**: Used `Write-Host` for debug output
**Fix**: Changed to `Write-Verbose`

**Line 208**: `Write-Host "$ServiceNames"` debug line left in
**Fix**: Changed to `Write-Verbose "Exporting service state for: $($ServiceNames -join ', ')"`

### 6. Feature Module Issues
**File**: `winspec/managers/feature.psm1`

#### 6.1 String Expansion Bug
**Lines 88-95**: `Invoke-AdminCommand` scriptblocks used single-quoted strings `'$featureName'`
**Fix**: Changed to double-quoted strings `$featureName` for proper variable expansion

#### 6.2 Filter Logic Bug
**Line 122**: Filter used `-ne` with `-or` logic that is always true
**Fix**: Changed to `-and` logic for correct filtering

### 7. Scoop Module Issues
**File**: `winspec/managers/scoop.psm1`

#### 7.1 Invalid Log Level
**Line 96**: Used `Write-Log -Level WARNING` (invalid level)
**Fix**: Changed to `Write-Log -Level WARN`

#### 7.2 Parameter Name Mismatch
**Line 523**: Called `Merge-PackageState -SpecState` but parameter is `-ExistingConfig`
**Fix**: Changed to `-ExistingConfig`

### 8. Winget Module Issues
**File**: `winspec/managers/winget.psm1`

#### 8.1 Invalid Log Level
**Line 89**: Used `Write-Log -Level "WARNING"` (invalid level)
**Fix**: Changed to `Write-Log -Level "WARN"`

#### 8.2 Unapproved Verb
**Line 97**: Function `Parse-WingetExportJson` uses unapproved verb `Parse-`
**Fix**: Renamed to `ConvertFrom-WingetExportJson` (approved verb)
**Also updated**: All references to the function (lines 111, 222)

### 9. Utils Module Positional Parameters
**File**: `winspec/utils.psm1`

#### 9.1 Missing Parameter Names
**Line 334**: `Write-Log "INFO"` missing `-Level` and `-Message` parameter names
**Fix**: Changed to `Write-Log -Level "INFO" -Message`

**Line 338**: Same issue
**Fix**: Changed to `Write-Log -Level "ERROR" -Message`

### 10. Main Script Undefined Variables
**File**: `winspec/winspec.ps1`

#### 10.1 Undefined Variable
**Line 561**: Referenced `$outputPath` (undefined)
**Fix**: Changed to `$Output` (correct parameter name)

#### 10.2 Undeclared Parameters
**Lines 650-651**: Referenced `$Template` and `$Minimal` variables not declared as parameters
**Fix**: Removed references (these parameters don't exist in the script)

### 11. Logging Module Global Scope Pollution
**File**: `winspec/logging.psm1`
**Issue**: Global alias functions (`global:INFO`, `global:OK`, etc.) pollute global scope and shadow legitimate uses
**Fix**: Removed all global alias functions (lines 42-65)
**Impact**: Users should now use `Write-Log -Level "INFO" -Message` directly

### 12. Logging Module Duplicate Function Definition
**File**: `winspec/logging.psm1`
**Issue**: Duplicate `Write-Log` function definition causing parsing errors (lines 40-75)
**Fix**: Removed duplicate function definition
**Impact**: Module now parses correctly and `Write-Log` function is available

### 13. Module Removal After Execution
**File**: `winspec/state.psm1`
**Issue**: Modules were not being removed after execution, potentially causing memory leaks
**Fix**: Added `Remove-Module` calls in `finally` blocks for both `Invoke-Manager` and `Invoke-TriggerProvider` functions
**Impact**: Modules are now properly cleaned up after execution, freeing resources

## Summary

### Critical Fixes (Would Cause Runtime Errors)
- Duplicate function definition in registry.psm1
- Trigger module export mismatches (reverted to use `Invoke-Trigger`)
- Undefined variables in state.psm1
- Missing parameters in function calls
- Duplicate function definition in logging.psm1

### Logic Bugs
- Incorrect filter logic in feature.psm1
- String expansion issues in feature.psm1
- Parameter name mismatches throughout

### Code Quality Issues
- Typos and debug output left in code
- Invalid log levels
- Unapproved verb usage
- Global scope pollution
- Module removal after execution

## Testing Recommendations

After applying these fixes, the following should be tested:

1. **Provider Discovery**: Verify all providers are discovered correctly
2. **Trigger Execution**: Test each trigger (Activation, Debloat, Office)
3. **State Comparison**: Verify diff output shows correct property names
4. **Service Management**: Test service state export and configuration
5. **Feature Management**: Test Windows feature enable/disable
6. **Package Managers**: Test scoop and winget operations
7. **Logging**: Verify all log levels work correctly

## Breaking Changes

### Removed Global Aliases
The following global functions were removed:
- `global:INFO`
- `global:OK`
- `global:APPLIED`
- `global:WARN`
- `global:ERROR`
- `global:CHANGE`

**Migration**: Replace calls like `INFO "message"` with `Write-Log -Level "INFO" -Message "message"`

### Renamed Function
- `Parse-WingetExportJson` → `ConvertFrom-WingetExportJson`

**Migration**: Update any external calls to use the new name

## Files Modified

1. `winspec/managers/registry.psm1`
2. `winspec/triggers/activation.psm1`
3. `winspec/triggers/debloat.psm1`
4. `winspec/triggers/office.psm1`
5. `winspec/state.psm1`
6. `winspec/managers/service.psm1`
7. `winspec/managers/feature.psm1`
8. `winspec/managers/scoop.psm1`
9. `winspec/managers/winget.psm1`
10. `winspec/utils.psm1`
11. `winspec/winspec.ps1`
12. `winspec/logging.psm1`

Total: 12 files modified

## Test Suite Added

### Integration Tests
Created comprehensive integration test suite in `tests/` directory:

1. **`tests/Provider.Tests.ps1`** - Tests for declarative providers (Registry, Feature, Service)
2. **`tests/Trigger.Tests.ps1`** - Tests for trigger providers (Activation, Debloat, Office)
3. **`tests/State.Tests.ps1`** - Tests for state comparison and diff output
4. **`tests/Integration.Tests.ps1`** - End-to-end workflow tests

### Test Fixtures
- `tests/fixtures/sample-config.ps1` - Sample configuration for testing

### Test Documentation
- `tests/README.md` - Test documentation and guidelines

### CI/CD Workflow
- `.github/workflows/test.yml` - GitHub Actions workflow for automated testing

### Test Features
- **No System Impact**: Tests use sandbox/mock mode to avoid modifying the actual system
- **Integration Focus**: Tests verify the interaction between components
- **Realistic Scenarios**: Tests use realistic configurations and data
- **Fast Execution**: Tests should complete quickly for rapid feedback
- **Multiple PowerShell Versions**: Tests run on PowerShell 7.0, 7.2, and 7.4
- **Linting**: PSScriptAnalyzer integration for code quality checks
- **Test Reporting**: JUnit XML output for CI/CD integration
