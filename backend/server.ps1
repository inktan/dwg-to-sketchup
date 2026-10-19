# Backend on the CAD computer: read DWG, ask DeepSeek, build SketchUp and Rhino models.
# The web computer runs frontend\server.js and forwards /api here.
# Foreground, reloads when server.ps1 or lib\*.ps1 changes:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File server.ps1
# Serves /api/* only. Pages come from the web computer running frontend\server.js.

param([switch]$Child)

# Cursor 终端按 UTF-8 解码。Windows PowerShell 5.1 默认用系统代码页 GBK(936) 写控制台，中文会显示成乱码。
if ($PSVersionTable.PSVersion.Major -lt 6) {
  try {
    $utf8Console = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8Console
    [Console]::OutputEncoding = $utf8Console
    $OutputEncoding = $utf8Console
  } catch {}
}

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Child) {
  $serverFile = $MyInvocation.MyCommand.Path
  function Get-ScriptStamp {
    $paths = @($serverFile, (Join-Path $Root ".env"))
    $lib = Join-Path $Root "lib"
    if (Test-Path -LiteralPath $lib) {
      $paths += @(Get-ChildItem -LiteralPath $lib -Filter *.ps1 -File | ForEach-Object { $_.FullName })
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in $paths) {
      if (-not (Test-Path -LiteralPath $path)) { $parts.Add("missing:$path") | Out-Null; continue }
      $item = Get-Item -LiteralPath $path
      $parts.Add($item.FullName + "=" + $item.Length + ":" + $item.LastWriteTimeUtc.Ticks) | Out-Null
    }
    return ($parts -join "|")
  }
  function Wait-ListenPort {
    $deadline = (Get-Date).AddSeconds(8)
    do {
      $hit = netstat -ano | Select-String -Pattern ":8780\s" -Quiet
      if (-not $hit) { return }
      Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
  }
  function Start-ServerChild {
    Wait-ListenPort
    return Start-Process -FilePath "powershell.exe" -WorkingDirectory $Root -NoNewWindow -PassThru -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", $serverFile, "-Child"
    )
  }

  Write-Host "前台运行。修改 server.ps1 或 lib 下的脚本会自动重启，按 Ctrl+C 停止。"
  Write-Host "本机打开 http://127.0.0.1:8780/api/status 可查看三个软件的连接状态。"
  $proc = $null
  $stamp = Get-ScriptStamp
  try {
    $proc = Start-ServerChild
    while ($true) {
      if ($proc.WaitForExit(400)) {
        if ($proc.ExitCode -eq 5) {
          Write-Host "没有权限监听 8780，已停止重试。请先用管理员身份执行上面的 netsh 命令，再重新运行本脚本。"
          break
        }
        Write-Host ("服务进程已退出，代码 " + $proc.ExitCode + "。若提示前缀已被占用，请先关掉旧窗口。2 秒后重试。")
        Start-Sleep -Seconds 2
        $stamp = Get-ScriptStamp
        $proc = Start-ServerChild
        continue
      }
      $now = Get-ScriptStamp
      if ($now -eq $stamp) { continue }
      Start-Sleep -Milliseconds 400
      $now = Get-ScriptStamp
      if ($now -eq $stamp) { continue }
      Write-Host "检测到脚本变化，正在重启..."
      $stamp = $now
      if (-not $proc.HasExited) {
        try { $proc.Kill() } catch {}
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
      }
      $proc = Start-ServerChild
    }
  } finally {
    if ($proc -and -not $proc.HasExited) {
      try { $proc.Kill() } catch {}
    }
  }
  exit 0
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  Write-Host "请用 STA 启动：powershell -NoProfile -ExecutionPolicy Bypass -STA -File server.ps1"
  exit 1
}

$Jobs = Join-Path $Root "jobs"
New-Item -ItemType Directory -Force -Path $Jobs | Out-Null
. (Join-Path $Root "lib\Extract-DwgStructure.ps1")
. (Join-Path $Root "lib\Send-SketchUp.ps1")
. (Join-Path $Root "lib\Send-Rhino.ps1")
. (Join-Path $Root "lib\BuildPipeline.ps1")

