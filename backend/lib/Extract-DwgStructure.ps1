# Read a structural DWG through the running ZWCAD, then let deepseek-flash choose beams, columns, walls and the slab.

. (Join-Path $PSScriptRoot "Invoke-DeepSeekParse.ps1")
. (Join-Path $PSScriptRoot "Close-ZwcadDialogs.ps1")

function Get-ZwcadApp {
  try {
    return [System.Runtime.InteropServices.Marshal]::GetActiveObject("ZWCAD.Application")
  } catch {
    throw "没有连上中望 CAD。请先打开 ZWCAD。"
  }
}

function Convert-PolyPoints {
  param($Entity)
  $coords = @($Entity.Coordinates)
  $step = 2
  if ($coords.Length -ge 3 -and ($coords.Length % 3) -eq 0 -and ($coords.Length % 2) -ne 0) { $step = 3 }
  $pts = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i + 1 -lt $coords.Length; $i += $step) {
    $pts.Add(@([double]$coords[$i], [double]$coords[$i + 1]))
  }
  if ($pts.Count -ge 2) {
    $a = $pts[0]
    $b = $pts[$pts.Count - 1]
    $dx = [double]$a[0] - [double]$b[0]
    $dy = [double]$a[1] - [double]$b[1]
    if (($dx * $dx + $dy * $dy) -lt 1) { $pts.RemoveAt($pts.Count - 1) }
  }
  return $pts
}

function Get-CadPoint {
  param($Point)
  if ($null -eq $Point) { return $null }
  if ($Point -is [System.Array]) {
    if ($Point.Length -ge 2) { return @([double]$Point[0], [double]$Point[1]) }
    return $null
  }
  try {
    $x = $Point.X
    $y = $Point.Y
    if ($null -ne $x -and $null -ne $y) { return @([double]$x, [double]$y) }
  } catch {}
  return $null
}

function Convert-MlinePoints {
  param($Entity)
  $coords = @($Entity.Coordinates)
  $pts = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i + 1 -lt $coords.Length; $i += 3) {
    $pts.Add(@([double]$coords[$i], [double]$coords[$i + 1]))
  }
  return $pts
}

function Get-PathLength {
  param($Pts, [bool]$Closed)
  $n = 0
  if ($null -ne $Pts) { $n = [int]$Pts.Count }
  if ($n -lt 2) { return 0 }
  $len = 0.0
  $steps = $n - 1
  if ($Closed) { $steps = $n }
  for ($i = 0; $i -lt $steps; $i++) {
    $j = ($i + 1) % $n
    $dx = [double]$Pts[$j][0] - [double]$Pts[$i][0]
    $dy = [double]$Pts[$j][1] - [double]$Pts[$i][1]
    $len += [math]::Sqrt($dx * $dx + $dy * $dy)
  }
  return $len
}

function Get-PointBounds {
  param($Pts)
  $minX = [double]::MaxValue
  $minY = [double]::MaxValue
  $maxX = [double]::MinValue
  $maxY = [double]::MinValue
  $n = 0
  if ($null -ne $Pts) { $n = [int]$Pts.Count }
  for ($i = 0; $i -lt $n; $i++) {
    $p = $Pts[$i]
    $x = [double]$p[0]
    $y = [double]$p[1]
    if ($x -lt $minX) { $minX = $x }
    if ($y -lt $minY) { $minY = $y }
    if ($x -gt $maxX) { $maxX = $x }
    if ($y -gt $maxY) { $maxY = $y }
  }
  return @($minX, $minY, $maxX, $maxY)
}

function Expand-Bounds {
  param($Bounds, [double]$X0, [double]$Y0, [double]$X1, [double]$Y1)
  if ($X0 -lt $Bounds[0]) { $Bounds[0] = $X0 }
  if ($Y0 -lt $Bounds[1]) { $Bounds[1] = $Y0 }
  if ($X1 -gt $Bounds[2]) { $Bounds[2] = $X1 }
  if ($Y1 -gt $Bounds[3]) { $Bounds[3] = $Y1 }
}

