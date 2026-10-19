function Zh {
  param([string]$Hex)
  $chars = New-Object System.Collections.Generic.List[char]
  for ($i = 0; $i -lt $Hex.Length; $i += 4) {
    $chars.Add([char][Convert]::ToInt32($Hex.Substring($i, 4), 16)) | Out-Null
  }
  return -join $chars
}

function ConvertTo-BeLength {
  param([int]$Length)
  return [byte[]]@(
    [byte](($Length -shr 24) -band 255),
    [byte](($Length -shr 16) -band 255),
    [byte](($Length -shr 8) -band 255),
    [byte]($Length -band 255)
  )
}

function ConvertFrom-BeLength {
  param([byte[]]$Bytes)
  return (([int]$Bytes[0] -shl 24) -bor ([int]$Bytes[1] -shl 16) -bor ([int]$Bytes[2] -shl 8) -bor [int]$Bytes[3])
}

function Read-ExactBytes {
  param($Stream, [int]$Count)
  $buf = New-Object byte[] $Count
  $got = 0
  while ($got -lt $Count) {
    $n = $Stream.Read($buf, $got, $Count - $got)
    if ($n -le 0) { throw ("Rhino " + (Zh "8FDE63A5572865365B8C54CD5E94524D65AD5F004E86")) }
    $got += $n
  }
  return $buf
}

function Send-RhinoFrame {
  param(
    [Parameter(Mandatory = $true)]$Command,
    [int]$TimeoutMs = 180000
  )
  $json = ConvertTo-ApiJson $Command
  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $client.SendTimeout = 15000
    $client.ReceiveTimeout = $TimeoutMs
    $client.Connect("127.0.0.1", 2000)
  } catch {
    throw ((Zh "6CA167098FDE4E0A") + " Rhino" + (Zh "FF08") + "127.0.0.1:2000" + (Zh "FF0930028BF762535F00") + " Rhino" + (Zh "FF0C5E768BA968654FDD630176D1542C3002"))
  }
  try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $head = ConvertTo-BeLength $body.Length
    $stream.Write($head, 0, 4)
    $stream.Write($body, 0, $body.Length)
    $lenBytes = Read-ExactBytes $stream 4
    $len = ConvertFrom-BeLength $lenBytes
    if ($len -le 0 -or $len -gt 8000000) { throw ("Rhino " + (Zh "8FD456DE7684957F5EA665E06548")) }
    $payload = Read-ExactBytes $stream $len
    return [System.Text.Encoding]::UTF8.GetString($payload)
  } finally {
    $client.Close()
  }
}

function Test-RhinoPort {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", 2000, $null, $null)
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

function Invoke-RhinoBuild {
  param([Parameter(Mandatory = $true)][string]$JobDir)
  $resultPath = Join-Path $JobDir "rhino_result.json"
  $modelPath = Join-Path $JobDir "model.3dm"
  if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
  $backendRoot = Split-Path $PSScriptRoot -Parent
  $buildPy = (Join-Path $backendRoot "rhino\build.py") -replace '\\', '/'
  $command = "_-RunPythonScript `"$buildPy`""
  $raw = Send-RhinoFrame @{ type = "run_command"; params = @{ command = $command } }
  if (-not (Test-Path -LiteralPath $resultPath)) {
    throw ("Rhino " + (Zh "6CA16709519956DE7ED3679C3002") + $raw)
  }
  $built = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $built.ok) { throw [string]$built.error }
  if (-not (Test-Path -LiteralPath $modelPath)) { throw ((Zh "6CA16709751F6210") + " 3dm " + (Zh "65874EF6")) }
  try { Send-RhinoFrame @{ type = "run_command"; params = @{ command = "_-Zoom _All _Extents _Enter" } } -TimeoutMs 20000 | Out-Null } catch {}
  return $built
}
