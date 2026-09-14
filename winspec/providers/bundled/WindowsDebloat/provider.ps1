Import-Module (Join-Path $PSScriptRoot '../common.psm1') -ErrorAction Stop

$request = Read-BundledProviderRequest
try {
    $result = Invoke-BundledCurrentScript -Request $request `
        -Uri 'https://debloat.raphi.re/'
    Write-BundledProviderResponse $request $result.Status $result.Output
}
catch {
    Write-BundledProviderFailure $request $_
}
