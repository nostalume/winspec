[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProviderPath)

$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

& $ProviderPath
if (-not $?) { exit 1 }
