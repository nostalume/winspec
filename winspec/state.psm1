Import-Module (Join-Path $PSScriptRoot 'comparison.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'provider-runtime.psm1') -ErrorAction Stop

function Get-Managers {
    return @(
        [pscustomobject]@{Name = 'Registry'; Type = 'State'; Path = (Join-Path $PSScriptRoot 'providers/registry.psm1') }
        [pscustomobject]@{Name = 'Service'; Type = 'State'; Path = (Join-Path $PSScriptRoot 'providers/service.psm1') }
        [pscustomobject]@{Name = 'Feature'; Type = 'State'; Path = (Join-Path $PSScriptRoot 'providers/feature.psm1') }
    )
}

function Resolve-ProviderList {
    param([object[]]$Available, [string[]]$Providers)
    if (-not $Providers -or $Providers.Count -eq 0) { return @($Available) }
    $result = @()
    foreach ($name in $Providers) {
        $match = @($Available | Where-Object Name -ieq $name)
        if ($match.Count -ne 1) { throw "UnknownProvider: '$name'" }
        $result += $match[0]
    }
    return $result
}

function Get-ProviderCommand {
    param($Provider, [string]$Verb)
    $module = Import-Module $Provider.Path -PassThru -ErrorAction Stop
    $name = "$Verb-$($Provider.Name)State"
    $command = $module.ExportedCommands[$name]
    if (-not $command) { return $null }
    return $command
}

function Export-ProviderState {
    param([Parameter(Mandatory)]$Provider)
    $command = Get-ProviderCommand $Provider 'Export'
    if (-not $command) { throw "MissingProviderCapability: '$($Provider.Name)' lacks capture" }
    return & $command
}

function Get-SystemState {
    [CmdletBinding()]
    param([string[]]$Providers)
    $result = @{}
    foreach ($provider in Resolve-ProviderList (Get-Managers) $Providers) {
        try {
            $value = Export-ProviderState $provider
        }
        catch {
            throw "ProviderFailed: '$($provider.Name)' capture: $($_.Exception.Message)"
        }
        if ($null -ne $value -and $value.Count -gt 0) { $result[$provider.Name] = $value }
    }
    return $result
}

function Compare-ProviderState {
    param([Parameter(Mandatory)]$Provider, [hashtable]$Desired, [hashtable]$Actual)
    $command = Get-ProviderCommand $Provider 'Compare'
    if ($command) { return @(& $command -System $Actual -Desired $Desired) }
    if (Test-WinSpecValueEqual $Desired $Actual) { return @() }
    return @([pscustomobject]@{Path = $Provider.Name; ConfigValue = $Desired; SystemValue = $Actual; Type = 'Changed' })
}

function Compare-SystemState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Spec, [hashtable]$Against, [string[]]$Providers)
    if ($null -eq $Against) { $Against = Get-SystemState -Providers $Providers }
    $result = @{Added = @(); Changed = @(); Removed = @(); Equal = @() }
    foreach ($provider in Resolve-ProviderList (Get-Managers) $Providers) {
        if (-not $Spec.ContainsKey($provider.Name)) { continue }
        $actualValue = if ($Against.ContainsKey($provider.Name)) { $Against[$provider.Name] } else { @{} }
        foreach ($item in @(Compare-ProviderState $provider $Spec[$provider.Name] $actualValue)) {
            $kind = if ($item.Type -in @('Added', 'Changed', 'Removed', 'Equal')) { $item.Type } else { 'Changed' }
            $result[$kind] += $item
        }
    }
    return $result
}

function Invoke-Manager {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][hashtable]$Config,
        [hashtable]$CommonParameters = @{})
    $desired = $Config[$Provider.Name]
    $test = Get-ProviderCommand $Provider 'Test'
    $set = Get-ProviderCommand $Provider 'Set'
    if (-not $test -or -not $set) { throw "MissingProviderCapability: '$($Provider.Name)' lacks test/apply" }
    if (& $test -Desired $desired) { return @{Status = 'Unchanged' } }
    if ($CommonParameters.ContainsKey('WhatIf') -and $CommonParameters.WhatIf) {
        return @{Status = 'Planned' }
    }
    return & $set -Desired $desired
}

