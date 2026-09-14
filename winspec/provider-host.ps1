[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProviderPath)

$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$inputBuffer = New-Object IO.MemoryStream
try {
    [Console]::OpenStandardInput().CopyTo($inputBuffer)
    $inputText = $utf8.GetString($inputBuffer.ToArray())
}
finally {
    $inputBuffer.Dispose()
}
[Console]::SetIn((New-Object IO.StringReader($inputText)))

& $ProviderPath
if (-not $?) { exit 1 }
