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

# --- 梁定位线 ---
# 定位线坐标在交给 DeepSeek 之前定死。模型只负责挑选 id，不能把两根线收成中点。
# 间距小于 190 mm 的平行线一律不配对：错台、并排小梁常见这种间距，取中线会离开 CAD。
# 只有同一空间、同一图层里大部分长线都能两两配成边线，且间距在 190–1010 mm 时，
# 才把互为最近、中间没有第三条线的那一对收成中心线；只在一端被短线连上的错台不配。

function Get-OpenLineAxis {
  param($Local, [double]$MinLen = 200)
  if ($null -eq $Local) { return $null }
  $t = [string]$Local.type
  if ($t -ne "line" -and $t -ne "polyline") { return $null }
  try { if ($Local.closed) { return $null } } catch {}
  $pts = $Local.pts
  if ($null -eq $pts -or [int]$pts.Count -lt 2) { return $null }
  $last = [int]$pts.Count - 1
  $x0 = [double]$pts[0][0]; $y0 = [double]$pts[0][1]
  $x1 = [double]$pts[$last][0]; $y1 = [double]$pts[$last][1]
  $dx = $x1 - $x0; $dy = $y1 - $y0
  $len = [math]::Sqrt($dx * $dx + $dy * $dy)
  if ($len -lt $MinLen) { return $null }
  $ux = $dx / $len; $uy = $dy / $len
  for ($i = 1; $i -lt $last; $i++) {
    $px = [double]$pts[$i][0] - $x0
    $py = [double]$pts[$i][1] - $y0
    if ([math]::Abs($ux * $py - $uy * $px) -gt 8) { return $null }
  }
  return @{ x0 = $x0; y0 = $y0; x1 = $x1; y1 = $y1; len = $len; ux = $ux; uy = $uy }
}

function Get-AxisOverlap {
  param($A, $B)
  $pa0 = $A.x0 * $A.ux + $A.y0 * $A.uy
  $pa1 = $A.x1 * $A.ux + $A.y1 * $A.uy
  $pb0 = $B.x0 * $A.ux + $B.y0 * $A.uy
  $pb1 = $B.x1 * $A.ux + $B.y1 * $A.uy
  $aLo = [math]::Min($pa0, $pa1); $aHi = [math]::Max($pa0, $pa1)
  $bLo = [math]::Min($pb0, $pb1); $bHi = [math]::Max($pb0, $pb1)
  $overlap = [math]::Min($aHi, $bHi) - [math]::Max($aLo, $bLo)
  return @{ overlap = $overlap; pa0 = $pa0; lo = [math]::Max($aLo, $bLo); hi = [math]::Min($aHi, $bHi) }
}

function Test-BeamEdgePair {
  param($A, $B)
  $no = @{ ok = $false }
  if ([string]$A.id -eq [string]$B.id) { return $no }
  if ([string]$A.space -ne [string]$B.space) { return $no }
  if ([string]$A.layer -ne [string]$B.layer) { return $no }
  if ([double]$A.len -lt 200 -or [double]$B.len -lt 200) { return $no }
  $dot = [math]::Abs($A.ux * $B.ux + $A.uy * $B.uy)
  if ($dot -lt 0.998) { return $no }
  $dist = [math]::Abs($A.ux * ($B.y0 - $A.y0) - $A.uy * ($B.x0 - $A.x0))
  # 小于 190 mm：当作两根独立定位线，不收中线。
  if ($dist -lt 190 -or $dist -gt 1010) { return $no }
  $ov = Get-AxisOverlap $A $B
  $overlap = [double]$ov.overlap
  if ($overlap -lt 200) { return $no }
  $short = [math]::Min([double]$A.len, [double]$B.len)
  $long = [math]::Max([double]$A.len, [double]$B.len)
  if ($short -lt 1) { return $no }
  if (($overlap / $short) -lt 0.75) { return $no }
  if (($overlap / $long) -lt 0.55) { return $no }
  return @{ ok = $true; dist = $dist; overlap = $overlap; pa0 = [double]$ov.pa0; lo = [double]$ov.lo; hi = [double]$ov.hi }
}

function Test-PointNear {
  param([double]$X, [double]$Y, [double]$Px, [double]$Py, [double]$Tol2)
  $dx = $X - $Px; $dy = $Y - $Py
  return (($dx * $dx + $dy * $dy) -le $Tol2)
}

function Get-ShortJoinCount {
  # 一对平行线有几端被同层短线接上。错台通常只接一端；封闭的双边梁两端都有端线。
  param($A, $B, [double]$Dist, $Pool)
  $limit = $Dist * 1.8 + 120
  $tol2 = 150.0 * 150.0
  $a0 = $false
  $a1 = $false
  foreach ($C in $Pool) {
    if ([string]$C.id -eq [string]$A.id -or [string]$C.id -eq [string]$B.id) { continue }
    $dot = [math]::Abs($A.ux * $C.ux + $A.uy * $C.uy)
    if ($dot -gt 0.3) { continue }
    if ([double]$C.len -gt $limit -or [double]$C.len -lt 40) { continue }
    $c0b = (Test-PointNear $C.x0 $C.y0 $B.x0 $B.y0 $tol2) -or (Test-PointNear $C.x0 $C.y0 $B.x1 $B.y1 $tol2)
    $c1b = (Test-PointNear $C.x1 $C.y1 $B.x0 $B.y0 $tol2) -or (Test-PointNear $C.x1 $C.y1 $B.x1 $B.y1 $tol2)
    $c0a0 = Test-PointNear $C.x0 $C.y0 $A.x0 $A.y0 $tol2
    $c1a0 = Test-PointNear $C.x1 $C.y1 $A.x0 $A.y0 $tol2
    $c0a1 = Test-PointNear $C.x0 $C.y0 $A.x1 $A.y1 $tol2
    $c1a1 = Test-PointNear $C.x1 $C.y1 $A.x1 $A.y1 $tol2
    if (($c0a0 -and $c1b) -or ($c1a0 -and $c0b)) { $a0 = $true }
    if (($c0a1 -and $c1b) -or ($c1a1 -and $c0b)) { $a1 = $true }
  }
  $n = 0
  if ($a0) { $n = $n + 1 }
  if ($a1) { $n = $n + 1 }
  return $n
}

