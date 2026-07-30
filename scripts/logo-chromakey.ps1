<#
=====================================================================
 ML Expert AI — ตัดพื้นหลัง green screen ออกจากโลโก้
---------------------------------------------------------------------
 ทำไมไม่ใช้ "ลบทุกพิกเซลที่เขียว": ใบไม้ในโลโก้ก็เขียว (greenness 107-133)
 ใกล้กับพื้นหลัง (168) เกินกว่าจะแยกด้วยเกณฑ์สีอย่างเดียว
 จึงใช้วิธีไล่ระบายจากขอบภาพเข้ามา (flood fill) — พื้นหลังต่อเนื่องถึงขอบ
 ส่วนใบไม้อยู่ในกรอบโลโก้ ไล่เข้าไปไม่ถึง จึงไม่โดนลบ

   powershell -ExecutionPolicy Bypass -File scripts\logo-chromakey.ps1
=====================================================================
#>
[CmdletBinding()]
param(
  [string] $In  = 'logo app.png',
  [string] $Out = 'LOGO.png',
  [int]    $Size = 256,
  [int]    $Tol  = 90,    # greenness ขั้นต่ำที่ถือว่าเป็นพื้นหลัง (ใช้กับฉากเขียว)
  [int]    $FlatTol = 26, # ระยะห่างจากสีมุมภาพที่ยังถือว่าเป็นพื้นหลัง (ใช้กับพื้นทึบ)
  [int]    $LocalTol = 10 # ระยะห่างจาก "พิกเซลที่เดินมา" ที่ยังถือว่าเป็นพื้นหลังเดียวกัน
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing

$src = Join-Path $Root $In
if (-not (Test-Path -LiteralPath $src)) { Write-Host "ไม่พบไฟล์ $In" -ForegroundColor Red; exit 1 }

$bmp = [System.Drawing.Bitmap]::FromFile($src)
$w = $bmp.Width; $h = $bmp.Height
Write-Host "`nต้นฉบับ: ${w}x${h}" -ForegroundColor Cyan

# แปลงเป็น 32bpp ARGB แล้วอ่านทั้งภาพเป็น byte array ทีเดียว
# (GetPixel ทีละจุดกับภาพ 1.5 ล้านพิกเซลช้าเกินไป)
$work = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($work)
$g.DrawImage($bmp, 0, 0, $w, $h); $g.Dispose(); $bmp.Dispose()

$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$data = $work.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$len = $data.Stride * $h
$buf = New-Object byte[] $len
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)

# ไบต์เรียงเป็น B,G,R,A
function Greenness([int]$i) {
  $b = $buf[$i]; $gr = $buf[$i+1]; $r = $buf[$i+2]
  return $gr - [Math]::Max($r, $b)
}

# ── เดาสีพื้นหลังจากมุมบนซ้าย ────────────────────────────────────────
# โลโก้รุ่นแรกใช้ฉากเขียว รุ่นใหม่พื้นขาว ถ้าฝังเกณฑ์ "เขียว" ไว้ตายตัว
# พอผู้ใช้ส่งไฟล์พื้นขาวมาสคริปต์จะไม่ตัดอะไรเลย เลยวัดจากมุมภาพแทน
$bgB = $buf[0]; $bgG = $buf[1]; $bgR = $buf[2]
$bgIsGreen = ($bgG - [Math]::Max($bgR, $bgB)) -ge 60
Write-Host ("สีพื้นหลังที่ตรวจพบ: R=$bgR G=$bgG B=$bgB " +
            $(if ($bgIsGreen) { '(ฉากเขียว)' } else { '(พื้นทึบ)' })) -ForegroundColor Cyan

# ระยะห่างจากสีพื้นหลัง — ใช้ได้กับพื้นสีอะไรก็ได้ ไม่ผูกกับเขียว
function BgDistance([int]$i) {
  $db = [Math]::Abs([int]$buf[$i]   - $bgB)
  $dg = [Math]::Abs([int]$buf[$i+1] - $bgG)
  $dr = [Math]::Abs([int]$buf[$i+2] - $bgR)
  return [Math]::Max($dr, [Math]::Max($dg, $db))
}

