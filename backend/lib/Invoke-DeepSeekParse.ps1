# Classify a CAD inventory with deepseek-flash and turn the chosen ids back into floor geometry.
# https://api-docs.deepseek.com/zh-cn/quick_start/pricing

function ConvertTo-ApiJson {
  param($Value)
  if (-not ("JsonBox" -as [type])) {
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections;
using System.Web.Script.Serialization;
public static class JsonBox {
  static object Unwrap(object value) {
    if (value == null) return null;
    Type t = value.GetType();
    if (t.FullName == "System.Management.Automation.PSObject") {
      object inner = t.GetProperty("BaseObject").GetValue(value, null);
      if (inner == null || object.ReferenceEquals(inner, value)) return value.ToString();
      return Unwrap(inner);
    }
    if (value is string || value is bool || value is byte || value is int || value is long || value is double || value is decimal || value is float) return value;
    IDictionary dict = value as IDictionary;
    if (dict != null) {
      Hashtable copy = new Hashtable();
      foreach (DictionaryEntry entry in dict) {
        copy[Convert.ToString(entry.Key)] = Unwrap(entry.Value);
      }
      return copy;
    }
    IEnumerable seq = value as IEnumerable;
    if (seq != null) {
      ArrayList copy = new ArrayList();
      foreach (object item in seq) copy.Add(Unwrap(item));
      return copy;
    }
    return value.ToString();
  }
  public static string Serialize(object value) {
    JavaScriptSerializer ser = new JavaScriptSerializer();
    ser.MaxJsonLength = 67108864;
    ser.RecursionLimit = 64;
    return ser.Serialize(Unwrap(value));
  }
}
'@
  }
  return [JsonBox]::Serialize($Value)
}

function Expand-JsonUnicode {
  param([string]$Json)
  $eval = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
  }
  return [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', $eval)
}

function Assert-DeepSeekKey {
  param([string]$ApiKey)
  $req = [System.Net.HttpWebRequest]::Create("https://api.deepseek.com/models")
  $req.Method = "GET"
  $req.Timeout = 20000
  $req.Headers.Add("Authorization", "Bearer $ApiKey")
  try {
    $resp = $req.GetResponse()
    $resp.Close()
  } catch [System.Net.WebException] {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 401 -or $code -eq 403) { throw "DeepSeek API Key 无效或已过期。" }
    throw "连不上 DeepSeek API。"
  }
}

function Invoke-DeepSeekRaw {
  param([string]$Json, [string]$ApiKey)
  $req = [System.Net.HttpWebRequest]::Create("https://api.deepseek.com/chat/completions")
  $req.Method = "POST"
  $req.ContentType = "application/json; charset=utf-8"
  $req.Timeout = 300000
  $req.ReadWriteTimeout = 300000
  $req.Headers.Add("Authorization", "Bearer $ApiKey")
  $payload = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $req.ContentLength = $payload.Length
  $stream = $req.GetRequestStream()
  $stream.Write($payload, 0, $payload.Length)
  $stream.Close()
  try {
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    return $text
  } catch [System.Net.WebException] {
    $code = 0
    $errText = ""
    $webResp = $_.Exception.Response
    if ($webResp) {
      $code = [int]$webResp.StatusCode
      try {
        $reader = New-Object System.IO.StreamReader($webResp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $errText = $reader.ReadToEnd()
        $reader.Close()
      } catch {}
    }
    if ($code -eq 401 -or $code -eq 403) { throw "DeepSeek API Key 无效或已过期。" }
    $msg = "DeepSeek 请求失败（HTTP $code）。"
    if ($errText) {
      try {
        $errObj = $errText | ConvertFrom-Json
        if ($errObj.error.message) { $msg = "DeepSeek 请求失败：$($errObj.error.message)" }
      } catch {}
    }
    throw ($msg -replace 'sk-[A-Za-z0-9_\-]+', 'sk-***')
  }
}

function ConvertFrom-ModelJson {
  param([string]$Text)
  $t = $Text.Trim()
  if ($t.StartsWith('```')) {
    $t = [regex]::Replace($t, '(?s)^```(?:json)?\s*', '')
    $t = [regex]::Replace($t, '\s*```\s*$', '')
  }
  $start = $t.IndexOf('{')
  $end = $t.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) { throw "模型返回的不是 JSON 对象" }
  $t = $t.Substring($start, $end - $start + 1)
  return ($t | ConvertFrom-Json)
}