function Test-LineBetweenPair {
  param($A, $B, [double]$SignedB, $Pool)
  foreach ($C in $Pool) {
    if ([string]$C.id -eq [string]$A.id -or [string]$C.id -eq [string]$B.id) { continue }
    if ([string]$C.layer -ne [string]$A.layer -or [string]$C.space -ne [string]$A.space) { continue }
    $dot = [math]::Abs($A.ux * $C.ux + $A.uy * $C.uy)
    if ($dot -lt 0.998) { continue }
    $nx = -$A.uy; $ny = $A.ux
    $sc = ($C.x0 - $A.x0) * $nx + ($C.y0 - $A.y0) * $ny
    $between = $false
    if ($SignedB -gt 0) {
      if ($sc -gt 30 -and $sc -lt ($SignedB - 30)) { $between = $true }
    } elseif ($SignedB -lt 0) {
      if ($sc -lt -30 -and $sc -gt ($SignedB + 30)) { $between = $true }
    }
    if (-not $between) { continue }
    $ov = Get-AxisOverlap $A $C
    if ([double]$ov.overlap -gt 100) { return $true }
  }
  return $false
}

function Get-InventoryId {
  param($Entity)
  if ($null -eq $Entity) { return "" }
  if ($Entity -is [System.Collections.IDictionary]) { return [string]$Entity["id"] }
  $prop = $Entity.PSObject.Properties["id"]
  if ($prop) { return [string]$prop.Value }
  return ""
}

function Merge-BeamEdgePairs {
  param($Inventory, $Index)
  if ($null -eq $Index -or $null -eq $Inventory) { return 0 }
  $pool = New-Object System.Collections.Generic.List[object]
  foreach ($id in @($Index.Keys)) {
    $local = $Index[$id]
    $axis = Get-OpenLineAxis $local 40
    if ($null -eq $axis) { continue }
    $pool.Add([pscustomobject]@{
      id = [string]$id
      space = [string]$local.space
      layer = [string]$local.layer
      x0 = [double]$axis.x0; y0 = [double]$axis.y0
      x1 = [double]$axis.x1; y1 = [double]$axis.y1
      len = [double]$axis.len; ux = [double]$axis.ux; uy = [double]$axis.uy
    }) | Out-Null
  }
  if ($pool.Count -lt 4) { return 0 }

  $groups = @{}
  foreach ($item in $pool) {
    $key = $item.space + "|" + $item.layer
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
    $groups[$key].Add($item) | Out-Null
  }

  $accepted = New-Object System.Collections.Generic.List[object]
  foreach ($key in @($groups.Keys)) {
    $group = $groups[$key]
    $longN = 0
    foreach ($item in $group) { if ([double]$item.len -ge 200) { $longN = $longN + 1 } }
    if ($longN -lt 4) { continue }
    $best = @{}
    $bestFit = @{}
    foreach ($a in $group) {
      if ([double]$a.len -lt 200) { continue }
      $bestDist = [double]::MaxValue
      $bestItem = $null
      $fitKeep = $null
      foreach ($b in $group) {
        $fit = Test-BeamEdgePair $a $b
        if (-not $fit.ok) { continue }
        if ([double]$fit.dist -lt $bestDist) {
          $bestDist = [double]$fit.dist
          $bestItem = $b
          $fitKeep = $fit
        }
      }
      if ($null -eq $bestItem) { continue }
      $nx = -$a.uy; $ny = $a.ux
      $signed = ($bestItem.x0 - $a.x0) * $nx + ($bestItem.y0 - $a.y0) * $ny
      if (Test-LineBetweenPair -A $a -B $bestItem -SignedB $signed -Pool $group) { continue }
      if ((Get-ShortJoinCount -A $a -B $bestItem -Dist $bestDist -Pool $group) -eq 1) { continue }
      $best[[string]$a.id] = [string]$bestItem.id
      $bestFit[[string]$a.id] = $fitKeep
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    $seenPair = @{}
    foreach ($a in $group) {
      $aid = [string]$a.id
      if (-not $best.ContainsKey($aid)) { continue }
      $bid = [string]$best[$aid]
      if (-not $best.ContainsKey($bid)) { continue }
      if ([string]$best[$bid] -ne $aid) { continue }
      $loId = $aid; $hiId = $bid
      if ($hiId -lt $loId) { $swap = $loId; $loId = $hiId; $hiId = $swap }
      $pk = $loId + "|" + $hiId
      if ($seenPair.ContainsKey($pk)) { continue }
      $seenPair[$pk] = $true
      $pairs.Add([pscustomobject]@{ A = $a; PeerId = $bid; Dist = [double]$bestFit[$aid].dist; Fit = $bestFit[$aid] }) | Out-Null
    }
    if ($pairs.Count -lt 2) { continue }
    $pairedIds = @{}
    foreach ($p in $pairs) {
      $pairedIds[[string]$p.A.id] = $true
      $pairedIds[[string]$p.PeerId] = $true
    }
    if ($pairedIds.Count -lt 4) { continue }
    if (($pairedIds.Count / [double]$longN) -lt 0.45) { continue }
    $dists = New-Object System.Collections.Generic.List[double]
    foreach ($p in $pairs) { $dists.Add([double]$p.Dist) | Out-Null }
    $sorted = @($dists.ToArray() | Sort-Object)
    $median = [double]$sorted[[int](($sorted.Count - 1) / 2)]
    $limit = [math]::Max($median * 2.0, $median + 300)
    foreach ($p in $pairs) {
      if ([double]$p.Dist -gt $limit) { continue }
      $accepted.Add($p) | Out-Null
    }
  }

  $tag = ""
  if (Get-Command Get-BuildTag -ErrorAction SilentlyContinue) { $tag = Get-BuildTag + " " }
  if ($accepted.Count -eq 0) {
    Write-Host ($tag + "梁定位线：这一层不是成对边线，平行线保持在 CAD 原位")
    return 0
  }

  if ($Inventory.entities -isnot [System.Collections.Generic.List[object]]) {
    $asList = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Inventory.entities) { $asList.Add($e) | Out-Null }
    $Inventory.entities = $asList
  }
  $byId = @{}
  foreach ($item in $pool) { $byId[[string]$item.id] = $item }
  $remove = @{}
  $seq = 0
  foreach ($p in $accepted) {
    do { $seq = $seq + 1; $cid = "b$seq" } while ($Index.ContainsKey($cid))
    $a = $p.A
    $b = $byId[[string]$p.PeerId]
    $fit = $p.Fit
    $nx = -$a.uy; $ny = $a.ux
    $mx = (($b.x0 + $b.x1) / 2) - (($a.x0 + $a.x1) / 2)
    $my = (($b.y0 + $b.y1) / 2) - (($a.y0 + $a.y1) / 2)
    $sign = [math]::Sign($mx * $nx + $my * $ny)
    if ($sign -eq 0) { $sign = 1 }
    $off = ([double]$p.Dist / 2) * $sign
    $pa0 = [double]$fit.pa0
    $c0x = $a.x0 + $a.ux * ([double]$fit.lo - $pa0) + $nx * $off
    $c0y = $a.y0 + $a.uy * ([double]$fit.lo - $pa0) + $ny * $off
    $c1x = $a.x0 + $a.ux * ([double]$fit.hi - $pa0) + $nx * $off
    $c1y = $a.y0 + $a.uy * ([double]$fit.hi - $pa0) + $ny * $off
    $pts = New-Object System.Collections.Generic.List[object]
    $zPair = Get-EdgeEndZs -Index $Index -SourceId ([string]$a.id) -StartParam ([double]$fit.pa0) -EndParam ([double]$fit.pa0 + [double]$a.len) -At0 ([double]$fit.lo) -At1 ([double]$fit.hi)
    if ($null -ne $zPair) {
      $pts.Add(@([math]::Round($c0x, 1), [math]::Round($c0y, 1), [math]::Round([double]$zPair[0], 1))) | Out-Null
      $pts.Add(@([math]::Round($c1x, 1), [math]::Round($c1y, 1), [math]::Round([double]$zPair[1], 1))) | Out-Null
    } else {
      $pts.Add(@([math]::Round($c0x, 1), [math]::Round($c0y, 1))) | Out-Null
      $pts.Add(@([math]::Round($c1x, 1), [math]::Round($c1y, 1))) | Out-Null
    }
    $Index[$cid] = @{
      type = "line"; space = [string]$a.space; pts = $pts; closed = $false; scale = 0
      layer = [string]$a.layer; axis = "center"; pairWidth = [math]::Round([double]$p.Dist, 1)
    }
    $clen = [math]::Sqrt(($c1x - $c0x) * ($c1x - $c0x) + ($c1y - $c0y) * ($c1y - $c0y))
    $Inventory.entities.Add(@{
      id = $cid
      type = "line"
      space = [string]$a.space
      layer = [string]$a.layer
      length = [long][math]::Round($clen, 0)
      a = @([long][math]::Round($c0x, 0), [long][math]::Round($c0y, 0))
      b = @([long][math]::Round($c1x, 0), [long][math]::Round($c1y, 0))
      axis = "center"
      width = [long][math]::Round([double]$p.Dist, 0)
    }) | Out-Null
    if ($Index.ContainsKey([string]$a.id)) { $Index[[string]$a.id]["replacedBy"] = $cid }
    if ($Index.ContainsKey([string]$b.id)) { $Index[[string]$b.id]["replacedBy"] = $cid }
    $remove[[string]$a.id] = $true
    $remove[[string]$b.id] = $true
  }
  $kept = New-Object System.Collections.Generic.List[object]
  foreach ($e in $Inventory.entities) {
    $eid = Get-InventoryId $e
    if ($eid -and $remove.ContainsKey($eid)) { continue }
    $kept.Add($e) | Out-Null
  }
  $Inventory["entities"] = $kept
  Write-Host ($tag + "梁定位线：收成 " + $accepted.Count + " 条中心线，去掉 " + $remove.Count + " 条边线")
  return $accepted.Count
}

