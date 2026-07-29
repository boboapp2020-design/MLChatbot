<#
=====================================================================
 ML Expert AI — แบ่งไฟล์ SQL ก้อนใหญ่เป็นหลายไฟล์
---------------------------------------------------------------------
 003_seed_kb.sql มีขนาด ~5 MB / 37,000 บรรทัด
 วางลง SQL Editor ของ Supabase ทีเดียวไม่ได้ — หน้าเว็บค้างหรือ timeout

 สองเรื่องที่ต้องระวัง (เคยพลาดมาแล้วทั้งคู่):
 1) ไฟล์ต้นฉบับครอบด้วย begin; ... commit; เป็นทรานแซกชันเดียว
    ถ้าตัดดื้อๆ ไฟล์แรกจะมี begin; แต่ไม่มี commit; -> ข้อมูลไม่ถูกบันทึก
    ไฟล์สุดท้ายมี commit; ลอยๆ -> error
    จึงต้องให้ทุกไฟล์มี begin;/commit; ของตัวเอง
 2) ขนาดต้องนับเป็น "ไบต์" ไม่ใช่จำนวนตัวอักษร
    ภาษาไทยใน UTF-8 กินตัวละ 3 ไบต์ ถ้านับตัวอักษรไฟล์จะใหญ่เกินเป้า 3 เท่า

   powershell -ExecutionPolicy Bypass -File scripts\split-sql.ps1
=====================================================================
#>
[CmdletBinding()]
param(
  [string] $In     = 'supabase\migrations\003_seed_kb.sql',
  [string] $OutDir = 'supabase\migrations\003_parts',
  [int]    $MaxKB  = 900     # ต่อไฟล์ (ไบต์จริง) — เผื่อไว้ต่ำกว่าลิมิตหน้าเว็บ
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $Root $In

if (-not (Test-Path -LiteralPath $src)) {
  Write-Host "ไม่พบไฟล์ $In — รัน scripts\build-kb.ps1 ก่อน" -ForegroundColor Red; exit 1
}

$dir = Join-Path $Root $OutDir
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Path $dir | Out-Null

$enc     = New-Object Text.UTF8Encoding($false)
$utf8    = [Text.Encoding]::UTF8
$reader  = [System.IO.StreamReader]::new($src, $utf8)

$part  = 0
$buf   = New-Object Text.StringBuilder
$bytes = 0
$prelude = ''      # คำสั่งล้างข้อมูลเดิม ใส่เฉพาะไฟล์แรก
$inHeader = $true
$files = @()

function Write-Part {
  param([int]$n, [string]$sql, [string]$pre)
  $head = "-- ML Expert AI — seed ส่วนที่ {0}`r`n" -f $n
  $head += "-- รันเรียงตามลำดับ part01, part02, ... ในหน้า SQL Editor`r`n"
  $head += "-- แต่ละไฟล์เป็นทรานแซกชันของตัวเอง รันซ้ำไฟล์ที่ error ได้`r`n`r`n"
  $body = $head + "begin;`r`n`r`n" + $pre + $sql + "`r`ncommit;`r`n"
  $path = Join-Path $script:dir ("003_seed_kb_part{0:D2}.sql" -f $n)
  [System.IO.File]::WriteAllText($path, $body, $script:enc)
  $kb = [math]::Round((Get-Item $path).Length / 1KB, 0)
  Write-Host ("  part{0:D2}  {1,5:N0} KB" -f $n, $kb) -ForegroundColor DarkGray
  return $path
}

Write-Host "`nกำลังแบ่งไฟล์..." -ForegroundColor Cyan
while ($null -ne ($line = $reader.ReadLine())) {

  # ส่วนหัว: คอมเมนต์ / begin; / คำสั่ง delete ของเดิม
  if ($inHeader) {
    if ($line -match '^\s*INSERT\s+INTO') { $inHeader = $false }
    else {
      # เก็บเฉพาะคำสั่ง delete ไว้ใส่ไฟล์แรก ส่วน begin; กับคอมเมนต์ทิ้งได้
      if ($line -match '^\s*delete\s+from') { $prelude += $line + "`r`n`r`n" }
      continue
    }
  }

  # ข้าม commit; ของไฟล์ต้นฉบับ — แต่ละไฟล์ย่อยมี commit; ของตัวเองแล้ว
  if ($line -match '^\s*commit\s*;') { continue }

  # ขึ้นคำสั่ง INSERT ใหม่ = จุดตัดที่ปลอดภัย (ไม่ตัดกลางคำสั่ง)
  if ($line -match '^\s*INSERT\s+INTO' -and $bytes -gt ($MaxKB * 1024)) {
    $part++
    $files += Write-Part -n $part -sql $buf.ToString() -pre $prelude
    $prelude = ''                       # ใส่แค่ไฟล์แรก
    $buf = New-Object Text.StringBuilder; $bytes = 0
  }

  [void]$buf.AppendLine($line)
  $bytes += $utf8.GetByteCount($line) + 2
}
$reader.Close()

if ($buf.Length -gt 0) { $part++; $files += Write-Part -n $part -sql $buf.ToString() -pre $prelude }

# ── ตรวจผลลัพธ์ ──────────────────────────────────────────────────────
Write-Host "`nตรวจสอบ:" -ForegroundColor Cyan
$ok = $true
foreach ($f in $files) {
  $t = [System.IO.File]::ReadAllText($f, $utf8)
  $b = ([regex]::Matches($t,'(?m)^begin;')).Count
  $c = ([regex]::Matches($t,'(?m)^commit;')).Count
  if ($b -ne 1 -or $c -ne 1) {
    Write-Host ("  ผิดพลาด: {0} มี begin={1} commit={2}" -f (Split-Path $f -Leaf), $b, $c) -ForegroundColor Red
    $ok = $false
  }
}
$srcIns  = ([regex]::Matches([System.IO.File]::ReadAllText($src,$utf8),'(?im)^\s*INSERT\s+INTO')).Count
$partIns = 0
foreach ($f in $files) { $partIns += ([regex]::Matches([System.IO.File]::ReadAllText($f,$utf8),'(?im)^\s*INSERT\s+INTO')).Count }
Write-Host ("  คำสั่ง INSERT: ต้นฉบับ {0} / แบ่งแล้วรวม {1}" -f $srcIns, $partIns) -ForegroundColor DarkGray
if ($srcIns -ne $partIns) { Write-Host "  ผิดพลาด: จำนวนคำสั่งไม่ตรงกัน" -ForegroundColor Red; $ok = $false }
if ($ok) { Write-Host "  ทุกไฟล์มี begin/commit ครบ และคำสั่งไม่หาย" -ForegroundColor Green }

Write-Host "`nเสร็จแล้ว — $part ไฟล์ที่ $OutDir" -ForegroundColor Green
Write-Host "เปิด Supabase -> SQL Editor แล้ววางทีละไฟล์ตามลำดับ" -ForegroundColor Yellow
Write-Host "ถ้ามี Supabase CLI ใช้ 'supabase db push' ทีเดียวจบ ไม่ต้องแบ่ง" -ForegroundColor DarkGray
