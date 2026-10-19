# Human projection only. Never load configuration, discover providers or perform
# an operation here. Context is supplied by the CLI's existing decision owner;
# the result document remains owned by the machine interface.
function Get-HumanField {
    param($Value, [string]$Name, $Default = $null)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-HumanText {
    param($Value)
    $text = ([string]$Value).Replace("`r`n", "`n")
    $text = [regex]::Replace($text, '(?i)https?://[^\s"''<>]+', {
            param($match)
            $uri = $null
            if ([uri]::TryCreate($match.Value, [UriKind]::Absolute, [ref]$uri)) {
                $builder = New-Object UriBuilder($uri)
                $builder.UserName = ''
                $builder.Password = ''
                $builder.Query = ''
                $builder.Fragment = ''
                return $builder.Uri.AbsoluteUri
            }
            return '[invalid URI]'
        })
    # Escape terminal controls, including CR, ANSI/OSC and bidi formatting.
    [regex]::Replace($text, '[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]', {
            param($match)
            '\u{0:x4}' -f [int][char]$match.Value
        })
}

function Get-HumanCell {
    param($Value)
    $text = if ($null -eq $Value) { 'null' }
    elseif ($Value -is [bool]) { ([string]$Value).ToLowerInvariant() }
    elseif ($Value -is [Collections.IDictionary]) { "object ($($Value.Count) fields; use -Json)" }
    elseif ($Value -is [pscustomobject]) { "object ($(@($Value.PSObject.Properties).Count) fields; use -Json)" }
    elseif ($Value -is [Collections.IList]) { "list ($($Value.Count) items; use -Json)" }
    else { ConvertTo-HumanText $Value }
    $text = $text.Replace("`n", '\n').Replace("`t", '\t')
    if ($text.Length -gt 256) {
        $suffix = '... [display truncated; use -Json]'
        $length = 256 - $suffix.Length
        if ([char]::IsHighSurrogate($text[$length - 1])) { $length-- }
        return $text.Substring(0, $length) + $suffix
    }
    return $text
}

function Write-HumanLine {
    param([IO.TextWriter]$Writer, [string]$Text)
    $Writer.WriteLine((ConvertTo-HumanText $Text).Replace("`n", '\n').Replace("`t", '\t'))
}

function Get-HumanQuotedArgument {
    param([string]$Value, [switch]$Always)
    if (-not $Always -and $Value -match '^[A-Za-z0-9_.-]+$') { return $Value }
    # Copyable Next commands use PowerShell quoting, never executable config.
    '"' + $Value.Replace('`', '``').Replace('$', '`$').Replace('"', '`"') + '"'
}

function Write-HumanTable {
    param([IO.TextWriter]$Writer, [string[]]$Columns, [object[]]$Rows, [int]$Total = -1)
    $shown = @($Rows | Select-Object -First 100)
    if ($Total -lt 0) { $Total = @($Rows).Count }
    if ($shown.Count -gt 0) {
        $widths = @($Columns | ForEach-Object { $_.Length })
        $cells = @(foreach ($row in $shown) {
                $values = @()
                for ($column = 0; $column -lt $Columns.Count; $column++) {
                    $value = Get-HumanCell (Get-HumanField $row $Columns[$column])
                    $widths[$column] = [Math]::Max($widths[$column], $value.Length)
                    $values += $value
                }
                , $values
            })
        $header = for ($column = 0; $column -lt $Columns.Count; $column++) {
            $Columns[$column].PadRight($widths[$column])
        }
        $Writer.WriteLine(($header -join '  ').TrimEnd())
        foreach ($row in $cells) {
            $line = for ($column = 0; $column -lt $Columns.Count; $column++) {
                $row[$column].PadRight($widths[$column])
            }
            $Writer.WriteLine(($line -join '  ').TrimEnd())
        }
    }
    if ($Total -gt $shown.Count) {
        $Writer.WriteLine("... display omitted $($Total - $shown.Count) result rows; use -Json for the result document.")
    }
}

function Add-HumanLeaves {
    param($Value, [string]$Path, [hashtable]$Buffer, [int]$Depth = 0)
    $keys = @()
    if ($Value -is [Collections.IDictionary]) { $keys = @($Value.Keys | Sort-Object) }
    elseif ($Value -is [pscustomobject]) { $keys = @($Value.PSObject.Properties.Name | Sort-Object) }
    elseif ($Value -is [Collections.IList]) { $keys = @(0..($Value.Count - 1) | Where-Object { $_ -ge 0 -and $_ -lt $Value.Count }) }
    if ($keys.Count -gt 0 -and $Depth -lt 64) {
        foreach ($key in $keys) {
            # Input configuration and argument vectors are not default output.
            if ([string]$key -in @('With', 'Args', 'Arguments', 'Configuration')) { continue }
            $next = if ($Path) { "$Path.$key" } else { [string]$key }
            $child = if ($Value -is [Collections.IList]) { $Value[[int]$key] } else { Get-HumanField $Value $key }
            Add-HumanLeaves $child $next $Buffer ($Depth + 1)
        }
        return
    }
    $Buffer.Total++
    if ($Buffer.Rows.Count -lt 100) {
        $display = if ($Depth -ge 64) { '[display depth limit]' }
        elseif ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) { '(empty object)' }
        elseif ($Value -is [Collections.IList]) { '(empty list)' }
        else { $Value }
        $null = $Buffer.Rows.Add([pscustomobject]@{ Key = $Path; Value = $display; Resource = $Path; Observed = $display })
    }
}

