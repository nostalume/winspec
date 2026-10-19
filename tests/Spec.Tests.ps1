BeforeAll {
    $script:WinSpecRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'winspec'
    Import-Module (Join-Path $script:WinSpecRoot 'spec.psm1') -Force
}

Describe 'data-only specification boundary' -Tag 'Unit' {
    It 'loads equivalent PSD1 and JSON data without executing a ps1 file' {
        $psd1 = Join-Path $TestDrive 'sample.winspec.psd1'
        $json = Join-Path $TestDrive 'sample.winspec.json'
        $ps1 = Join-Path $TestDrive 'sample.ps1'

        Set-Content -LiteralPath $psd1 -Encoding UTF8 -Value "@{ SchemaVersion = 1; Value = 'safe' }"
        Set-Content -LiteralPath $json -Encoding UTF8 -Value '{"SchemaVersion":1,"Value":"safe"}'
        Set-Content -LiteralPath $ps1 -Encoding UTF8 -Value "throw 'executed'"

        (Import-Configuration -Path $psd1).Value | Should -Be 'safe'
        (Import-Configuration -Path $json).Value | Should -Be 'safe'
        { Import-Configuration -Path $ps1 } | Should -Throw '*UnsupportedSpecFormat*'
    }

    It 'round-trips strings literally through PSD1' {
        $path = Join-Path $TestDrive 'literal.winspec.psd1'
        $value = '$(throw "executed"); quote='' slash=\ newline=' + [Environment]::NewLine
        $spec = @{ SchemaVersion = 1; Text = $value; Values = @($null, $true, [long]::MaxValue, 1.25) }

        Save-Configuration -Config $spec -Path $path -Force | Out-Null
        $loaded = Import-Configuration -Path $path

        $loaded.Text | Should -BeExactly $value
        $loaded.Values.Count | Should -Be 4
        $loaded.Values[0] | Should -BeNullOrEmpty
        $loaded.Values[2] | Should -Be ([long]::MaxValue)
    }

    It 'rejects case-insensitive and exact duplicate JSON keys' {
        $case = Join-Path $TestDrive 'case.winspec.json'
        $exact = Join-Path $TestDrive 'exact.winspec.json'
        Set-Content -LiteralPath $case -Encoding UTF8 -Value '{"Name":"a","name":"b"}'
        Set-Content -LiteralPath $exact -Encoding UTF8 -Value '{"Name":"a","Name":"b"}'

        { Import-Configuration -Path $case } | Should -Throw '*DuplicateKey*'
        { Import-Configuration -Path $exact } | Should -Throw '*DuplicateKey*'
    }

    It 'compares decoded escaped keys, including nested objects' -ForEach @(
        @{ Json = '{"a":1,"\u0061":2}' },
        @{ Json = '{"nested":{"NAME":1,"\u006eame":2}}' },
        @{ Json = '{"a\"b":1,"a\u0022b":2}' }
    ) {
        $path = Join-Path $TestDrive 'escaped.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $Json
        { Import-Configuration -Path $path } | Should -Throw '*DuplicateKey*'
    }

    It 'retains escaped value strings without confusing quotes with object keys' {
        $path = Join-Path $TestDrive 'values.json'
        $value = 'quote=" backslash=\ double=\\ tail=\'
        $data = @{ SchemaVersion = 1; Text = $value; Nested = @{ Text = $value }; Items = @($value) }
        $data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
        $loaded = Import-Configuration -Path $path
        $loaded.Text | Should -BeExactly $value
        $loaded.Nested.Text | Should -BeExactly $value
        $loaded.Items[0] | Should -BeExactly $value
    }

    It 'still rejects malformed strings in values' -ForEach @(
        @{ Json = '{"text":"bad\q"}' },
        @{ Json = '{"text":"unterminated}' },
        @{ Json = '{"text":"bad\u00xx"}' }
    ) {
        $path = Join-Path $TestDrive 'malformed.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $Json
        { Import-Configuration -Path $path } | Should -Throw
    }

    It 'preserves the 4 MiB file and depth 64 guards' {
        $path = Join-Path $TestDrive 'limits.json'
        [IO.File]::WriteAllText($path, '{"text":"' + ('x' * 4MB) + '"}')
        { Import-Configuration -Path $path } | Should -Throw '*SpecTooLarge*'
        [IO.File]::WriteAllText($path, ('{"x":' * 66) + '0' + ('}' * 66))
        { Import-Configuration -Path $path } | Should -Throw '*DataDepthExceeded*'
    }

    It 'replaces arrays while recursively composing includes' {
        $base = Join-Path $TestDrive 'base.winspec.json'
        $middle = Join-Path $TestDrive 'middle.winspec.psd1'
        $top = Join-Path $TestDrive 'top.winspec.psd1'
        Set-Content -LiteralPath $base -Encoding UTF8 -Value '{"SchemaVersion":1,"Nested":{"A":1},"Items":[1,2]}'
        Set-Content -LiteralPath $middle -Encoding UTF8 -Value "@{ SchemaVersion = 1; Include = @('./base.winspec.json'); Nested = @{ B = 2 }; Items = @(3) }"
        Set-Content -LiteralPath $top -Encoding UTF8 -Value "@{ SchemaVersion = 1; Include = @('./middle.winspec.psd1'); Nested = @{ A = 4 } }"

        $loaded = Get-Spec -Path $top

        $loaded.Nested.A | Should -Be 4
        $loaded.Nested.B | Should -Be 2
        @($loaded.Items) | Should -Be @(3)
        $loaded.ContainsKey('Include') | Should -BeFalse
    }

    It 'rejects include cycles atomically' {
        $one = Join-Path $TestDrive 'one.winspec.psd1'
        $two = Join-Path $TestDrive 'two.winspec.psd1'
        Set-Content -LiteralPath $one -Encoding UTF8 -Value "@{ SchemaVersion = 1; Include = @('./two.winspec.psd1') }"
        Set-Content -LiteralPath $two -Encoding UTF8 -Value "@{ SchemaVersion = 1; Include = @('./one.winspec.psd1') }"

        { Get-Spec -Path $one } | Should -Throw '*IncludeCycle*'
    }
}

