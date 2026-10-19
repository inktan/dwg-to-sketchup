# 建模流水线：任务锁、DeepSeek 分析、SketchUp 与 Rhino 建模、进度事件与控制台日志。
# server.ps1 的主循环和后台工作 runspace 都会加载这个文件；
# 加载前必须已经定义 $Root 和 $Jobs 两个变量。

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
        // 连接已断（用户关掉或刷新了页面）。立刻终止子进程：正在进行的
        // 读图、DeepSeek 请求和建模调用随进程一起结束，不会拖进下一个任务。
        // 父进程会在 2 秒后重启子进程，监听自动恢复。
        stop = true;
        Environment.Exit(88);
      }
    }
  }
}

// 任务锁：同一时刻只允许一个建模任务。
public static class BuildQueue {
  static readonly object Gate = new object();
  static bool busy;

  // 返回 null 表示拿到执行权；返回 "full" 表示已有任务在建模，调用方应直接拒绝。
  public static object TryBegin() {
    lock (Gate) {
      if (busy) { return "full"; }
      busy = true;
      return null;
    }
  }

  public static void Release() {
    lock (Gate) { busy = false; }
  }

  public static bool Busy { get { lock (Gate) { return busy; } } }

  // worker 卡死兜底：主循环确认 worker 已不在运行时释放。
  public static void ReleaseIfStuck(bool workerAlive) {
    if (workerAlive) return;
    lock (Gate) { busy = false; }
  }
}
'@ -Language CSharp
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

# 控制台日志：每条都带时间戳。worker runspace 里也能用。
function Write-BuildLog {
  param([string]$Message)
  try { [Console]::WriteLine(("[" + (Get-Date -Format "HH:mm:ss") + "] " + $Message)) } catch {}
}

function Get-BuildTag {
  if ($script:BuildTag) { return [string]$script:BuildTag }
  return "任务"
}

# 取梁、柱、墙、楼板的数量。四项缺一个或不是数字时返回 $null，让界面别显示不可靠的数字。
function Get-ModelCounts {
  param($Result)
  if ($null -eq $Result) { return $null }
  $counts = @{}
  foreach ($name in @("beams", "columns", "walls", "slab")) {
    $value = $null
    if ($Result -is [System.Collections.IDictionary]) {
      if ($Result.Contains($name)) { $value = $Result[$name] }
    } else {
      $value = Get-PlanProp $Result @($name)
    }
    if ($null -eq $value -or ([string]$value).Trim() -eq "") { return $null }
    $number = 0.0
    if (-not [double]::TryParse(([string]$value).Trim(), [ref]$number)) { return $null }
    $counts[$name] = [int]$number
  }
  return $counts
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
  $stepSeconds = Get-ProgressSeconds $script:ProgressStepAt $now
  Write-Event $script:ProgressContext @{
    type = "progress"
    status = "done"
    step = [string]$script:ProgressStep
    detail = [string]$script:ProgressStepDetail
    stepSeconds = $stepSeconds
    totalSeconds = (Get-ProgressSeconds $script:ProgressStarted $now)
  }
  Write-BuildLog ((Get-BuildTag) + " 步骤「" + [string]$script:ProgressStep + "」完成，用时 " + $stepSeconds + " 秒")
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
  # 每个步骤都用心跳兜着：连接一断，2 秒内心跳写失败，任务立刻终止。
  Start-ProgressHeartbeat
  Write-BuildLog ((Get-BuildTag) + " 步骤「" + $Step + "」开始 —— " + $Detail)
}

