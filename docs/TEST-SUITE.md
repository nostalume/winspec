# WinSpec Test Suite

## Overview

This document describes the comprehensive integration test suite for WinSpec. The test suite is designed to verify the functionality of WinSpec without affecting the user's system.

## Test Structure

```
tests/
├── Integration.Tests.ps1    # Core integration tests
├── Provider.Tests.ps1       # Provider-specific tests
├── Trigger.Tests.ps1        # Trigger-specific tests
├── State.Tests.ps1          # State management tests
├── fixtures/
│   └── sample-config.ps1    # Sample configuration
└── README.md                # Test documentation
```

## Test Categories

### 1. Integration Tests (`Integration.Tests.ps1`)

Core integration tests that verify the main WinSpec functionality:

- **Provider Discovery**: Tests that providers are correctly discovered and loaded
- **State Comparison**: Tests that system state is correctly compared with specifications
- **Diff Output**: Tests that differences are correctly formatted
- **Manager Execution**: Tests that managers are executed correctly
- **Trigger Execution**: Tests that triggers are executed correctly
- **Configuration Loading**: Tests that configurations are loaded correctly
- **Logging**: Tests that logging functionality works correctly

### 2. Provider Tests (`Provider.Tests.ps1`)

Tests for individual provider modules:

- **Registry Provider**: Tests for registry state management
- **Feature Provider**: Tests for Windows feature management
- **Service Provider**: Tests for Windows service management
- **Scoop Provider**: Tests for Scoop package management
- **Winget Provider**: Tests for Winget package management

### 3. Trigger Tests (`Trigger.Tests.ps1`)

Tests for trigger modules:

- **Activation Trigger**: Tests for Windows/Office activation
- **Debloat Trigger**: Tests for system debloating
- **Office Trigger**: Tests for Office installation

### 4. State Tests (`State.Tests.ps1`)

Tests for state management functionality:

- **State Comparison**: Tests for comparing system state with specifications
- **Diff Output**: Tests for formatting differences
- **State Merge**: Tests for merging states
- **State Export**: Tests for exporting system state
- **State Validation**: Tests for validating specifications

## Running Tests

### Prerequisites

- PowerShell 7.0 or later
- Pester 5.0 or later

### Install Pester

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser -MinimumVersion 5.0
```

### Run All Tests

```powershell
Invoke-Pester -Path ./tests
```

### Run Specific Test File

```powershell
Invoke-Pester -Path ./tests/Integration.Tests.ps1
```

### Run with Detailed Output

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

### Run with Code Coverage

```powershell
$config = New-PesterConfiguration
$config.Run.Path = "./tests"
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = "./winspec"
$config.CodeCoverage.OutputFormat = "JaCoCo"
$config.CodeCoverage.OutputPath = "./coverage.xml"
Invoke-Pester -Configuration $config
```

## Test Design Principles

### 1. No System Impact

All tests use mocking to avoid making actual changes to the system:

```powershell
Mock -CommandName "Set-RegistryState" -MockWith { return @{ Success = $true } }
```

### 2. Integration Focus

Tests verify the interaction between different components:

```powershell
It "Should execute managers with dry run" {
    $spec = @{
        Registry = @{
            "HKCU:\Software\TestKey" = @{
                "TestValue" = "TestData"
            }
        }
    }
    
    $result = Invoke-Managers -Config $spec -DryRun
    $result | Should -Not -BeNullOrEmpty
}
```

### 3. Comprehensive Coverage

Tests cover all major functionality:

- Provider discovery and execution
- Trigger discovery and execution
- State comparison and formatting
- Configuration loading and validation
- Logging and error handling

### 4. CI/CD Ready

Tests are designed to run in automated environments:

- No user interaction required
- No system changes made
- Fast execution
- Clear pass/fail results

## Continuous Integration

Tests are automatically run via GitHub Actions:

- **On Push**: Tests run on every push to main/develop branches
- **On Pull Request**: Tests run on every pull request
- **Weekly Schedule**: Tests run every Sunday at 00:00 UTC

See `.github/workflows/test.yml` for details.

## Writing Tests

### Test Structure

```powershell
Describe "Feature Name" {
    Context "Scenario" {
        It "Should do something" {
            # Arrange
            Mock -CommandName "Some-Command" -MockWith { return "mocked" }
            
            # Act
            $result = My-Function
            
            # Assert
            $result | Should -Be "mocked"
        }
    }
}
```

### Best Practices

1. **Use Describe/Context/It**: Organize tests logically
2. **Use Mock**: Avoid making actual system changes
3. **Use Should**: Make clear assertions
4. **Use BeforeAll/AfterAll**: Setup and cleanup
5. **Test One Thing**: Each test should verify one behavior
6. **Use Clear Names**: Test names should describe what they test

### Example Test

```powershell
Describe "Registry Provider" {
    Context "Get-RegistryState" {
        It "Should get registry state" {
            # Arrange
            Mock -CommandName "Get-ItemProperty" -MockWith {
                return @{
                    TestValue = "TestData"
                }
            }
            
            # Act
            $state = Get-RegistryState -Path "HKCU:\Software\TestKey"
            
            # Assert
            $state | Should -Not -BeNullOrEmpty
            $state.TestValue | Should -Be "TestData"
        }
    }
}
```

## Test Coverage

The test suite covers:

- ✅ Provider discovery
- ✅ Provider execution
- ✅ Trigger discovery
- ✅ Trigger execution
- ✅ State comparison
- ✅ Diff output formatting
- ✅ State merge
- ✅ State export
- ✅ State validation
- ✅ Configuration loading
- ✅ Logging
- ✅ Error handling

## Future Improvements

- [ ] Add code coverage reporting
- [ ] Add performance tests
- [ ] Add stress tests
- [ ] Add security tests
- [ ] Add cross-platform tests
