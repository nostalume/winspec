[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entry = Join-Path $root 'winspec/winspec.ps1'
$errors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'InvalidCliSource: cannot generate Help reference' }
# Read only literal inventory assignments; never execute the CLI or configuration.
$optionAst = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$Script:Options'
    }, $false).Right.Find({ param($node)
        $node -is [Management.Automation.Language.HashtableAst]
    }, $false)
$options = [ordered]@{}
foreach ($pair in $optionAst.KeyValuePairs) {
    $options[$pair.Item1.SafeGetValue()] = $pair.Item2.SafeGetValue()
}
$commandAst = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$Script:CommandHelp'
    }, $false).Right.Find({ param($node)
        $node -is [Management.Automation.Language.HashtableAst]
    }, $false)
$commands = [ordered]@{}
foreach ($pair in $commandAst.KeyValuePairs) {
    $commands[$pair.Item1.SafeGetValue()] = $pair.Item2.SafeGetValue()
}
$lines = @(
    '<!-- BEGIN GENERATED CLI OPTIONS: tools/update-help-reference.ps1 -->',
    'The following inventory is generated from the CLI option/command records.',
    'Only listed commands accept each option; `-Help` is the separate help-only form.',
    '',
    '| Option | Value / repetition | Commands | Meaning and default |',
    '| --- | --- | --- | --- |')
foreach ($name in $options.Keys) {
    $option = $options[$name]
    $accepted = @($commands.Keys | Where-Object { $name -in $commands[$_].Options }) -join ', '
    if ($name -eq '-help') { $accepted = 'all commands (help-only)' }
    $description = $option.Description
    if ($option.ContainsKey('Default')) { $description = $description -f $option.Default }
    $repetition = if ($option.Type -eq 'List') { 'repeatable' } else { 'once' }
    $lines += '| `' + $option.Display + '` | ' + $option.Type + '; ' + $repetition + ' | ' + $accepted + ' | ' + $description + ' |'
}
$lines += '<!-- END GENERATED CLI OPTIONS -->'
$generated = $lines -join "`n"
$path = Join-Path $root 'docs/api.md'
$original = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$pattern = '(?s)<!-- BEGIN GENERATED CLI OPTIONS.*?<!-- END GENERATED CLI OPTIONS -->'
if (-not [regex]::IsMatch($original, $pattern)) { throw 'MissingHelpReferenceMarkers' }
$updated = [regex]::Replace($original, $pattern, { $generated })
if ($updated -cne $original) {
    if ($Check) { throw 'HelpReferenceDrift: run tools/update-help-reference.ps1' }
    [IO.File]::WriteAllText($path, $updated, (New-Object Text.UTF8Encoding($false)))
}