function Get-PointComponentCount {
  param($Point)
  if ($null -eq $Point) { return 0 }
  if ($Point -is [System.Array]) { return [int]$Point.Length }
  try { return [int]$Point.Count } catch { return 0 }
}

function Get-PointZ {
  param($Point)
  if ((Get-PointComponentCount $Point) -ge 3) { return [double]$Point[2] }
  return 0.0
}

function Parse-ElevationText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $t = $Text.Trim()
  if ($t -match '[φΦ@]') { return $null }
  if ($t -match '(?i)(?:H|HN|HW|HM|I)?\d+\s*[xX×*]\s*\d+') { return $null }
  $role = $null
  $num = $null
  $number = '[\d]+(?:[,，]\d{3})+(?:\.\d+)?|\d+\.\d+|\d+'
  if ($t -match ('(' + $number + ')\s*[\(（]\s*屋脊\s*[\)）]')) {
    $num = $Matches[1]
    $role = 'ridge'
  } elseif ($t -match ('(?:▽|▼|标高|(?i)\bEL\b|(?i)\bH\s*[=＝])\s*(' + $number + ')')) {
    $num = $Matches[1]
    $role = 'level'
  } else {
    return $null
  }
  $raw = $num -replace '[,，]', ''
  $v = 0.0
  $ok = [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
  if (-not $ok) { return $null }
  $z = $v
  if ($raw.Contains('.') -and [math]::Abs($v) -lt 200) { $z = $v * 1000.0 }
  if ($z -lt -10000 -or $z -gt 200000) { return $null }
  return @{ zMm = [math]::Round($z, 1); role = $role }
}

function Get-CadZs {
  param($Pts)
  $n = 0
  if ($null -ne $Pts) { $n = [int]$Pts.Count }
  if ($n -lt 2) { return $null }
  $zs = New-Object 'double[]' $n
  $min = [double]::MaxValue
  $max = [double]::MinValue
  $any = $false
  for ($i = 0; $i -lt $n; $i++) {
    $z = Get-PointZ $Pts[$i]
    $zs[$i] = $z
    if ([math]::Abs($z) -gt 1) { $any = $true }
    if ($z -lt $min) { $min = $z }
    if ($z -gt $max) { $max = $z }
  }
  if ($any -or (($max - $min) -gt 50)) { return ,$zs }
  return $null
}

