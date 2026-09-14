Import-Module (Join-Path $PSScriptRoot 'actions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'state.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'spec.psm1') -ErrorAction Stop

function Get-WorkflowStepKind {
    param([hashtable]$Step)
    return [string]@($Step.Keys)[0]
}

function Resolve-WorkflowOutputPath {
    param([string]$Output, [string]$BasePath)
    if ([IO.Path]::IsPathRooted($Output)) {
        return [IO.Path]::GetFullPath($Output)
    }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Output))
}

function Test-WorkflowPreflight {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][hashtable]$Workflow,
        [Parameter(Mandatory)][object[]]$Catalog,
        [switch]$DryRun,
        [switch]$MachineOutput,
        [int]$TimeoutSeconds
    )
    $basePath = [IO.Path]::GetDirectoryName($Document.Path)
    $spec = $Document.Spec
    $plans = @()
    $index = 0
    foreach ($step in @($Workflow.Steps)) {
        $kind = Get-WorkflowStepKind $step
        $value = $step[$kind]
        switch ($kind) {
            'Run' {
                $action = $spec.Actions[$value]
                $provider = @($Catalog | Where-Object {
                        $_.Kind -eq 'Action' -and $_.Name -ieq $action.Use
                    })[0]
                $configuredInteractive = $action.Use -ieq 'Script' -and
                $action.ContainsKey('With') -and
                $action.With.ContainsKey('Interactive') -and
                $action.With.Interactive
                if ($configuredInteractive -and ($MachineOutput -or $DryRun)) {
                    throw "InteractiveWorkflowOutput: action '$value' cannot use JSON or DryRun"
                }
                $preview = Invoke-WinSpecAction -Action $action -Provider $provider `
                    -BasePath $basePath -DryRun `
                    -TimeoutSeconds $TimeoutSeconds
                if ($preview.Status -eq 'Failed') {
                    throw "ProviderPreviewFailed: '$value'"
                }
                $plans += [pscustomobject]@{
                    Index = $index
                    Kind = $kind
                    Name = $value
                    Provider = $provider
                    Preview = $preview
                }
            }
            'Apply' {
                $selected = Resolve-WinSpecStateProviders -Catalog $Catalog `
                    -Providers @($value.Providers) -Spec $spec -SpecScoped
                foreach ($provider in $selected) {
                    if ($provider.Execution -eq 'Protocol' -and
                        'apply' -notin @($provider.Operations)) {
                        throw "UnsupportedProviderOperation: '$($provider.Name)' lacks 'apply'"
                    }
                }
                $comparison = Compare-WinSpecState -Spec $spec `
                    -Catalog $Catalog -Providers @($selected.Name) `
                    -TimeoutSeconds $TimeoutSeconds
                $plans += [pscustomobject]@{
                    Index = $index
                    Kind = $kind
                    Providers = @($value.Providers)
                    Preview = $comparison
                }
            }
            'Capture' {
                $outputPath = Resolve-WorkflowOutputPath $value.Output $basePath
                if ($outputPath -in @($Document.SourcePaths)) {
                    throw "CaptureOverwritesInput: '$outputPath'"
                }
                if ([IO.File]::Exists($outputPath) -and -not [bool]$value.Force) {
                    throw "OutputExists: '$outputPath'"
                }
                $null = Resolve-WinSpecStateProviders -Catalog $Catalog `
                    -Providers @($value.Providers) -Spec $spec -SpecScoped
                $plans += [pscustomobject]@{
                    Index = $index
                    Kind = $kind
                    Providers = @($value.Providers)
                    OutputPath = $outputPath
                    Force = [bool]$value.Force
                    Preview = [pscustomobject]@{
                        Status = 'Planned'
                        Path = $outputPath
                        Publishes = $false
                    }
                }
            }
        }
        $index++
    }
    if ($Workflow.ContainsKey('Checkpoint') -and $Workflow.Checkpoint -and
        -not $DryRun) {
        Import-Module (Join-Path $PSScriptRoot 'checkpoint.psm1') -Force
        $capability = Test-CheckpointCapability
        if (-not $capability.CanCreateCheckpoint) {
            throw 'CheckpointUnavailable: system restore and administrator privileges are required'
        }
    }
    return @($plans)
}