# ระยะห่างจากสีของพิกเซลที่ไล่ระบายมาถึงจุดนี้
# โลโก้บางแบบพื้นหลังไม่ได้สีเดียว แต่ไล่เฉดจากขาวไปฟ้าอ่อน (เงาเรืองแสงใต้ตัวหุ่น)
# ถ้าวัดจากสีมุมภาพอย่างเดียวจะตัดเฉพาะส่วนขาว เหลือคราบฟ้าเป็นสี่เหลี่ยมรอบโลโก้
# จึงเทียบกับ "เพื่อนบ้านที่เดินมา" ด้วย — เฉดที่ค่อยๆ เปลี่ยนจะไล่ตามไปได้
# ส่วนขอบโลโก้ที่สีกระโดดแรงในไม่กี่พิกเซลจะหยุด ไม่ทะลุเข้าไปกินตัวโลโก้
function RefDistance([int]$i, [int]$rb, [int]$rg, [int]$rr) {
  $db = [Math]::Abs([int]$buf[$i]   - $rb)
  $dg = [Math]::Abs([int]$buf[$i+1] - $rg)
  $dr = [Math]::Abs([int]$buf[$i+2] - $rr)
  return [Math]::Max($dr, [Math]::Max($dg, $db))
}

# คืนค่า $true เมื่อพิกเซลนี้ถือเป็นพื้นหลัง
# $ref = สีของพิกเซลก่อนหน้าแบบแพ็ก (b<<16|g<<8|r) ส่ง -1 มาถ้าเป็นจุดเริ่มที่ขอบภาพ
function IsBackground([int]$i, [int]$ref) {
  if ($bgIsGreen) { return (Greenness $i) -ge $Tol }
  if ((BgDistance $i) -le $FlatTol) { return $true }
  if ($ref -lt 0) { return $false }
  return (RefDistance $i ($ref -shr 16) (($ref -shr 8) -band 255) ($ref -band 255)) -le $LocalTol
}

# ── ไล่ระบายจากขอบ ───────────────────────────────────────────────────
$visited = New-Object 'bool[]' ($w * $h)
# ต้องใส่เครื่องหมายคำพูดรอบชื่อชนิดที่มี [] ไม่งั้น PowerShell อ่าน Stack[int]
# เป็นการ "เข้าถึงสมาชิกลำดับที่ int ของ Stack" แล้วพังด้วย error ที่ชี้ไปคนละที่
$stack = New-Object 'System.Collections.Generic.Stack[int]'
# สีของพิกเซลที่เดินมา เก็บคู่ขนานกับ $stack (แพ็กเป็น b<<16|g<<8|r)
$refs  = New-Object 'System.Collections.Generic.Stack[int]'

$lastX = $w - 1; $lastY = $h - 1
for ($x = 0; $x -lt $w; $x++) {
  $stack.Push($x);               $refs.Push(-1)   # แถวบน
  $stack.Push($lastY * $w + $x); $refs.Push(-1)   # แถวล่าง
}
for ($y = 0; $y -lt $h; $y++) {
  $stack.Push($y * $w);          $refs.Push(-1)   # คอลัมน์ซ้าย
  $stack.Push($y * $w + $lastX); $refs.Push(-1)   # คอลัมน์ขวา
}

$removed = 0
while ($stack.Count -gt 0) {
  $p = $stack.Pop(); $ref = $refs.Pop()
  if ($visited[$p]) { continue }
  $visited[$p] = $true
  $py = [Math]::Floor($p / $w); $px = $p - ($py * $w)
  $i = ($py * $data.Stride) + ($px * 4)
  if (-not (IsBackground $i $ref)) { continue }
  $me = ([int]$buf[$i] -shl 16) -bor ([int]$buf[$i+1] -shl 8) -bor [int]$buf[$i+2]
  $buf[$i+3] = 0                                    # โปร่งใส
  $removed++
  if ($px -gt 0)      { $stack.Push($p - 1);  $refs.Push($me) }
  if ($px -lt $w - 1) { $stack.Push($p + 1);  $refs.Push($me) }
  if ($py -gt 0)      { $stack.Push($p - $w); $refs.Push($me) }
  if ($py -lt $h - 1) { $stack.Push($p + $w); $refs.Push($me) }
}
Write-Host ("ลบพื้นหลัง: {0:N0} พิกเซล ({1:N1}%)" -f $removed, ($removed / ($w*$h) * 100)) -ForegroundColor DarkGray