function Write-HumanValues {
    param([IO.TextWriter]$Writer, $Value, [string[]]$Columns = @('Key', 'Value'))
    $buffer = @{ Rows = (New-Object Collections.ArrayList); Total = 0 }
    Add-HumanLeaves $Value '' $buffer
    if ($buffer.Total -eq 0) { Write-HumanLine $Writer '(no displayable fields; input metadata suppressed)' }
    Write-HumanTable $Writer $Columns @($buffer.Rows) $buffer.Total
}

function Get-HumanSegment {
    param([string]$Text, [int]$Budget, [switch]$Tail)
    $encoding = New-Object Text.UTF8Encoding($false)
    $low = 0
    $high = [Math]::Min($Text.Length, $Budget)
    while ($low -lt $high) {
        $length = [int][Math]::Ceiling(($low + $high) / 2.0)
        $part = if ($Tail) { $Text.Substring($Text.Length - $length) } else { $Text.Substring(0, $length) }
        if ($encoding.GetByteCount((ConvertTo-HumanText $part)) -le $Budget) { $low = $length }
        else { $high = $length - 1 }
    }
    # Do not split a UTF-16 surrogate pair at a head/tail boundary.
    if ($low -gt 0 -and $low -lt $Text.Length) {
        $boundary = if ($Tail) { $Text.Length - $low } else { $low - 1 }
        if (($Tail -and [char]::IsLowSurrogate($Text[$boundary])) -or
            (-not $Tail -and [char]::IsHighSurrogate($Text[$boundary]))) { $low-- }
    }
    $part = if ($Tail) { $Text.Substring($Text.Length - $low) } else { $Text.Substring(0, $low) }
    [pscustomobject]@{ Text = (ConvertTo-HumanText $part); Bytes = $encoding.GetByteCount($part) }
}

function Write-HumanPayload {
    param([IO.TextWriter]$Writer, [string]$Label, [string]$Text, [bool]$CaptureTruncated = $false, [int]$Budget = 8192)
    if ($Text) {
        $encoding = New-Object Text.UTF8Encoding($false)
        $bytes = $encoding.GetByteCount($Text)
        $head = Get-HumanSegment $Text $Budget
        if ($Label -eq 'Reason:' -and $head.Bytes -eq $bytes) {
            $Writer.WriteLine('Reason: ' + $head.Text.TrimEnd("`n"))
            if ($CaptureTruncated) { $Writer.WriteLine('Warning: child capture itself was truncated; discarded bytes cannot be recovered.') }
            return
        }
        $Writer.WriteLine($Label)
        if ($head.Bytes -eq $bytes) {
            foreach ($line in ($head.Text.TrimEnd("`r", "`n") -split "`n")) { $Writer.WriteLine("  $line") }
        }
        else {
            $head = Get-HumanSegment $Text ([int]($Budget / 2))
            $tail = Get-HumanSegment $Text ([int]($Budget / 2)) -Tail
            foreach ($line in ($head.Text -split "`n")) { $Writer.WriteLine("  $line") }
            $Writer.WriteLine("... display omitted $($bytes - $head.Bytes - $tail.Bytes) captured bytes; use -Json for retained output.")
            foreach ($line in ($tail.Text.TrimEnd("`r", "`n") -split "`n")) { $Writer.WriteLine("  $line") }
        }
    }
    if ($CaptureTruncated) { $Writer.WriteLine('Warning: child capture itself was truncated; discarded bytes cannot be recovered.') }
}