Describe 'specification path and publication policy' -Tag 'Unit' {
    It 'refuses overwrite without Force and leaves no temporary residue' {
        $path = Join-Path $TestDrive 'existing.winspec.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value '{"SchemaVersion":1}'

        { Save-Configuration -Config @{ SchemaVersion = 1; Changed = $true } -Path $path } |
            Should -Throw '*OutputExists*'
        (Get-Content -Raw -LiteralPath $path) | Should -Not -Match 'Changed'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }

    It 'publishes and replaces PSD1 and JSON only with explicit Force' {
        foreach ($extension in @('psd1', 'json')) {
            $path = Join-Path $TestDrive "replace.$extension"
            Save-Configuration -Config @{ SchemaVersion = 1; Value = 'original' } -Path $path | Out-Null
            Save-Configuration -Config @{ SchemaVersion = 1; Value = 'replacement' } -Path $path -Force | Out-Null
            (Import-Configuration -Path $path).Value | Should -Be 'replacement'
        }
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }

    It 'preserves a destination created after admission without Force' {
        $path = Join-Path $TestDrive 'racing.psd1'
        Mock ConvertTo-HashtableString -ModuleName spec {
            param($Hashtable)
            [IO.File]::WriteAllText($Hashtable.Destination, 'concurrent publisher')
            "@{ SchemaVersion = 1; Value = 'candidate' }"
        }
        { Save-Configuration -Config @{ Destination = $path } -Path $path } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly 'concurrent publisher'
        Should -Invoke ConvertTo-HashtableString -ModuleName spec -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }

    It 'preserves a locked destination and removes the temporary file on publication failure' {
        $path = Join-Path $TestDrive 'locked.json'
        Save-Configuration -Config @{ SchemaVersion = 1; Value = 'original' } -Path $path | Out-Null
        $locked = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            { Save-Configuration -Config @{ SchemaVersion = 1; Value = 'replacement' } -Path $path -Force } | Should -Throw
        }
        finally { $locked.Dispose() }
        (Import-Configuration -Path $path).Value | Should -Be 'original'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
}
