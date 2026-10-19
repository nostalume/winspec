param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$ContentPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$RequestLogPath,
    [ValidateRange(1, 20)][int]$RequestCount = 1,
    [ValidateRange(0, 10)][int]$RedirectCount = 0,
    [switch]$OmitContentLength,
    [int]$ChunkDelayMilliseconds = 0,
    [int]$ChunkBytes = [int]::MaxValue
)

if ($ChunkDelayMilliseconds -and -not $PSBoundParameters.ContainsKey('ChunkBytes')) { $ChunkBytes = 1024 }

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
    [IO.File]::WriteAllText($ReadyPath, 'ready')
    for ($index = 0; $index -lt $RequestCount; $index++) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream)
            $requestLine = $reader.ReadLine()
            while (-not [string]::IsNullOrEmpty($reader.ReadLine())) {
            }
            [IO.File]::AppendAllText($RequestLogPath, $requestLine + "`n")

            if ($index -lt $RedirectCount) {
                $location = "http://127.0.0.1:$Port/redirect-$index"
                $header = "HTTP/1.1 302 Found`r`nLocation: $location`r`n" +
                "Content-Length: 0`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
            }
            else {
                $body = [IO.File]::ReadAllBytes($ContentPath)
                $lengthHeader = if ($OmitContentLength) {
                    ''
                }
                else {
                    "Content-Length: $($body.Length)`r`n"
                }
                $header = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`n" +
                $lengthHeader + "Connection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                for ($offset = 0; $offset -lt $body.Length; $offset += $ChunkBytes) {
                    $stream.Write($body, $offset, [Math]::Min($ChunkBytes, $body.Length - $offset))
                    $stream.Flush()
                    if ($ChunkDelayMilliseconds) { Start-Sleep -Milliseconds $ChunkDelayMilliseconds }
                }
            }
            $stream.Flush()
            $reader.Dispose()
        }
        finally {
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
}