function ConvertTo-InventoryNum {
  param([double]$Value)
  if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return [long]0 }
  $rounded = [math]::Round($Value, 0)
  if ($rounded -gt [long]::MaxValue) { return [long]::MaxValue }
  if ($rounded -lt [long]::MinValue) { return [long]::MinValue }
  return [long]$rounded
}

function Get-TextRank {
  param([string]$Text)
  if ($Text -match '(?:H|HN|HW|HM|I)?\d+\s*[xX×*]\s*\d+(\s*[xX×*]\s*\d+)*') { return 0 }
  if ($Text -match '梁|柱|墙|板|层高|标高|KL|LL|剪力墙|板厚') { return 1 }
  return 2
}

function Add-CadPublic {
  param($Bag, [string]$Prefix, $Public, $Local)
  $Bag.Seq = [int]$Bag.Seq + 1
  $id = "{0}{1}" -f $Prefix, $Bag.Seq
  $Public["id"] = $id
  $Bag.Entities.Add($Public) | Out-Null
  if ($null -ne $Local) { $Bag.Index[$id] = $Local }
  return $id
}

function Read-CadContainer {
  param($Space, [string]$SpaceName, $Bag)
  $mlines = New-Object System.Collections.Generic.List[object]
  $closed = New-Object System.Collections.Generic.List[object]
  $opens = New-Object System.Collections.Generic.List[object]
  $lines = New-Object System.Collections.Generic.List[object]
  $circles = New-Object System.Collections.Generic.List[object]
  $texts = New-Object System.Collections.Generic.List[object]
  $inserts = New-Object System.Collections.Generic.List[object]
  $seen = @{ mline = 0; polyline = 0; line = 0; circle = 0; text = 0; insert = 0 }

  foreach ($e in @($Space)) {
    try {
      $kind = [string]$e.ObjectName
      $layer = ""
      try { $layer = ([string]$e.Layer).Trim() } catch {}
      if ($layer.Length -gt 40) { $layer = $layer.Substring(0, 40) }
      if ($layer) { [void]$Bag.Layers.Add($layer) }

      if ($kind -eq "AcDbMline") {
        $pts = Convert-MlinePoints $e
        if ($pts.Count -lt 2) { continue }
        $len = Get-PathLength $pts $false
        if ($len -lt 1) { continue }
        $scale = 0.0
        try { $scale = [double]$e.MLineScale } catch {}
        $seen.mline++
        $mlines.Add(@{ pts = $pts; len = $len; scale = $scale; layer = $layer }) | Out-Null
      } elseif ($kind -eq "AcDbPolyline") {
        $pts = Convert-PolyPoints $e
        if ($pts.Count -lt 2) { continue }
        $isClosed = $false
        try { $isClosed = [bool]$e.Closed } catch {}
        $len = Get-PathLength $pts $isClosed
        if ($isClosed -and $pts.Count -ge 3) {
          $area = 0.0
          try { $area = [math]::Abs([double]$e.Area) } catch {}
          if ($area -lt 1 -or $len -lt 1) { continue }
          $seen.polyline++
          $thick = 2.0 * $area / $len
          $closed.Add(@{ pts = $pts; len = $len; area = $area; thick = $thick; layer = $layer }) | Out-Null
        } elseif ($len -ge 1) {
          $seen.polyline++
          $opens.Add(@{ pts = $pts; len = $len; layer = $layer }) | Out-Null
        }
      } elseif ($kind -eq "AcDbLine") {
        $p1 = Get-CadPoint $e.StartPoint
        $p2 = Get-CadPoint $e.EndPoint
        if (-not $p1 -or -not $p2) { continue }
        $dx = $p2[0] - $p1[0]
        $dy = $p2[1] - $p1[1]
        $len = [math]::Sqrt($dx * $dx + $dy * $dy)
        if ($len -lt 1) { continue }
        $seen.line++
        $lines.Add(@{ a = $p1; b = $p2; len = $len; layer = $layer }) | Out-Null
      } elseif ($kind -eq "AcDbCircle") {
        $c = Get-CadPoint $e.Center
        $r = [double]$e.Radius
        if (-not $c -or $r -lt 1 -or $r -gt 100000) { continue }
        $seen.circle++
        $circles.Add(@{ x = [double]$c[0]; y = [double]$c[1]; r = $r; layer = $layer }) | Out-Null
      } elseif ($kind -eq "AcDbText" -or $kind -eq "AcDbMText") {
        $text = ""
        try { $text = [string]$e.TextString } catch {}
        if (-not $text) { try { $text = [string]$e.Contents } catch {} }
        if (-not $text) { continue }
        $text = $text -replace '\\[A-Za-z][^;]*;', ''
        $text = ($text -replace '[{}]', '').Trim()
        if (-not $text) { continue }
        if ($text.Length -gt 80) { $text = $text.Substring(0, 80) }
        $ip = $null
        try { $ip = Get-CadPoint $e.InsertionPoint } catch {}
        if (-not $ip) { try { $ip = Get-CadPoint $e.Location } catch {} }
        if (-not $ip) { continue }
        $rot = 0.0
        try { $rot = [double]$e.Rotation } catch {}
        $seen.text++
        $texts.Add([pscustomobject]@{
          rank = (Get-TextRank $text)
          text = $text
          x = [double]$ip[0]
          y = [double]$ip[1]
          rot = $rot
          layer = $layer
        }) | Out-Null
      } elseif ($kind -eq "AcDbBlockReference") {
        $name = ""
        try { $name = ([string]$e.Name).Trim() } catch {}
        if (-not $name -or $name.StartsWith("*")) { continue }
        $ip = Get-CadPoint $e.InsertionPoint
        if (-not $ip) { continue }
        $seen.insert++
        $inserts.Add(@{ name = $name; x = [double]$ip[0]; y = [double]$ip[1]; layer = $layer }) | Out-Null
      }
    } catch {}
  }

  $keepM = $mlines.ToArray()
  $keepC = $closed.ToArray()
  $keepO = $opens.ToArray()
  $keepL = $lines.ToArray()
  $keepR = $circles.ToArray()
  $keepT = $texts.ToArray()
  $keepI = $inserts.ToArray()

  $bounds = @([double]::MaxValue, [double]::MaxValue, [double]::MinValue, [double]::MinValue)
  $kept = @{ mline = 0; polyline = 0; line = 0; circle = 0; text = 0; insert = 0 }

  foreach ($item in @($keepM)) {
    if ($null -eq $item) { continue }
    $box = Get-PointBounds $item.pts
    Expand-Bounds $bounds $box[0] $box[1] $box[2] $box[3]
    $pub = @{
      type = "mline"
      space = $SpaceName
      layer = $item.layer
      scale = (ConvertTo-InventoryNum ([math]::Abs([double]$item.scale)))
      length = (ConvertTo-InventoryNum ([double]$item.len))
    }
    if ($item.pts.Count -le 8) {
      $pub["pts"] = Copy-PointList $item.pts
    } else {
      $pub["bbox"] = @((ConvertTo-InventoryNum $box[0]), (ConvertTo-InventoryNum $box[1]), (ConvertTo-InventoryNum $box[2]), (ConvertTo-InventoryNum $box[3]))
    }
    Add-CadPublic $Bag "m" $pub @{
      type = "mline"; space = $SpaceName; pts = $item.pts; scale = $item.scale; closed = $false; layer = $item.layer
    } | Out-Null
    $kept.mline++
  }
  foreach ($item in @($keepC)) {
    if ($null -eq $item) { continue }
    $box = Get-PointBounds $item.pts
    Expand-Bounds $bounds $box[0] $box[1] $box[2] $box[3]
    Add-CadPublic $Bag "p" @{
      type = "polyline"; space = $SpaceName; layer = $item.layer; closed = $true
      area = (ConvertTo-InventoryNum ([double]$item.area))
      thick = (ConvertTo-InventoryNum ([double]$item.thick))
      length = (ConvertTo-InventoryNum ([double]$item.len))
      n = $item.pts.Count
      bbox = @((ConvertTo-InventoryNum $box[0]), (ConvertTo-InventoryNum $box[1]), (ConvertTo-InventoryNum $box[2]), (ConvertTo-InventoryNum $box[3]))
    } @{
      type = "polyline"; space = $SpaceName; pts = $item.pts; closed = $true
      area = $item.area; thick = $item.thick; length = $item.len; layer = $item.layer
    } | Out-Null
    $kept.polyline++
  }
  foreach ($item in @($keepO)) {
    if ($null -eq $item) { continue }
    $box = Get-PointBounds $item.pts
    Expand-Bounds $bounds $box[0] $box[1] $box[2] $box[3]
    $pub = @{
      type = "polyline"; space = $SpaceName; layer = $item.layer; closed = $false
      length = (ConvertTo-InventoryNum ([double]$item.len)); n = $item.pts.Count
    }
    if ($item.pts.Count -le 6) { $pub["pts"] = Copy-PointList $item.pts }
    else { $pub["bbox"] = @((ConvertTo-InventoryNum $box[0]), (ConvertTo-InventoryNum $box[1]), (ConvertTo-InventoryNum $box[2]), (ConvertTo-InventoryNum $box[3])) }
    Add-CadPublic $Bag "p" $pub @{
      type = "polyline"; space = $SpaceName; pts = $item.pts; closed = $false; scale = 0; layer = $item.layer
    } | Out-Null
    $kept.polyline++
  }
  foreach ($item in @($keepL)) {
    if ($null -eq $item) { continue }
    Expand-Bounds $bounds $item.a[0] $item.a[1] $item.b[0] $item.b[1]
    $pts = New-Object System.Collections.Generic.List[object]
    $pts.Add($item.a) | Out-Null
    $pts.Add($item.b) | Out-Null
    Add-CadPublic $Bag "l" @{
      type = "line"; space = $SpaceName; layer = $item.layer
      length = (ConvertTo-InventoryNum ([double]$item.len))
      a = @((ConvertTo-InventoryNum $item.a[0]), (ConvertTo-InventoryNum $item.a[1]))
      b = @((ConvertTo-InventoryNum $item.b[0]), (ConvertTo-InventoryNum $item.b[1]))
    } @{
      type = "line"; space = $SpaceName; pts = $pts; closed = $false; scale = 0; layer = $item.layer
    } | Out-Null
    $kept.line++
  }
  foreach ($item in @($keepR)) {
    if ($null -eq $item) { continue }
    Expand-Bounds $bounds ($item.x - $item.r) ($item.y - $item.r) ($item.x + $item.r) ($item.y + $item.r)
    Add-CadPublic $Bag "c" @{
      type = "circle"; space = $SpaceName; layer = $item.layer
      r = (ConvertTo-InventoryNum ([double]$item.r))
      c = @((ConvertTo-InventoryNum $item.x), (ConvertTo-InventoryNum $item.y))
    } @{
      type = "circle"; space = $SpaceName; cx = $item.x; cy = $item.y; r = $item.r
    } | Out-Null
    $kept.circle++
  }
  foreach ($item in @($keepT)) {
    if ($null -eq $item) { continue }
    Expand-Bounds $bounds $item.x $item.y $item.x $item.y
    Add-CadPublic $Bag "t" @{
      type = "text"; space = $SpaceName; layer = $item.layer
      text = $item.text
      x = (ConvertTo-InventoryNum $item.x)
      y = (ConvertTo-InventoryNum $item.y)
      rot = [math]::Round([double]$item.rot, 4)
    } $null | Out-Null
    $kept.text++
  }
  foreach ($item in @($keepI)) {
    if ($null -eq $item) { continue }
    Expand-Bounds $bounds $item.x $item.y $item.x $item.y
    $label = [string]$item.name
    if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
    Add-CadPublic $Bag "r" @{
      type = "insert"; space = $SpaceName; layer = $item.layer; name = $label
      x = (ConvertTo-InventoryNum $item.x); y = (ConvertTo-InventoryNum $item.y)
    } $null | Out-Null
    $kept.insert++
  }

  $totalKept = $kept.mline + $kept.polyline + $kept.line + $kept.circle + $kept.text + $kept.insert
  if ($totalKept -eq 0 -or $bounds[0] -eq [double]::MaxValue) { return }
  $truncated = ($seen.mline -gt $kept.mline) -or ($seen.polyline -gt $kept.polyline) -or ($seen.line -gt $kept.line) -or ($seen.circle -gt $kept.circle) -or ($seen.text -gt $kept.text) -or ($seen.insert -gt $kept.insert)
  $Bag.Spaces.Add(@{
    name = $SpaceName
    bbox = @((ConvertTo-InventoryNum $bounds[0]), (ConvertTo-InventoryNum $bounds[1]), (ConvertTo-InventoryNum $bounds[2]), (ConvertTo-InventoryNum $bounds[3]))
    seen = $seen
    kept = $kept
    truncated = [bool]$truncated
  }) | Out-Null
}