function Get-EdgeEndZs {
  param($Index, [string]$SourceId, [double]$StartParam, [double]$EndParam, [double]$At0, [double]$At1)
  if (-not $Index.ContainsKey($SourceId)) { return $null }
  $src = Get-CadZs $Index[$SourceId].pts
  if ($null -eq $src) { return $null }
  $span = $EndParam - $StartParam
  if ([math]::Abs($span) -lt 1) { $span = 1 }
  $za = [double]$src[0]
  $zb = [double]$src[$src.Length - 1]
  $t0 = ($At0 - $StartParam) / $span
  $t1 = ($At1 - $StartParam) / $span
  $out = New-Object 'double[]' 2
  $out[0] = $za + ($zb - $za) * $t0
  $out[1] = $za + ($zb - $za) * $t1
  return ,$out
}

function Get-DistPointSeg {
  param([double]$X, [double]$Y, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2)
  $dx = $X2 - $X1
  $dy = $Y2 - $Y1
  $len2 = $dx * $dx + $dy * $dy
  if ($len2 -lt 1) {
    $ex = $X - $X1
    $ey = $Y - $Y1
    return [math]::Sqrt($ex * $ex + $ey * $ey)
  }
  $t = (($X - $X1) * $dx + ($Y - $Y1) * $dy) / $len2
  if ($t -lt 0) { $t = 0 }
  if ($t -gt 1) { $t = 1 }
  $px = $X1 + $t * $dx
  $py = $Y1 + $t * $dy
  $ex = $X - $px
  $ey = $Y - $py
  return [math]::Sqrt($ex * $ex + $ey * $ey)
}

function Test-TextParallel {
  param([double]$Rot, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2)
  $ang = [math]::Atan2(($Y2 - $Y1), ($X2 - $X1))
  $d = $ang - $Rot
  while ($d -gt [math]::PI) { $d = $d - (2 * [math]::PI) }
  while ($d -lt -[math]::PI) { $d = $d + (2 * [math]::PI) }
  $d = [math]::Abs($d)
  if ($d -gt ([math]::PI / 2)) { $d = [math]::PI - $d }
  return ($d -le (15 * [math]::PI / 180))
}

function Get-OpenSegments {
  param($Index)
  $segs = New-Object System.Collections.Generic.List[object]
  foreach ($id in @($Index.Keys)) {
    $local = $Index[$id]
    if ($null -eq $local) { continue }
    $type = [string]$local.type
    if ($type -ne "line" -and $type -ne "polyline" -and $type -ne "mline") { continue }
    $closed = $false
    try { $closed = [bool]$local.closed } catch {}
    if ($closed) { continue }
    $pts = $local.pts
    if ($null -eq $pts -or [int]$pts.Count -lt 2) { continue }
    for ($i = 0; $i -lt ([int]$pts.Count - 1); $i++) {
      $x1 = [double]$pts[$i][0]
      $y1 = [double]$pts[$i][1]
      $x2 = [double]$pts[$i + 1][0]
      $y2 = [double]$pts[$i + 1][1]
      $dx = $x2 - $x1
      $dy = $y2 - $y1
      if (($dx * $dx + $dy * $dy) -lt 40000) { continue }
      $segs.Add([pscustomobject]@{ id = [string]$id; x1 = $x1; y1 = $y1; x2 = $x2; y2 = $y2 }) | Out-Null
    }
  }
  return ,$segs
}

function Get-RidgeLines {
  param($Index)
  $ridges = New-Object System.Collections.Generic.List[object]
  $segs = Get-OpenSegments $Index
  if ($null -eq $segs -or [int]$segs.Count -eq 0) { return ,$ridges }
  $owners = @{}
  foreach ($id in @($Index.Keys)) {
    $local = $Index[$id]
    if ($null -eq $local) { continue }
    if ([string]$local.type -ne "text") { continue }
    if ([string]$local.role -ne "ridge") { continue }
    if ($null -eq $local.zMm) { continue }
    $tx = [double]$local.x
    $ty = [double]$local.y
    $rot = 0.0
    try { $rot = [double]$local.rot } catch {}
    $bestId = $null
    $bestD = 2500.0
    foreach ($seg in $segs) {
      if (-not (Test-TextParallel $rot $seg.x1 $seg.y1 $seg.x2 $seg.y2)) { continue }
      $d = Get-DistPointSeg $tx $ty $seg.x1 $seg.y1 $seg.x2 $seg.y2
      if ($d -lt $bestD) {
        $bestD = $d
        $bestId = [string]$seg.id
      }
    }
    if (-not $bestId) { continue }
    $prev = $owners[$bestId]
    if ($null -eq $prev -or $bestD -lt [double]$prev.d) {
      $owners[$bestId] = [pscustomobject]@{ d = $bestD; z = [double]$local.zMm }
    }
  }
  foreach ($seg in $segs) {
    if (-not $owners.ContainsKey([string]$seg.id)) { continue }
    $own = $owners[[string]$seg.id]
    $ridges.Add([pscustomobject]@{
      id = [string]$seg.id; x1 = $seg.x1; y1 = $seg.y1; x2 = $seg.x2; y2 = $seg.y2; z = [double]$own.z
    }) | Out-Null
  }
  return ,$ridges
}

function Get-RidgeCrossing {
  param(
    [double]$Ax, [double]$Ay, [double]$Bx, [double]$By,
    [double]$Rx1, [double]$Ry1, [double]$Rx2, [double]$Ry2
  )
  $dx = $Bx - $Ax
  $dy = $By - $Ay
  $rx = $Rx2 - $Rx1
  $ry = $Ry2 - $Ry1
  $den = $dx * $ry - $dy * $rx
  $beamLen = [math]::Sqrt($dx * $dx + $dy * $dy)
  $ridgeLen = [math]::Sqrt($rx * $rx + $ry * $ry)
  if ($beamLen -lt 50 -or $ridgeLen -lt 50) { return $null }
  if (([math]::Abs($den) / ($beamLen * $ridgeLen)) -lt 0.087) { return $null }
  $t = (($Rx1 - $Ax) * $ry - ($Ry1 - $Ay) * $rx) / $den
  $u = (($Rx1 - $Ax) * $dy - ($Ry1 - $Ay) * $dx) / $den
  if ($u -lt -0.02 -or $u -gt 1.02) { return $null }
  $over = 0.0
  if ($t -lt 0) { $over = -$t * $beamLen }
  elseif ($t -gt 1) { $over = ($t - 1) * $beamLen }
  if ($over -gt 300) { return $null }
  return [pscustomobject]@{
    t = $t; over = $over; x = ($Ax + $t * $dx); y = ($Ay + $t * $dy)
  }
}

