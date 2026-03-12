Import-Module Pester -Force
$config = New-PesterConfiguration
$config.Run.Path = "./winspec/tests"
$config.Output.Verbosity = "Minimal"
Invoke-Pester -Configuration $config
