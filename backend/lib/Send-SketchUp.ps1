function Send-SketchUpRuby {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [int]$TimeoutMs = 180000
  )
  $payloadObj = @{
    jsonrpc = "2.0"
    id = 1
    method = "tools/call"
    params = @{
      name = "eval_ruby"
      arguments = @{ code = $Code }
    }
  }
  $payload = ($payloadObj | ConvertTo-Json -Compress -Depth 6) + "`n"
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $client.SendTimeout = 15000
    $client.ReceiveTimeout = $TimeoutMs
    $client.Connect("127.0.0.1", 9876)
  } catch {
    throw "没有连上 SketchUp（127.0.0.1:9876）。请打开 SketchUp，并在扩展程序里启动 MCP Server。"
  }
  try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $stream.Write($bytes, 0, $bytes.Length)
    $buffer = New-Object System.IO.MemoryStream
    $tmp = New-Object byte[] 8192
    while ($true) {
      $n = $stream.Read($tmp, 0, $tmp.Length)
      if ($n -le 0) { break }
      $buffer.Write($tmp, 0, $n)
      $text = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
      if ($text.Contains("`n")) { break }
    }
    return [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()).Trim()
  } finally {
    $client.Close()
  }
}

function Test-SketchUpPort {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", 9876, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(400)
    if (-not $ok) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}
