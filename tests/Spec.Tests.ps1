BeforeAll {
    $script:WinSpecRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'winspec'
    Import-Module (Join-Path $script:WinSpecRoot 'spec.psm1') -Force
}

Describe 'data-only specification boundary' {
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

Describe 'specification path and publication policy' {
    It 'refuses overwrite without Force and leaves no temporary residue' {
        $path = Join-Path $TestDrive 'existing.winspec.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value '{"SchemaVersion":1}'

        { Save-Configuration -Config @{ SchemaVersion = 1; Changed = $true } -Path $path } |
            Should -Throw '*OutputExists*'
        (Get-Content -Raw -LiteralPath $path) | Should -Not -Match 'Changed'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
}