function New-SlopePts {
  param([double]$X1, [double]$Y1, [double]$Z1, [double]$X2, [double]$Y2, [double]$Z2)
  $out = New-Object System.Collections.ArrayList
  $a = New-Object System.Collections.ArrayList
  [void]$a.Add([math]::Round($X1, 1))
  [void]$a.Add([math]::Round($Y1, 1))
  [void]$a.Add([math]::Round($Z1, 1))
  $b = New-Object System.Collections.ArrayList
  [void]$b.Add([math]::Round($X2, 1))
  [void]$b.Add([math]::Round($Y2, 1))
  [void]$b.Add([math]::Round($Z2, 1))
  [void]$out.Add($a)
  [void]$out.Add($b)
  return ,$out
}

function New-BeamPiece {
  param($Beam, $Pts, [bool]$Slope)
  $rise = 0.0
  if (-not $Slope) {
    try { $rise = [double]$Beam.rise } catch {}
  }
  return @{
    pts = $Pts
    w = $Beam.w
    h = $Beam.h
    rise = [math]::Round($rise, 1)
    len = [math]::Round((Get-PointPathLength $Pts), 1)
    steel = $Beam.steel
    slope = $Slope
  }
}

function Get-SegmentRidgePieces {
  param($Beam, [double]$Ax, [double]$Ay, [double]$Bx, [double]$By, $Ridges, [double]$Story)
  $best = $null
  foreach ($ridge in $Ridges) {
    $hit = Get-RidgeCrossing $Ax $Ay $Bx $By $ridge.x1 $ridge.y1 $ridge.x2 $ridge.y2
    if ($null -eq $hit) { continue }
    $dxA = $Ax - $hit.x
    $dyA = $Ay - $hit.y
    $dxB = $Bx - $hit.x
    $dyB = $By - $hit.y
    $dA = $dxA * $dxA + $dyA * $dyA
    $dB = $dxB * $dxB + $dyB * $dyB
    $onSeg = ($hit.t -ge 0 -and $hit.t -le 1 -and $dA -gt 2500 -and $dB -gt 2500)
    $tier = 1
    if ($onSeg) { $tier = 0 }
    $mid = [math]::Abs($hit.t - 0.5)
    $take = $false
    if ($null -eq $best) { $take = $true }
    elseif ($tier -lt $best.tier) { $take = $true }
    elseif ($tier -eq $best.tier -and $hit.over -lt ($best.over - 1)) { $take = $true }
    elseif ($tier -eq $best.tier -and [math]::Abs($hit.over - $best.over) -le 1 -and $mid -lt $best.mid) { $take = $true }
    if ($take) {
      $best = [pscustomobject]@{
        tier = $tier; over = $hit.over; mid = $mid; x = $hit.x; y = $hit.y
        z = [double]$ridge.z; onSeg = $onSeg; dA = $dA; dB = $dB
      }
    }
  }
  if ($null -eq $best) { return $null }
  $list = New-Object System.Collections.Generic.List[object]
  if ($best.onSeg) {
    $list.Add((New-BeamPiece $Beam (New-SlopePts $Ax $Ay $Story $best.x $best.y $best.z) $true)) | Out-Null
    $list.Add((New-BeamPiece $Beam (New-SlopePts $best.x $best.y $best.z $Bx $By $Story) $true)) | Out-Null
  } else {
    $fx = $Bx
    $fy = $By
    if ($best.dA -gt $best.dB) { $fx = $Ax; $fy = $Ay }
    $list.Add((New-BeamPiece $Beam (New-SlopePts $best.x $best.y $best.z $fx $fy $Story) $true)) | Out-Null
  }
  return ,$list
}

function Get-BeamRidgePieces {
  param($Beam, $Ridges, [double]$Story)
  $pts = $null
  if ($Beam -is [System.Collections.IDictionary]) { $pts = $Beam["pts"] }
  if ($null -eq $pts -or [int]$pts.Count -lt 2) { return $null }
  $n = [int]$pts.Count
  if ($n -eq 2) {
    $part = Get-SegmentRidgePieces $Beam ([double]$pts[0][0]) ([double]$pts[0][1]) ([double]$pts[1][0]) ([double]$pts[1][1]) $Ridges $Story
    if ($null -eq $part) { return $null }
    return ,$part
  }
  $all = New-Object System.Collections.Generic.List[object]
  $hit = $false
  for ($i = 0; $i -lt ($n - 1); $i++) {
    $part = Get-SegmentRidgePieces $Beam ([double]$pts[$i][0]) ([double]$pts[$i][1]) ([double]$pts[$i + 1][0]) ([double]$pts[$i + 1][1]) $Ridges $Story
    if ($null -eq $part) {
      $flat = New-SlopePts ([double]$pts[$i][0]) ([double]$pts[$i][1]) 0 ([double]$pts[$i + 1][0]) ([double]$pts[$i + 1][1]) 0
      $all.Add((New-BeamPiece $Beam $flat $false)) | Out-Null
    } else {
      $hit = $true
      foreach ($piece in $part) { $all.Add($piece) | Out-Null }
    }
  }
  if (-not $hit) { return $null }
  return ,$all
}

function Apply-RidgeSlopeBeams {
  param($Beams, $Index, [double]$Story)
  $ridges = Get-RidgeLines $Index
  if ($null -eq $ridges -or [int]$ridges.Count -eq 0) { return 0 }
  $next = New-Object System.Collections.Generic.List[object]
  $slopeCount = 0
  foreach ($beam in $Beams) {
    $pieces = Get-BeamRidgePieces -Beam $beam -Ridges $ridges -Story $Story
    if ($null -eq $pieces) {
      $next.Add($beam) | Out-Null
      continue
    }
    foreach ($piece in $pieces) {
      $next.Add($piece) | Out-Null
      $isSlope = $false
      if ($piece -is [System.Collections.IDictionary] -and $piece.Contains("slope") -and $piece["slope"] -eq $true) { $isSlope = $true }
      if ($isSlope) { $slopeCount = $slopeCount + 1 }
    }
  }
  $Beams.Clear()
  foreach ($item in $next) { [void]$Beams.Add($item) }
  if ($slopeCount -gt 0) {
    $tag = ""
    if (Get-Command Get-BuildTag -ErrorAction SilentlyContinue) { $tag = Get-BuildTag + " " }
    Write-Host ($tag + "斜梁 " + $slopeCount + " 根：交点用屋脊标高，另一端用层高 " + $Story + " mm")
  }
  return $slopeCount
}