function Invoke-WinSpecWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Catalog,
        [switch]$DryRun,
        [switch]$MachineOutput,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $spec = $Document.Spec
    if (-not $spec.ContainsKey('Workflows') -or
        -not $spec.Workflows.ContainsKey($Name)) {
        throw "UnknownWorkflow: '$Name'"
    }
    $workflow = $spec.Workflows[$Name]
    $plans = Test-WorkflowPreflight -Document $Document -Workflow $workflow `
        -Catalog $Catalog -DryRun:$DryRun -MachineOutput:$MachineOutput `
        -TimeoutSeconds $TimeoutSeconds
    $basePath = [IO.Path]::GetDirectoryName($Document.Path)
    $receipts = @()
    $failed = $false
    $checkpointCreated = $false
    foreach ($plan in $plans) {
        if ($failed) {
            $receipts += [pscustomobject]@{
                Index = $plan.Index
                Kind = $plan.Kind
                Status = 'Skipped'
            }
            continue
        }
        if ($DryRun) {
            $plannedStatus = if ($plan.Kind -eq 'Apply' -and
                $plan.Preview.Status -eq 'Unchanged') {
                'Unchanged'
            }
            else {
                'Planned'
            }
            $receipts += [pscustomobject]@{
                Index = $plan.Index
                Kind = $plan.Kind
                Name = $plan.Name
                Status = $plannedStatus
                Result = $plan.Preview
            }
            continue
        }
        try {
            if ($workflow.Checkpoint -and -not $checkpointCreated) {
                $checkpoint = New-Checkpoint -Name "WinSpec-$Name"
                if (-not $checkpoint.Success) {
                    throw "CheckpointFailed: $($checkpoint.Reason)"
                }
                $checkpointCreated = $true
            }
            switch ($plan.Kind) {
                'Run' {
                    $action = $spec.Actions[$plan.Name]
                    $value = Invoke-WinSpecAction -Action $action `
                        -Provider $plan.Provider -BasePath $basePath `
                        -TimeoutSeconds $TimeoutSeconds
                }
                'Apply' {
                    $value = Invoke-WinSpecStateApply -Spec $spec `
                        -Catalog $Catalog -Providers $plan.Providers `
                        -TimeoutSeconds $TimeoutSeconds
                }
                'Capture' {
                    $captured = Get-WinSpecObservedState -Catalog $Catalog `
                        -Spec $spec -Providers $plan.Providers `
                        -TimeoutSeconds $TimeoutSeconds
                    $captured.SchemaVersion = 1
                    Save-Configuration -Config $captured `
                        -Path $plan.OutputPath -Force:$plan.Force | Out-Null
                    $value = [pscustomobject]@{
                        Status = 'Succeeded'
                        Path = $plan.OutputPath
                    }
                }
            }
            $status = if ($value.Status) { $value.Status } else { 'Succeeded' }
            if ($status -in @('Failed', 'Error')) { $failed = $true }
            $receipts += [pscustomobject]@{
                Index = $plan.Index
                Kind = $plan.Kind
                Name = $plan.Name
                Status = $status
                Result = $value
            }
        }
        catch {
            $failed = $true
            $receipts += [pscustomobject]@{
                Index = $plan.Index
                Kind = $plan.Kind
                Name = $plan.Name
                Status = 'Failed'
                Diagnostics = @([pscustomobject]@{
                        Code = ($_.Exception.Message -split ':')[0]
                        Message = $_.Exception.Message
                    })
            }
        }
    }
    return [pscustomobject]@{
        Status = if ($failed) { 'Failed' } elseif ($DryRun) { 'Planned' } else { 'Succeeded' }
        Name = $Name
        CheckpointCreated = $checkpointCreated
        Steps = @($receipts)
    }
}

Export-ModuleMember -Function 'Invoke-WinSpecWorkflow'