function Write-HumanDiagnostics {
    param([IO.TextWriter]$Writer, [object[]]$Diagnostics, [string]$Resource, [string]$HeaderCode,
        [hashtable]$Budget, [string]$Owner)
    if (-not $Owner) { $Owner = $Resource }
    foreach ($diagnostic in $Diagnostics) {
        if ($null -eq $diagnostic) { continue }
        $code = [string](Get-HumanField $diagnostic 'code')
        $message = [string](Get-HumanField $diagnostic 'message')
        $subject = [string](Get-HumanField $diagnostic 'subject')
        if (-not $subject) { $subject = [string](Get-HumanField $diagnostic 'resource') }
        if (-not $subject) { $subject = $Resource }
        $identity = "$($Owner.Length):$Owner|$($subject.Length):$subject|$($code.Length):$code"
        if (-not $Budget.Seen.Add("$identity|$($message.Length):$message")) { continue }
        if ($Budget.Count -ge 100) { $Budget.Omitted++; continue }
        $Budget.Count++
        if ($subject) { Write-HumanLine $Writer "Resource: $(Get-HumanCell $subject)" }
        if ($code -and $code -ne $HeaderCode -and $Budget.Codes.Add($identity)) { Write-HumanLine $Writer "Code: $(Get-HumanCell $code)" }
        if ($message -eq $code -and $HeaderCode -eq $code) { continue }
        $prefix = $code + ':'
        if ($code -and $message.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $message = $message.Substring($prefix.Length).Trim()
        }
        Write-HumanPayload $Writer 'Reason:' $message -Budget 4096
    }
}

function Get-HumanDifferences {
    param($Comparison)
    foreach ($provider in @(Get-HumanField $Comparison 'Providers')) {
        foreach ($difference in @(Get-HumanField $provider 'Differences')) {
            if ($null -eq $difference) { continue }
            [pscustomobject]@{
                Resource = Get-HumanField $difference 'Path' 'not reported'
                Observed = Get-HumanField $difference 'SystemValue' '(absent)'
                Desired = Get-HumanField $difference 'ConfigValue' '(absent)'
                Against = Get-HumanField $difference 'SystemValue' '(absent)'
                Spec = Get-HumanField $difference 'ConfigValue' '(absent)'
            }
        }
    }
}