function Test-ColumnReaches {
  param($Col, [double]$X, [double]$Y)
  $kind = ""
  $center = $null
  $radius = 0.0
  $pts = $null
  if ($Col -is [System.Collections.IDictionary]) {
    $kind = [string]$Col["kind"]
    $center = $Col["c"]
    try { $radius = [double]$Col["r"] } catch {}
    $pts = $Col["pts"]
  } else {
    $kind = [string]$Col.kind
    $center = $Col.c
    try { $radius = [double]$Col.r } catch {}
    $pts = $Col.pts
  }
  if ($kind -eq "circle" -and $null -ne $center) {
    if ($radius -lt 150) { $radius = 150 }
    $dx = $X - [double]$center[0]
    $dy = $Y - [double]$center[1]
    $lim = $radius + 400
    return (($dx * $dx + $dy * $dy) -le ($lim * $lim))
  }
  if ($null -eq $pts) { return $false }
  $minX = [double]::MaxValue
  $minY = [double]::MaxValue
  $maxX = [double]::MinValue
  $maxY = [double]::MinValue
  $near = $false
  foreach ($p in @($pts)) {
    if ($null -eq $p) { continue }
    $px = [double]$p[0]
    $py = [double]$p[1]
    if ($px -lt $minX) { $minX = $px }
    if ($py -lt $minY) { $minY = $py }
    if ($px -gt $maxX) { $maxX = $px }
    if ($py -gt $maxY) { $maxY = $py }
    $dx = $X - $px
    $dy = $Y - $py
    if (($dx * $dx + $dy * $dy) -le 160000.0) { $near = $true }
  }
  if ($near) { return $true }
  if ($minX -eq [double]::MaxValue) { return $false }
  return ($X -ge ($minX - 400) -and $X -le ($maxX + 400) -and $Y -ge ($minY - 400) -and $Y -le ($maxY + 400))
}

function Set-ColumnTops {
  param($Columns, $Beams, [double]$Story)
  foreach ($col in $Columns) {
    if ($null -eq $col) { continue }
    $top = $Story
    foreach ($beam in $Beams) {
      if ($null -eq $beam) { continue }
      $isSlope = $false
      $bpts = $null
      if ($beam -is [System.Collections.IDictionary]) {
        if ($beam.Contains("slope") -and $beam["slope"] -eq $true) { $isSlope = $true }
        $bpts = $beam["pts"]
      }
      if (-not $isSlope -or $null -eq $bpts) { continue }
      foreach ($p in $bpts) {
        if ($null -eq $p) { continue }
        if ((Get-PointComponentCount $p) -lt 3) { continue }
        $z = [double]$p[2]
        if ($z -le ($top + 1)) { continue }
        if (Test-ColumnReaches $col ([double]$p[0]) ([double]$p[1])) { $top = $z }
      }
    }
    if ($col -is [System.Collections.IDictionary]) { $col["top"] = [math]::Round($top, 1) }
  }
}