function Export-DwgInventory {
  param($Doc, [double]$Story, [double]$SlabThick)
  $bag = @{
    Entities = (New-Object System.Collections.Generic.List[object])
    Index = @{}
    Spaces = (New-Object System.Collections.Generic.List[object])
    Layers = (New-Object 'System.Collections.Generic.HashSet[string]')
    Seq = 0
  }
  Read-CadContainer -Space $Doc.ModelSpace -SpaceName "Model" -Bag $bag
  foreach ($block in @($Doc.Blocks)) {
    $name = ""
    try {
      if ($block.IsLayout) { continue }
      $name = ([string]$block.Name).Trim()
    } catch { continue }
    if (-not $name -or $name.StartsWith("*")) { continue }
    Read-CadContainer -Space $block -SpaceName $name -Bag $bag
  }
  $layers = @()
  if ($bag.Layers.Count -gt 0) { $layers = @($bag.Layers) }
  $inventory = @{
    unit = "mm"
    storyDefault = [int]$Story
    slabDefault = [int]$SlabThick
    layers = $layers
    spaces = $bag.Spaces
    entities = $bag.Entities
  }
  $boxes = @{}
  foreach ($space in $bag.Spaces) { $boxes[[string]$space.name] = $space.bbox }
  Write-Host ("inventory spaces " + $bag.Spaces.Count + " entities " + $bag.Entities.Count)
  return @{ Inventory = $inventory; Index = $bag.Index; SpaceBoxes = $boxes }
}