function Write-JsonResponse {
  param($Context, $Status, $Obj)
  $json = $Obj | ConvertTo-Json -Compress -Depth 8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = "application/json; charset=utf-8"
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-TextResponse {
  param($Context, $Status, [string]$Text, [string]$ContentType)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-RequestBytes {
  param($Request)
  $len = [int]$Request.ContentLength64
  if ($len -le 0) { return New-Object byte[] 0 }
  $buf = New-Object byte[] $len
  $read = 0
  while ($read -lt $len) {
    $n = $Request.InputStream.Read($buf, $read, $len - $read)
    if ($n -le 0) { break }
    $read += $n
  }
  return $buf
}

function Find-ByteSequence {
  param([byte[]]$Hay, [byte[]]$Needle, [int]$Start)
  $last = $Hay.Length - $Needle.Length
  for ($i = $Start; $i -le $last; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $Needle.Length; $j++) {
      if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
    }
    if ($ok) { return $i }
  }
  return -1
}

function Parse-Multipart {
  param([byte[]]$Body, [string]$ContentType)
  if ($ContentType -notmatch "boundary=(?<b>[^;]+)") { throw "上传格式不是 multipart" }
  $boundary = $Matches["b"].Trim().Trim('"')
  $marker = [System.Text.Encoding]::ASCII.GetBytes("--$boundary")
  $sep = [System.Text.Encoding]::ASCII.GetBytes("`r`n`r`n")
  $parts = @{}
  $pos = 0
  while ($true) {
    $at = Find-ByteSequence $Body $marker $pos
    if ($at -lt 0) { break }
    $start = $at + $marker.Length
    if ($start + 1 -lt $Body.Length -and $Body[$start] -eq 45 -and $Body[$start + 1] -eq 45) { break }
    if ($start + 1 -lt $Body.Length -and $Body[$start] -eq 13) { $start += 2 }
    $next = Find-ByteSequence $Body $marker $start
    if ($next -lt 0) { break }
    $headerEnd = Find-ByteSequence $Body $sep $start
    if ($headerEnd -lt 0 -or $headerEnd -gt $next) { break }
    $headerText = [System.Text.Encoding]::UTF8.GetString($Body, $start, $headerEnd - $start)
    $dataStart = $headerEnd + 4
    $dataEnd = $next - 2
    if ($dataEnd -lt $dataStart) { $dataEnd = $dataStart }
    $data = New-Object byte[] ($dataEnd - $dataStart)
    if ($data.Length -gt 0) { [Array]::Copy($Body, $dataStart, $data, 0, $data.Length) }
    $name = "file"
    $filename = "upload.dwg"
    if ($headerText -match 'name="([^"]+)"') { $name = $Matches[1] }
    if ($headerText -match 'filename="([^"]*)"') { $filename = $Matches[1] }
    $parts[$name] = @{ Name = $name; FileName = $filename; Bytes = $data; Text = [System.Text.Encoding]::UTF8.GetString($data) }
    $pos = $next
  }
  return $parts
}

function Import-ProjectEnv {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
  foreach ($line in $lines) {
    $text = $line.Trim()
    if (-not $text -or $text.StartsWith("#")) { continue }
    $eq = $text.IndexOf("=")
    if ($eq -lt 1) { continue }
    $name = $text.Substring(0, $eq).Trim()
    $value = $text.Substring($eq + 1).Trim()
    if ($value.Length -ge 2) {
      $quote = $value.Substring(0, 1)
      if (($quote -eq '"' -or $quote -eq "'") -and $value.EndsWith($quote)) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    if ($name -and $value) {
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

function Get-DownloadDisposition {
  param([string]$FileName)
  $ascii = [regex]::Replace($FileName, "[^\x20-\x7E]", "_")
  $utf = [Uri]::EscapeDataString($FileName)
  return "attachment; filename=`"$ascii`"; filename*=UTF-8''$utf"
}

function Get-NumberField {
  param($Parts, [string]$Name, [double]$Default, [double]$Min, [double]$Max)
  $value = $Default
  if ($Parts.ContainsKey($Name)) {
    $parsed = 0.0
    if ([double]::TryParse([string]$Parts[$Name].Text.Trim(), [ref]$parsed)) { $value = $parsed }
  }
  if ($value -lt $Min -or $value -gt $Max) { throw "$Name 超出范围（$Min - $Max）" }
  return $value
}

function Get-AllowedClientIps {
  $raw = [Environment]::GetEnvironmentVariable("ALLOWED_CLIENT_IPS", "Process")
  if (-not $raw) { return @() }
  $list = New-Object System.Collections.ArrayList
  foreach ($item in $raw.Split(",")) {
    $ip = $item.Trim()
    if ($ip) { [void]$list.Add($ip) }
  }
  return $list.ToArray()
}

function Test-ClientAllowed {
  param($Context)
  $allowed = Get-AllowedClientIps
  if ($allowed.Count -eq 0) { return $true }
  $addr = $Context.Request.RemoteEndPoint.Address
  if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
  $remote = $addr.ToString()
  foreach ($ip in $allowed) { if ($ip -eq $remote) { return $true } }
  return $false
}

# 建模在后台 STA runspace 里串行执行；主循环保持接收请求，忙时新上传直接被拒。
$script:BuildWorker = $null

function Test-BuildWorkerAlive {
  $w = $script:BuildWorker
  if (-not $w) { return $true }
  try { return $w.PS.InvocationStateInfo.State -eq "Running" } catch { return $true }
}

function Start-BuildWorker {
  param($FirstJob)
  $body = @'
param($WRoot, $WJobs, $Job)
$ErrorActionPreference = "Stop"
$Root = $WRoot
$Jobs = $WJobs
# 后台 runspace 没有控制台主机，把 Write-Host 落到进程控制台。
function Write-Host { param($Object) try { [Console]::WriteLine([string]$Object) } catch {} }
. (Join-Path $Root "lib\Extract-DwgStructure.ps1")
. (Join-Path $Root "lib\Send-SketchUp.ps1")
. (Join-Path $Root "lib\Send-Rhino.ps1")
. (Join-Path $Root "lib\BuildPipeline.ps1")
try {
  Start-BuildRequest -Context $Job["Context"] -Bytes $Job["Bytes"] -Name ([string]$Job["Name"]) -Story ([double]$Job["Story"]) -Slab ([double]$Job["Slab"]) -StartedAt $Job["StartedAt"]
} catch {}
[BuildQueue]::Release()
'@
  $ps = [powershell]::Create()
  try {
    $rs = [runspacefactory]::CreateRunspace()
    try { $rs.ApartmentState = "STA" } catch { Write-Host "无法把工作 runspace 设为 STA，改用 MTA 继续。" }
    $rs.Open()
    $ps.Runspace = $rs
  } catch {
    try { $ps.Dispose() } catch {}
    throw
  }
  [void]$ps.AddScript($body)
  [void]$ps.AddArgument($Root)
  [void]$ps.AddArgument($Jobs)
  [void]$ps.AddArgument($FirstJob)
  $script:BuildWorker = @{ PS = $ps }
  [void]$ps.BeginInvoke()
}

Import-ProjectEnv (Join-Path $Root ".env")
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:8780/')
try {
  $listener.Start()
} catch {
  Write-Host "没有权限监听 http://+:8780/ 。当前用户不能占用这个地址。"
  Write-Host "请用管理员 PowerShell 执行一次下面这句，然后重新运行本脚本："
  Write-Host "netsh http add urlacl url=http://+:8780/ user=Everyone"
  exit 5
}
Write-Host 'listening http://+:8780/'
$allowedIps = Get-AllowedClientIps
if ($allowedIps.Count -eq 0) {
  Write-Host '未设置 ALLOWED_CLIENT_IPS，任何能连到 8780 的机器都可以调用接口。'
} else {
  Write-Host ('ALLOWED_CLIENT_IPS = ' + ($allowedIps -join ', '))
}

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    # /api/build 的连接要交给后台 worker 继续写进度，主循环不能替它关闭。
    $holdOpen = $false
    try {
      if (-not (Test-ClientAllowed $ctx)) {
        Write-TextResponse $ctx 403 "forbidden" "text/plain; charset=utf-8"
      } elseif ($path -notlike "/api/*") {
        Write-TextResponse $ctx 404 "not found" "text/plain; charset=utf-8"
      } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/api/status") {
        $zw = $false
        try { [void](Get-ZwcadApp); $zw = $true } catch { $zw = $false }
        $su = Test-SketchUpPort
        $rhino = Test-RhinoPort
        Write-JsonResponse $ctx 200 @{
          ok = $true
          zwcad = $zw
          sketchup = $su
          rhino = $rhino
        }
      } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/api/build") {
        # 同一时刻只执行一个建模任务；忙时直接拒绝，前端弹窗提示等待。
        [BuildQueue]::ReleaseIfStuck((Test-BuildWorkerAlive))
        $bytes = Read-RequestBytes $req
        $parts = Parse-Multipart $bytes $req.ContentType
        if (-not $parts.ContainsKey("file") -or $parts["file"].Bytes.Length -lt 32) { throw "请上传 DWG 文件" }
        $name = [string]$parts["file"].FileName
        if ($name -notmatch "\.(dwg|DWG)$") { throw "只接受 .dwg 文件" }
        $story = Get-NumberField $parts "story" 3000 500 20000
        $slab = Get-NumberField $parts "slab" 130 40 800
        $verdict = [BuildQueue]::TryBegin()
        if ($verdict -eq "full") {
          Write-BuildLog ("拒绝上传 " + $name + "：已有任务正在建模")
          Write-JsonResponse $ctx 429 @{ ok = $false; error = "当前已有任务正在建模，请等待它完成后再上传。" }
        } else {
          # 拿到执行权：交给后台 STA worker。用户中途关掉页面时，
          # NDJSON 心跳写失败会终止子进程，父进程 2 秒后重启。
          $holdOpen = $true
          Write-BuildLog ("收到上传 " + $name)
          Start-BuildWorker @{
            Context = $ctx
            Bytes = $parts["file"].Bytes
            Name = $name
            Story = $story
            Slab = $slab
            StartedAt = (Get-Date)
          }
        }
      } elseif ($req.HttpMethod -eq "GET" -and $path -match '^/api/download/([a-f0-9]{32})$') {
        $id = $Matches[1]
        $format = [string]$req.QueryString["format"]
        if (-not $format) { $format = "skp" }
        $stored = "model.skp"
        $ext = "skp"
        if ($format -eq "rhino") { $stored = "model.3dm"; $ext = "3dm" }
        $filePath = Join-Path $Jobs "$id\$stored"
        if (-not (Test-Path -LiteralPath $filePath)) { throw "模型不存在或已清理" }
        $downloadName = "结构模型.$ext"
        $metaPath = Join-Path $Jobs "$id\meta.json"
        if (Test-Path -LiteralPath $metaPath) {
          $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
          if ($meta.skpName -and [string]$meta.skpName.ToLower().EndsWith(".skp")) {
            $stem = [string]$meta.skpName
            $stem = $stem.Substring(0, $stem.Length - 4)
            $downloadName = $stem + "." + $ext
          }
        }
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentType = "application/octet-stream"
        $ctx.Response.Headers.Add("Content-Disposition", (Get-DownloadDisposition $downloadName))
        $ctx.Response.ContentLength64 = $fileBytes.Length
        $ctx.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
      } else {
        Write-TextResponse $ctx 404 "not found" "text/plain; charset=utf-8"
      }
    } catch {
      Write-Host ("ERR " + $_.Exception.Message)
      try {
        Write-JsonResponse $ctx 500 @{ ok = $false; error = $_.Exception.Message }
      } catch {}
    } finally {
      if (-not $holdOpen) { try { $ctx.Response.OutputStream.Close() } catch {} }
    }
  }
} finally {
  $listener.Stop()
}