function Invoke-Managers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [string[]]$Providers,
        [hashtable]$CommonParameters = @{})
    $result = @{}
    foreach ($provider in Resolve-ProviderList (Get-Managers) $Providers) {
        if ($Config.ContainsKey($provider.Name)) {
            $result[$provider.Name] = Invoke-Manager $provider $Config $CommonParameters
        }
    }
    return $result
}

function Test-WinSpecResultSuccessful {
    param($Result)
    if ($null -eq $Result) { return $false }
    if ($Result -is [hashtable] -and $Result.ContainsKey('Status')) {
        return $Result.Status -notin @('Error', 'Failed')
    }
    return $true
}

function Invoke-WinSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Spec, [string[]]$Providers, [switch]$WhatIf)
    $common = if ($WhatIf) { @{WhatIf = $true } } else { @{} }
    $values = Invoke-Managers -Config $Spec -Providers $Providers -CommonParameters $common
    $success = $true
    foreach ($value in $values.Values) { if (-not (Test-WinSpecResultSuccessful $value)) { $success = $false } }
    return @{Success = $success; Providers = $values }
}

function Resolve-WinSpecStateProviders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Catalog,
        [string[]]$Providers,
        [hashtable]$Spec,
        [switch]$SpecScoped
    )
    $available = @($Catalog | Where-Object Kind -EQ 'State')
    if ($Providers -and $Providers.Count -gt 0) {
        return Resolve-ProviderList $available $Providers
    }
    if ($SpecScoped) {
        if ($null -eq $Spec) { return @() }
        return @($available | Where-Object {
                $Spec.ContainsKey($_.Name)
            })
    }
    return @($available | Where-Object Execution -EQ 'Core')
}

function Assert-WinSpecStateCapability {
    param([object[]]$Providers, [string]$Operation)
    foreach ($provider in $Providers) {
        if ($provider.Execution -eq 'Protocol' -and
            $Operation -notin @($provider.Operations)) {
            throw "UnsupportedProviderOperation: '$($provider.Name)' lacks '$Operation'"
        }
    }
}

function Get-WinSpecObservedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Catalog,
        [hashtable]$Spec,
        [string[]]$Providers,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $specScoped = $PSBoundParameters.ContainsKey('Spec')
    $selected = Resolve-WinSpecStateProviders -Catalog $Catalog `
        -Providers $Providers -Spec $Spec -SpecScoped:$specScoped
    Assert-WinSpecStateCapability $selected 'capture'
    $result = @{}
    $core = @($selected | Where-Object Execution -EQ 'Core' |
            ForEach-Object Name)
    if ($core.Count -gt 0) {
        $captured = Get-SystemState -Providers $core
        foreach ($key in $captured.Keys) { $result[$key] = $captured[$key] }
    }
    foreach ($provider in @($selected | Where-Object Execution -EQ 'Protocol')) {
        $configuration = if ($null -ne $Spec -and
            $Spec.ContainsKey($provider.Name)) {
            $Spec[$provider.Name]
        }
        else {
            @{}
        }
        $response = Invoke-ExternalProvider -Provider $provider `
            -Operation capture -RequestInput @{
            configuration = $configuration
            executionPolicy = @{ timeoutSeconds = $TimeoutSeconds }
        } -TimeoutSeconds $TimeoutSeconds
        if ($response.Status -eq 'Failed') {
            throw "ProviderFailed: '$($provider.Name)'"
        }
        if ($response.Status -ne 'Succeeded') {
            throw "InvalidProviderStatus: '$($provider.Name)' capture returned '$($response.Status)'"
        }
        $result[$provider.Name] = $response.Output
    }
    return $result
}

