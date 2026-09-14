# Data admission, specification composition, and publication for WinSpec.

$Script:MaximumDataDepth = 64
$Script:MaximumSpecBytes = 4MB
$Script:DefaultSpecName = '.winspec.psd1'

function ConvertTo-WinSpecHashtable {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt $Script:MaximumDataDepth) { throw 'DataDepthExceeded: specification exceeds depth 64' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) { throw 'InvalidMapKey: map keys must be strings' }
            if ($result.ContainsKey($key)) { throw "DuplicateKey: '$key'" }
            $result[$key] = ConvertTo-WinSpecHashtable $Value[$key] ($Depth + 1)
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($result.ContainsKey($property.Name)) { throw "DuplicateKey: '$($property.Name)'" }
            $result[$property.Name] = ConvertTo-WinSpecHashtable $property.Value ($Depth + 1)
        }
        return $result
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) {
            $null = $items.Add((ConvertTo-WinSpecHashtable $item ($Depth + 1)))
        }
        return , $items.ToArray()
    }
    return $Value
}

function Assert-WinSpecValue {
    param($Value, [string]$Path = '$', [int]$Depth = 0)
    if ($Depth -gt $Script:MaximumDataDepth) { throw "DataDepthExceeded: '$Path'" }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [decimal]) { return }
    if ($Value -is [single] -or $Value -is [double]) {
        if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) {
            throw "InvalidNumber: '$Path' must be finite"
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) { throw "InvalidMapKey: '$Path'" }
            Assert-WinSpecValue $Value[$key] "$Path.$key" ($Depth + 1)
        }
        return
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-WinSpecValue $item ($Path + '[' + $index + ']') ($Depth + 1)
            $index++
        }
        return
    }
    throw "InvalidValueType: '$Path' has unsupported type '$($Value.GetType().FullName)'"
}

function Assert-JsonObjectKeys {
    param([Parameter(Mandatory)][string]$Json)
    $script:JsonText = $Json
    $script:JsonIndex = 0

    function Skip-JsonWhitespace {
        while ($script:JsonIndex -lt $script:JsonText.Length -and
            [char]::IsWhiteSpace($script:JsonText[$script:JsonIndex])) { $script:JsonIndex++ }
    }
    function Read-JsonString {
        if ($script:JsonText[$script:JsonIndex] -ne '"') {
            throw "InvalidJson: expected string at offset $script:JsonIndex"
        }
        $start = $script:JsonIndex
        $script:JsonIndex++
        while ($script:JsonIndex -lt $script:JsonText.Length) {
            $ch = $script:JsonText[$script:JsonIndex]
            if ($ch -eq '\') { $script:JsonIndex += 2; continue }
            $script:JsonIndex++
            if ($ch -eq '"') {
                $token = $script:JsonText.Substring($start, $script:JsonIndex - $start)
                return ($token | ConvertFrom-Json)
            }
        }
        throw "InvalidJson: unterminated string at offset $start"
    }
    function Read-JsonValue {
        param([int]$Depth)
        if ($Depth -gt $Script:MaximumDataDepth) { throw 'DataDepthExceeded: JSON exceeds depth 64' }
        Skip-JsonWhitespace
        if ($script:JsonIndex -ge $script:JsonText.Length) { throw 'InvalidJson: unexpected end' }
        $ch = $script:JsonText[$script:JsonIndex]
        if ($ch -eq '{') {
            $script:JsonIndex++
            $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            Skip-JsonWhitespace
            if ($script:JsonIndex -lt $script:JsonText.Length -and $script:JsonText[$script:JsonIndex] -eq '}') {
                $script:JsonIndex++
                return
            }
            while ($true) {
                Skip-JsonWhitespace
                $key = Read-JsonString
                if (-not $keys.Add($key)) { throw "DuplicateKey: '$key'" }
                Skip-JsonWhitespace
                if ($script:JsonIndex -ge $script:JsonText.Length -or $script:JsonText[$script:JsonIndex] -ne ':') {
                    throw "InvalidJson: expected colon at offset $script:JsonIndex"
                }
                $script:JsonIndex++
                Read-JsonValue ($Depth + 1)
                Skip-JsonWhitespace
                if ($script:JsonIndex -ge $script:JsonText.Length) { throw 'InvalidJson: incomplete object' }
                $delimiter = $script:JsonText[$script:JsonIndex]
                $script:JsonIndex++
                if ($delimiter -eq '}') { return }
                if ($delimiter -ne ',') { throw 'InvalidJson: expected object delimiter' }
            }
        }
        if ($ch -eq '[') {
            $script:JsonIndex++
            Skip-JsonWhitespace
            if ($script:JsonIndex -lt $script:JsonText.Length -and $script:JsonText[$script:JsonIndex] -eq ']') {
                $script:JsonIndex++
                return
            }
            while ($true) {
                Read-JsonValue ($Depth + 1)
                Skip-JsonWhitespace
                if ($script:JsonIndex -ge $script:JsonText.Length) { throw 'InvalidJson: incomplete array' }
                $delimiter = $script:JsonText[$script:JsonIndex]
                $script:JsonIndex++
                if ($delimiter -eq ']') { return }
                if ($delimiter -ne ',') { throw 'InvalidJson: expected array delimiter' }
            }
        }
        if ($ch -eq '"') { $null = Read-JsonString; return }
        while ($script:JsonIndex -lt $script:JsonText.Length -and
            $script:JsonText[$script:JsonIndex] -notin @(',', '}', ']') -and
            -not [char]::IsWhiteSpace($script:JsonText[$script:JsonIndex])) { $script:JsonIndex++ }
    }

    Read-JsonValue 0
    Skip-JsonWhitespace
    if ($script:JsonIndex -ne $script:JsonText.Length) {
        throw "InvalidJson: extra content at offset $script:JsonIndex"
    }
}

function ConvertTo-PowerShellValue {
    param($Value, [int]$IndentLevel = 0)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [single] -or $Value -is [double]) {
        return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [decimal]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [ValueType] -and $Value -isnot [datetime]) {
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return ConvertTo-HashtableString $Value $IndentLevel
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '@()' }
        $indent = '    ' * $IndentLevel
        $inner = '    ' * ($IndentLevel + 1)
        $lines = foreach ($item in $items) {
            $inner + (ConvertTo-PowerShellValue $item ($IndentLevel + 1))
        }
        return '@(' + [Environment]::NewLine + ($lines -join [Environment]::NewLine) +
        [Environment]::NewLine + $indent + ')'
    }
    throw "InvalidValueType: cannot serialize '$($Value.GetType().FullName)'"
}