# ── เก็บขอบฟันเลื่อย ─────────────────────────────────────────────────
# พิกเซลขอบที่ผสมระหว่างโลโก้กับพื้นเขียว จะเหลือเป็นเส้นเขียวบางๆ รอบภาพ
# ลดความเขียวลง (despill) และไล่ alpha ตามสัดส่วนความเขียวที่เหลือ
$edge = 0
for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    $i = ($y * $data.Stride) + ($x * 4)
    if ($buf[$i+3] -eq 0) { continue }
    $gn = Greenness $i
    if ($gn -le 35) { continue }
    # ดูว่าติดกับพื้นที่โปร่งใสไหม ถ้าไม่ติดแปลว่าเป็นสีเขียวจริงของโลโก้ (ใบไม้)
    $near = $false
    foreach ($d in @(-1, 1, -$w, $w)) {
      $q = ($y * $w + $x) + $d
      if ($q -lt 0 -or $q -ge ($w * $h)) { continue }
      $qy = [Math]::Floor($q / $w); $qx = $q - ($qy * $w)
      if ($buf[($qy * $data.Stride) + ($qx * 4) + 3] -eq 0) { $near = $true; break }
    }
    if (-not $near) { continue }
    $b = $buf[$i]; $r = $buf[$i+2]
    $buf[$i+1] = [byte][Math]::Max([Math]::Max($r, $b), 0)   # despill
    $buf[$i+3] = [byte]([Math]::Max(0, 255 - ($gn * 2)))
    $edge++
  }
}
Write-Host ("เก็บขอบ: {0:N0} พิกเซล" -f $edge) -ForegroundColor DarkGray

[System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $data.Scan0, $len)
$work.UnlockBits($data)

# ── ตัดขอบว่างรอบภาพ ─────────────────────────────────────────────────
$minX = $w; $minY = $h; $maxX = -1; $maxY = -1
for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    if ($buf[($y * $data.Stride) + ($x * 4) + 3] -gt 8) {
      if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
    }
  }
}
if ($maxX -lt 0) { Write-Host "ตัดหมดทั้งภาพ - ค่า Tol สูงเกินไป" -ForegroundColor Red; exit 1 }
$cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1
Write-Host "ตัดขอบว่างเหลือ: ${cw}x${ch}" -ForegroundColor DarkGray

# ── ย่อเป็นสี่เหลี่ยมจัตุรัสตามขนาดที่ขอ ─────────────────────────────
# ห้ามตั้งชื่อ $out เพราะชนกับพารามิเตอร์ $Out ที่ประกาศเป็น [string]
# (ตัวแปร PowerShell ไม่แยกตัวพิมพ์ และตัวแปรที่ประกาศชนิดไว้จะแปลงค่าที่ assign ให้เป็นชนิดนั้น
#  Bitmap จึงกลายเป็นข้อความเงียบๆ แล้วไปพังตอนเรียก FromImage)
$dstBmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g2 = [System.Drawing.Graphics]::FromImage($dstBmp)
$g2.InterpolationMode = 'HighQualityBicubic'
$g2.SmoothingMode = 'HighQuality'
$g2.PixelOffsetMode = 'HighQuality'
$g2.CompositingQuality = 'HighQuality'
# รักษาสัดส่วนเดิม วางกึ่งกลาง
$scale = [Math]::Min($Size / $cw, $Size / $ch)
$dw = [int]($cw * $scale); $dh = [int]($ch * $scale)
$dst = New-Object System.Drawing.Rectangle([int](($Size - $dw)/2), [int](($Size - $dh)/2), $dw, $dh)
$srcR = New-Object System.Drawing.Rectangle($minX, $minY, $cw, $ch)
$g2.DrawImage($work, $dst, $srcR, [System.Drawing.GraphicsUnit]::Pixel)
$g2.Dispose(); $work.Dispose()

$target = Join-Path $Root $Out
$dstBmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$dstBmp.Dispose()

$kb = [math]::Round((Get-Item -LiteralPath $target).Length / 1KB, 0)
Write-Host "`nเสร็จแล้ว: $Out  (${Size}x${Size}, $kb KB, พื้นหลังโปร่งใส)" -ForegroundColor Green
