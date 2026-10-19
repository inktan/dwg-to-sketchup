# Web frontend. Serves www and forwards /api to the CAD computer.
# ZWCAD, SketchUp, and Rhino stay on the backend machine. This machine does not run them.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File web.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File web.ps1 -Port 80 -Upstream http://10.1.12.30:8780

param(
  [int]$Port = 8780,
  [string]$Upstream = "http://10.1.12.30:8780"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Www = Join-Path $Root "www"
$Upstream = $Upstream.TrimEnd("/")

[System.Net.ServicePointManager]::Expect100Continue = $false

function Send-Bytes {
  param($Context, [int]$Status, [byte[]]$Bytes, [string]$ContentType)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $Bytes.Length
  $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Static {
  param($Context, [string]$Relative, [string]$ContentType)
  $path = Join-Path $Www $Relative
  if (-not (Test-Path -LiteralPath $path)) {
    Send-Bytes $Context 404 ([Text.Encoding]::UTF8.GetBytes("not found")) "text/plain; charset=utf-8"
    return
  }
  Send-Bytes $Context 200 ([IO.File]::ReadAllBytes($path)) $ContentType
}

function Copy-Stream {
  param($From, $To)
  $buf = New-Object byte[] 65536
  while ($true) {
    $n = $From.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $To.Write($buf, 0, $n)
    $To.Flush()
  }
}

function Send-Upstream {
  param($Context)
  $target = $Upstream + $Context.Request.Url.PathAndQuery
  $up = [System.Net.HttpWebRequest]::Create($target)
  $up.Method = $Context.Request.HttpMethod
  $up.Timeout = 900000
  $up.ReadWriteTimeout = 900000
  $up.AllowWriteStreamBuffering = $false
  $up.AutomaticDecompression = [System.Net.DecompressionMethods]::None
  if ($Context.Request.ContentType) { $up.ContentType = $Context.Request.ContentType }
  $length = $Context.Request.ContentLength64
  if ($Context.Request.HttpMethod -eq "POST" -or $Context.Request.HttpMethod -eq "PUT") {
    if ($length -lt 0) { $length = 0 }
    $up.ContentLength = $length
    if ($length -gt 0) {
      $out = $up.GetRequestStream()
      try { Copy-Stream $Context.Request.InputStream $out } finally { $out.Close() }
    }
  }
  $remote = $null
  try {
    $remote = $up.GetResponse()
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { $remote = $_.Exception.Response }
    else { throw }
  }
  try {
    $Context.Response.StatusCode = [int]$remote.StatusCode
    if ($remote.ContentType) { $Context.Response.ContentType = $remote.ContentType }
    foreach ($name in @("Content-Disposition", "Cache-Control", "X-Accel-Buffering")) {
      $value = $remote.Headers[$name]
      if ($value) { $Context.Response.Headers[$name] = $value }
    }
    if ($remote.ContentLength -ge 0) {
      $Context.Response.ContentLength64 = $remote.ContentLength
    } else {
      $Context.Response.SendChunked = $true
    }
    $incoming = $remote.GetResponseStream()
    try { Copy-Stream $incoming $Context.Response.OutputStream } finally { $incoming.Close() }
  } finally {
    $remote.Close()
  }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$listener.IgnoreWriteExceptions = $true
try {
  $listener.Start()
} catch {
  Write-Host "没有权限监听 http://+:$Port/ 。当前用户不能占用这个地址。"
  Write-Host "请用管理员 PowerShell 执行一次下面这句，然后重新运行本脚本："
  Write-Host "netsh http add urlacl url=http://+:$Port/ user=Everyone"
  exit 5
}
Write-Host "网页 http://+:$Port/  接口转发到 $Upstream"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $path = $ctx.Request.Url.AbsolutePath
      if ($path.StartsWith("/api/")) {
        Send-Upstream $ctx
      } elseif ($path -eq "/" -or $path -eq "/index.html") {
        Send-Static $ctx "index.html" "text/html; charset=utf-8"
      } elseif ($path -eq "/app.css") {
        Send-Static $ctx "app.css" "text/css; charset=utf-8"
      } elseif ($path -eq "/app.js") {
        Send-Static $ctx "app.js" "text/javascript; charset=utf-8"
      } else {
        Send-Bytes $ctx 404 ([Text.Encoding]::UTF8.GetBytes("not found")) "text/plain; charset=utf-8"
      }
    } catch {
      Write-Host ("ERR " + $_.Exception.Message)
      try {
        $msg = '{"ok":false,"error":"建模电脑没有连上"}'
        if (-not $ctx.Response.SendChunked -and $ctx.Response.ContentLength64 -lt 0) {
          Send-Bytes $ctx 502 ([Text.Encoding]::UTF8.GetBytes($msg)) "application/json; charset=utf-8"
        }
      } catch {}
    } finally {
      try { $ctx.Response.OutputStream.Close() } catch {}
      $ctx.Response.Close()
    }
  }
} finally {
  $listener.Stop()
}