function ConvertTo-HashtableString {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Hashtable, [int]$IndentLevel = 0)
    Assert-WinSpecValue $Hashtable
    $indent = '    ' * $IndentLevel
    $inner = '    ' * ($IndentLevel + 1)
    $lines = @($indent + '@{')
    foreach ($key in @($Hashtable.Keys | Sort-Object)) {
        $safeKey = if ($key -match '^[a-zA-Z_][a-zA-Z0-9_]*$') { $key }
        else { "'" + $key.Replace("'", "''") + "'" }
        $lines += $inner + $safeKey + ' = ' + (ConvertTo-PowerShellValue $Hashtable[$key] ($IndentLevel + 1))
    }
    $lines += $indent + '}'
    return ($lines -join [Environment]::NewLine)
}

function Import-Configuration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { throw "SpecNotFound: '$fullPath'" }
    if ((New-Object IO.FileInfo($fullPath)).Length -gt $Script:MaximumSpecBytes) {
        throw "SpecTooLarge: '$fullPath'"
    }
    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($extension -eq '.psd1') {
        try { $value = Import-PowerShellDataFile -LiteralPath $fullPath -ErrorAction Stop }
        catch { throw "InvalidPsd1: '$fullPath': $($_.Exception.Message)" }
    } elseif ($extension -eq '.json') {
        $json = [IO.File]::ReadAllText($fullPath)
        Assert-JsonObjectKeys $json
        try { $value = $json | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "InvalidJson: '$fullPath': $($_.Exception.Message)" }
    } else {
        throw "UnsupportedSpecFormat: '$extension'; use .psd1 or .json"
    }
    $normalized = ConvertTo-WinSpecHashtable $value
    if ($normalized -isnot [hashtable]) { throw "InvalidSpecRoot: '$fullPath' must contain a map" }
    Assert-WinSpecValue $normalized
    return $normalized
}

function Merge-Hashtables {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Override,
        [int]$MaxDepth = 64, [int]$CurrentDepth = 0)
    if ($CurrentDepth -gt $MaxDepth) { throw "DataDepthExceeded: merge exceeds depth $MaxDepth" }
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-Hashtables $result[$key] $Override[$key] $MaxDepth ($CurrentDepth + 1)
        } else { $result[$key] = $Override[$key] }
    }
    return $result
}

function Resolve-Candidate {
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    $fullPath = [IO.Path]::GetFullPath($Candidate)
    if ([IO.Directory]::Exists($fullPath)) { $fullPath = Join-Path $fullPath $Script:DefaultSpecName }
    if ([IO.File]::Exists($fullPath)) { return $fullPath }
    return $null
}

function Get-WinSpecUserDirectory {
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path (Join-Path $profile '.config') 'winspec'
}