function Compare-WinSpecState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][object[]]$Catalog,
        [hashtable]$Against,
        [string[]]$Providers,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $selected = Resolve-WinSpecStateProviders -Catalog $Catalog `
        -Providers $Providers -Spec $Spec -SpecScoped
    Assert-WinSpecStateCapability $selected 'compare'
    if ($null -eq $Against) {
        $Against = Get-WinSpecObservedState -Catalog $Catalog -Spec $Spec `
            -Providers @($selected.Name) -TimeoutSeconds $TimeoutSeconds
    }
    $items = @()
    foreach ($provider in $selected) {
        if (-not $Spec.ContainsKey($provider.Name)) { continue }
        $actual = if ($Against.ContainsKey($provider.Name)) {
            $Against[$provider.Name]
        }
        else {
            @{}
        }
        if ($provider.Execution -eq 'Core') {
            $manager = Get-Managers | Where-Object Name -ieq $provider.Name
            try {
                $differences = @(Compare-ProviderState $manager `
                        $Spec[$provider.Name] $actual)
            }
            catch {
                throw "ProviderFailed: '$($provider.Name)' compare: $($_.Exception.Message)"
            }
            $changed = @($differences | Where-Object Type -NE 'Equal')
            $status = if ($changed.Count -eq 0) { 'Unchanged' } else { 'Different' }
            $items += [pscustomobject]@{
                Name = $provider.Name
                Status = $status
                Differences = $changed
            }
        }
        else {
            $response = Invoke-ExternalProvider -Provider $provider `
                -Operation compare -RequestInput @{
                configuration = $Spec[$provider.Name]
                observed = $actual
                executionPolicy = @{ timeoutSeconds = $TimeoutSeconds }
            } -TimeoutSeconds $TimeoutSeconds
            if ($response.Status -eq 'Failed') {
                throw "ProviderFailed: '$($provider.Name)' compare"
            }
            if ($response.Status -notin @('Different', 'Unchanged')) {
                throw "InvalidProviderStatus: '$($provider.Name)' compare returned '$($response.Status)'"
            }
            $items += [pscustomobject]@{
                Name = $provider.Name
                Status = $response.Status
                Differences = @($response.Output.differences)
                Diagnostics = @($response.Diagnostics)
            }
        }
    }
    $status = if (@($items | Where-Object Status -EQ 'Different').Count -gt 0) {
        'Different'
    }
    else {
        'Unchanged'
    }
    return [pscustomobject]@{ Status = $status; Providers = @($items) }
}

function Invoke-WinSpecStateApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][object[]]$Catalog,
        [string[]]$Providers,
        [switch]$DryRun,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $selected = Resolve-WinSpecStateProviders -Catalog $Catalog `
        -Providers $Providers -Spec $Spec -SpecScoped
    Assert-WinSpecStateCapability $selected 'apply'
    $results = @()
    foreach ($provider in $selected) {
        if (-not $Spec.ContainsKey($provider.Name)) { continue }
        if ($provider.Execution -eq 'Core') {
            $manager = Get-Managers | Where-Object Name -ieq $provider.Name
            $common = if ($DryRun) { @{ WhatIf = $true } } else { @{} }
            try {
                $value = Invoke-Manager $manager $Spec $common
                $coreResult = ConvertTo-WinSpecCoreResult `
                    -ProviderName $provider.Name -Value $value
            }
            catch {
                $message = $_.Exception.Message
                $coreResult = [pscustomobject]@{
                    Status = 'Failed'
                    Output = @{}
                    Diagnostics = @([pscustomobject]@{
                            severity = 'error'
                            code = ($message -split ':')[0]
                            message = $message
                            resource = $provider.Name
                        })
                }
            }
            $results += [pscustomobject]@{
                Name = $provider.Name
                Status = $coreResult.Status
                Output = $coreResult.Output
                Diagnostics = @($coreResult.Diagnostics)
            }
        }
        else {
            $capture = Invoke-ExternalProvider -Provider $provider `
                -Operation capture -RequestInput @{
                configuration = $Spec[$provider.Name]
                executionPolicy = @{ timeoutSeconds = $TimeoutSeconds }
            } -TimeoutSeconds $TimeoutSeconds
            if ($capture.Status -eq 'Failed') {
                throw "ProviderFailed: '$($provider.Name)' capture"
            }
            if ($capture.Status -ne 'Succeeded') {
                throw "InvalidProviderStatus: '$($provider.Name)' capture returned '$($capture.Status)'"
            }
            $comparison = Invoke-ExternalProvider -Provider $provider `
                -Operation compare -RequestInput @{
                configuration = $Spec[$provider.Name]
                observed = $capture.Output
                executionPolicy = @{ timeoutSeconds = $TimeoutSeconds }
            } -TimeoutSeconds $TimeoutSeconds
            if ($comparison.Status -eq 'Failed') {
                throw "ProviderFailed: '$($provider.Name)' compare"
            }
            if ($comparison.Status -notin @('Different', 'Unchanged')) {
                throw "InvalidProviderStatus: '$($provider.Name)' compare returned '$($comparison.Status)'"
            }
            if ($comparison.Status -eq 'Unchanged') {
                $results += [pscustomobject]@{
                    Name = $provider.Name
                    Status = 'Unchanged'
                    Output = $comparison.Output
                    Diagnostics = @($comparison.Diagnostics)
                }
                continue
            }
            if ($DryRun) {
                $results += [pscustomobject]@{
                    Name = $provider.Name
                    Status = 'Planned'
                    Output = $comparison.Output
                    Diagnostics = @($comparison.Diagnostics)
                }
                continue
            }
            $response = Invoke-ExternalProvider -Provider $provider `
                -Operation apply `
                -RequestInput @{
                configuration = $Spec[$provider.Name]
                executionPolicy = @{
                    timeoutSeconds = $TimeoutSeconds
                }
            } -TimeoutSeconds $TimeoutSeconds
            $results += [pscustomobject]@{
                Name = $provider.Name
                Status = $response.Status
                Output = $response.Output
                Diagnostics = @($response.Diagnostics)
            }
        }
    }
    $failed = @($results | Where-Object Status -In @('Failed', 'Error'))
    return [pscustomobject]@{
        Status = if ($failed.Count) {
            'Failed'
        }
        elseif ($results.Count -gt 0 -and
            @($results | Where-Object Status -NE 'Unchanged').Count -eq 0) {
            'Unchanged'
        }
        elseif ($DryRun) {
            'Planned'
        }
        else {
            'Succeeded'
        }
        Providers = @($results)
    }
}

