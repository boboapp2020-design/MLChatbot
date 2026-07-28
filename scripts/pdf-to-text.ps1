<#
=====================================================================
 ML Expert AI — PDF to Text
---------------------------------------------------------------------
 ใช้ pdftotext (ติดมากับ Git for Windows อยู่แล้ว ไม่ต้องติดตั้งเพิ่ม)
 ถ้าหาไม่เจอในระบบ สคริปต์จะไปหาใน Git installation ให้เอง

 หมายเหตุเรื่องภาษาไทย:
   PDF เก็บสระ/วรรณยุกต์ไทยตามลำดับการวาดบนหน้า ไม่ใช่ลำดับเชิงตรรกะ
   ข้อความที่สกัดออกมาจึงมีสระลอยผิดตำแหน่งบ้าง สคริปต์นี้จะทำ
   normalize เบื้องต้นให้ แต่ผลลัพธ์ภาษาไทยจะไม่สมบูรณ์ 100%
   ส่วนเอกสารภาษาอังกฤษสกัดได้ครบถ้วน

 วิธีใช้:
   powershell -ExecutionPolicy Bypass -File scripts\pdf-to-text.ps1
   powershell -ExecutionPolicy Bypass -File scripts\pdf-to-text.ps1 -Only preecha
=====================================================================
#>
[CmdletBinding()]
param([string]$InDir="", [string]$OutDir="", [string]$Only="", [switch]$Force)

$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if(-not $InDir){  $InDir  = Join-Path $ProjectRoot 'Support Document' }
if(-not $OutDir){ $OutDir = Join-Path $InDir '_text' }

# ── หา pdftotext ──────────────────────────────────────────────────
$exe = (Get-Command pdftotext -ErrorAction SilentlyContinue).Source
if(-not $exe){
  foreach($c in @("$env:LOCALAPPDATA\Programs\Git\mingw64\bin\pdftotext.exe",
                  "$env:ProgramFiles\Git\mingw64\bin\pdftotext.exe",
                  "${env:ProgramFiles(x86)}\Git\mingw64\bin\pdftotext.exe")){
    if(Test-Path $c){ $exe=$c; break }
  }
}
if(-not $exe){ Write-Error "ไม่พบ pdftotext — ติดตั้ง Git for Windows หรือ poppler-utils" }
Write-Host "pdftotext: $exe" -ForegroundColor DarkGray

