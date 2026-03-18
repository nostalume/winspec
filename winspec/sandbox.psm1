# sandbox.psm1 - Sandbox engine for WinSpec: mock state management

# Import dependent modules
# ------------------------------------------------------------
# Winspec Sandbox System
# ------------------------------------------------------------

$ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $ModuleRoot "logging.psm1") -Force -Global

$Script:SandboxRoot = Join-Path $env:USERPROFILE ".config\winspec\sandbox"
$Script:SnapshotsDir = Join-Path $Script:SandboxRoot "snapshots"
$Script:HistoryDir = Join-Path $Script:SandboxRoot "history"
$Script:Sandbox = Join-Path $Script:SandboxRoot "sandbox.json"

$Script:Providers = @(
    "Scoop",
    "Winget",
    "Registry",
    "Service",
    "Feature"
)

$Script:SandboxContext = $null


# ------------------------------------------------------------
# Directory Initialization
# ------------------------------------------------------------

function Initialize-SandboxDirectory {
    $dirs = @(
        $Script:SandboxRoot,
        $Script:SnapshotsDir,
        $Script:HistoryDir
    )

    foreach ($d in $dirs) {
        if (!(Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}


# ------------------------------------------------------------
# State Factory
# ------------------------------------------------------------

function New-SandboxState {
    @{
        Scoop    = @{
            apps    = @()
            buckets = @(
                @{ name = "main"; source = "https://github.com/ScoopInstaller/Main" }
            )
        }

        Winget   = @{
            packages = @()
        }

        Registry = @{
            Explorer  = @{
                ShowHidden  = $false
                HideFileExt = $true
            }
            Clipboard = @{}
            Theme     = @{}
            Desktop   = @{}
        }
        Service  = @{}
        Feature  = @{}
    }
}


# ------------------------------------------------------------
# Sandbox Context
# ------------------------------------------------------------

function New-SandboxContext {
    param(
        [string]$Mode,
        [string]$Snapshot
    )

    @{
        Mode      = $Mode
        Snapshot  = $Snapshot
        StartTime = Get-Date
        Changes   = @()
        State     = New-SandboxState
        Original  = $null
    }
}

function Get-SandboxContext {
    if (Test-Path $Script:Sandbox) {
        return Get-Content $Script:Sandbox -Raw | ConvertFrom-Json -Depth 20
    } else {
        return $null
    }
}

function Test-SandboxActive {
    return Test-Path $Script:Sandbox
}

function Get-SandboxMode {
    if (-not $Script:SandboxContext) {
        return "Live"
    }

    return $Script:SandboxContext.Mode
}


# ------------------------------------------------------------
# Profile IO
# ------------------------------------------------------------

function Import-SandboxState {
    param([string]$Snapshot = "default")

    Initialize-SandboxDirectory

    $file = Join-Path $Script:SnapshotsDir "$Snapshot.json"

    if (!(Test-Path $file)) {
        return New-SandboxState
    }

    try {
        $json = Get-Content $file -Raw | ConvertFrom-Json
        return $json.state
    }
    catch {
        Write-Log -Level ERROR -Message "Failed loading sandbox snapshot: $_"
        return New-SandboxState
    }
}


function Export-SandboxState {
    param(
        [string]$Snapshot = "default",
        [hashtable]$State
    )
    Initialize-SandboxDirectory
    $file = Join-Path $Script:SnapshotsDir "$Snapshot.json"
    @{
        state = $State
    } |
    ConvertTo-Json -Depth 20 |
    Set-Content $file -Encoding UTF8

    Write-Log -Level OK -Message "Sandbox snapshot exported: $Snapshot"
}


function Get-SandboxSnapshots {
    Initialize-SandboxDirectory
    if (!(Test-Path $Script:SnapshotsDir)) {
        return @()
    }

    Get-ChildItem $Script:SnapshotsDir -Filter "*.json" |
    ForEach-Object { $_.BaseName }
}


function Remove-SandboxSnapshot {
    param([string]$Snapshot)

    $file = Join-Path $Script:SnapshotsDir "$Snapshot.json"

    if (Test-Path $file) {
        Remove-Item $file -Force
        Write-Log -Level OK -Message "Removed sandbox snapshot: $Snapshot"
    }
}


# ------------------------------------------------------------
# Sandbox Lifecycle
# ------------------------------------------------------------

function Enter-Sandbox {
    param(
        [ValidateSet("DryRun", "Mock", "Live")]
        [string]$Mode = "Mock",

        [string]$Snapshot = "default"
    )

    if ($Script:SandboxContext) {
        Exit-Sandbox
    }

    Initialize-SandboxDirectory
    $ctx = New-SandboxContext $Mode $Snapshot

    if ($Mode -eq "Mock") {
        $ctx.State = Import-SandboxState $Snapshot
    }

    # deep clone via json
    $ctx.Original = $ctx.State | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $Script:SandboxContext = $ctx
    # persistent sandbox state
    $ctx | ConvertTo-Json -Depth 20 | Set-Content -Path $Script:Sandbox

    Write-Log -Level OK -Message "Entered sandbox ($Mode / $Snapshot)"

    return $ctx
}


function Exit-Sandbox {
    param(
        [switch]$DiscardChanges
    )

    $ctx = Get-SandboxContext
    if ($null -eq $ctx) {
        Write-Log -Level "WARN" "Sandbox is not active"
        return
    }

    if (!$DiscardChanges -and $ctx.Changes.Count -gt 0) {
        Export-SandboxHistory $ctx
    }

    $Script:SandboxContext = $null
    Remove-Item $Script:Sandbox -ErrorAction SilentlyContinue

    Write-Log -Level OK -Message "Exited sandbox"
}


# ------------------------------------------------------------
# History
# ------------------------------------------------------------

function Export-SandboxHistory {

    param($Context)

    Initialize-SandboxDirectory

    $file = Join-Path $Script:HistoryDir (
        (Get-Date -Format "yyyyMMdd-HHmmss") + ".json"
    )

    $Context |
    ConvertTo-Json -Depth 20 |
    Set-Content $file

    Write-Log -Level OK -Message "Sandbox history saved: $file"
}


# ------------------------------------------------------------
# State Access
# ------------------------------------------------------------

function Get-SandboxState {

    param([string]$Provider)

    if (!$Script:SandboxContext) {
        throw "Sandbox not active"
    }

    return $Script:SandboxContext.State[$Provider]
}


function Update-SandboxState {
    param(
        [string]$Provider,
        [scriptblock]$Mutation
    )

    if (!$Script:SandboxContext) {
        throw "Sandbox not active"
    }

    $state = $Script:SandboxContext.State[$Provider]

    $newState = & $Mutation $state

    if ($null -ne $newState) {
        $Script:SandboxContext.State[$Provider] = $newState
    }
}


function Reset-SandboxState {

    if (!$Script:SandboxContext) {
        return
    }

    $Script:SandboxContext.State =
    ConvertFrom-Json (
        $Script:SandboxContext.Original |
        ConvertTo-Json -Depth 20
    ) -AsHashtable

    $Script:SandboxContext.Changes = @()

    Write-Log -Level INFO -Message "Sandbox reset"
}


# ------------------------------------------------------------
# Change Tracking
# ------------------------------------------------------------

function Update-SandboxChanges {
    param(
        $Provider,
        $Action,
        $Data
    )

    if (!$Script:SandboxContext) {
        return
    }

    $Script:SandboxContext.Changes += @{
        provider = $Provider
        action   = $Action
        data     = $Data
        time     = Get-Date
    }
}


function Get-SandboxChanges {
    if (!$Script:SandboxContext) {
        return @()
    }

    return $Script:SandboxContext.Changes
}


# ------------------------------------------------------------
# Provider Comparison Dispatch
# ------------------------------------------------------------

$Script:ProviderComparators = @{}


function Register-ProviderComparator {
    param(
        [string]$Provider,
        [scriptblock]$Comparator
    )

    $Script:ProviderComparators[$Provider] = $Comparator
}


function Compare-ProviderState {
    param(
        [string]$Provider,
        $Current,
        $Desired
    )

    if (!$Script:ProviderComparators.ContainsKey($Provider)) {
        throw "No comparator registered for $Provider"
    }

    $cmp = $Script:ProviderComparators[$Provider]

    & $cmp $Current $Desired
}


# ------------------------------------------------------------
# DryRun Engine
# ------------------------------------------------------------

function Invoke-SandboxDryRun {
    param(
        [hashtable]$Spec,
        [scriptblock]$SystemStateProvider
    )

    $result = @{
        Mode       = "DryRun"
        Comparison = @{}
    }

    foreach ($provider in $Script:Providers) {
        if (!$Spec.ContainsKey($provider)) {
            continue
        }

        $desired = $Spec[$provider]

        if ($Script:SandboxContext -and $Script:SandboxContext.Mode -eq "Mock") {
            $current = $Script:SandboxContext.State[$provider]
        }
        elseif ($SystemStateProvider) {
            $current = & $SystemStateProvider $provider
        }
        else {
            continue
        }

        $result.Comparison[$provider] =
        Compare-ProviderState $provider $current $desired
    }

    return $result
}


# ------------------------------------------------------------
# Diff Formatter
# ------------------------------------------------------------

function Format-SandboxDiff {
    param([hashtable]$Comparison)

    $out = @()

    foreach ($provider in $Comparison.Keys) {
        $comp = $Comparison[$provider]

        $out += "=== $provider ==="

        foreach ($a in $comp.Added) {
            $out += "[+] $a"
        }

        foreach ($r in $comp.Removed) {
            $out += "[-] $r"
        }

        foreach ($c in $comp.Changed) {
            $out += "[~] $c"
        }

        foreach ($u in $comp.Unchanged) {
            $out += "[=] $u"
        }

        $out += ""
    }

    return $out -join "`n"
}

Export-ModuleMember -Function @(
    "Test-SandboxActive"
    "Get-SandboxMode"
    "Get-SandboxContext"

    "Import-SandboxState"
    "Export-SandboxState"

    "Get-SandboxSnapshots"
    "Remove-SandboxSnapshot"

    "Enter-Sandbox"
    "Exit-Sandbox"

    "Get-SandboxState"
    "Update-SandboxState"
    "Reset-SandboxState"

    "Get-SandboxChanges"
    "Update-SandboxChanges"

    # Invoke-SandboxDryRun
    # Format-SandboxDiff
)
