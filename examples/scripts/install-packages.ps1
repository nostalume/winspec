[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Roles = 'base,dev,backup',
    [switch]$Force,
    [switch]$IncludeInteractive
)

$roleCatalog = @{
    base = @{
        Scoop = @(
            '7zip', 'git', 'starship', 'rage', 'neovim', 'shed', 'aria2',
            'bat', 'fd', 'fzf', 'ripgrep', 'tree-sitter', 'scoop-search',
            'eget', 'just', 'zed', 'gsudo', 'Maple-Mono', 'Maple-Mono-NF',
            'Maple-Mono-NF-CN', 'clash-verge-rev')
        Winget = @(
            'Microsoft.PowerToys', 'Microsoft.PowerShell',
            'MartiCliment.UniGetUI', 'GitHub.cli')
    }
    daily = @{
        Winget = @(
            @{ Name = 'Vivaldi.Vivaldi'; Interactive = $true }
            @{ Name = 'Valve.Steam'; Interactive = $true }
            @{ Name = 'EpicGames.EpicGamesLauncher'; Interactive = $true }
            @{ Name = 'Tencent.QQ'; Interactive = $true })
    }
    dev = @{
        Scoop = @('aqua', 'pixi', 'hugo-extended')
        Winget = @('Rustlang.Rustup')
    }
    backup = @{
        Scoop = @('rustic', 'openlist', 'gopass')
    }
}

function Resolve-Package {
    param([Parameter(Mandatory)]$Package)

    if ($Package -is [string]) {
        return [pscustomobject]@{
            Name = $Package
            Flags = @()
            Interactive = $false
        }
    }
    $flags = if ($null -ne $Package.Flags) { @($Package.Flags) } else { @() }
    return [pscustomobject]@{
        Name = [string]$Package.Name
        Flags = @($flags)
        Interactive = [bool]$Package.Interactive -or ($flags -contains '-i')
    }
}

$selectedRoles = @($Roles -split ',' | ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
if ($selectedRoles.Count -eq 0) {
    Write-Error 'InvalidRoles: provide at least one comma-separated role'
    exit 2
}
$unknownRoles = @($selectedRoles | Where-Object {
        -not $roleCatalog.ContainsKey($_)
    } | Select-Object -Unique)
if ($unknownRoles.Count -gt 0) {
    Write-Error "UnknownRole: $($unknownRoles -join ', ')"
    exit 2
}

$requiredProviders = @($selectedRoles | ForEach-Object {
        $definition = $roleCatalog[$_]
        foreach ($name in @('Scoop', 'Winget')) {
            if (@($definition[$name]).Count -gt 0) {
                $name.ToLowerInvariant()
            }
        }
    } | Select-Object -Unique)
foreach ($provider in $requiredProviders) {
    if (-not (Get-Command $provider -ErrorAction SilentlyContinue)) {
        Write-Error "PackageManagerNotFound: '$provider'"
        exit 2
    }
}

$failed = 0
foreach ($role in $selectedRoles) {
    $roleDefinition = $roleCatalog[$role]
    foreach ($providerName in @('Scoop', 'Winget')) {
        foreach ($rawPackage in @($roleDefinition[$providerName])) {
            if ($null -eq $rawPackage) { continue }
            $provider = $providerName.ToLowerInvariant()
            $package = Resolve-Package $rawPackage
            if ($package.Interactive -and -not $IncludeInteractive) {
                [pscustomobject]@{
                    Provider = $provider
                    Role = $role
                    Package = $package.Name
                    Status = 'Skipped'
                    Reason = 'InteractivePackage'
                }
                continue
            }

            $arguments = if ($provider -eq 'scoop') {
                @('install')
            }
            else {
                @('install', '--accept-source-agreements',
                    '--accept-package-agreements')
            }
            if ($Force) { $arguments += '--force' }
            if ($provider -eq 'winget' -and -not $package.Interactive) {
                $arguments += '--silent'
            }
            $arguments += @($package.Flags) + $package.Name

            if (-not $PSCmdlet.ShouldProcess(
                    "$provider package $($package.Name)", 'Install')) {
                [pscustomobject]@{
                    Provider = $provider
                    Role = $role
                    Package = $package.Name
                    Status = 'DryRun'
                }
                continue
            }

            $reason = $null
            try {
                & $provider @arguments
                $exitCode = $LASTEXITCODE
            }
            catch {
                $exitCode = 1
                $reason = $_.Exception.Message
            }
            if ($exitCode -ne 0) { $failed++ }
            $result = [ordered]@{
                Provider = $provider
                Role = $role
                Package = $package.Name
                Status = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
                ExitCode = $exitCode
            }
            if ($reason) { $result.Reason = $reason }
            [pscustomobject]$result
        }
    }
}

if ($failed -gt 0) { exit 1 }
