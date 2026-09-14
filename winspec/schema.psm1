Import-Module (Join-Path $PSScriptRoot 'providers/registry-maps.psm1') -Force

$Script:ServicePolicy = Import-PowerShellDataFile `
(Join-Path $PSScriptRoot 'providers/service-policy.psd1')
$Script:ManagedServiceNames = @($Script:ServicePolicy.Services)

$Script:CoreKeys = @(
    'SchemaVersion', 'Name', 'Description', 'Registry', 'Service', 'Feature',
    'Actions', 'Workflows')

function Add-UnknownFields {
    param(
        [hashtable]$Value,
        [string[]]$Allowed,
        [string]$Code,
        [string]$Path,
        [ref]$Errors
    )
    foreach ($key in $Value.Keys) {
        if ($key -notin $Allowed) {
            $Errors.Value += "${Code}: '$Path.$key'"
        }
    }
}

function Test-StringArray {
    param($Value)
    if ($Value -is [string] -or $Value -is [hashtable]) { return $false }
    foreach ($item in @($Value)) {
        if ($item -isnot [string]) { return $false }
    }
    return $true
}

function Test-RegistrySpecValue {
    param(
        [hashtable]$Definition,
        $Value
    )
    if ($Definition.ContainsKey('AllowedValues')) {
        $allowed = @($Definition.AllowedValues)
        if ($allowed.Count -gt 0 -and $allowed[0] -is [bool]) {
            return $Value -is [bool] -and $allowed -contains $Value
        }
        if ($allowed.Count -gt 0 -and $allowed[0] -is [string]) {
            return $Value -is [string] -and $allowed -contains $Value
        }
        return $allowed -contains $Value
    }
    switch ($Definition.Type) {
        'DWord' {
            if ($null -eq $Value -or $Value.GetType().Name -notin @(
                    'Byte', 'UInt16', 'UInt32', 'UInt64',
                    'SByte', 'Int16', 'Int32', 'Int64')) {
                return $false
            }
            return [decimal]$Value -ge 0 -and
            [decimal]$Value -le [uint32]::MaxValue
        }
        'String' { return $Value -is [string] }
        default { return $false }
    }
}

function Get-SpecSchema {
    return @{
        SchemaVersion = @{ Type = 'integer'; Required = $true }
        Name = @{ Type = 'string'; Required = $false }
        Description = @{ Type = 'string'; Required = $false }
        Registry = @{ Type = 'hashtable'; Required = $false }
        Service = @{ Type = 'hashtable'; Required = $false }
        Feature = @{ Type = 'hashtable'; Required = $false }
        Actions = @{ Type = 'hashtable'; Required = $false }
        Workflows = @{ Type = 'hashtable'; Required = $false }
    }
}

function Test-WinSpecSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [object[]]$ProviderCatalog = @()
    )

    $errors = @()
    $warnings = @()
    if (-not $Spec.ContainsKey('SchemaVersion')) {
        $errors += 'MissingSchemaVersion: SchemaVersion = 1 is required'
    }
    elseif ($Spec.SchemaVersion -ne 1) {
        $errors += "UnsupportedSchemaVersion: '$($Spec.SchemaVersion)'"
    }
    foreach ($oldKey in @('Import', 'Trigger', 'TriggerConfig')) {
        if ($Spec.ContainsKey($oldKey)) {
            $errors += "RemovedField: '$oldKey'; use Include, Actions, or Workflows"
        }
    }

    $externalState = @($ProviderCatalog | Where-Object {
            $_.Execution -eq 'Protocol' -and $_.Kind -eq 'State'
        })
    foreach ($key in $Spec.Keys) {
        if ($key -notin $Script:CoreKeys) {
            $provider = @($externalState | Where-Object Name -ieq $key)
            if ($provider.Count -ne 1) {
                $errors += "UnknownSpecificationKey: '$key'"
            }
            else {
                $warnings += "ProviderValidationUnavailable: '$key'"
            }
        }
    }

    foreach ($textKey in @('Name', 'Description')) {
        if ($Spec.ContainsKey($textKey) -and $Spec[$textKey] -isnot [string]) {
            $errors += "InvalidFieldType: '$textKey' must be a string"
        }
    }
    if ($Spec.ContainsKey('Feature')) {
        if ($Spec.Feature -isnot [hashtable]) {
            $errors += "InvalidFieldType: 'Feature' must be a map"
        }
        else {
            foreach ($feature in $Spec.Feature.Keys) {
                if ($feature -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($feature)) {
                    $errors += "InvalidFeatureName: '$feature'"
                }
                if ($Spec.Feature[$feature] -isnot [string] -or
                    $Spec.Feature[$feature] -notin @('enabled', 'disabled')) {
                    $errors += "InvalidFeatureState: '$feature'"
                }
            }
        }
    }
    if ($Spec.ContainsKey('Service')) {
        if ($Spec.Service -isnot [hashtable]) {
            $errors += "InvalidFieldType: 'Service' must be a map"
        }
        else {
            foreach ($service in $Spec.Service.Keys) {
                $value = $Spec.Service[$service]
                if ($service -isnot [string] -or
                    $Script:ManagedServiceNames -notcontains $service) {
                    $errors += "ServiceNotManaged: '$service'"
                }
                if ($value -isnot [hashtable]) {
                    $errors += "InvalidService: '$service' must be a map"
                    continue
                }
                Add-UnknownFields $value @('State', 'Startup') `
                    'UnknownServiceField' "Service.$service" ([ref]$errors)
                if ($value.ContainsKey('State') -and
                    $value.State -notin @('running', 'stopped')) {
                    $errors += "InvalidServiceState: '$service'"
                }
                if ($value.ContainsKey('Startup') -and
                    $value.Startup -notin @('automatic', 'manual', 'disabled')) {
                    $errors += "InvalidServiceStartup: '$service'"
                }
            }
        }
    }
    if ($Spec.ContainsKey('Registry')) {
        if ($Spec.Registry -isnot [hashtable]) {
            $errors += "InvalidFieldType: 'Registry' must be a map"
        }
        else {
            $maps = Get-RegistryMaps
            foreach ($category in $Spec.Registry.Keys) {
                if (-not $maps.ContainsKey($category)) {
                    $errors += "UnknownRegistryCategory: '$category'"
                    continue
                }
                if ($Spec.Registry[$category] -isnot [hashtable]) {
                    $errors += "InvalidRegistryCategory: '$category' must be a map"
                    continue
                }
                foreach ($property in $Spec.Registry[$category].Keys) {
                    if (-not $maps[$category].Properties.ContainsKey($property)) {
                        $errors += "UnknownRegistryProperty: '$category.$property'"
                        continue
                    }
                    $definition = $maps[$category].Properties[$property]
                    if (-not (Test-RegistrySpecValue $definition `
                                $Spec.Registry[$category][$property])) {
                        $errors += "InvalidRegistryValue: '$category.$property'"
                    }
                }
            }
        }
    }

    if ($Spec.ContainsKey('Actions')) {
        if ($Spec.Actions -isnot [hashtable]) {
            $errors += "InvalidFieldType: 'Actions' must be a map"
        }
        else {
            $actionProviders = @($ProviderCatalog | Where-Object Kind -EQ 'Action')
            foreach ($name in $Spec.Actions.Keys) {
                $action = $Spec.Actions[$name]
                if ([string]::IsNullOrWhiteSpace($name) -or
                    $action -isnot [hashtable]) {
                    $errors += "InvalidAction: '$name' must be a named map"
                    continue
                }
                Add-UnknownFields $action @('Use', 'With') 'UnknownActionField' `
                    "Actions.$name" ([ref]$errors)
                if (-not $action.ContainsKey('Use') -or
                    $action.Use -isnot [string]) {
                    $errors += "InvalidAction: '$name' requires a string Use"
                    continue
                }
                $provider = @($actionProviders | Where-Object Name -ieq $action.Use)
                if ($provider.Count -ne 1) {
                    $errors += "UnknownActionProvider: '$($action.Use)'"
                    continue
                }
                $with = if ($action.ContainsKey('With')) { $action.With } else { @{} }
                if ($with -isnot [hashtable]) {
                    $errors += "InvalidActionWith: '$name.With' must be a map"
                    continue
                }
                if ($action.Use -ieq 'Script') {
                    Add-UnknownFields $with `
                    @('File', 'Uri', 'Args', 'Sha256', 'Interactive') `
                        'UnknownScriptActionField' "Actions.$name.With" `
                    ([ref]$errors)
                    $hasFile = $with.ContainsKey('File')
                    $hasUri = $with.ContainsKey('Uri')
                    if ($hasFile -eq $hasUri) {
                        $errors += "InvalidScriptAction: '$name' needs exactly one of File or Uri"
                    }
                    foreach ($sourceKey in @('File', 'Uri')) {
                        if ($with.ContainsKey($sourceKey) -and
                            ($with[$sourceKey] -isnot [string] -or
                            [string]::IsNullOrWhiteSpace($with[$sourceKey]))) {
                            $errors += "InvalidScriptSource: '$name.$sourceKey'"
                        }
                    }
                    if ($hasUri -and $with.Uri -is [string] -and
                        -not [string]::IsNullOrWhiteSpace($with.Uri)) {
                        $parsedUri = $null
                        if (-not [Uri]::TryCreate(
                                $with.Uri, [UriKind]::Absolute,
                                [ref]$parsedUri) -or
                            $parsedUri.Scheme -notin @('http', 'https')) {
                            $errors += "InvalidScriptUri: '$name'"
                        }
                        elseif ($parsedUri.Scheme -eq 'http' -and
                            -not $with.ContainsKey('Sha256')) {
                            $errors += "InsecureRemoteScript: '$name' HTTP requires Sha256"
                        }
                    }
                    if ($with.ContainsKey('Args') -and
                        -not (Test-StringArray $with.Args)) {
                        $errors += "InvalidScriptArgument: '$name'"
                    }
                    if ($with.ContainsKey('Sha256') -and
                        ($with.Sha256 -isnot [string] -or
                        $with.Sha256 -notmatch '^[0-9a-fA-F]{64}$')) {
                        $errors += "InvalidSha256: '$name'"
                    }
                    if ($hasFile -and $with.ContainsKey('Sha256')) {
                        $errors += "InvalidSha256: '$name' uses Sha256 with File"
                    }
                    if ($with.ContainsKey('Interactive') -and
                        $with.Interactive -isnot [bool]) {
                        $errors += "InvalidInteractive: '$name'"
                    }
                    if ($hasUri -and $with.ContainsKey('Interactive') -and
                        $with.Interactive) {
                        $errors += "InteractiveRemoteScript: '$name'"
                    }
                }
                else {
                    $warnings += "ProviderValidationUnavailable: action '$name'"
                }
            }
        }
    }

    if ($Spec.ContainsKey('Workflows')) {
        if ($Spec.Workflows -isnot [hashtable]) {
            $errors += "InvalidFieldType: 'Workflows' must be a map"
        }
        else {
            foreach ($name in $Spec.Workflows.Keys) {
                $workflow = $Spec.Workflows[$name]
                if ([string]::IsNullOrWhiteSpace($name) -or
                    $workflow -isnot [hashtable]) {
                    $errors += "InvalidWorkflow: '$name' must be a named map"
                    continue
                }
                Add-UnknownFields $workflow @('Checkpoint', 'Steps') `
                    'UnknownWorkflowField' "Workflows.$name" ([ref]$errors)
                if ($workflow.ContainsKey('Checkpoint') -and
                    $workflow.Checkpoint -isnot [bool]) {
                    $errors += "InvalidWorkflowCheckpoint: '$name'"
                }
                if (-not $workflow.ContainsKey('Steps') -or
                    $workflow.Steps -is [string] -or
                    $workflow.Steps -is [hashtable]) {
                    $errors += "InvalidWorkflowSteps: '$name' requires an array"
                    continue
                }
                if (@($workflow.Steps).Count -eq 0) {
                    $errors += "InvalidWorkflowSteps: '$name' requires at least one step"
                    continue
                }
                $stepIndex = 0
                foreach ($step in @($workflow.Steps)) {
                    $path = "Workflows.$name.Steps[$stepIndex]"
                    if ($step -isnot [hashtable] -or $step.Keys.Count -ne 1 -or
                        $step.Keys[0] -notin @('Apply', 'Run', 'Capture')) {
                        $errors += "InvalidWorkflowStep: '$path' needs exactly one of Apply, Run, or Capture"
                        $stepIndex++
                        continue
                    }
                    $kind = [string]$step.Keys[0]
                    $value = $step[$kind]
                    if ($kind -eq 'Run') {
                        if ($value -isnot [string] -or
                            [string]::IsNullOrWhiteSpace($value)) {
                            $errors += "InvalidWorkflowRun: '$path.Run'"
                        }
                        elseif (-not $Spec.ContainsKey('Actions') -or
                            -not $Spec.Actions.ContainsKey($value)) {
                            $errors += "UnknownAction: '$value'"
                        }
                    }
                    else {
                        if ($value -isnot [hashtable]) {
                            $errors += "InvalidWorkflow$kind`: '$path.$kind' must be a map"
                            $stepIndex++
                            continue
                        }
                        $allowed = if ($kind -eq 'Apply') {
                            @('Providers')
                        }
                        else {
                            @('Output', 'Providers', 'Force')
                        }
                        Add-UnknownFields $value $allowed `
                            "UnknownWorkflow$kind`Field" "$path.$kind" `
                        ([ref]$errors)
                        if ($value.ContainsKey('Providers') -and
                            -not (Test-StringArray $value.Providers)) {
                            $errors += "InvalidWorkflowProviders: '$path.$kind'"
                        }
                        if ($kind -eq 'Capture') {
                            if (-not $value.ContainsKey('Output') -or
                                $value.Output -isnot [string] -or
                                [string]::IsNullOrWhiteSpace($value.Output)) {
                                $errors += "InvalidWorkflowCapture: '$path.Capture.Output'"
                            }
                            if ($value.ContainsKey('Force') -and
                                $value.Force -isnot [bool]) {
                                $errors += "InvalidWorkflowForce: '$path.Capture.Force'"
                            }
                        }
                    }
                    $stepIndex++
                }
            }
        }
    }

    return [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        Errors = @($errors)
        Warnings = @($warnings)
    }
}

function Test-SpecSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [object[]]$ProviderCatalog = @()
    )
    return (Test-WinSpecSchema -Spec $Spec `
            -ProviderCatalog $ProviderCatalog).Valid
}

Export-ModuleMember -Function @(
    'Get-SpecSchema', 'Test-WinSpecSchema', 'Test-SpecSchema')
