<#
=====================================================================
 ML Expert AI — Build single-file distribution
---------------------------------------------------------------------
 รวม web/index.html + kb/chunks.js + kb/personas.js เป็นไฟล์เดียว
 ที่ dist/index.html — อัปโหลดไฟล์นี้ไฟล์เดียวขึ้น GitHub ก็ใช้ได้ทันที

 เหตุผล: GitHub Pages เสิร์ฟไฟล์ตามที่อัปไป ถ้าอัปแค่ index.html
 แท็ก <script src="../kb/chunks.js"> จะ 404 คลังความรู้จึงว่างเปล่า
 และผู้เชี่ยวชาญจะปฏิเสธทุกคำถามแม้ใส่ API key แล้ว

   powershell -ExecutionPolicy Bypass -File scripts\build-dist.ps1
=====================================================================
#>
[CmdletBinding()]
param([switch] $Open)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot

function Read-Text($p) {
  if (-not (Test-Path -LiteralPath $p)) { throw "ไม่พบไฟล์: $p" }
  return [System.IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
}

$srcHtml     = Join-Path $Root 'web\index.html'
$srcChunks   = Join-Path $Root 'kb\chunks.js'
$srcPersonas = Join-Path $Root 'kb\personas.js'

Write-Host "`nอ่านไฟล์ต้นทาง..." -ForegroundColor Cyan
$html     = Read-Text $srcHtml
$chunks   = Read-Text $srcChunks
$personas = Read-Text $srcPersonas

foreach ($f in @($srcHtml, $srcChunks, $srcPersonas)) {
  $kb = [math]::Round((Get-Item -LiteralPath $f).Length / 1KB, 0)
  Write-Host ("  {0,7:N0} KB  {1}" -f $kb, $f.Replace("$Root\", ''))
}

# ── ตรวจว่าคลังไม่ว่าง ────────────────────────────────────────────────
# เคยเจอกรณีอัป index.html ขึ้นเว็บโดยลืมคลัง แล้วงงว่าทำไมไม่ตอบ
# ถ้าคลังในเครื่องว่างอยู่แล้ว สร้าง dist ไปก็เจอปัญหาเดิม จึงหยุดตรงนี้
$nChunks = ([regex]::Matches($chunks, '"doc_code"')).Count
$nPers   = ([regex]::Matches($personas, '^\s*"[a-z_]+"\s*:', 'Multiline')).Count
if ($nChunks -lt 50) {
  Write-Host "`nคลังความรู้มีแค่ $nChunks ท่อน — น้อยผิดปกติ" -ForegroundColor Red
  Write-Host "รัน scripts\build-kb.ps1 ก่อน แล้วค่อยสร้าง dist ใหม่" -ForegroundColor Red
  exit 1
}

# ── ฝังสคริปต์เข้าไปในไฟล์เดียว ──────────────────────────────────────
# ถ้าเนื้อหาเอกสารบังเอิญมีสตริง </script> เบราว์เซอร์จะปิดแท็กตรงนั้น
# แล้วโค้ดที่เหลือกลายเป็นข้อความบนหน้าจอ ต้องหักล้างก่อนเสมอ
function Protect-Script([string]$js) { return $js -replace '</script', '<\/script' }

$inline = "<script>`n" + (Protect-Script $chunks) + "`n</script>`n" +
          "<script>`n" + (Protect-Script $personas) + "`n</script>"

$pattern = '<script src="\.\./kb/chunks\.js"></script>\s*<script src="\.\./kb/personas\.js"></script>'
if ($html -notmatch $pattern) {
  Write-Host "`nไม่พบแท็ก <script src=...> ที่คาดไว้ใน web\index.html" -ForegroundColor Red
  Write-Host "โครงสร้างไฟล์เปลี่ยนไป — แก้ `$pattern ในสคริปต์นี้ให้ตรงก่อน" -ForegroundColor Red
  exit 1
}
$out = [regex]::Replace($html, $pattern, { param($m) $inline })

# ── เขียนออก ─────────────────────────────────────────────────────────
$dist = Join-Path $Root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$target = Join-Path $dist 'index.html'

# UTF-8 ไม่มี BOM — BOM ทำให้บาง static host ส่ง header ผิดและขึ้นอักขระประหลาด
[System.IO.File]::WriteAllText($target, $out, (New-Object Text.UTF8Encoding($false)))

# .nojekyll กัน GitHub Pages เอา Jekyll มาประมวลผลไฟล์ก่อนเสิร์ฟ
[System.IO.File]::WriteAllText((Join-Path $dist '.nojekyll'), '')

$mb = [math]::Round((Get-Item -LiteralPath $target).Length / 1MB, 2)
Write-Host "`nสร้างเสร็จ: dist\index.html  ($mb MB)" -ForegroundColor Green
Write-Host "  คลังความรู้ $nChunks ท่อน · ผู้เชี่ยวชาญ $nPers คน · ไม่ต้องพึ่งไฟล์อื่น" -ForegroundColor DarkGray
Write-Host "`nอัปไฟล์นี้ไฟล์เดียวขึ้น GitHub ทับ index.html เดิมได้เลย" -ForegroundColor Yellow

if ($Open) { Start-Process $target }