function Write-WinSpecHumanResult {
    param($Result, [hashtable]$Context = @{}, [int]$ExitCode = 0,
        [IO.TextWriter]$OutputWriter = [Console]::Out, [IO.TextWriter]$ErrorWriter = [Console]::Error)
    $command = [string]$Result.command
    $failed = $Result.status -in @('Failed', 'Error')
    $planned = $Result.status -eq 'Planned'
    $writer = if ($failed) { $ErrorWriter } else { $OutputWriter }
    $value = $Result.results
    $spec = $Context.Spec
    $diagnostics = @($Result.diagnostics)
    $diagnosticBudget = @{
        Seen = (New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
        Codes = (New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
        Count = 0; Omitted = 0
    }
    # Exceptions/admission have no command receipt. Keep the original code once.
    if ($failed -and $diagnostics.Count -gt 0 -and
        (@($value.Keys).Count -eq 0 -or $null -eq $value)) {
        $first = $diagnostics[0]
        $code = [string](Get-HumanField $first 'code')
        if ($code -match 'Timeout|Cancel') {
            $identity = if ($Context.ActionProvider) {
                if ($Context.ActionName) { " $($Context.ActionName) [$($Context.ActionProvider)]" }
                else { " [$($Context.ActionProvider)]" }
            } else { '' }
            $outcome = if ($code -match 'Timeout') { "timeout after $($Context.TimeoutSeconds)s" } else { 'operation cancelled' }
            Write-HumanLine $writer "FAIL $command$identity -- $outcome"
            if ($Context.Source) { Write-HumanLine $writer "Source: $($Context.Source)" }
            Write-HumanLine $writer "WinSpec exit: $ExitCode"
            $cleanup = if ($Context.CleanupFailed) { 'failure reported' } else { 'not reported' }
            Write-HumanLine $writer "Cleanup: $cleanup"
            Write-HumanDiagnostics $writer $diagnostics -Budget $diagnosticBudget
            Write-HumanLine $writer 'Recovery: external effects may remain; no automatic retry or rollback occurred.'
            return
        }
        Write-HumanLine $writer "FAIL $command -- $(Get-HumanCell $code)"
        if ($code -eq 'RetiredCommand' -and $command -eq 'sandbox') {
            Write-HumanLine $writer 'Reason: global sandbox context is no longer supported.'
            Write-HumanLine $writer 'Next: use the selected command -DryRun; Script/provider previews have explicit limits.'
            Write-HumanLine $writer 'Existing sandbox files were not changed.'
        }
        elseif ($code -eq 'UnknownAction') {
            Write-HumanLine $writer "Action: $($Context.Target)"
            if ($spec) { Write-HumanLine $writer "Spec: $spec" }
            Write-HumanLine $writer "Next: winspec actions $(Get-HumanQuotedArgument $spec -Always)"
        }
        elseif ($code -eq 'MissingOptionValue') {
            $message = [string](Get-HumanField $first 'message')
            if ($message -match "'([^']+)'") { Write-HumanLine $writer "Option: $($Matches[1])" }
            if ($Context.MissingValueBefore) { Write-HumanLine $writer "Reason: expected a value before $($Context.MissingValueBefore)." }
            else { Write-HumanLine $writer 'Reason: expected a value.' }
            Write-HumanLine $writer "Next: winspec help $command"
        }
        else {
            if ($spec) { Write-HumanLine $writer "Spec: $spec" }
            Write-HumanDiagnostics $writer $diagnostics -HeaderCode $code -Budget $diagnosticBudget
            Write-HumanLine $writer "Next: winspec help $command"
        }
        return
    }
    switch ($command) {
        'providers' {
            $items = @($value.providers)
            Write-HumanLine $writer "OK providers -- $($items.Count) implementations discovered (static)"
            $rows = @($items | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Kind = $_.Kind; Origin = $_.Origin; Operations = @($_.Operations) -join ', ' } })
            Write-HumanTable $writer @('Name', 'Kind', 'Origin', 'Operations') $rows
            Write-HumanLine $writer 'Scope: discovery only; runtime dependencies and configured Actions were not checked.'
            Write-HumanLine $writer 'Next: winspec actions <spec>'
        }
        'actions' {
            $items = @($value.actions)
            if ($items.Count) { Write-HumanLine $writer "OK actions -- $($items.Count) configured Actions" }
            else { Write-HumanLine $writer 'NO-WORK actions -- no Actions configured' }
            Write-HumanLine $writer "Spec: $spec"
            if ($items.Count) {
                $rows = @($items | ForEach-Object { [pscustomobject]@{ Name = $_.name; Provider = $_.provider; Origin = $_.origin; Operations = @($_.operations) -join ', ' } })
                Write-HumanTable $writer @('Name', 'Provider', 'Origin', 'Operations') $rows
                Write-HumanLine $writer 'Scope: static bindings only; no Action/provider was started.'
                if ($Context.NextAction) {
                    Write-HumanLine $writer "Next: winspec run $(Get-HumanQuotedArgument $Context.NextAction) -Spec $(Get-HumanQuotedArgument $spec -Always) -DryRun"
                }
                else { Write-HumanLine $writer 'Next: winspec help run' }
            }
            else { Write-HumanLine $writer 'Scope: no Action/provider was started.' }
        }
        'validate' {
            $validation = $value.validation
            $subjects = @($validation.subjects)
            $valid = @($subjects | Where-Object status -EQ 'Valid').Count
            $notRun = @($subjects | Where-Object status -EQ 'NotRun').Count
            $unavailable = @($subjects | Where-Object status -EQ 'Unavailable').Count
            $invalid = @($subjects | Where-Object status -EQ 'Invalid').Count
            if ($failed) {
                $outcome = if ($invalid) { "provider validation rejected $invalid subject$(if ($invalid -ne 1) { 's' })" } else { 'validation did not complete successfully' }
                Write-HumanLine $writer "FAIL validate -- $outcome"
            }
            elseif ($notRun -or $unavailable) { Write-HumanLine $writer 'PARTIAL validate -- structural checks passed; provider validation incomplete' }
            elseif ($subjects.Count -gt 0 -and $validation.mode -eq 'ActionPreview') { Write-HumanLine $writer 'OK validate -- structural checks and declared provider previews passed' }
            else { Write-HumanLine $writer 'OK validate -- structural checks passed' }
            Write-HumanLine $writer "Spec: $spec"
            $mode = [string]$validation.mode
            if ($mode -eq 'ActionPreview' -and $valid + $invalid -gt 0) { $mode += ' (trusted provider code was started)' }
            Write-HumanLine $writer "Mode: $mode"
            if ($subjects.Count) {
                Write-HumanLine $writer "Provider checks: $valid valid, $notRun not run, $unavailable unavailable, $invalid invalid"
                $rows = @($subjects | ForEach-Object { [pscustomobject]@{ Subject = $_.path; Provider = $_.provider; Check = $_.status } })
                Write-HumanTable $writer @('Subject', 'Provider', 'Check') $rows
            }
            else { Write-HumanLine $writer 'Provider-owned subjects: 0' }
            if ($subjects.Count -gt 0 -and -not ($notRun -or $unavailable) -and -not $failed -and $validation.mode -eq 'ActionPreview') {
                Write-HumanLine $writer 'Scope: preview acceptance only; runtime success is not proven.'
            }
            else { Write-HumanLine $writer 'Scope: runtime dependencies and successful execution are not proven.' }
            if ($notRun -and -not $failed -and $validation.mode -eq 'Structural') {
                Write-HumanLine $writer "Optional: winspec validate $(Get-HumanQuotedArgument $spec -Always) -PreviewActions"
                Write-HumanLine $writer '          This starts trusted provider preview code.'
            }
        }
        'status' {
            $names = @($value.state.Keys | Sort-Object)
            if ($names.Count) { Write-HumanLine $writer "OK status -- observed $($names.Count) selected provider$(if ($names.Count -ne 1) { 's' })" }
            else { Write-HumanLine $writer 'NO-WORK status -- no State providers selected' }
            if ($spec) { Write-HumanLine $writer "Spec: $spec" }
            $selection = $names -join ', '
            if ($spec -and -not $Context.ExplicitProviders) { $selection += ' (from specification sections)' }
            if ($names.Count) {
                Write-HumanLine $writer "Selection: $selection"
                Write-HumanValues $writer $value.state @('Resource', 'Observed')
            }
            Write-HumanLine $writer 'Scope: observation only; desired State was not compared.'
        }
        { $_ -in @('diff', 'apply') } {
            $comparison = if ($command -eq 'diff') { $value } else { $value.comparison }
            $compared = @(Get-HumanField $comparison 'Providers')
            $differences = @(Get-HumanDifferences $comparison)
            $missingDetails = @($compared | Where-Object { $_.Status -eq 'Different' -and @($_.Differences | Where-Object { $null -ne $_ }).Count -eq 0 }).Count
            $providers = @(Get-HumanField $value 'providers')
            # An external provider may recheck drift away immediately before
            # apply. Its Unchanged receipt (and an already-created checkpoint)
            # must not be confused with the early no-op comparison branch.
            $actualApply = $command -eq 'apply' -and -not $planned -and $providers.Count -gt 0
            if ($actualApply) {
                if ($failed) {
                    $bad = @($providers | Where-Object Status -In @('Failed', 'Error')).Count
                    Write-HumanLine $writer "FAIL apply -- $bad provider$(if ($bad -ne 1) { 's' }) failed; earlier changes may remain"
                }
                else { Write-HumanLine $writer 'OK apply -- selected providers reported success' }
            }
            elseif ($compared.Count -eq 0) { Write-HumanLine $writer "NO-WORK $command -- no State sections selected" }
            elseif ($planned -and $missingDetails) { Write-HumanLine $writer 'PLAN apply -- provider reported State differences; some details not reported; apply was not called' }
            elseif ($planned) { Write-HumanLine $writer "PLAN apply -- $($differences.Count) State difference$(if ($differences.Count -ne 1) { 's' }); apply was not called" }
            elseif ($Result.status -eq 'Different' -and $differences.Count -eq 0) { Write-HumanLine $writer 'DIFF diff -- provider reported differences; details not reported; no changes applied' }
            elseif ($Result.status -eq 'Different' -and $missingDetails) { Write-HumanLine $writer "DIFF diff -- $($differences.Count) reported difference(s); other details not reported; no changes applied" }
            elseif ($Result.status -eq 'Different') { Write-HumanLine $writer "DIFF diff -- $($differences.Count) difference$(if ($differences.Count -ne 1) { 's' }); no changes applied" }
            elseif ($command -eq 'apply') { Write-HumanLine $writer 'OK apply -- selected State was already unchanged' }
            else { Write-HumanLine $writer "OK diff -- no differences in $($compared.Count) selected provider$(if ($compared.Count -ne 1) { 's' })" }
            Write-HumanLine $writer "Spec: $spec"
            if ($compared.Count -eq 0 -and -not $actualApply) { Write-HumanLine $writer 'Scope: no State comparison was performed.'; break }
            if ($command -eq 'diff') {
                $against = if ($Context.Against) { $Context.Against } else { 'current machine' }
                Write-HumanLine $writer "Against: $against"
            }
            Write-HumanLine $writer "Selection: $(@($compared | ForEach-Object { $_.Name }) -join ', ')"
            if ($actualApply) {
                $rows = @($providers | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Result = $_.Status } })
                Write-HumanTable $writer @('Provider', 'Result') $rows
                foreach ($provider in $providers) { Write-HumanDiagnostics $ErrorWriter @($provider.Diagnostics) $provider.Name -Budget $diagnosticBudget }
                if (-not $failed -or $Context.Checkpoint -or $value.checkpoint) {
                    $checkpoint = if (-not $Context.Checkpoint) { 'not requested' } elseif ($value.checkpoint) { 'reported created' } else { 'not reported' }
                    Write-HumanLine $writer "Checkpoint: $checkpoint"
                    if ($value.checkpoint) { Write-HumanValues $writer $value.checkpoint }
                }
                if ($failed) { Write-HumanLine $writer 'Recovery: inspect the affected State before retrying; no automatic rollback occurred.' }
                else {
                    Write-HumanLine $writer 'Post-apply verification: not performed'
                    Write-HumanLine $writer 'Scope: no Actions were run.'
                }
            }
            else {
                $columns = if ($Context.Against) { @('Resource', 'Against', 'Spec') } else { @('Resource', 'Observed', 'Desired') }
                Write-HumanTable $writer $columns $differences
                if ($planned) { Write-HumanLine $writer 'Checkpoint: not created (DryRun)' }
                elseif ($Result.status -eq 'Different') { Write-HumanLine $writer 'Exit 1 means differences were found, not command failure.' }
                else { Write-HumanLine $writer 'Scope: selected State only; Actions were not compared.' }
                foreach ($provider in $compared) { Write-HumanDiagnostics $ErrorWriter @($provider.Diagnostics) $provider.Name -Budget $diagnosticBudget }
            }
        }
        'run' {
            $item = @($value.actions)[0]
            $receipt = Get-HumanField $item 'result'
            if ($null -eq $receipt) { $receipt = $item }
            $provider = $Context.ActionProvider
            $identity = if ($Context.ActionName) { " $($Context.ActionName) [$provider]" } else { " [$provider]" }
            $isScript = $provider -ieq 'Script'
            $opaque = [bool](Get-HumanField $receipt 'Opaque')
            $hasChildExit = $null -ne (Get-HumanField $receipt 'ExitCode')
            $outcome = if ($isScript -and $planned) { 'opaque preview; Script was not executed' }
            elseif ($isScript -and $failed) { 'child exited unsuccessfully' }
            elseif ($isScript) { 'child completed successfully' }
            elseif ($planned -and $opaque) { 'opaque preview; provider was not started' }
            elseif ($planned) { "provider preview returned $($receipt.status)" }
            else { "provider reported $($receipt.status)" }
            $token = if ($failed) { 'FAIL' } elseif ($planned) { 'PLAN' } else { 'OK' }
            Write-HumanLine $writer "$token run$identity -- $outcome"
            if ($spec) { Write-HumanLine $writer "Spec: $spec" }
            if ($Context.RunSelection -eq 'Provider') { Write-HumanLine $writer 'Selection: direct provider; empty configuration' }
            if ($isScript) {
                $source = Get-HumanField $receipt 'Source'
                if (-not $source) { $source = $Context.Source }
                Write-HumanLine $writer "Source: $source"
                if ($planned) {
                    if (Get-HumanField $receipt 'RequestedUri') {
                        Write-HumanLine $writer 'Download: not performed'
                        $digest = if (Get-HumanField $receipt 'ExpectedSha256') { 'expected pin supplied' } else { 'no pin supplied' }
                        Write-HumanLine $writer "Digest: $digest"
                    }
                    else { Write-HumanLine $writer 'Checked: Action selection and local file existence' }
                    Write-HumanLine $writer 'Not checked: Script contents, runtime dependencies, or internal changes'
                }
                else {
                    if (Get-HumanField $receipt 'RequestedUri') {
                        if (Get-HumanField $receipt 'FinalUri') { Write-HumanLine $writer "Received from: $($receipt.FinalUri)" }
                        $digest = if ((Get-HumanField $receipt 'DigestVerified') -eq $true) { 'verified against expected pin' }
                        elseif ((Get-HumanField $receipt 'DigestVerified') -eq $false) { 'not pinned; received digest is observational only' }
                        else { 'not reported' }
                        Write-HumanLine $writer "Digest: $digest"
                        if (Get-HumanField $receipt 'ReceivedSha256') { Write-HumanLine $writer "Received SHA-256: $($receipt.ReceivedSha256)" }
                    }
                    if ($hasChildExit) { Write-HumanLine $writer "Child exit: $($receipt.ExitCode)" }
                    else { Write-HumanLine $writer 'Child exit: not reported' }
                    if ($failed) { Write-HumanLine $writer "WinSpec exit: $ExitCode" }
                    Write-HumanPayload $OutputWriter 'Child stdout:' ([string]$receipt.Stdout) ([bool]$receipt.StdoutTruncated)
                    $label = if (-not $failed -and $receipt.ExitCode -eq 0) { 'Child stderr (exit 0; not classified as failure):' } else { 'Child stderr:' }
                    Write-HumanPayload $ErrorWriter $label ([string]$receipt.Stderr) ([bool]$receipt.StderrTruncated)
                    if ($failed) { Write-HumanLine $writer 'Recovery: inspect the Script and its inputs before retrying; external effects may remain.' }
                }
            }
            else {
                if ($planned -and -not $opaque) { Write-HumanLine $writer 'Operation: preview (trusted provider code was started)' }
                if ($provider -in @('MicrosoftActivation', 'OfficeDeployment', 'WindowsDebloat') -and $planned -and -not $opaque) {
                    $output = Get-HumanField $receipt 'output'
                    $uri = Get-HumanField $output 'requestedUri'
                    if ($uri) { Write-HumanLine $writer "Provider-reported source: $uri" }
                    Write-HumanLine $writer 'Opaque: yes; upstream Script changes cannot be predicted'
                }
                elseif ($null -ne (Get-HumanField $receipt 'output')) {
                    Write-HumanLine $writer 'Provider output:'
                    Write-HumanValues $writer $receipt.output
                }
                if ($planned) { Write-HumanLine $writer 'Scope: preview is not an OS security sandbox.' }
                Write-HumanPayload $ErrorWriter 'Provider stderr:' ([string](Get-HumanField $receipt 'stderr')) ([bool](Get-HumanField $receipt 'stderrTruncated'))
                Write-HumanDiagnostics $ErrorWriter @(Get-HumanField $receipt 'diagnostics') $provider -Budget $diagnosticBudget
                if ($failed) { Write-HumanLine $writer 'Recovery: inspect provider diagnostics before retrying; external effects may remain.' }
            }
        }
        'workflow' {
            $steps = @($value.Steps)
            $bad = @($steps | Where-Object Status -In @('Failed', 'Error'))
            $good = @($steps | Where-Object Status -EQ 'Succeeded').Count
            $unchanged = @($steps | Where-Object Status -EQ 'Unchanged').Count
            $skipped = @($steps | Where-Object Status -EQ 'Skipped').Count
            if ($failed) { Write-HumanLine $writer "FAIL workflow $($value.Name) -- stopped at step $([int]$bad[0].Index + 1) of $($steps.Count)" }
            elseif ($planned) { Write-HumanLine $writer "PLAN workflow $($value.Name) -- $($steps.Count) steps planned; no steps executed" }
            elseif ($steps.Count -eq 0) { Write-HumanLine $writer "NO-WORK workflow $($value.Name) -- no steps configured" }
            else { Write-HumanLine $writer "OK workflow $($value.Name) -- all $($steps.Count) steps reported success" }
            Write-HumanLine $writer "Spec: $spec"
            $rows = @()
            foreach ($step in $steps) {
                $index = [int]$step.Index
                $identity = [string]$step.Name
                if ($step.Kind -eq 'Capture' -and (Get-HumanField $step.Result 'Path')) { $identity = $step.Result.Path }
                if ($step.Kind -eq 'Apply' -and @(Get-HumanField $step.Result 'Providers').Count -gt 0) {
                    $identity = @($step.Result.Providers | ForEach-Object Name) -join ', '
                }
                if (-not $identity -and $Context.Steps -and $index -lt $Context.Steps.Count) { $identity = $Context.Steps[$index].Identity }
                if (-not $identity) { $identity = 'not reported' }
                $rows += [pscustomobject]@{ Step = $index + 1; Operation = $step.Kind; Identity = $identity; Result = $step.Status; Opaque = if (Get-HumanField $step.Result 'Opaque') { 'yes' } else { 'not reported' } }
            }
            $columns = @('Step', 'Operation', 'Identity', 'Result')
            if ($planned) { $columns += 'Opaque' }
            Write-HumanTable $writer $columns $rows
            if ($planned) {
                Write-HumanLine $writer 'Checkpoint: not created (DryRun)'
                Write-HumanLine $writer 'Scope: previews are not an OS security sandbox.'
            }
            else {
                $summary = "Summary: $good succeeded, $($bad.Count) failed, $skipped skipped"
                if ($unchanged) { $summary += ", $unchanged unchanged" }
                Write-HumanLine $writer $summary
                foreach ($step in $steps) {
                    $identity = $rows[[int]$step.Index].Identity
                    $label = "Step $([int]$step.Index + 1) / $identity"
                    $receipt = Get-HumanField $step 'Result'
                    $isProviderReceipt = $step.Kind -eq 'Run' -and ($null -ne (Get-HumanField $receipt 'output') -or $null -ne (Get-HumanField $receipt 'protocolVersion'))
                    if ($isProviderReceipt) {
                        $providerWriter = if ($step.Status -in @('Failed', 'Error')) { $ErrorWriter } else { $OutputWriter }
                        Write-HumanLine $providerWriter "$label provider output:"
                        Write-HumanValues $providerWriter $receipt.output
                        Write-HumanPayload $ErrorWriter "$label provider stderr:" ([string](Get-HumanField $receipt 'stderr')) ([bool](Get-HumanField $receipt 'stderrTruncated'))
                    }
                    if (-not $isProviderReceipt) { Write-HumanPayload $OutputWriter "$label stdout:" ([string](Get-HumanField $receipt 'Stdout')) ([bool](Get-HumanField $receipt 'StdoutTruncated')) }
                    if (-not $isProviderReceipt -and $step.Status -in @('Failed', 'Error')) {
                        $childExit = Get-HumanField $receipt 'ExitCode'
                        if ($null -ne $childExit) { Write-HumanLine $writer "Failed child exit: $childExit" }
                        Write-HumanPayload $ErrorWriter 'Reason:' ([string](Get-HumanField $receipt 'Stderr')) ([bool](Get-HumanField $receipt 'StderrTruncated')) -Budget 4096
                    }
                    elseif (-not $isProviderReceipt) {
                        Write-HumanPayload $ErrorWriter "$label stderr (not classified as failure):" ([string](Get-HumanField $receipt 'Stderr')) ([bool](Get-HumanField $receipt 'StderrTruncated'))
                    }
                    Write-HumanDiagnostics $ErrorWriter @(Get-HumanField $step 'Diagnostics') $identity -Budget $diagnosticBudget -Owner $label
                    Write-HumanDiagnostics $ErrorWriter @(Get-HumanField $receipt 'Diagnostics') $identity -Budget $diagnosticBudget -Owner $label
                    foreach ($provider in @(Get-HumanField $receipt 'Providers')) {
                        Write-HumanDiagnostics $ErrorWriter @(Get-HumanField $provider 'Diagnostics') $provider.Name -Budget $diagnosticBudget -Owner "$label / $($provider.Name)"
                    }
                }
                if ($failed) {
                    if ($value.CheckpointCreated) { Write-HumanLine $writer 'Checkpoint created: true' }
                    Write-HumanLine $writer 'Recovery: steps already completed were not undone; inspect effects before retrying.'
                }
                else { Write-HumanLine $writer "Checkpoint created: $(([string][bool]$value.CheckpointCreated).ToLowerInvariant())" }
            }
        }
        'capture' {
            Write-HumanLine $writer 'OK capture -- State specification published'
            Write-HumanLine $writer "Output: $($value.path)"
            Write-HumanLine $writer "Providers: $(@($value.providers | Sort-Object) -join ', ')"
            if ($Context.Force) { Write-HumanLine $writer 'Overwrite permission: allowed (-Force)' }
            Write-HumanLine $writer 'Scope: State snapshot only; Actions and arbitrary user files were not backed up.'
        }
        'merge' {
            $conflicts = @($value.Conflicts)
            if ($failed) {
                Write-HumanLine $writer "FAIL merge -- $($conflicts.Count) unresolved conflict$(if ($conflicts.Count -ne 1) { 's' }); no file was written"
                Write-HumanLine $writer "Strategy: $($value.Strategy)"
                Write-HumanTable $writer @('Path', 'Base', 'Incoming') $conflicts
                Write-HumanLine $writer 'Next: review both inputs and choose an explicit resolution strategy if intended.'
            }
            else {
                $outcome = if ($Context.Output) { 'merged specification published' } else { 'merge completed; no file was written' }
                Write-HumanLine $writer "OK merge -- $outcome"
                Write-HumanLine $writer "Base: $($Context.Base)"
                Write-HumanLine $writer "Incoming: $($Context.Incoming)"
                Write-HumanLine $writer "Strategy: $($value.Strategy)"
                Write-HumanLine $writer "Conflicts: $($conflicts.Count)"
                if ($Context.Output) { Write-HumanLine $writer "Output: $($Context.Output)" }
                else {
                    Write-HumanLine $writer 'Next: repeat with -Output <path> to publish a specification.'
                    Write-HumanLine $writer '      Use -Json to inspect the merged result document.'
                }
            }
        }
        'rollback' {
            if ($planned) {
                Write-HumanLine $writer 'PLAN rollback -- no restore was requested'
                $selector = if ($value.last) { 'latest Windows restore point' } else { "sequence $($value.sequenceNumber)" }
                Write-HumanLine $writer "Target selector: $selector"
                Write-HumanLine $writer 'Target resolution: not checked'
                Write-HumanLine $writer 'Scope: DryRun does not prove the target exists or System Restore is available.'
            }
            else {
                Write-HumanLine $writer 'OK rollback -- Windows System Restore request accepted'
                foreach ($field in @(@('Sequence', 'SequenceNumber'), @('Description', 'Description'))) {
                    $reported = Get-HumanField $value.rollback $field[1]
                    if ($null -eq $reported -or [string]$reported -eq '') { $reported = 'not reported' }
                    Write-HumanLine $writer "$($field[0]): $reported"
                }
                Write-HumanLine $writer 'Scope: system recovery has not been verified complete; restart may be required.'
            }
        }
    }
    Write-HumanDiagnostics $ErrorWriter $diagnostics -Budget $diagnosticBudget
    if ($diagnosticBudget.Omitted) {
        $ErrorWriter.WriteLine("... display omitted $($diagnosticBudget.Omitted) diagnostics; use -Json for the result document.")
    }
}

function Write-WinSpecHumanWait {
    param([string]$Identity, [string]$Activity, [double]$Elapsed, [int]$Budget,
        [IO.TextWriter]$Writer = [Console]::Error)
    $outcome = if ($Elapsed -le 0) { $Activity }
    else { "elapsed $([int][Math]::Floor($Elapsed))s / operation budget $($Budget)s" }
    Write-HumanLine $Writer "WAIT $Identity -- $outcome"
}

Export-ModuleMember -Function Write-WinSpecHumanResult, Write-WinSpecHumanWait
