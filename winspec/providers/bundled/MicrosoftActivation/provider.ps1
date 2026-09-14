Import-Module (Join-Path $PSScriptRoot '../common.psm1') -ErrorAction Stop

$request = Read-BundledProviderRequest
try {
    $result = Invoke-BundledCurrentScript -Request $request `
        -Uri 'https://get.activated.win/'
    Write-BundledProviderResponse $request $result.Status $result.Output
}
catch {
    Write-BundledProviderFailure $request $_
}