# 在一个连接上执行完整建模并流式输出进度。
function Start-BuildRequest {
  param($Context, [byte[]]$Bytes, [string]$Name, [double]$Story, [double]$SlabThick, $StartedAt)
  Open-EventStream $Context
  $script:ProgressContext = $Context
  $script:ProgressStarted = if ($StartedAt) { [datetime]$StartedAt } else { Get-Date }
  $script:ProgressStep = $null
  $script:ProgressStepDetail = $null
  $script:ProgressStepAt = $null
  $script:BuildSeq = ([int]$script:BuildSeq) + 1
  $script:BuildTag = "任务 #$($script:BuildSeq)"
  Write-BuildLog ($script:BuildTag + " 开始处理 " + $Name)
  try {
    $result = Invoke-StructureBuild -DwgBytes $Bytes -DwgName $Name -Story $Story -SlabThick $SlabThick -OnProgress { param($step, $detail) Report-Progress $step $detail }
    Close-ProgressStep
    $result.type = "result"
    Write-Event $Context $result
    Write-BuildLog ($script:BuildTag + " 完成，总用时 " + (Get-ProgressSeconds $script:ProgressStarted (Get-Date)) + " 秒")
  } catch {
    Write-BuildLog ((Get-BuildTag) + " 失败：" + $_.Exception.Message)
    try { Close-ProgressStep } catch {}
    try { Write-Event $Context @{ type = "error"; error = $_.Exception.Message } } catch {}
  } finally {
    Stop-ProgressHeartbeat
    $script:ProgressContext = $null
    $script:ProgressStep = $null
    $script:BuildTag = $null
    try { $Context.Response.OutputStream.Close() } catch {}
  }
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
  Write-BuildLog ((Get-BuildTag) + " 任务目录 " + $id + "，开始读取 " + $DwgName)
  $data = Extract-DwgStructure -DwgPath $dwg -Story $Story -SlabThick $SlabThick -ApiKey $ApiKey -OnProgress $OnProgress
  if ($OnProgress) { & $OnProgress "保存分析结果" "正在把 DeepSeek 整理出的梁、柱、墙和楼板写入 floor.json。" }
  Save-FloorJson $data (Join-Path $dir "floor.json")
  [System.IO.File]::WriteAllText((Join-Path $Root "ruby\job.txt"), ($dir -replace '\\', '/'), (New-Object System.Text.UTF8Encoding $false))
  Write-BuildLog ((Get-BuildTag) + " 分析完成，开始 SketchUp 建模")
  $planCounts = Get-ModelCounts $data.counts
  $sketchupDetail = "分析已经完成，正在 SketchUp 里创建梁、柱、墙和楼板，并保存 skp。"
  if ($planCounts) {
    $sketchupDetail = "分析已经完成：梁 $($planCounts.beams)、柱 $($planCounts.columns)、墙 $($planCounts.walls)。正在 SketchUp 里创建这些构件，并保存 skp。"
  }
  if ($OnProgress) { & $OnProgress "写入 SketchUp" $sketchupDetail }
  $rubyScript = (Join-Path $Root "ruby\build.rb") -replace '\\', '/'
  $raw = Send-SketchUpRuby -Code "load '$rubyScript'"
  $resultPath = Join-Path $dir "build_result.json"
  $skp = Join-Path $dir "model.skp"
  if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "SketchUp 没有返回结果。$raw"
  }
  $built = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $built.ok) { throw [string]$built.error }
  if (-not (Test-Path -LiteralPath $skp)) { throw "没有生成 skp 文件" }
  # 前端显示的数量用实际建出来的构件数，拿不到时退回分析结果里的数量。
  $counts = Get-ModelCounts $built
  if (-not $counts) { $counts = $planCounts }

  $warnings = New-Object System.Collections.Generic.List[string]
  $hosts = @{ sketchup = $true; rhino = $false }
  if (Test-RhinoPort) {
    try {
      $rhinoDetail = "正在把同一套梁、柱、墙和楼板写入当前 Rhino 文档，并保存 3dm。"
      if ($OnProgress) { & $OnProgress "写入 Rhino" $rhinoDetail }
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
    counts = $counts
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
    counts = $counts
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

$script:UploadIndex = Read-UploadIndex
