# 转换核心.ps1 - 批量图片 / PDF 转换引擎（本机服务调用）
#
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File 转换核心.ps1 -Job <任务.json> -Result <结果.json>
#       powershell -NoProfile -ExecutionPolicy Bypass -File 转换核心.ps1 -Probe -Result <结果.json>
#
# 任务 JSON: { "任务": [ { "类型":"图片"|"PDF", "输入":路径, "输出":路径, ... } ] }
#   图片: "输出格式" jpg|png|gif|bmp|tif, "质量" 1-100, "宽" 0=按比例, "高" 0=按比例, "帧" "全部"|数字(1起)
#   PDF : "页码" [1,2,..] 空=全部, "目标宽" 像素 0=自动取嵌入图原生宽, "DPI" 0=不用, "输出格式" jpg|png, "质量"
# 结果 JSON: { "结果":[ {"ok":true,"输出":[{"路径","宽","高","大小"}],...} ] }
#
# 为什么按「批」而不是按「张」调用: 每开一次 PowerShell 进程要 ~400ms 冷启动,
# 批量转 20 张图如果逐张起进程就是 8 秒纯启动开销。整批一次进、一次出, 启动只付一遍。

param(
  [string]$Job    = '',
  [string]$Result = '',
  [switch]$Probe
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# 前端传来的路径可能带正斜杠。WinRT 的 StorageFile.GetFileFromPathAsync 只认反斜杠,
# 传正斜杠会抛一个不带任何有用信息的异常, 所以统一在这里转掉。
function NPath($p) { return ([string]$p).Replace('/', '\') }

# .NET 异常经常把真正的原因藏在 InnerException 里(尤其 WinRT 的 AggregateException),
# 只报外层 Message 等于什么都没说。逐层摊开。
function Err-Text($e) {
  $m = $e.Message
  $x = $e
  while ($x.InnerException) { $x = $x.InnerException; $m = $m + '  <-  ' + $x.Message }
  return $m
}

function Write-Json($path, $obj) {
  # 结果给 node 的 JSON.parse 读, 必须 UTF-8 无 BOM（带 BOM 会让 JSON.parse 报错）
  $json = $obj | ConvertTo-Json -Depth 8 -Compress
  [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# ---------- 能力自检 ----------
# 界面按这里的实际结果决定哪些格式可用, 而不是写死 —— 换台机器装没装某个编解码器, 界面自动跟着变。
if ($Probe) {
  $dec = @([System.Drawing.Imaging.ImageCodecInfo]::GetImageDecoders() | ForEach-Object { $_.MimeType })
  $enc = @([System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | ForEach-Object { $_.MimeType })
  $pdfOk = $false
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType=WindowsRuntime]
    $pdfOk = $true
  } catch { $pdfOk = $false }
  Write-Json $Result @{
    ok       = $true
    解码     = $dec
    编码     = $enc
    支持PDF  = $pdfOk
    说明     = 'GDI+ 编解码器清单; HEIC 走 WIC 不在此列, 故本服务不提供 HEIC'
  }
  exit 0
}

# ---------- 图片: 保存 ----------
function Get-Encoder($mime) {
  [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq $mime } | Select-Object -First 1
}
function Mime-Of($format) {
  switch ($format.ToLower()) {
    'jpg'  { 'image/jpeg' }
    'jpeg' { 'image/jpeg' }
    'png'  { 'image/png'  }
    'gif'  { 'image/gif'  }
    'bmp'  { 'image/bmp'  }
    'tif'  { 'image/tiff' }
    'tiff' { 'image/tiff' }
    default { '' }
  }
}
function Save-Image($img, $outPath, $format, $quality) {
  $mime = Mime-Of $format
  if (-not $mime) { throw "服务端不支持输出格式「$format」（ICO 由前端生成，不经服务）" }
  $enc = Get-Encoder $mime
  if (-not $enc) { throw "本机没有 $mime 编码器" }
  if ($mime -eq 'image/jpeg') {
    $ps = New-Object System.Drawing.Imaging.EncoderParameters 1
    $ps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int64]$quality)
    $img.Save($outPath, $enc, $ps)
    $ps.Dispose()
  } else {
    # 坑: Image 没有 Save(string, ImageCodecInfo) 这个重载。只传两个参数时 PowerShell 会去匹配
    # Save(string, ImageFormat), 然后报「无法把 ImageCodecInfo 转成 ImageFormat」—— 报错信息
    # 完全没提「重载不存在」, 很容易误以为是自己参数写错。必须补第三个参数, 并用 [T]$null 消歧。
    $img.Save($outPath, $enc, [System.Drawing.Imaging.EncoderParameters]$null)
  }
}

# JPEG 没有透明通道。把带 alpha 的图直接存 JPEG, 透明区会变成黑块(甚至花屏)。
# 所以先铺一层白底再把图画上去。
function Flatten-ToWhite($img) {
  $bmp = New-Object System.Drawing.Bitmap $img.Width, $img.Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::White)
  $g.DrawImage($img, 0, 0, $img.Width, $img.Height)
  $g.Dispose()
  return $bmp
}

function Resize-Image($img, $w, $h) {
  if ($w -le 0 -and $h -le 0) { return $null }   # 不需要缩放
  $ratio = $img.Width / $img.Height
  if ($w -le 0) { $w = [int][Math]::Round($h * $ratio) }
  if ($h -le 0) { $h = [int][Math]::Round($w / $ratio) }
  if ($w -lt 1) { $w = 1 }
  if ($h -lt 1) { $h = 1 }
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  # 用 ImageAttributes 包一层, 否则半透明像素缩放时边缘会发黑
  $ia = New-Object System.Drawing.Imaging.ImageAttributes
  $ia.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
  $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
  $g.DrawImage($img, $rect, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
  $ia.Dispose(); $g.Dispose()
  return $bmp
}

# 多页输出时在扩展名前插 _p01 / _p02; 单页保持原文件名
function Page-Path($basePath, $idx, $total) {
  if ($total -le 1) { return $basePath }
  $dir = Split-Path -Parent $basePath
  $stem = [IO.Path]::GetFileNameWithoutExtension($basePath)
  $ext  = [IO.Path]::GetExtension($basePath)
  return (Join-Path $dir ($stem + '_p' + ('{0:D2}' -f $idx) + $ext))
}

function Do-Image($t) {
  $src = $null; $work = $null; $flat = $null
  try {
    # 文件不存在时 GDI+ 抛的异常只把路径重复一遍, 完全看不出是"找不到文件"还是"格式损坏"。
    # 这里先判一次, 给个能直接读懂的报错。
    if (-not (Test-Path -LiteralPath (NPath $t.输入))) { throw "找不到文件：$($t.输入)" }
    $src = [System.Drawing.Image]::FromFile((NPath $t.输入))
    $format = [string]$t.输出格式
    if (-not $format) { $format = 'jpg' }
    $quality = 92
    if ($null -ne $t.质量 -and [int]$t.质量 -gt 0) { $quality = [int]$t.质量 }
    $w = 0; $h = 0
    if ($null -ne $t.宽) { $w = [int]$t.宽 }
    if ($null -ne $t.高) { $h = [int]$t.高 }

    # 帧: "全部" -> 多页 TIFF/GIF 每帧出一张; 数字 -> 指定帧(1起); 缺省 -> 第 1 帧
    $frameDim = New-Object System.Drawing.Imaging.FrameDimension $src.FrameDimensionsList[0]
    $frameCount = $src.GetFrameCount($frameDim)
    $frames = @(0)
    $wantAll = ("$($t.帧)" -eq '全部')
    if ($wantAll -and $frameCount -gt 1) {
      $frames = 0..($frameCount - 1)
    } elseif ("$($t.帧)" -match '^\d+$' -and [int]$t.帧 -ge 1) {
      $frames = @([int]$t.帧 - 1)
    }

    $outs = New-Object System.Collections.ArrayList
    foreach ($fi in $frames) {
      if ($fi -ge $frameCount) { throw "第 $($fi+1) 帧不存在（该文件共 $frameCount 帧）" }
      [void]$src.SelectActiveFrame($frameDim, $fi)
      if ($work) { $work.Dispose(); $work = $null }
      $work = Resize-Image $src $w $h
      $target = $work
      if (-not $target) { $target = $src }
      if ((Mime-Of $format) -eq 'image/jpeg') {
        $flat = Flatten-ToWhite $target
        $target = $flat
      }
      $outPath = Page-Path (NPath $t.输出) ($fi + 1) $frames.Count
      # 宽高必须在 Save 之后、Dispose 之前取。JPEG 分支里 $target 就是 $flat, 先 Dispose 再读
      # 宽高会静默拿到空值(不报错), 前端就显示不出尺寸 —— 这个坑踩过一次。
      $ow = $target.Width; $oh = $target.Height
      Save-Image $target $outPath $format $quality
      if ($flat) { $flat.Dispose(); $flat = $null }
      $fi2 = Get-Item -LiteralPath $outPath
      [void]$outs.Add(@{ 路径 = $outPath; 宽 = $ow; 高 = $oh; 大小 = $fi2.Length })
    }
    return @{ ok = $true; 输出 = $outs; 帧数 = $frames.Count }
  } finally {
    if ($flat) { $flat.Dispose() }
    if ($work) { $work.Dispose() }
    if ($src)  { $src.Dispose()  }
  }
}

# ---------- PDF: WinRT 渲染 ----------
$script:PdfReady = $false
$script:AsTaskOp = $null
$script:AsTaskAct = $null
function Ensure-Pdf {
  if ($script:PdfReady) { return }
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $exts = [System.WindowsRuntimeSystemExtensions].GetMethods()
  $script:AsTaskOp = ($exts | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $script:AsTaskAct = ($exts | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
  [void][Windows.Storage.StorageFile,           Windows.Storage,    ContentType=WindowsRuntime]
  [void][Windows.Storage.StorageFolder,         Windows.Storage,    ContentType=WindowsRuntime]
  [void][Windows.Data.Pdf.PdfDocument,          Windows.Data.Pdf,   ContentType=WindowsRuntime]
  [void][Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf,   ContentType=WindowsRuntime]
  $script:PdfReady = $true
}
function AwaitOp($op, $t) { $m = $script:AsTaskOp.MakeGenericMethod($t); $k = $m.Invoke($null, @($op)); $k.Wait(-1) | Out-Null; $k.Result }
function AwaitAct($act)   { $k = $script:AsTaskAct.Invoke($null, @($act)); $k.Wait(-1) | Out-Null }

function Do-Pdf($t) {
  Ensure-Pdf
  if (-not (Test-Path -LiteralPath (NPath $t.输入))) { throw "找不到文件：$($t.输入)" }
  $tmpDir = Split-Path -Parent (NPath $t.输出)
  $file   = AwaitOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync((NPath $t.输入))) ([Windows.Storage.StorageFile])
  $doc    = AwaitOp ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
  $folder = AwaitOp ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($tmpDir)) ([Windows.Storage.StorageFolder])
  $temps = New-Object System.Collections.ArrayList

  # 渲染单页到临时 PNG, 返回 @{路径;宽;高}
  $render = {
    param($idx, $reqW)
    $page = $doc.GetPage($idx)
    $pw = $page.Size.Width; $ph = $page.Size.Height
    $opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
    $opts.DestinationWidth = $reqW
    $tmp = Join-Path $tmpDir ('_cvt_' + [Guid]::NewGuid().ToString('N') + '.png')
    $sf  = AwaitOp ($folder.CreateFileAsync((Split-Path -Leaf $tmp), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    $st  = AwaitOp ($sf.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
    AwaitAct ($page.RenderToStreamAsync($st, $opts))
    $st.Dispose()
    $page.Dispose()          # 注意: Size 必须在 Dispose 之前取出来, 之后取会抛
    [void]$temps.Add($tmp)
    $im = [System.Drawing.Image]::FromFile($tmp)
    $r = @{ 路径 = $tmp; 宽 = $im.Width; 高 = $im.Height; 页面宽 = $pw; 页面高 = $ph }
    $im.Dispose()
    return $r
  }

  try {
    $total = $doc.PageCount
    # 页码: 空 = 全部; 数组 = 指定页(1起)
    $pages = @()
    if ($null -ne $t.页码 -and @($t.页码).Count -gt 0) {
      foreach ($p in @($t.页码)) { $n = [int]$p; if ($n -ge 1 -and $n -le $total) { $pages += ($n - 1) } }
    } else {
      $pages = 0..($total - 1)
    }
    if ($pages.Count -eq 0) { throw "页码超出范围（该 PDF 共 $total 页）" }

    $format = [string]$t.输出格式; if (-not $format) { $format = 'jpg' }
    $quality = 92; if ($null -ne $t.质量 -and [int]$t.质量 -gt 0) { $quality = [int]$t.质量 }

    # 坑: PdfPageRenderOptions.DestinationWidth 会被系统显示缩放(本机 150%)乘一遍,
    #     设 1004 实际出 1506。所以先试探渲一次量出系数, 再按系数反算请求宽。
    $probe = & $render $pages[0] 1000
    $factor = $probe.宽 / 1000.0
    if ($factor -le 0) { $factor = 1.0 }

    $autoW = 0
    if ($null -eq $t.目标宽 -or [int]$t.目标宽 -le 0) {
      # 自动: 取 PDF 里最大嵌入图的像素宽, 保证 1:1 不吃掉原图细节
      $bytes = [IO.File]::ReadAllBytes((NPath $t.输入))
      $s = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
      $maxW = 0
      foreach ($m in [regex]::Matches($s, '/Subtype\s*/Image')) {
        $st0 = [Math]::Max(0, $m.Index - 400)
        $ctx = $s.Substring($st0, [Math]::Min(900, $s.Length - $st0))
        $mw = [regex]::Match($ctx, '/Width\s+(\d+)').Groups[1].Value
        if ($mw -and [int]$mw -gt $maxW) { $maxW = [int]$mw }
      }
      $autoW = $maxW
    }

    $outs = New-Object System.Collections.ArrayList
    foreach ($pi in $pages) {
      $targetW = 0
      if ($null -ne $t.DPI -and [int]$t.DPI -gt 0) {
        $pg = $doc.GetPage($pi); $pwD = $pg.Size.Width; $pg.Dispose()
        $targetW = [int][Math]::Round($pwD / 96.0 * [int]$t.DPI)
      } elseif ([int]$t.目标宽 -gt 0) {
        $targetW = [int]$t.目标宽
      } elseif ($autoW -gt 0) {
        $targetW = $autoW
      } else {
        $targetW = 1000
      }
      if ($targetW -gt 20000) { $targetW = 20000 }   # 防手滑设成天文数字把内存打爆

      $req = [int][Math]::Round($targetW / $factor)
      if ($req -lt 1) { $req = 1 }
      $r = & $render $pi $req

      $outPath = Page-Path (NPath $t.输出) ($pi + 1) $pages.Count
      $im = [System.Drawing.Image]::FromFile($r.路径)
      $save = $im
      if ((Mime-Of $format) -eq 'image/jpeg') { $save = Flatten-ToWhite $im }
      Save-Image $save $outPath $format $quality
      $sw = $save.Width; $sh = $save.Height
      if ($save -ne $im) { $save.Dispose() }
      $im.Dispose()
      $fi2 = Get-Item -LiteralPath $outPath
      [void]$outs.Add(@{ 路径 = $outPath; 宽 = $sw; 高 = $sh; 大小 = $fi2.Length })
    }
    return @{ ok = $true; 输出 = $outs; 页数 = $total; 缩放系数 = $factor; 自动宽 = $autoW }
  } finally {
    foreach ($p in $temps) { try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch {} }
    # WinRT 的 PdfDocument 走 IClosable 投影, 是 Close() 不是 Dispose()。
    # 反射在这里取不到方法, 所以两个都试、都吞异常 —— 关不掉不该让整批任务失败。
    try { $doc.Close() } catch { try { $doc.Dispose() } catch {} }
  }
}

# ---------- 主流程 ----------
$jobData = [IO.File]::ReadAllText($Job, [Text.Encoding]::UTF8) | ConvertFrom-Json
$results = New-Object System.Collections.ArrayList

foreach ($t in @($jobData.任务)) {
  try {
    $r = $null
    switch ("$($t.类型)") {
      '图片' { $r = Do-Image $t }
      'PDF'  { $r = Do-Pdf  $t }
      default { throw "未知任务类型「$($t.类型)」" }
    }
    [void]$results.Add(@{ ok = $true; 输入 = "$($t.输入)"; 输出 = $r.输出; 详情 = $r })
  } catch {
    # 单个文件失败不能拖垮整批 —— 记下原因, 继续下一个
    [void]$results.Add(@{ ok = $false; 输入 = "$($t.输入)"; 错误 = (Err-Text $_.Exception) })
  }
}

Write-Json $Result @{ ok = $true; 结果 = $results }
exit 0