function Resolve-SpecPath {
    [CmdletBinding()]
    param([string]$Path, [switch]$ForCapture)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $fullPath = [IO.Path]::GetFullPath($Path)
        if ($ForCapture) { return $fullPath }
        if (-not [IO.File]::Exists($fullPath)) { throw "SpecNotFound: '$fullPath'" }
        return $fullPath
    }
    $directory = Get-WinSpecUserDirectory
    $psd1 = Join-Path $directory '.winspec.psd1'
    $json = Join-Path $directory '.winspec.json'
    if ($ForCapture) { return $psd1 }
    if ([IO.File]::Exists($psd1) -and [IO.File]::Exists($json)) {
        throw "AmbiguousDefaultSpec: both '$psd1' and '$json' exist"
    }
    if ([IO.File]::Exists($psd1)) { return $psd1 }
    if ([IO.File]::Exists($json)) { return $json }
    throw "SpecNotFound: no default specification in '$directory'"
}

function Resolve-SpecFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Stack,
        $Sources
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $Stack.Add($fullPath)) { throw "IncludeCycle: '$fullPath'" }
    if ($null -ne $Sources) { $null = $Sources.Add($fullPath) }
    try {
        $config = Import-Configuration $fullPath
        $result = @{}
        if ($config.ContainsKey('Include')) {
            $includeValue = $config.Include
            if ($includeValue -is [string]) { $includes = @($includeValue) }
            elseif (($includeValue -is [System.Collections.IEnumerable]) -and
                ($includeValue -isnot [System.Collections.IDictionary])) { $includes = @($includeValue) }
            else { throw "InvalidInclude: '$fullPath' Include must be a string array" }
            foreach ($include in $includes) {
                if ($include -isnot [string] -or [string]::IsNullOrWhiteSpace($include)) {
                    throw "InvalidInclude: '$fullPath' contains an invalid path"
                }
                $childPath = if ([IO.Path]::IsPathRooted($include)) { $include }
                else { Join-Path ([IO.Path]::GetDirectoryName($fullPath)) $include }
                $child = Resolve-SpecFile $childPath $Stack $Sources
                $result = Merge-Hashtables $result $child
            }
        }
        $local = @{}
        foreach ($key in $config.Keys) { if ($key -ine 'Include') { $local[$key] = $config[$key] } }
        return Merge-Hashtables $result $local
    } finally { $null = $Stack.Remove($fullPath) }
}

function Resolve-Spec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [string]$BasePath = $PWD)
    $result = @{}
    if ($Config.ContainsKey('Include')) {
        foreach ($include in @($Config.Include)) {
            $path = if ([IO.Path]::IsPathRooted($include)) { $include } else { Join-Path $BasePath $include }
            $stack = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $result = Merge-Hashtables $result (Resolve-SpecFile $path $stack)
        }
    }
    $local = @{}
    foreach ($key in $Config.Keys) { if ($key -ine 'Include') { $local[$key] = $Config[$key] } }
    return Merge-Hashtables $result $local
}

function Get-Spec {
    [CmdletBinding()]
    param([string]$Path)
    $specPath = Resolve-SpecPath $Path
    $stack = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    return Resolve-SpecFile $specPath $stack
}

function Get-SpecDocument {
    [CmdletBinding()]
    param([string]$Path)

    $specPath = Resolve-SpecPath $Path
    $stack = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    $sources = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    $spec = Resolve-SpecFile $specPath $stack $sources
    return [pscustomobject]@{
        Path = $specPath
        SourcePaths = @($sources | Sort-Object)
        Spec = $spec
    }
}

function Save-Configuration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Path, [switch]$Force)
    Assert-WinSpecValue $Config
    $fullPath = [IO.Path]::GetFullPath($Path)
    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($extension -notin @('.psd1', '.json')) {
        throw "UnsupportedSpecFormat: '$extension'; use .psd1 or .json"
    }
    if ([IO.File]::Exists($fullPath) -and -not $Force) { throw "OutputExists: '$fullPath'" }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $content = if ($extension -eq '.json') { $Config | ConvertTo-Json -Depth 64 }
    else { ConvertTo-HashtableString $Config }
    $tempPath = Join-Path $directory ([IO.Path]::GetRandomFileName() + '.tmp')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($tempPath, $content + [Environment]::NewLine, $encoding)
        if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($tempPath, $fullPath, $null) }
        else { [IO.File]::Move($tempPath, $fullPath) }
    } finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
    return $fullPath
}

Export-ModuleMember -Function @(
    'Assert-WinSpecValue', 'ConvertTo-WinSpecHashtable',
    'ConvertTo-HashtableString', 'ConvertTo-PowerShellValue',
    'Save-Configuration', 'Import-Configuration',
    'Resolve-Candidate', 'Resolve-SpecPath', 'Resolve-Spec', 'Get-Spec',
    'Get-SpecDocument',
    'Merge-Hashtables'
)