function Get-WinSpecCoreDiagnostics {
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        $Value,
        [Parameter(Mandatory)][string]$Resource
    )
    $diagnostics = @()
    if ($Value -isnot [Collections.IDictionary]) {
        return $diagnostics
    }
    if ($Value.Contains('Diagnostics')) {
        foreach ($item in @($Value.Diagnostics)) {
            if ($item -isnot [Collections.IDictionary] -or
                -not $item.Contains('Code') -or
                -not $item.Contains('Message')) {
                continue
            }
            $diagnostics += [pscustomobject]@{
                severity = if ($item.Contains('Severity')) {
                    [string]$item.Severity
                }
                else {
                    'warning'
                }
                code = [string]$item.Code
                message = [string]$item.Message
                resource = $Resource
            }
        }
    }
    if ($Value.Contains('Status') -and
        $Value.Status -in @('Error', 'Failed')) {
        $code = if ($Value.Contains('Reason') -and $Value.Reason) {
            [string]$Value.Reason
        }
        else {
            "${ProviderName}ApplyFailed"
        }
        $message = if ($Value.Contains('Message') -and $Value.Message) {
            [string]$Value.Message
        }
        else {
            "The $Resource resource failed to apply"
        }
        return @([pscustomobject]@{
                severity = 'error'
                code = $code
                message = $message
                resource = $Resource
            })
    }
    foreach ($key in $Value.Keys) {
        if ($key -in @('Status', 'Reason', 'Message', 'Diagnostics')) { continue }
        $diagnostics += @(Get-WinSpecCoreDiagnostics `
                -ProviderName $ProviderName -Value $Value[$key] `
                -Resource "$Resource.$key")
    }
    return $diagnostics
}

function ConvertTo-WinSpecCoreResult {
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        $Value
    )
    $diagnostics = @(Get-WinSpecCoreDiagnostics `
            -ProviderName $ProviderName -Value $Value `
            -Resource $ProviderName)
    $failures = @($diagnostics | Where-Object severity -EQ 'error')
    $status = if ($failures.Count -gt 0) {
        'Failed'
    }
    elseif ($Value -is [Collections.IDictionary] -and
        $Value.Contains('Status') -and
        $Value.Status -in @('Unchanged', 'Planned')) {
        [string]$Value.Status
    }
    else {
        'Succeeded'
    }
    return [pscustomobject]@{
        Status = $status
        Output = $Value
        Diagnostics = $diagnostics
    }
}

Export-ModuleMember -Function 'Get-Managers', 'Resolve-ProviderList', 'Export-ProviderState',
'Get-SystemState', 'Compare-ProviderState', 'Compare-SystemState', 'Invoke-Manager',
'Invoke-Managers', 'Test-WinSpecResultSuccessful', 'Invoke-WinSpec',
'Resolve-WinSpecStateProviders', 'Get-WinSpecObservedState',
'Compare-WinSpecState', 'Invoke-WinSpecStateApply'
