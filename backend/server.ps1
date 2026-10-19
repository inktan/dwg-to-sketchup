# Backend on the CAD computer: read DWG, ask DeepSeek, build SketchUp and Rhino models.
# The web computer runs frontend\web.ps1 and forwards /api here.
# Foreground, reloads when server.ps1 or lib\*.ps1 changes:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File server.ps1
# Open directly:  http://10.1.12.30:8780/

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
  Write-Host "打开 http://127.0.0.1:8780/ 。其他电脑使用这台电脑的局域网 IP 加 :8780 。"
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

$Www = Join-Path $Root "www"
$Jobs = Join-Path $Root "jobs"
$Sample = Join-Path $Root "sample.dwg"
New-Item -ItemType Directory -Force -Path $Jobs | Out-Null
. (Join-Path $Root "lib\Extract-DwgStructure.ps1")
. (Join-Path $Root "lib\Send-SketchUp.ps1")
. (Join-Path $Root "lib\Send-Rhino.ps1")

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

function Save-FloorJson {
  param($Data, [string]$Path)
  $json = ConvertTo-ApiJson $Data
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Resolve-DeepSeekKey {
  $key = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process")
  if (-not $key) { $key = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User") }
  if (-not $key) { $key = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Machine") }
  if ($key) { $key = $key.Trim() }
  if (-not $key) { throw "没有 DeepSeek API Key。请在 dwg-to-sketchup\backend\.env 中设置 DEEPSEEK_API_KEY。" }
  return $key
}

function Get-Sha256Hex {
  param([byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($Bytes)
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Get-SkpDownloadName {
  param([string]$DwgFileName)
  $base = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName($DwgFileName))
  if ([string]::IsNullOrWhiteSpace($base)) { $base = "结构模型" }
  foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
    $base = $base.Replace([string]$ch, "_")
  }
  return ($base + ".skp")
}

function Get-DownloadDisposition {
  param([string]$FileName)
  $ascii = [regex]::Replace($FileName, "[^\x20-\x7E]", "_")
  $utf = [Uri]::EscapeDataString($FileName)
  return "attachment; filename=`"$ascii`"; filename*=UTF-8''$utf"
}

$UploadIndexPath = Join-Path $Jobs "uploads.json"

function Read-UploadIndex {
  $map = @{}
  if (-not (Test-Path -LiteralPath $UploadIndexPath)) { return $map }
  $raw = [System.IO.File]::ReadAllText($UploadIndexPath, [System.Text.Encoding]::UTF8)
  if (-not $raw.Trim()) { return $map }
  $obj = $raw | ConvertFrom-Json
  foreach ($prop in $obj.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
  return $map
}

function ConvertTo-PlainUpload {
  param($Entry)
  $records = New-Object System.Collections.ArrayList
  foreach ($item in @($Entry.records)) {
    if ($item) { [void]$records.Add([string]$item) }
  }
  $counts = $null
  if ($Entry.counts -and $Entry.counts.beams -ne $null) {
    $counts = @{
      beams = [int]$Entry.counts.beams
      columns = [int]$Entry.counts.columns
      walls = [int]$Entry.counts.walls
      slab = [int]$Entry.counts.slab
    }
  }
  $story = $null
  $slab = $null
  if ($Entry.story -ne $null -and [string]$Entry.story -ne "") { $story = [double]$Entry.story }
  if ($Entry.slabThick -ne $null -and [string]$Entry.slabThick -ne "") { $slab = [double]$Entry.slabThick }
  return @{
    sha256 = [string]$Entry.sha256
    name = [string]$Entry.name
    skpName = [string]$Entry.skpName
    jobId = [string]$Entry.jobId
    records = $records
    summary = [string]$Entry.summary
    story = $story
    slabThick = $slab
    counts = $counts
  }
}

function Save-UploadIndex {
  param($Map)
  $plain = @{}
  foreach ($key in @($Map.Keys)) { $plain[$key] = ConvertTo-PlainUpload $Map[$key] }
  $json = ConvertTo-ApiJson $plain
  [System.IO.File]::WriteAllText($UploadIndexPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Remember-Upload {
  param($Entry)
  if (-not $script:UploadIndex) { $script:UploadIndex = @{} }
  $plain = ConvertTo-PlainUpload $Entry
  $records = New-Object System.Collections.ArrayList
  if ($plain.sha256 -and $script:UploadIndex.ContainsKey($plain.sha256)) {
    foreach ($item in @($script:UploadIndex[$plain.sha256].records)) {
      if ($item -and -not $records.Contains([string]$item)) { [void]$records.Add([string]$item) }
    }
  }
  foreach ($item in @($plain.records)) {
    if ($item -and -not $records.Contains([string]$item)) { [void]$records.Add([string]$item) }
  }
  $when = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  if (-not $records.Contains($when)) { [void]$records.Add($when) }
  $plain.records = $records
  $script:UploadIndex[$plain.sha256] = $plain
  Save-UploadIndex $script:UploadIndex
  return $plain
}

function Get-ModelDownloads {
  param([string]$JobId, [string]$SkpName)
  $dir = Join-Path $Jobs $JobId
  $stem = "结构模型"
  if ($SkpName -and $SkpName.ToLower().EndsWith(".skp")) {
    $stem = $SkpName.Substring(0, $SkpName.Length - 4)
  }
  $spec = @{
    skp = @{ file = "model.skp"; name = ($stem + ".skp") }
    rhino = @{ file = "model.3dm"; name = ($stem + ".3dm") }
  }
  $files = @{}
  $filenames = @{}
  foreach ($key in @("skp", "rhino")) {
    $path = Join-Path $dir $spec[$key].file
    if (Test-Path -LiteralPath $path) {
      $files[$key] = "/api/download/${JobId}?format=$key"
      $filenames[$key] = $spec[$key].name
    }
  }
  return @{ files = $files; filenames = $filenames; downloadable = [bool]($files.Count -gt 0) }
}

function Get-UploadView {
  param($Entry)
  if (-not $Entry) { return @{ found = $false } }
  $jobId = [string]$Entry.jobId
  $pack = Get-ModelDownloads $jobId ([string]$Entry.skpName)
  $records = @()
  foreach ($item in @($Entry.records)) { if ($item) { $records += [string]$item } }
  $skpUrl = ""
  if ($pack.files.ContainsKey("skp")) { $skpUrl = [string]$pack.files["skp"] }
  return @{
    found = $true
    downloadable = [bool]$pack.downloadable
    name = [string]$Entry.name
    skpName = [string]$Entry.skpName
    jobId = $jobId
    download = $skpUrl
    filename = [string]$Entry.skpName
    files = $pack.files
    filenames = $pack.filenames
    records = $records
    counts = $Entry.counts
    summary = [string]$Entry.summary
    story = $Entry.story
    slabThick = $Entry.slabThick
    reused = [bool]$pack.downloadable
  }
}

if (-not ("NdjsonPulse" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;

public static class NdjsonPulse {
  static readonly object Gate = new object();
  static Stream stream;
  static Thread thread;
  static volatile bool stop;
  static string stage = "";
  static string detail = "";
  static DateTime stepStart;

  public static object WriteGate { get { return Gate; } }

  static DateTime totalStart;

  public static void Begin(Stream output, string stageText, string detailText, DateTime startedAt) {
    End();
    stream = output;
    stage = stageText ?? "";
    detail = detailText ?? "";
    stepStart = DateTime.Now;
    totalStart = startedAt;
    stop = false;
    thread = new Thread(Loop);
    thread.IsBackground = true;
    thread.Start();
  }

  public static void End() {
    stop = true;
    Thread current = thread;
    if (current != null && current.IsAlive) {
      try { current.Join(2500); } catch {}
    }
  }

  static void Loop() {
    while (!stop) {
      WriteOnce();
      for (int i = 0; i < 20 && !stop; i++) Thread.Sleep(100);
    }
  }

  static string Escape(string value) {
    if (string.IsNullOrEmpty(value)) return "";
    return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
  }

  static void WriteOnce() {
    Stream output = stream;
    if (output == null || stop) return;
    int sec = (int)(DateTime.Now - stepStart).TotalSeconds;
    if (sec < 0) sec = 0;
    int total = (int)(DateTime.Now - totalStart).TotalSeconds;
    if (total < 0) total = 0;
    string json = "{\"type\":\"progress\",\"status\":\"tick\",\"step\":\"" + Escape(stage) + "\",\"detail\":\"" + Escape(detail) + "\",\"stepSeconds\":" + sec + ",\"totalSeconds\":" + total + "}\n";
    byte[] bytes = Encoding.UTF8.GetBytes(json);
    lock (Gate) {
      if (stop) return;
      try {
        output.Write(bytes, 0, bytes.Length);
        output.Flush();
      } catch {
        stop = true;
      }
    }
  }
}
'@ -Language CSharp
}

function Open-EventStream {
  param($Context)
  $Context.Response.StatusCode = 200
  $Context.Response.ContentType = "application/x-ndjson; charset=utf-8"
  $Context.Response.SendChunked = $true
  $Context.Response.Headers["Cache-Control"] = "no-cache, no-transform"
  $Context.Response.Headers["X-Accel-Buffering"] = "no"
}

function Write-Event {
  param($Context, $Obj)
  $json = ($Obj | ConvertTo-Json -Compress -Depth 8) + "`n"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  [System.Threading.Monitor]::Enter([NdjsonPulse]::WriteGate)
  try {
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
  } finally {
    [System.Threading.Monitor]::Exit([NdjsonPulse]::WriteGate)
  }
}

function Start-ProgressHeartbeat {
  param([string]$Step, [string]$Detail)
  if (-not $script:ProgressContext) { return }
  $started = $script:ProgressStarted
  if (-not $started) { $started = Get-Date }
  [NdjsonPulse]::Begin($script:ProgressContext.Response.OutputStream, $Step, $Detail, $started)
}

function Stop-ProgressHeartbeat {
  if ("NdjsonPulse" -as [type]) { [NdjsonPulse]::End() }
}

function Invoke-StructureBuild {
  param([byte[]]$DwgBytes, [string]$DwgName, [double]$Story, [double]$SlabThick, [scriptblock]$OnProgress)
  $sha = Get-Sha256Hex $DwgBytes
  $skpName = Get-SkpDownloadName $DwgName
  $ApiKey = Resolve-DeepSeekKey
  if ($OnProgress) { & $OnProgress "校验接口" "正在确认 DeepSeek API Key。后面会把读到的图元和默认结构规则一起交给模型分析。" }
  Assert-DeepSeekKey $ApiKey
  $id = [guid]::NewGuid().ToString("n")
  $dir = Join-Path $Jobs $id
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $dwg = Join-Path $dir "source.dwg"
  if ($OnProgress) { & $OnProgress "保存图纸" "正在把这次上传的 DWG 写入任务目录，随后交给中望 CAD 读取。" }
  [System.IO.File]::WriteAllBytes($dwg, $DwgBytes)
  Write-Host "JOB $id extract $DwgName"
  $data = Extract-DwgStructure -DwgPath $dwg -Story $Story -SlabThick $SlabThick -ApiKey $ApiKey -OnProgress $OnProgress
  if ($OnProgress) { & $OnProgress "保存分析结果" "正在把 DeepSeek 整理出的梁、柱、墙和楼板写入 floor.json。" }
  Save-FloorJson $data (Join-Path $dir "floor.json")
  [System.IO.File]::WriteAllText((Join-Path $Root "ruby\job.txt"), ($dir -replace '\\', '/'), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "JOB $id sketchup"
  $beamCount = 0
  $columnCount = 0
  $wallCount = 0
  try { $beamCount = @($data.beams).Count } catch {}
  try { $columnCount = @($data.columns).Count } catch {}
  try { $wallCount = @($data.walls).Count } catch {}
  $sketchupDetail = "分析已经完成：梁 $beamCount、柱 $columnCount、墙 $wallCount。正在 SketchUp 里创建这些构件，并保存 skp。"
  if ($OnProgress) { & $OnProgress "写入 SketchUp" $sketchupDetail }
  Start-ProgressHeartbeat -Step "写入 SketchUp" -Detail $sketchupDetail
  $rubyScript = (Join-Path $Root "ruby\build.rb") -replace '\\', '/'
  $raw = Send-SketchUpRuby -Code "load '$rubyScript'"
  Stop-ProgressHeartbeat
  $resultPath = Join-Path $dir "build_result.json"
  $skp = Join-Path $dir "model.skp"
  if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "SketchUp 没有返回结果。$raw"
  }
  $built = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $built.ok) { throw [string]$built.error }
  if (-not (Test-Path -LiteralPath $skp)) { throw "没有生成 skp 文件" }

  $warnings = New-Object System.Collections.Generic.List[string]
  $hosts = @{ sketchup = $true; rhino = $false }
  if (Test-RhinoPort) {
    try {
      $rhinoDetail = "正在把同一套梁、柱、墙和楼板写入当前 Rhino 文档，并保存 3dm。"
      if ($OnProgress) { & $OnProgress "写入 Rhino" $rhinoDetail }
      Start-ProgressHeartbeat -Step "写入 Rhino" -Detail $rhinoDetail
      Invoke-RhinoBuild -JobDir $dir | Out-Null
      $hosts.rhino = $true
    } catch {
      $warnings.Add("Rhino 模型没有生成：" + $_.Exception.Message) | Out-Null
    } finally {
      Stop-ProgressHeartbeat
    }
  } else {
    if ($OnProgress) { & $OnProgress "跳过 Rhino" "Rhino 没有连上 127.0.0.1:2000。这一步不生成 3dm，模型只写入 SketchUp。" }
    $warnings.Add("Rhino 没有连上（127.0.0.1:2000）。请打开 Rhino，并让 MCP 桥保持监听。") | Out-Null
  }

  $entry = Remember-Upload @{
    sha256 = $sha
    name = [System.IO.Path]::GetFileName($DwgName)
    skpName = $skpName
    jobId = $id
    records = @()
    summary = [string]$data.summary
    story = $data.story
    slabThick = $data.slab_thick
    counts = $data.counts
  }
  $meta = @{
    name = [System.IO.Path]::GetFileName($DwgName)
    skpName = $skpName
    sha256 = $sha
    created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  }
  [System.IO.File]::WriteAllText((Join-Path $dir "meta.json"), (ConvertTo-ApiJson $meta), (New-Object System.Text.UTF8Encoding $false))
  $pack = Get-ModelDownloads $id $skpName
  return @{
    ok = $true
    id = $id
    download = $(if ($pack.files.ContainsKey("skp")) { [string]$pack.files["skp"] } else { "" })
    filename = $skpName
    files = $pack.files
    filenames = $pack.filenames
    hosts = $hosts
    warnings = $warnings
    counts = $data.counts
    summary = [string]$data.summary
    model = "deepseek-flash"
    usage = $data.usage
    story = $data.story
    slabThick = $data.slab_thick
    sketchup = $built
    reused = $false
    records = @($entry.records)
    name = [System.IO.Path]::GetFileName($DwgName)
  }
}

function Get-ProgressSeconds {
  param($From, $Now)
  if (-not $From) { return 0 }
  $sec = [int]($Now - $From).TotalSeconds
  if ($sec -lt 0) { return 0 }
  return $sec
}

function Close-ProgressStep {
  if (-not $script:ProgressContext -or -not $script:ProgressStep) { return }
  Stop-ProgressHeartbeat
  $now = Get-Date
  Write-Event $script:ProgressContext @{
    type = "progress"
    status = "done"
    step = [string]$script:ProgressStep
    detail = [string]$script:ProgressStepDetail
    stepSeconds = (Get-ProgressSeconds $script:ProgressStepAt $now)
    totalSeconds = (Get-ProgressSeconds $script:ProgressStarted $now)
  }
  $script:ProgressStep = $null
  $script:ProgressStepDetail = $null
  $script:ProgressStepAt = $null
}

function Report-Progress {
  param([string]$Step, [string]$Detail)
  if (-not $script:ProgressContext -or -not $Step) { return }
  Close-ProgressStep
  $now = Get-Date
  $script:ProgressStep = $Step
  $script:ProgressStepDetail = $Detail
  $script:ProgressStepAt = $now
  Write-Event $script:ProgressContext @{
    type = "progress"
    status = "run"
    step = $Step
    detail = $Detail
    stepSeconds = 0
    totalSeconds = (Get-ProgressSeconds $script:ProgressStarted $now)
  }
}

function Start-BuildRequest {
  param($Context, [byte[]]$Bytes, [string]$Name, [double]$Story, [double]$Slab)
  Open-EventStream $Context
  $script:ProgressContext = $Context
  $script:ProgressStarted = Get-Date
  $script:ProgressStep = $null
  $script:ProgressStepDetail = $null
  $script:ProgressStepAt = $null
  try {
    $result = Invoke-StructureBuild -DwgBytes $Bytes -DwgName $Name -Story $Story -SlabThick $Slab -OnProgress { param($step, $detail) Report-Progress $step $detail }
    Close-ProgressStep
    $result.type = "result"
    Write-Event $Context $result
  } catch {
    Write-Host ("ERR " + $_.Exception.Message)
    try { Close-ProgressStep } catch {}
    try { Write-Event $Context @{ type = "error"; error = $_.Exception.Message } } catch {}
  } finally {
    Stop-ProgressHeartbeat
    $script:ProgressContext = $null
    $script:ProgressStep = $null
  }
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

Import-ProjectEnv (Join-Path $Root ".env")
$script:UploadIndex = Read-UploadIndex
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

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    try {
      if ($req.HttpMethod -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
        $file = Join-Path $Www "index.html"
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $ctx.Response.ContentType = "text/html; charset=utf-8"
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/app.css") {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Www "app.css"))
        $ctx.Response.ContentType = "text/css; charset=utf-8"
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/app.js") {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Www "app.js"))
        $ctx.Response.ContentType = "text/javascript; charset=utf-8"
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
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
          sample = (Test-Path -LiteralPath $Sample)
        }
      } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/api/build-sample") {
        if (-not (Test-Path -LiteralPath $Sample)) { throw "项目里没有示例图纸" }
        $body = [System.Text.Encoding]::UTF8.GetString((Read-RequestBytes $req))
        $story = 3000.0
        $slab = 130.0
        if ($body) {
          $parsed = $body | ConvertFrom-Json
          if ($parsed.story) { $story = [double]$parsed.story }
          if ($parsed.slab) { $slab = [double]$parsed.slab }
        }
        $bytes = [System.IO.File]::ReadAllBytes($Sample)
        Start-BuildRequest -Context $ctx -Bytes $bytes -Name ([System.IO.Path]::GetFileName($Sample)) -Story $story -Slab $slab
      } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/api/build") {
        $bytes = Read-RequestBytes $req
        $parts = Parse-Multipart $bytes $req.ContentType
        if (-not $parts.ContainsKey("file") -or $parts["file"].Bytes.Length -lt 32) { throw "请上传 DWG 文件" }
        $name = [string]$parts["file"].FileName
        if ($name -notmatch "\.(dwg|DWG)$") { throw "只接受 .dwg 文件" }
        $story = Get-NumberField $parts "story" 3000 500 20000
        $slab = Get-NumberField $parts "slab" 130 40 800
        Start-BuildRequest -Context $ctx -Bytes $parts["file"].Bytes -Name $name -Story $story -Slab $slab
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
      try { $ctx.Response.OutputStream.Close() } catch {}
    }
  }
} finally {
  $listener.Stop()
}