function Get-StructureRuleText {
  @'
默认结构规则（先判断整张图是否符合这些预定规则。图层名不区分大小写。符合时按规则归类。整张图的图层、图块和标注都对不上这些规则时，不要套用图层名，改为按结构设计是否合理自行判断）：

分析顺序（必须按这个顺序想，再写 JSON）：
1. 先看图层名、图块名，整张图是否整体符合下面的梁、柱、墙、楼板图层规则。
2. 再挑全部梁中心定位线，这一步与屋脊线无关。梁定位线以图元清单为准，不要自己算中点、不要改坐标。
3. 再挑柱、墙、楼板。不要输出 slopeBeams。
4. 最后写 summary：规则适用时写命中了哪些规则；不适用时写按结构关系做了什么判断。

梁图层：
- 图层名：s数字-beam、s数字-beam-hddn；图层名里含 gl 或 GL（不区分大小写，例如 s1-beam-gl、GL-1）的线状图元也算梁，而且是钢梁。图元类型是 mline、line 或 polyline。
- 梁尺寸文字图层：以 dsptext_beam 结尾、以 dsptext_wallbeam 结尾、G-ANNO-NPLT、尺寸标注数字-梁。梁高取定位线附近 2500 mm 内的尺寸文字，格式为 N x N、N*N 或 N×N；对不上时梁高用 500。

梁定位线（这是最容易错的地方，必须严格遵守）：
- 程序已经把可以配对的双边线收成中心线。你只负责选 id，建模时用该图元自己的坐标，不会再挪位置。
- 图元带 "axis":"center" 时：这是已经算好的梁中心线，width 字段是梁宽。一根梁只选这一个 id，不要再选被它替换掉的边线。
- 图元没有 axis 时：这条 line、开口 polyline 或 mline 本身就是定位线。按它的 a/b 或 pts 原样当作梁轴，不要改到别的位置。
- 两根平行线的间距小于 190 mm：一定是两根不同的梁（错台、并排梁、墙垛旁的短梁很常见）。必须各选各的 id，各建一根梁；禁止合并成一根，禁止取两线中点当定位线，禁止只选其中一根代表两根。
- 间距大于等于 190 mm 且清单里已经出现 axis 为 center 的图元时：只选那些中心线 id。
- 错台、墙垛、悬挑附近几根靠得很近的平行线，即使方向相同、投影重叠，只要间距小于 190 mm，就按多根梁处理。
- 一根梁在 beams 里只输出一个 id。不要为同一根梁输出两个边线 id。不要输出 slopeBeams。

梁截面：
- width 是梁宽，depth 是梁高，单位毫米。附近文字是两个数字时，200x500 表示宽 x 高；是四个数字的型钢规格时，400x200x8x13 表示高 400、宽 200，也就是 depth 取第 1 个数字、width 取第 2 个数字。( +0.020 ) 表示 rise 为 20。
- 没有标注时：axis 为 center 的用它自带的 width；mline 可用 scale 作 width；其它线 width 用 200，depth 用 500。
- 钢梁要在 beams 项里加 "steel":true。图层名含 gl 或 GL 的梁一定是钢梁；梁中线附近有四个数字型钢规格文字的梁也是钢梁。其它梁加 "steel":false。
- 钢梁尺寸文字：由四个数字组成，例如 400x200x8x13、HN400*200*8*13、400×200×8×13。它是截面尺寸，不要当成标注、轴号。第 1 个数字是 depth，第 2 个是 width。这种文字出现在哪条梁定位线附近，那条梁就是钢梁。

柱图层：a数字-cols 或 s数字-cols，数字可以没有，例如 S-COLS。闭合 polyline 面积在 10000 到 10000000 之间，以及圆。不要把轴号小圆当成柱。
墙图层：a数字-wall 或 s数字-wall。平行双线间距 80 到 1000 mm、重叠不少于 50 mm。墙厚通常小于 450，长度通常大于 1500。不要把整层外轮廓或轴线当成墙。
楼板图层：a数字-slab-otln、s数字-slab-otln、a数字-flor-otln、s数字-flor-otln 的闭合 polyline，面积不小于 1000000。板厚文字图层 s数字-slab-text，板厚取 40 到 800。没有板轮廓时，slabRect 用所选梁柱墙的包围盒。
id 必须来自输入，禁止编造 id 或坐标。
梁、柱、墙必须在同一坐标空间。图块定义是局部坐标，模型空间可能是另一套大坐标。若梁图块和柱墙图块的范围接近，就只选这些图块里的 id，不要再选模型空间里平移后的副本。
storyMm 和 slabThickMm 采用用户给出的默认值，除非文字明确只给出一个标准层高或板厚。
不要选择尺寸线、轴号、填充边界、图框和标题栏。

坡屋顶斜梁（你只选梁中心线 id，分段和标高由程序计算）：
- 第一步与屋脊线无关：把所有梁中心定位线放进 beams。带 axis:center 的选这个中心线 id；没有 axis 的线按自身坐标。间距小于 190 mm 的平行线各选各的 id。
- 只认带「屋脊」的文字，例如 15.850(屋脊)。15.850 按米是 15850 mm，是绝对标高，不要加到层高上。这种文字和它旁边的屋脊线都不是梁，不要选成梁、柱或截面。
- 屋脊线是该文字 2500 mm 内、与文字方向平行、距离最近的那条线。程序会用这条线处理第二步，你不要改梁的定位线。
- 第二步由程序做：梁中心线与屋脊线相交时，在交点分成两段。交点高度用屋脊标高，另一端高度用用户给出的层高。
- 若梁中心线与屋脊线不相交，程序把中心线两侧向外各延长不超过 300 mm。延长后有交点时，新定位线是交点到较远的那个原端点。交点用屋脊标高，另一端用层高。
- 这些梁在 JSON 里仍然只输出原来的那一个中心线 id，放进 beams。不要拆成两个 id，不要输出 slopeBeams，不要输出高度或 verts。

整张图完全不符合上面的预定规则时，必须自行判断，并思考这套结构是否合理：
- 先看图层名、图块名和文字是否整体对得上梁、柱、墙、楼板规则。只有少量图元对不上时，仍按规则处理能对上的部分，再用几何补全其余构件。
- 如果整张图都不是这套图层体系，就不要因为图层名不像 s-beam、s-cols、s-wall 而放弃。根据构件关系判断：柱是较小的支撑，通常落在梁的交点或端部；梁是连接柱或墙的线状构件，跨度和截面要像能承受楼盖的梁，定位线用该图元自己的坐标；间距小于 190 mm 的平行线仍按多根梁各选各的 id；会和 15.850(屋脊) 所标屋脊线相交的梁中心线仍放进 beams，不要输出 slopeBeams；墙是细长的竖向构件，不要把轴线、尺寸线或整层外框当成墙；楼板覆盖由这些梁、柱、墙围成的平面。
- 截面优先用附近尺寸文字。没有文字时，选择在常见结构范围里说得通的宽度和高度，不要把明显是标注、轴号、填充或图框的图元选进来。
- summary 要写明依据。规则适用时说明命中了哪些规则；规则不适用时说明图纸不符合预定规则，以及按结构关系做了什么判断。
'@
}