function Extract-DwgStructure {
  param(
    [Parameter(Mandatory = $true)][string]$DwgPath,
    [double]$Story = 3000,
    [double]$SlabThick = 130,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [scriptblock]$OnProgress
  )
  if (-not (Test-Path -LiteralPath $DwgPath)) { throw "找不到图纸：$DwgPath" }
  $ApiKey = $ApiKey.Trim()
  if (-not $ApiKey) { throw "没有 DeepSeek API Key。请在 dwg-to-sketchup\backend\.env 中设置 DEEPSEEK_API_KEY。" }
  $readDetail = "正在用中望 CAD 打开这张 DWG，读出直线、多线、多段线、圆、文字、图块和全部图层。"
  if ($OnProgress) { & $OnProgress "读取图纸" $readDetail }
  if (Get-Command Start-ProgressHeartbeat -ErrorAction SilentlyContinue) {
    Start-ProgressHeartbeat -Step "读取图纸" -Detail $readDetail
  }
  $app = Get-ZwcadApp
  $beforeDialogs = [ZwcadDialogGuard]::ClosedCount
  [ZwcadDialogGuard]::Start()
  $opened = $null
  $bundle = $null
  try {
    $opened = Open-DwgDocument -App $app -Path $DwgPath
    $bundle = Export-DwgInventory -Doc $opened.Doc -Story $Story -SlabThick $SlabThick
  } finally {
    Start-Sleep -Milliseconds 300
    [ZwcadDialogGuard]::StopGuard()
    $closedDialogs = [ZwcadDialogGuard]::ClosedCount - $beforeDialogs
    if ($closedDialogs -gt 0) { Write-Host ("已关闭 CAD 弹窗 " + $closedDialogs + " 次") }
    if ($opened -and $opened.Opened) {
      try { $opened.Doc.Close($false) } catch {}
    }
  }
  if (-not $bundle -or $bundle.Inventory.entities.Count -eq 0) { throw "图纸里没有可读的直线、多线、多段线或文字。" }
  return Invoke-DeepSeekStructure -Inventory $bundle.Inventory -Index $bundle.Index -SpaceBoxes $bundle.SpaceBoxes -ApiKey $ApiKey -Story $Story -SlabThick $SlabThick -OnProgress $OnProgress
}