function Get-PlanList {
  param($Node)
  if ($null -eq $Node) { return @() }
  return @($Node)
}

function Get-PlanProp {
  param($Obj, [string[]]$Names)
  if ($null -eq $Obj) { return $null }
  foreach ($name in $Names) {
    $prop = $Obj.PSObject.Properties[$name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
  }
  return $null
}

function Convert-ToDouble {
  param($Value, [double]$Fallback)
  if ($null -eq $Value) { return $Fallback }
  $n = 0.0
  $ok = [double]::TryParse(([string]$Value).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
  if ($ok) { return $n }
  return $Fallback
}

function Copy-PointList {
  param($Pts)
  $out = New-Object System.Collections.ArrayList
  $n = 0
  if ($null -ne $Pts) { $n = [int]$Pts.Count }
  for ($i = 0; $i -lt $n; $i++) {
    $p = $Pts[$i]
    if ($null -eq $p) { continue }
    $pair = New-Object System.Collections.ArrayList
    [void]$pair.Add([math]::Round([double]$p[0], 1))
    [void]$pair.Add([math]::Round([double]$p[1], 1))
    [void]$out.Add($pair)
  }
  return ,$out
}

function Get-PointPathLength {
  param($Pts)
  $len = 0.0
  $n = 0
  if ($null -ne $Pts) { $n = [int]$Pts.Count }
  for ($i = 0; $i -lt ($n - 1); $i++) {
    $a = $Pts[$i]
    $b = $Pts[$i + 1]
    $dx = [double]$b[0] - [double]$a[0]
    $dy = [double]$b[1] - [double]$a[1]
    $len += [math]::Sqrt($dx * $dx + $dy * $dy)
  }
  return $len
}

function Get-StructureRuleText {
  @'
默认结构规则（先判断整张图是否符合这些预定规则。图层名不区分大小写。符合时按规则归类。整张图的图层、图块和标注都对不上这些规则时，不要套用图层名，改为按结构设计是否合理自行判断）：
- 梁图层：s数字-beam，或 s数字-beam-hddn；图层名里含 gl 或 GL（不区分大小写，例如 s1-beam-gl、GL-1）的线状图元也算梁，而且这条梁是钢梁。图元是 mline、line，或 polyline。平行双线方向点积绝对值不小于 0.99、重叠不少于 50 mm、间距 80 到 1010 mm 时，较短线向另一条偏移一半间距得到梁中线，间距就是梁宽。梁高取中线附近 2500 mm 内的尺寸文字，格式为 N x N、N*N 或 N×N；对不上时梁高用 500。梁尺寸文字图层：以 dsptext_beam 结尾、以 dsptext_wallbeam 结尾、G-ANNO-NPLT、尺寸标注数字-梁。
- 钢梁尺寸文字：由四个数字组成的型钢规格字符串，例如 400x200x8x13、HN400*200*8*13、400×200×8×13。它同样是梁的截面尺寸，不要当成标注、轴号或其它图元。第 1 个数字是截面高（depth），第 2 个是截面宽（width），后面两个是腹板厚和翼缘厚，不用管。这种文字出现在哪条梁中线附近，那条梁就是钢梁。
- 柱图层：a数字-cols 或 s数字-cols，数字可以没有，例如 S-COLS。闭合 polyline 面积在 10000 到 10000000 之间，以及圆。不要把轴号小圆当成柱。
- 墙图层：a数字-wall 或 s数字-wall。平行双线间距 80 到 1000 mm、重叠不少于 50 mm。墙厚通常小于 450，长度通常大于 1500。不要把整层外轮廓或轴线当成墙。
- 楼板图层：a数字-slab-otln、s数字-slab-otln、a数字-flor-otln、s数字-flor-otln 的闭合 polyline，面积不小于 1000000。板厚文字图层 s数字-slab-text，板厚取 40 到 800。没有板轮廓时，slabRect 用所选梁柱墙的包围盒。
- id 必须来自输入，禁止编造 id 或坐标。
- 梁、柱、墙必须在同一坐标空间。图块定义是局部坐标，模型空间可能是另一套大坐标。若梁图块和柱墙图块的范围接近，就只选这些图块里的 id，不要再选模型空间里平移后的副本。
- 梁的 width 是梁宽，depth 是梁高，单位毫米。附近文字是两个数字时，200x500 表示宽 x 高；是四个数字的型钢规格时，400x200x8x13 表示高 400、宽 200，也就是 depth 取第 1 个数字、width 取第 2 个数字。( +0.020 ) 表示 rise 为 20。没有标注时，mline 的 scale 可作为 width，depth 用 500。
- 钢梁要在 beams 项里加 "steel":true。图层名含 gl 或 GL 的梁一定是钢梁；梁中线附近有四个数字型钢规格文字的梁也是钢梁。其它梁加 "steel":false。
- storyMm 和 slabThickMm 采用用户给出的默认值，除非文字明确只给出一个标准层高或板厚。
- 不要选择尺寸线、轴号、填充边界、图框和标题栏。
整张图完全不符合上面的预定规则时，必须自行判断，并思考这套结构是否合理：
- 先看图层名、图块名和文字是否整体对得上梁、柱、墙、楼板规则。只有少量图元对不上时，仍按规则处理能对上的部分，再用几何补全其余构件。
- 如果整张图都不是这套图层体系，就不要因为图层名不像 s-beam、s-cols、s-wall 而放弃。根据构件关系判断：柱是较小的支撑，通常落在梁的交点或端部；梁是连接柱或墙的线状构件，跨度和截面要像能承受楼盖的梁；墙是细长的竖向构件，不要把轴线、尺寸线或整层外框当成墙；楼板覆盖由这些梁、柱、墙围成的平面。
- 截面优先用附近尺寸文字。没有文字时，选择在常见结构范围里说得通的宽度和高度，不要把明显是标注、轴号、填充或图框的图元选进来。
- summary 要写明依据。规则适用时说明命中了哪些规则；规则不适用时说明图纸不符合预定规则，以及按结构关系做了什么判断。
'@
}

function New-DeepSeekBody {
  param([string]$InventoryJson, [double]$Story, [double]$SlabThick, [bool]$Think)
  $rules = Get-StructureRuleText
  $system = @"
你是结构施工图解析器。每次请求都会同时给你两份材料：中望 CAD 读出的全部图元清单，以及下面这套默认结构规则。图纸符合规则时按规则归类。图纸整体不符合预定规则时，不要硬套图层名，要自行判断哪些图元是梁、柱、墙、楼板，并思考这样的结构布置是否合理。id 仍然只能来自清单。
只输出一个 JSON 对象，不要 Markdown，不要解释。格式：
{"summary":"一两句中文，说明依据","storyMm":3000,"slabThickMm":130,"beams":[{"id":"m1","width":200,"depth":500,"rise":0,"steel":false}],"columns":[{"id":"p1"}],"walls":[{"id":"p2"}],"slabRect":[0,0,1000,1000]}
$rules
"@
  $user = "请把下面的 CAD 图元和默认规则放在一起分析，并输出 JSON。先看整张图是否符合预定规则。符合就按规则归类；完全不符合时，请自行判断梁、柱、墙、楼板，并思考结构布置是否合理。用户指定的默认层高是 $Story mm，默认板厚是 $SlabThick mm。`n`n" + $rules + "`n`n图元 JSON：`n" + $InventoryJson
  $thinking = @{ type = "disabled" }
  $maxTokens = 16384
  if ($Think) {
    $thinking = @{ type = "enabled" }
    $maxTokens = 32768
  }
  $body = @{
    model = "deepseek-flash"
    messages = @(
      @{ role = "system"; content = $system },
      @{ role = "user"; content = $user }
    )
    response_format = @{ type = "json_object" }
    thinking = $thinking
    max_tokens = $maxTokens
  }
  if ($Think) { $body["reasoning_effort"] = "high" }
  return (Expand-JsonUnicode (ConvertTo-ApiJson $body))
}

function Select-SameSpace {
  param($Selections, $Index, $SpaceBoxes)
  $groups = @{}
  foreach ($sel in @($Selections)) {
    $id = [string]$sel.Id
    if (-not $Index.ContainsKey($id)) { continue }
    $space = [string]$Index[$id].space
    if (-not $groups.ContainsKey($space)) { $groups[$space] = New-Object System.Collections.Generic.List[object] }
    $groups[$space].Add($sel) | Out-Null
  }
  if ($groups.Count -le 1) { return @{ Items = @($Selections); Dropped = $false } }
  $best = $null
  $bestN = -1
  foreach ($name in @($groups.Keys)) {
    if ($groups[$name].Count -gt $bestN) {
      $bestN = $groups[$name].Count
      $best = $name
    }
  }
  $bestBox = $null
  if ($SpaceBoxes.ContainsKey($best)) { $bestBox = $SpaceBoxes[$best] }
  $kept = New-Object System.Collections.Generic.List[object]
  $dropped = $false
  foreach ($name in @($groups.Keys)) {
    $far = $false
    if ($name -ne $best -and $bestBox -and $SpaceBoxes.ContainsKey($name)) {
      $box = $SpaceBoxes[$name]
      $dx = [math]::Abs([double]$box[0] - [double]$bestBox[0])
      $dy = [math]::Abs([double]$box[1] - [double]$bestBox[1])
      if ($dx -gt 20000 -or $dy -gt 20000) { $far = $true }
    }
    if ($far) { $dropped = $true; continue }
    foreach ($sel in $groups[$name]) { $kept.Add($sel) | Out-Null }
  }
  return @{ Items = $kept.ToArray(); Dropped = $dropped }
}

function Convert-StructurePlan {
  param($Plan, $Index, $SpaceBoxes, [double]$Story, [double]$SlabThick, $Usage, [bool]$Thinking)
  $summary = [string](Get-PlanProp $Plan @("summary"))
  if ($summary.Length -gt 400) { $summary = $summary.Substring(0, 400) }

  $beamWant = @{}
  foreach ($item in (Get-PlanList (Get-PlanProp $Plan @("beams")))) {
    $id = [string](Get-PlanProp $item @("id"))
    if ($id) { $beamWant[$id] = $item }
  }
  $colWant = @{}
  foreach ($item in (Get-PlanList (Get-PlanProp $Plan @("columns")))) {
    $id = [string](Get-PlanProp $item @("id"))
    if ($id) { $colWant[$id] = $item }
  }
  $wallWant = @{}
  foreach ($item in (Get-PlanList (Get-PlanProp $Plan @("walls")))) {
    $id = [string](Get-PlanProp $item @("id"))
    if ($id) { $wallWant[$id] = $item }
  }

  foreach ($id in @($colWant.Keys)) {
    if (-not $wallWant.ContainsKey($id)) { continue }
    $local = $null
    if ($Index.ContainsKey($id)) { $local = $Index[$id] }
    $asWall = $false
    if ($local -and $local.type -eq "polyline") {
      $asWall = ([double]$local.thick -le 450 -and [double]$local.length -ge 1500)
    }
    if ($asWall) { $colWant.Remove($id) } else { $wallWant.Remove($id) }
  }

  $selections = New-Object System.Collections.Generic.List[object]
  foreach ($id in @($beamWant.Keys)) { $selections.Add([pscustomobject]@{ Id = $id; Role = "beam"; Raw = $beamWant[$id] }) | Out-Null }
  foreach ($id in @($colWant.Keys)) { $selections.Add([pscustomobject]@{ Id = $id; Role = "column"; Raw = $colWant[$id] }) | Out-Null }
  foreach ($id in @($wallWant.Keys)) { $selections.Add([pscustomobject]@{ Id = $id; Role = "wall"; Raw = $wallWant[$id] }) | Out-Null }

  $filtered = Select-SameSpace -Selections $selections.ToArray() -Index $Index -SpaceBoxes $SpaceBoxes
  if ($filtered.Dropped) {
    if ($summary) { $summary += " " }
    $summary += "已忽略另一坐标空间中的重复图元。"
  }

  $beams = New-Object System.Collections.Generic.List[object]
  $columns = New-Object System.Collections.Generic.List[object]
  $walls = New-Object System.Collections.Generic.List[object]
  $minX = [double]::MaxValue
  $minY = [double]::MaxValue
  $maxX = [double]::MinValue
  $maxY = [double]::MinValue
  $used = @{}

  foreach ($sel in @($filtered.Items)) {
    if ($null -eq $sel) { continue }
    $id = [string]$sel.Id
    if ($used.ContainsKey($id)) { continue }
    if (-not $Index.ContainsKey($id)) { continue }
    $local = $Index[$id]
    $used[$id] = $true

    if ($sel.Role -eq "beam") {
      if ($beams.Count -ge 500) { continue }
      if ($local.type -eq "circle") { continue }
      if ($local.type -eq "polyline" -and $local.closed) { continue }
      $pts = Copy-PointList $local.pts
      if ($null -eq $pts -or $pts.Count -lt 2) { continue }
      $width = Convert-ToDouble (Get-PlanProp $sel.Raw @("width", "w")) 0
      if ($width -le 0 -and $local.scale) { $width = [math]::Abs([double]$local.scale) }
      if ($width -lt 80 -or $width -gt 1500) { $width = 200 }
      $depth = Convert-ToDouble (Get-PlanProp $sel.Raw @("depth", "h", "height")) 500
      if ($depth -lt 150 -or $depth -gt 2500) { $depth = 500 }
      $rise = Convert-ToDouble (Get-PlanProp $sel.Raw @("rise")) 0
      if ($rise -lt -2000 -or $rise -gt 5000) { $rise = 0 }
      $steel = $false
      if ($local.layer -and ([string]$local.layer -match 'gl')) { $steel = $true }
      $steelRaw = Get-PlanProp $sel.Raw @("steel", "isSteel", "is_steel")
      if ($null -ne $steelRaw) {
        if ($steelRaw -eq $true) { $steel = $true }
        elseif (([string]$steelRaw).Trim().ToLowerInvariant() -eq 'true' -or ([string]$steelRaw).Trim() -eq '1') { $steel = $true }
      }
      $len = [math]::Round((Get-PointPathLength $pts), 1)
      $beams.Add(@{ pts = $pts; w = [math]::Round($width, 1); h = [math]::Round($depth, 1); rise = [math]::Round($rise, 1); len = $len; steel = $steel }) | Out-Null
      for ($pi = 0; $pi -lt $pts.Count; $pi++) {
        $p = $pts[$pi]
        if ([double]$p[0] -lt $minX) { $minX = [double]$p[0] }
        if ([double]$p[1] -lt $minY) { $minY = [double]$p[1] }
        if ([double]$p[0] -gt $maxX) { $maxX = [double]$p[0] }
        if ([double]$p[1] -gt $maxY) { $maxY = [double]$p[1] }
      }
    } elseif ($sel.Role -eq "column" -and $local.type -eq "circle") {
      if ($columns.Count -ge 300) { continue }
      $cx = [math]::Round([double]$local.cx, 1)
      $cy = [math]::Round([double]$local.cy, 1)
      $r = [math]::Round([double]$local.r, 1)
      $columns.Add(@{ kind = "circle"; c = @($cx, $cy); r = $r }) | Out-Null
      if (($cx - $r) -lt $minX) { $minX = $cx - $r }
      if (($cy - $r) -lt $minY) { $minY = $cy - $r }
      if (($cx + $r) -gt $maxX) { $maxX = $cx + $r }
      if (($cy + $r) -gt $maxY) { $maxY = $cy + $r }
    } elseif ($local.type -eq "polyline" -and $local.closed) {
      $pts = Copy-PointList $local.pts
      if ($null -eq $pts -or $pts.Count -lt 3) { continue }
      $item = @{
        pts = $pts
        area = [math]::Round([double]$local.area, 1)
        thick = [math]::Round([double]$local.thick, 1)
        length = [math]::Round([double]$local.length, 1)
      }
      if ($sel.Role -eq "wall") {
        if ($walls.Count -ge 300) { continue }
        $walls.Add($item) | Out-Null
      } else {
        if ($columns.Count -ge 300) { continue }
        $columns.Add($item) | Out-Null
      }
      for ($pi = 0; $pi -lt $pts.Count; $pi++) {
        $p = $pts[$pi]
        if ([double]$p[0] -lt $minX) { $minX = [double]$p[0] }
        if ([double]$p[1] -lt $minY) { $minY = [double]$p[1] }
        if ([double]$p[0] -gt $maxX) { $maxX = [double]$p[0] }
        if ([double]$p[1] -gt $maxY) { $maxY = [double]$p[1] }
      }
    }
  }

  if ($beams.Count -eq 0 -and $columns.Count -eq 0 -and $walls.Count -eq 0) {
    $why = $summary
    if (-not $why) { $why = "模型没有选中可建模的图元。" }
    throw "没有识别到梁、柱或墙。$why"
  }

  if ($minX -eq [double]::MaxValue) {
    $minX = 0; $minY = 0; $maxX = 1000; $maxY = 1000
  }
  $rect = @([math]::Round($minX, 1), [math]::Round($minY, 1), [math]::Round($maxX, 1), [math]::Round($maxY, 1))
  $given = @(Get-PlanList (Get-PlanProp $Plan @("slabRect", "slab_rect")))
  if ($given.Count -ge 4) {
    $gx0 = Convert-ToDouble $given[0] $rect[0]
    $gy0 = Convert-ToDouble $given[1] $rect[1]
    $gx1 = Convert-ToDouble $given[2] $rect[2]
    $gy1 = Convert-ToDouble $given[3] $rect[3]
    if ($gx0 -gt $gx1) { $t = $gx0; $gx0 = $gx1; $gx1 = $t }
    if ($gy0 -gt $gy1) { $t = $gy0; $gy0 = $gy1; $gy1 = $t }
    $rw = $gx1 - $gx0
    $rh = $gy1 - $gy0
    $mw = $rect[2] - $rect[0]
    $mh = $rect[3] - $rect[1]
    $sane = ($rw -ge 500 -and $rh -ge 500)
    if ($sane -and $mw -gt 500 -and ($rw -gt $mw * 4 -or $rh -gt $mh * 4)) { $sane = $false }
    if ($sane) { $rect = @([math]::Round($gx0, 1), [math]::Round($gy0, 1), [math]::Round($gx1, 1), [math]::Round($gy1, 1)) }
  }

  $storyOut = Convert-ToDouble (Get-PlanProp $Plan @("storyMm", "story")) $Story
  if ($storyOut -lt 500 -or $storyOut -gt 20000) { $storyOut = $Story }
  $slabOut = Convert-ToDouble (Get-PlanProp $Plan @("slabThickMm", "slabThick", "slab_thick")) $SlabThick
  if ($slabOut -lt 40 -or $slabOut -gt 800) { $slabOut = $SlabThick }

  return @{
    units = "mm"
    story = [math]::Round($storyOut, 1)
    slab_thick = [math]::Round($slabOut, 1)
    slab_rect = $rect
    beams = $beams
    columns = $columns
    walls = $walls
    counts = @{
      beams = $beams.Count
      columns = $columns.Count
      walls = $walls.Count
      slab = 1
    }
    summary = $summary
    model = "deepseek-flash"
    thinking = $Thinking
    usage = $Usage
  }
}

function Invoke-DeepSeekStructure {
  param($Inventory, $Index, $SpaceBoxes, [string]$ApiKey, [double]$Story, [double]$SlabThick, [scriptblock]$OnProgress)
  $entityCount = 0
  $layerCount = 0
  # 这里不能用 @() 包一层取 Count：PS 5.1 对 List[object] 这样取会抛
  # "Argument types do not match"，异常被吞掉后图元数就显示成 0。
  # List 和数组都有 .Count，直接取。
  try { $entityCount = [int]$Inventory.entities.Count } catch {}
  try { $layerCount = [int]$Inventory.layers.Count } catch {}
  if ($OnProgress) {
    & $OnProgress "打包图元" "已从 CAD 读出 $entityCount 个图元、$layerCount 个图层。正在把图元清单和默认梁柱墙板规则打包成同一次分析请求。"
  }
  $inventoryJson = Expand-JsonUnicode (ConvertTo-ApiJson $Inventory)
  Write-Host ((Get-BuildTag) + " 图元清单文本 " + $inventoryJson.Length + " 字符，交给 DeepSeek 分析")
  $wan = [math]::Round($inventoryJson.Length / 10000.0, 1)
  $plan = $null
  $usage = @{ prompt = 0; completion = 0 }
  $thinking = $true
  $lastError = ""
  try {
  foreach ($think in @($true, $false)) {
    $step = "DeepSeek 分析"
    $detail = "已提交 $entityCount 个图元、$layerCount 个图层和默认结构规则，约 $wan 万字。符合规则就按规则归类；整张图对不上规则时，模型会按结构布置是否合理自行判断。这一步通常要几分钟。"
    if (-not $think) {
      $step = "DeepSeek 重试"
      $detail = "第一次没有返回完整 JSON。正在关闭思考模式，把同一份图元和默认规则再分析一次。"
    }
    if ($OnProgress) { & $OnProgress $step $detail }
    if (Get-Command Start-ProgressHeartbeat -ErrorAction SilentlyContinue) {
      Start-ProgressHeartbeat -Step $step -Detail $detail
    }
    try {
      $raw = Invoke-DeepSeekRaw -Json (New-DeepSeekBody -InventoryJson $inventoryJson -Story $Story -SlabThick $SlabThick -Think $think) -ApiKey $ApiKey
      $obj = $raw | ConvertFrom-Json
      $content = ""
      if ($obj.choices) { $content = [string]$obj.choices[0].message.content }
      if ([string]::IsNullOrWhiteSpace($content)) { throw "模型没有返回 JSON 正文" }
      $plan = ConvertFrom-ModelJson $content
      if ($obj.usage) {
        $usage = @{
          prompt = [int]$obj.usage.prompt_tokens
          completion = [int]$obj.usage.completion_tokens
        }
      }
      $thinking = $think
      break
    } catch {
      $lastError = [string]$_.Exception.Message
      Write-Host ((Get-BuildTag) + " DeepSeek 第一次请求没有返回完整 JSON，关闭思考模式重试")
      if ($lastError -match "API Key") { throw $lastError }
    }
  }
  if (-not $plan) { throw "DeepSeek 没有返回可解析的 JSON。$lastError" }
  } finally {
    if (Get-Command Stop-ProgressHeartbeat -ErrorAction SilentlyContinue) { Stop-ProgressHeartbeat }
  }
  if ($OnProgress) { & $OnProgress "整理结果" "DeepSeek 已返回。正在按图元编号还原梁、柱、墙和楼板的坐标、截面和楼板范围。" }
  return Convert-StructurePlan -Plan $plan -Index $Index -SpaceBoxes $SpaceBoxes -Story $Story -SlabThick $SlabThick -Usage $usage -Thinking $thinking
}
