# WinSpec Integration Tests

This directory contains integration tests for WinSpec. These tests are designed to verify the functionality of WinSpec without affecting the user's system.

## Test Structure

- `Integration.Tests.ps1` - Core integration tests for WinSpec functionality
- `Provider.Tests.ps1` - Tests for individual provider modules
- `Trigger.Tests.ps1` - Tests for trigger modules
- `State.Tests.ps1` - Tests for state management functionality
- `fixtures/` - Test fixtures and sample configurations

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

## Test Design Principles

1. **No System Impact**: All tests use mocking to avoid making actual changes to the system
2. **Integration Focus**: Tests verify the interaction between different components
3. **Comprehensive Coverage**: Tests cover providers, triggers, and state management
4. **CI/CD Ready**: Tests are designed to run in automated environments

## Test Categories

### Integration Tests (`Integration.Tests.ps1`)

Core integration tests that verify:
- Provider discovery
- State comparison
- Diff output formatting
- Manager execution
- Trigger execution
- Configuration loading
- Logging functionality

### Provider Tests (`Provider.Tests.ps1`)

Tests for individual provider modules:
- Registry provider
- Feature provider
- Service provider

### Trigger Tests (`Trigger.Tests.ps1`)

Tests for trigger modules:
- Activation trigger
- Debloat trigger
- Office trigger

### State Tests (`State.Tests.ps1`)

Tests for state management:
- State comparison
- Diff output formatting
- State merge
- State export
- State validation

## Writing Tests

When writing new tests:

1. Use `Describe` blocks to group related tests
2. Use `Context` blocks to describe different scenarios
3. Use `It` blocks for individual test cases
4. Use `BeforeAll` for setup code
5. Use `Mock` to avoid making actual system changes
6. Use `Should` for assertions

Example:

```powershell
Describe "My Feature" {
    Context "When doing something" {
        It "Should work correctly" {
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

## Continuous Integration

Tests are automatically run via GitHub Actions on:
- Push to main/develop branches
- Pull requests
- Weekly schedule (Sunday at 00:00 UTC)

See `.github/workflows/test.yml` for details.
