#!/usr/bin/env pwsh
# run-tests.ps1 - Run all WinSpec tests with Pester

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$TestPath = ""
)

$ErrorActionPreference = 'Stop'

# Determine test path
if ([string]::IsNullOrEmpty($TestPath)) {
    $TestPath = $PSScriptRoot
    if ([string]::IsNullOrEmpty($TestPath)) {
        $TestPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrEmpty($TestPath)) {
        $TestPath = $PWD
    }
}

# Check if Pester is available
if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host "Installing Pester module..." -ForegroundColor Yellow
    Install-Module -Name Pester -Force -Scope CurrentUser -SkipPublisherCheck
}

# Import Pester
Import-Module Pester -MinimumVersion 5.0

# Configure Pester
$verbosity = if ($VerbosePreference -eq 'Continue') { "Detailed" } else { "Normal" }

# Run tests
Write-Host "Running WinSpec tests..." -ForegroundColor Cyan
Write-Host "Test path: $TestPath" -ForegroundColor Gray
Write-Host ""

$result = Invoke-Pester -Path $TestPath -Output $verbosity -PassThru

# Get test result - handle different Pester output structures
if ($null -ne $result -and $result.TotalCount) {
    $testResult = $result
} elseif ($null -ne $result -and $null -ne $result.Result) {
    $testResult = $result.Result
} else {
    # Fallback: try to construct from available properties
    $testResult = [PSCustomObject]@{
        TotalCount = if ($result.TotalCount) { $result.TotalCount } else { 0 }
        PassedCount = if ($result.PassedCount) { $result.PassedCount } else { 0 }
        FailedCount = if ($result.FailedCount) { $result.FailedCount } else { 0 }
        SkippedCount = if ($result.SkippedCount) { $result.SkippedCount } else { 0 }
        Duration = if ($result.Duration) { $result.Duration } else { New-TimeSpan }
    }
}

# Summary
Write-Host ""
Write-Host "=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Total tests:  $($testResult.TotalCount)" -ForegroundColor White
Write-Host "Passed:       $($testResult.PassedCount)" -ForegroundColor Green
Write-Host "Failed:       $($testResult.FailedCount)" -ForegroundColor $(if ($testResult.FailedCount -gt 0) { "Red" } else { "Green" })
Write-Host "Skipped:      $($testResult.SkippedCount)" -ForegroundColor Yellow
Write-Host "Duration:     $($testResult.Duration.TotalSeconds.ToString('0.00'))s" -ForegroundColor White

# Exit with appropriate code
if ($testResult.FailedCount -gt 0) {
    Write-Host ""
    Write-Host "Some tests failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "All tests passed!" -ForegroundColor Green
exit 0