if(-not (Test-Path $InDir)){ Write-Error "ไม่พบโฟลเดอร์: $InDir" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$pdfs = Get-ChildItem $InDir -Filter *.pdf -File
if($Only){ $pdfs = $pdfs | Where-Object { $_.Name -like "*$Only*" } }
if(-not $pdfs){ Write-Error "ไม่พบไฟล์ PDF ที่ตรงเงื่อนไข" }

# ── ซ่อมข้อความไทยที่สกัดจาก PDF ─────────────────────────────────
# โหมด -raw ให้ลำดับตัวอักษรไทยถูกต้องอยู่แล้วในเนื้อความปกติ
# จะเพี้ยนเฉพาะบางส่วน (สารบัญ หัวตาราง) ที่ PDF วาดสระเป็น glyph แยก
# จนเครื่องหมายไปอยู่หลังพยัญชนะตัวถัดไป เช่น "จัดโหลด" -> "จดั โหลด"
#
# จุดสังเกตที่ใช้ได้จริง: กรณีเพี้ยนจะมี "ช่องว่างเกิน" ตามหลังเครื่องหมายเสมอ
# จึงแก้เฉพาะกรณีที่มีช่องว่างนั้น ไม่แตะข้อความปกติ
# (เคยลองสลับทุกกรณีที่เจอ C C M แล้วพัง เพราะ "เครื่อง" ก็เข้าแพตเทิร์นนี้
#  แต่ถูกต้องอยู่แล้ว — กลายเป็น "เคื่รอง")
function Normalize-Thai([string]$t){
  if($t -notmatch '[฀-๿]'){ return (Compact $t) }

  $C = '[ก-ฮ]'                       # พยัญชนะ
  $M = '[ัิ-ฺ็-๎]'                    # สระบน/ล่าง + วรรณยุกต์ (U+0E31, U+0E34-3A, U+0E47-4E)

  # พยัญชนะ-พยัญชนะ-เครื่องหมาย ที่ตามด้วยช่องว่าง -> สลับเครื่องหมายกลับที่เดิม
  # ทำสองรอบเพราะบางคำมีเครื่องหมายซ้อนสองชั้น
  for($i=0;$i -lt 2;$i++){
    $t = [regex]::Replace($t,"($C)($C)($M+)(\s+)",'$1$3$2$4')
  }
  # ตัดช่องว่างที่แทรกก่อนเครื่องหมาย (เครื่องหมายต้องติดพยัญชนะเสมอ)
  $t = [regex]::Replace($t,"(?<=[฀-๿])[ \t]+(?=$M)",'')

  return (Compact $t)
}

function Compact([string]$t){
  $t = [regex]::Replace($t,'[ \t]{2,}',' ')
  $t = [regex]::Replace($t,'(?m)^\s*\d{1,4}\s*$','')      # เลขหน้าโดดๆ
  $t = [regex]::Replace($t,'(?m)^\s*[.·…]{4,}.*$','')      # บรรทัดจุดไข่ปลาในสารบัญ
  $t = [regex]::Replace($t,'\.{5,}','  ')                  # จุดไข่ปลากลางบรรทัด
  $t = [regex]::Replace($t,'(\r?\n){3,}',"`n`n")
  return $t.Trim()
}

Write-Host "`nไฟล์ที่จะแปลง: $($pdfs.Count)" -ForegroundColor Cyan
foreach($pdf in $pdfs){
  $out = Join-Path $OutDir ($pdf.BaseName + '.txt')
  if((Test-Path $out) -and -not $Force){
    Write-Host "[ข้าม] มีอยู่แล้ว: $($pdf.BaseName).txt" -ForegroundColor DarkYellow; continue
  }
  Write-Host "`n[แปลง] $($pdf.Name)  ($([math]::Round($pdf.Length/1MB,1)) MB)" -ForegroundColor Cyan
  $t0=Get-Date

  # pdftotext เป็น native exe ที่รับ path ผ่าน ANSI codepage
  # ชื่อไฟล์ภาษาไทยจึงกลายเป็น ??? และเปิดไม่ได้ -> สำเนาไปชื่อ ASCII ชั่วคราวก่อน
  $srcPath = $pdf.FullName
  $tempPdf = $null
  if($pdf.Name -match '[^\x20-\x7E]'){
    $tempPdf = Join-Path $env:TEMP ("mlx_" + [Guid]::NewGuid().ToString('N').Substring(0,10) + ".pdf")
    Copy-Item -LiteralPath $pdf.FullName -Destination $tempPdf -Force
    $srcPath = $tempPdf
    Write-Host "        (ชื่อไฟล์ไม่ใช่ ASCII — สำเนาชั่วคราวก่อนแปลง)" -ForegroundColor DarkGray
  }

  $tmp = Join-Path $env:TEMP ("mlx_out_" + [Guid]::NewGuid().ToString('N').Substring(0,10) + ".txt")
  # ใช้ -raw (ลำดับการอ่านจริง) ไม่ใช่ -layout
  # เพราะตำราวิชาการมักจัดสองคอลัมน์ -layout จะเอาข้อความสองคอลัมน์มาต่อกันในบรรทัดเดียว
  # ทำให้ประโยคขาดและ RAG ค้นไม่เจอ
  & $exe -enc UTF-8 -raw -nopgbrk $srcPath $tmp 2>&1 | Out-Null
  if($tempPdf){ Remove-Item -LiteralPath $tempPdf -Force -ErrorAction SilentlyContinue }
  if(-not (Test-Path $tmp)){ Write-Host "        ล้มเหลว" -ForegroundColor Red; continue }

  $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
  Remove-Item -LiteralPath $tmp -Force
  $clean = Normalize-Thai $raw
  [IO.File]::WriteAllText($out,$clean,(New-Object Text.UTF8Encoding($false)))

  $secs=[math]::Round(((Get-Date)-$t0).TotalSeconds)
  $thai=([regex]::Matches($clean,'[฀-๿]')).Count
  $latin=([regex]::Matches($clean,'[A-Za-z]')).Count
  Write-Host ("        {0,6:N0} KB · ไทย {1,7:N0} / อังกฤษ {2,7:N0} ตัวอักษร · {3} วินาที" -f `
    ((Get-Item $out).Length/1KB), $thai, $latin, $secs) -ForegroundColor Green
}

Write-Host "`nผลลัพธ์: $OutDir" -ForegroundColor Cyan
Get-ChildItem $OutDir -Filter *.txt -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host ("  {0,-56} {1,8:N0} KB" -f $_.Name, ($_.Length/1KB)) }
