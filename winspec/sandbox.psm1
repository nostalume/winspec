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
        Registry = @{
            Explorer  = @{
                ShowHidden  = $false
                ShowFileExt = $false
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

function ConvertTo-SandboxHashtable {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [hashtable]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-SandboxHashtable $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-SandboxHashtable $_ })
    }
    if ($Value.PSObject.Properties.Count -gt 0 -and $Value.GetType().Name -eq "PSCustomObject") {
        $result = @{}
        foreach ($prop in $Value.PSObject.Properties) { $result[$prop.Name] = ConvertTo-SandboxHashtable $prop.Value }
        return $result
    }
    return $Value
}

function Get-SandboxContext {
    if (Test-Path $Script:Sandbox) {
        return ConvertTo-SandboxHashtable (Get-Content $Script:Sandbox -Raw | ConvertFrom-Json -Depth 20)
    }
    return $null
}

function Save-SandboxContext {
    param([hashtable]$Context)

    Initialize-SandboxDirectory
    $tmp = "$Script:Sandbox.tmp"
    $Context | ConvertTo-Json -Depth 20 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Script:Sandbox -Force
}

function Use-SandboxContext {
    if ($Script:SandboxContext) { return $true }
    $ctx = Get-SandboxContext
    if ($ctx) {
        $Script:SandboxContext = $ctx
        return $true
    }
    return $false
}

function Test-SandboxActive {
    return Test-Path $Script:Sandbox
}

function Get-SandboxMode {
    if (-not (Use-SandboxContext)) {
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
        $json = ConvertTo-SandboxHashtable (Get-Content $file -Raw | ConvertFrom-Json -Depth 20)
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
    $ctx.Original = ConvertTo-SandboxHashtable ($ctx.State | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20)
    $Script:SandboxContext = $ctx
    Save-SandboxContext $ctx

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

    if (-not (Use-SandboxContext)) {
        throw "Sandbox not active"
    }

    return $Script:SandboxContext.State[$Provider]
}


function Update-SandboxState {
    param(
        [string]$Provider,
        [scriptblock]$Mutation
    )

    if (-not (Use-SandboxContext)) {
        throw "Sandbox not active"
    }

    $state = $Script:SandboxContext.State[$Provider]

    $newState = & $Mutation $state

    if ($null -ne $newState) {
        $Script:SandboxContext.State[$Provider] = $newState
    }
    Save-SandboxContext $Script:SandboxContext
}


function Reset-SandboxState {

    if (-not (Use-SandboxContext)) {
        return
    }

    $Script:SandboxContext.State = ConvertTo-SandboxHashtable ($Script:SandboxContext.Original | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20)
    $Script:SandboxContext.Changes = @()
    Save-SandboxContext $Script:SandboxContext

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

    if (-not (Use-SandboxContext)) {
        return
    }

    $Script:SandboxContext.Changes += @{
        provider = $Provider
        action   = $Action
        data     = $Data
        time     = Get-Date
    }
    Save-SandboxContext $Script:SandboxContext
}


function Get-SandboxChanges {
    if (-not (Use-SandboxContext)) {
        return @()
    }

    return $Script:SandboxContext.Changes
}


Export-ModuleMember -Function @(
    "Test-SandboxActive"
    "Get-SandboxMode"
    "Get-SandboxContext"
    "Save-SandboxContext"

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
)