function New-DeepSeekBody {
  param([string]$InventoryJson, [double]$Story, [double]$SlabThick, [bool]$Think)
  $rules = Get-StructureRuleText
  $system = @"
你是结构施工图解析器。每次请求都会同时给你两份材料：中望 CAD 读出的全部图元清单，以及下面这套默认结构规则。

你的职责只有挑选图元 id 和截面，不要改坐标、不要把两根线收成中点。定位线以清单里的图元为准：
- 带 "axis":"center" 的是程序已算好的梁中心线，一根梁只选这一个 id。
- 没有 axis 的线本身就是定位线。
- 两根平行线间距小于 190 mm 时，一定是两根不同的梁，必须各选各的 id，禁止合并或取中线。

图纸符合规则时按规则归类。图纸整体不符合预定规则时，不要硬套图层名，要自行判断哪些图元是梁、柱、墙、楼板，并思考这样的结构布置是否合理。id 仍然只能来自清单。
看到 15.850(屋脊) 时：它旁边最近的平行线是屋脊线，不是梁。第一步先把全部梁中心线放进 beams，与屋脊无关。第二步的相交、分成两段、两侧延长 300 mm 和两端标高都由程序计算。不要输出 slopeBeams，不要编造标高。
只输出一个 JSON 对象，不要 Markdown，不要解释。格式：
{"summary":"一两句中文，说明依据","storyMm":3000,"slabThickMm":130,"beams":[{"id":"m1","width":200,"depth":500,"rise":0,"steel":false}],"columns":[{"id":"p1"}],"walls":[{"id":"p2"}],"slabRect":[0,0,1000,1000]}
$rules
"@
  $user = @"
请按下面步骤分析，并只输出一个 JSON：
1. 判断整张图是否符合预定图层规则。
2. 挑选全部梁中心定位线，这一步与屋脊线无关：优先选 axis 为 center 的图元；没有 axis 的线按它自己的坐标作为定位线；间距小于 190 mm 的平行线各选各的 id，不要合并。
3. 再挑选柱、墙、楼板。15.850(屋脊) 旁边最近的平行线是屋脊线，不要选成梁。会和屋脊线相交、或两侧向外延长不超过 300 mm 后相交的梁，仍只把原来的中心线 id 放进 beams。不要输出高度，不要输出 slopeBeams。
4. summary 用一两句中文说明依据。

用户指定的默认层高是 $Story mm，默认板厚是 $SlabThick mm。程序用这个层高作为斜梁不在屋脊交点那一端的高度，交点用 15.850(屋脊) 的标高。你不要在 JSON 里写这些高度。

$rules

图元 JSON：
$InventoryJson
"@
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
  foreach ($item in (Get-PlanList (Get-PlanProp $Plan @("slopeBeams", "slope_beams")))) {
    $id = [string](Get-PlanProp $item @("id"))
    if ($id -and -not $beamWant.ContainsKey($id)) { $beamWant[$id] = $item }
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

  $levelMm = Convert-ToDouble (Get-PlanProp $Plan @("storyMm", "story")) $Story
  if ($levelMm -lt 500 -or $levelMm -gt 20000) { $levelMm = $Story }
  $beams = New-Object System.Collections.Generic.List[object]
  $columns = New-Object System.Collections.Generic.List[object]
  $walls = New-Object System.Collections.Generic.List[object]
  $slopeCount = 0
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
      try {
        if ($beams.Count -ge 500) { continue }
        if ($local.replacedBy) {
          $resolvedId = [string]$local.replacedBy
          if ($used.ContainsKey($resolvedId)) { continue }
          if (-not $Index.ContainsKey($resolvedId)) { continue }
          $used[$resolvedId] = $true
          $local = $Index[$resolvedId]
        }
        if ($local.type -eq "circle") { continue }
        if ($local.type -eq "polyline" -and $local.closed) { continue }
        $pts = Copy-PointList $local.pts
        if ($null -eq $pts -or $pts.Count -lt 2) { continue }
        $width = Convert-ToDouble (Get-PlanProp $sel.Raw @("width", "w")) 0
        if ($width -le 0 -and $local.scale) { $width = [math]::Abs([double]$local.scale) }
        if (($width -lt 80 -or $width -gt 1500) -and $null -ne $local.pairWidth) { $width = [double]$local.pairWidth }
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
        $beams.Add(@{ pts = $pts; w = [math]::Round($width, 1); h = [math]::Round($depth, 1); rise = [math]::Round($rise, 1); len = $len; steel = $steel; slope = $false }) | Out-Null
        for ($pi = 0; $pi -lt $pts.Count; $pi++) {
          $p = $pts[$pi]
          if ([double]$p[0] -lt $minX) { $minX = [double]$p[0] }
          if ([double]$p[1] -lt $minY) { $minY = [double]$p[1] }
          if ([double]$p[0] -gt $maxX) { $maxX = [double]$p[0] }
          if ([double]$p[1] -gt $maxY) { $maxY = [double]$p[1] }
        }
      } catch {
        Write-Host ((Get-BuildTag) + " beam processing error for id=" + $id + ": " + $_.Exception.Message)
        Write-Host ((Get-BuildTag) + " stack: " + $_.ScriptStackTrace)
        continue
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

  $slopeCount = Apply-RidgeSlopeBeams -Beams $beams -Index $Index -Story $levelMm
  foreach ($beam in $beams) {
    $bpts = $null
    if ($beam -is [System.Collections.IDictionary]) { $bpts = $beam["pts"] }
    if ($null -eq $bpts) { continue }
    foreach ($p in $bpts) {
      if ($null -eq $p) { continue }
      if ([double]$p[0] -lt $minX) { $minX = [double]$p[0] }
      if ([double]$p[1] -lt $minY) { $minY = [double]$p[1] }
      if ([double]$p[0] -gt $maxX) { $maxX = [double]$p[0] }
      if ([double]$p[1] -gt $maxY) { $maxY = [double]$p[1] }
    }
  }
  Set-ColumnTops -Columns $columns -Beams $beams -Story $levelMm
  if ($slopeCount -gt 0) {
    if ($summary) { $summary += " " }
    $summary += "斜梁 $slopeCount 根。梁中心线与屋脊线相交时在交点分成两段；否则两侧向外延长不超过 300 mm，新定位线是交点到较远端点。交点用屋脊标高，另一端用层高 $levelMm mm。"
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

  $storyOut = $levelMm
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
      slope = $slopeCount
    }
    summary = $summary
    model = "deepseek-flash"
    thinking = $Thinking
    usage = $Usage
  }
}

function Invoke-DeepSeekStructure {
  param($Inventory, $Index, $SpaceBoxes, [string]$ApiKey, [double]$Story, [double]$SlabThick, [scriptblock]$OnProgress)
  Merge-BeamEdgePairs -Inventory $Inventory -Index $Index | Out-Null
  $entityCount = 0
  $layerCount = 0
  # 这里不能用 @() 包一层取 Count：PS 5.1 对 List[object] 这样取会抛
  # "Argument types do not match"，异常被吞掉后图元数就显示成 0。
  # List 和数组都有 .Count，直接取。
  try { $entityCount = [int]$Inventory.entities.Count } catch {}
  try { $layerCount = [int]$Inventory.layers.Count } catch {}
  if ($OnProgress) {
    & $OnProgress "打包图元" "已从 CAD 读出 $entityCount 个图元、$layerCount 个图层。间距小于 190 mm 的平行梁线已保持原位；可配对的双边线已收成中心线。正在把图元清单和默认梁柱墙板规则打包成同一次分析请求。"
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
    $detail = "已提交 $entityCount 个图元、$layerCount 个图层和默认结构规则，约 $wan 万字。模型只选梁中心线 id 和截面，不改定位线，也不输出斜梁高度。有 15.850(屋脊) 时，相交分段和两侧延长 300 mm 由程序计算。这一步通常要几分钟。"
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
  if ($OnProgress) { & $OnProgress "整理结果" "DeepSeek 已返回。正在按图元编号还原梁、柱、墙和楼板。若有屋脊线，梁中心线与它相交时在交点分成两段；否则两侧向外延长不超过 300 mm。" }
  return Convert-StructurePlan -Plan $plan -Index $Index -SpaceBoxes $SpaceBoxes -Story $Story -SlabThick $SlabThick -Usage $usage -Thinking $thinking
}
