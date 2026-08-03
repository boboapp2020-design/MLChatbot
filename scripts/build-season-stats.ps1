#Requires -Version 5.1
<#
=====================================================================
 ML Expert AI — สรุปสถิติรายฤดูจาก Daily Report
---------------------------------------------------------------------
 Daily Report ของแต่ละฤดูเป็นไฟล์เดียวที่มีคอลัมน์ TO-DATE
 ซึ่งคือค่าสะสมตลอดฤดู — ดึงค่านั้นออกมาทำเป็นตารางเทียบข้ามฤดู

 หน้ารายงานวางเป็น 3 บล็อกเรียงกันในแนวนอน แต่ละบล็อกมีชุดคอลัมน์ของตัวเอง
 และ **ตำแหน่งคอลัมน์ไม่เหมือนกันทุกฤดู** — ฤดูเก่า (2014-15 ถึง 2021-23) ไม่มีคอลัมน์ THIS WEEK
 ทำให้ TO-DATE เลื่อนไปคนละตำแหน่งกับฤดูใหม่ ถ้า hardcode เลขคอลัมน์จะได้ค่าไม่ครบ
 จึงหาตำแหน่ง TO-DATE จากแถวหัวตารางก่อน แล้วไล่ย้อนซ้ายหา label ของแต่ละบล็อกเอง

   powershell -File scripts\build-season-stats.ps1
=====================================================================
#>
[CmdletBinding()]
param([string]$InDir = "", [string]$OutFile = "")

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'xlsx-lib.ps1')

if (-not $InDir)   { $InDir   = Join-Path $Root 'Support Document\expert โรงงาน\Daily Report' }
if (-not $OutFile) { $OutFile = Join-Path $Root 'Support Document\_text\สถิติการผลิตรายฤดู 12 ฤดู (Daily Report 2014-2026).txt' }

# ── ตัวชี้วัดที่ดึง — ชื่อต้องตรงกับ label ในรายงาน (เทียบแบบ contains) ──
# เรียงตามลำดับที่อยากให้ปรากฏในตาราง
$WANT = [ordered]@{
  'TONS CANE CRUSHED'      = 'อ้อยเข้าหีบ (ตัน)'
  'FIBER % CANE'           = 'Fiber %Cane'
  'POL % CANE'             = 'Pol %Cane'
  'C.C.S. OF FACTORY'      = 'CCS โรงงาน'
  '% BURNT CANE'           = 'อ้อยไฟไหม้ %'
  'OVERALL RECOVERY'       = 'Overall Recovery %'
  'TOTAL LOSSES'           = 'การสูญเสียรวม %'
  'LOSS IN BAGASSE'        = 'สูญเสียในชานอ้อย %'
  'LOSS IN FILTER CAKE'    = 'สูญเสียในกากตะกอน %'
  'LOSS IN FINAL MOLASSES' = 'สูญเสียในกากน้ำตาล %'
  'UNDETERMINED LOSSES'    = 'สูญเสียไม่ทราบสาเหตุ UDL %'
  'BHR'                    = 'BHR %'
  'EXTRACTION % POL IN CANE'   = 'Extraction %Pol in Cane'
  'FIRST MILL EXTRACTION % POL'= 'First Mill Extraction %Pol'
  'IMBIBITION % FIBER'     = 'Imbibition %Fiber'
  'POL % BAGASSE'          = 'Pol %Bagasse'
  'MOISTURE % BAGASSE'     = 'Moisture %Bagasse'
  'OVERALL TIME EFFICIENCY'= 'Time Efficiency %'
  'MECHANICAL EFFICIENCY'  = 'Mechanical Efficiency %'
  'TONS STEAM PRODUCED'    = 'ไอน้ำที่ผลิตได้ (ตัน)'
  '% CANE AS 96 POL.10 C.C.S.' = 'ผลผลิตน้ำตาล %Cane (96 Pol, 10 CCS)'
}

function Get-ToDateCols($rows) {
  # หาแถวหัวตารางที่มีคำว่า TO-DATE แล้วคืนตำแหน่งคอลัมน์ทั้งหมดที่เจอ
  for ($i = 0; $i -lt [Math]::Min(12, $rows.Count); $i++) {
    $cols = @()
    for ($c = 0; $c -lt $rows[$i].Count; $c++) {
      if (([string]$rows[$i][$c]).Trim() -eq 'TO-DATE') { $cols += $c }
    }
    if ($cols.Count -ge 1) { return $cols }
  }
  return @()
}

$files = Get-ChildItem $InDir -Filter 'Daily Report *.xlsx' -File | Sort-Object Name
if (-not $files) { Write-Error "ไม่พบไฟล์ Daily Report ใน $InDir" }

Write-Host "ไฟล์ที่พบ: $($files.Count)" -ForegroundColor Cyan
$seasons = [ordered]@{}

foreach ($f in $files) {
  $season = ($f.BaseName -replace '^Daily Report\s*','')
  Write-Host "  อ่าน $season ..." -NoNewline
  try { $rows = Read-XlsxRows -Path $f.FullName } catch { Write-Host " ล้มเหลว" -ForegroundColor Red; continue }

  $tdCols = Get-ToDateCols $rows
  if ($tdCols.Count -eq 0) { Write-Host " ไม่พบหัวตาราง TO-DATE" -ForegroundColor Yellow; continue }

  $vals = [ordered]@{}
  for ($i = 0; $i -lt $rows.Count; $i++) {
    foreach ($tc in $tdCols) {
      # label ของบล็อกนี้คือ "เซลล์ข้อความ" ตัวแรกเมื่อไล่ย้อนซ้ายจาก TO-DATE
      # ต้องข้ามเซลล์ที่เป็นตัวเลขทิ้ง เพราะระหว่าง label กับ TO-DATE มีคอลัมน์
      # TO-DAY / THIS WEEK / THIS PERIOD คั่นอยู่ ซึ่งมีตัวเลขเต็มไปหมด
      # ถ้าไม่ข้ามจะได้ตัวเลขมาเป็น label แล้วจับคู่ไม่ติดสักตัว
      $label = ''
      $num0 = 0.0
      for ($c = $tc - 1; $c -ge [Math]::Max(0, $tc - 10); $c--) {
        $t = ([string]$rows[$i][$c]).Trim()
        if (-not $t) { continue }
        if ([double]::TryParse($t, [ref]$num0)) { continue }
        $label = $t; break
      }
      if (-not $label) { continue }
      foreach ($k in $WANT.Keys) {
        # ต้องขึ้นต้นด้วยคีย์ เพื่อกันชนกับบรรทัดที่มีคำนี้อยู่กลางประโยค
        if ($label -like "$k*" -and -not $vals.Contains($k)) {
          $v = $rows[$i][$tc]
          if ($null -ne $v -and $v -ne '') { $vals[$k] = $v }
        }
      }
    }
  }
  $seasons[$season] = $vals
  Write-Host (" {0} ค่า" -f $vals.Count) -ForegroundColor Green
}

# ── เขียนผลลัพธ์ ────────────────────────────────────────────────────
$sb = New-Object Text.StringBuilder
function W($t) { [void]$sb.AppendLine($t) }

W 'สถิติการผลิตรายฤดู — บริษัท น้ำตาลมิตรลาว จำกัด'
W 'สรุปจากคอลัมน์ TO-DATE (ค่าสะสมตลอดฤดู) ของ Daily Processing Status Report รายฤดู'
W ("สร้างอัตโนมัติด้วย scripts\build-season-stats.ps1 เมื่อ {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
W ''
W 'ค่าทั้งหมดเป็นค่าสะสมถึงวันสุดท้ายที่บันทึกในไฟล์ของฤดูนั้น'
W 'ฤดูที่ยังไม่จบจะเป็นค่าสะสมถึงวันที่บันทึกล่าสุด ไม่ใช่ค่าปิดฤดู'
W 'ตัวเลขคัดจากไฟล์ต้นฉบับโดยตรง ไม่มีการคำนวณซ้ำหรือปัดเศษ นอกจากตัดทศนิยมให้อ่านง่าย'
W ''
W 'ข้อควรทราบเรื่องชื่อฤดู'
W 'ชื่อฤดูมาจากชื่อไฟล์ต้นฉบับ ไฟล์ฤดู 2022-23 ตั้งชื่อว่า "Daily Report 2021-23.xlsx"'
W 'ซึ่งน่าจะพิมพ์ผิด (ควรเป็น 2022-23) เพราะฤดู 2021-22 มีไฟล์ของตัวเองแยกอยู่แล้ว'
W 'เวลาอ้างถึงฤดูนี้ให้ระบุว่าเป็นฤดู 2022-23 และหมายเหตุว่าชื่อไฟล์ต้นฉบับเขียนไว้แบบนั้น'
W ''
W 'การตรวจสอบความถูกต้อง'
W 'อนุกรม UDL ที่ดึงได้ตรงกับอนุกรมที่ใช้ในโครงการวิเคราะห์การสูญเสียน้ำตาล (UDL_project) ทุกฤดู'
W 'ยกเว้นฤดู 2022-23 ที่ไฟล์ให้ 7.10 แต่โครงการ UDL ระบุ 7.13 — ต่างกัน 0.03 จุด'
W 'สาเหตุน่าจะมาจากวันตัดข้อมูลที่ต่างกัน ถ้าต้องใช้ตัวเลขนี้ในเชิงทางการให้ทวนกับไฟล์ต้นฉบับก่อน'
W ''

foreach ($k in $WANT.Keys) {
  $th = $WANT[$k]
  $line = @()
  foreach ($s in $seasons.Keys) {
    $v = $seasons[$s][$k]
    if ($null -eq $v -or $v -eq '') { continue }
    $num = 0.0
    if ([double]::TryParse([string]$v, [ref]$num)) {
      $fmt = if ([Math]::Abs($num) -ge 1000) { '{0:N0}' } else { '{0:N2}' }
      $line += ("{0} = {1}" -f $s, ($fmt -f $num))
    }
  }
  if ($line.Count -gt 0) {
    W ("{0} ({1})" -f $th, $k)
    W ('  ' + ($line -join ' · '))
    W ''
  }
}

# ── สรุปประเด็นเด่นเป็นภาษาไทย ────────────────────────────────────
# ตารางตัวเลขล้วนค้นเจอยาก เพราะขา n-gram ภาษาไทยไปเข้าเอกสารที่มีข้อความเยอะกว่า
# (ทดสอบแล้วคำถาม "ฤดูไหน UDL สูงสุด" ไปได้ตำราโรงจักรต้นกำลังแทน)
# จึงเขียนสรุปเป็นประโยคไทยไว้ด้วย ให้มีคำที่คนถามจริงใช้
function Best($key, $wantMax) {
  $best = $null; $bestS = ''
  foreach ($s in $seasons.Keys) {
    $v = $seasons[$s][$key]; $n = 0.0
    if (-not [double]::TryParse([string]$v, [ref]$n)) { continue }
    if ($null -eq $best -or ($wantMax -and $n -gt $best) -or (-not $wantMax -and $n -lt $best)) { $best = $n; $bestS = $s }
  }
  return @{ S = $bestS; V = $best }
}

W '── สรุปประเด็นเด่นจากสถิติ 12 ฤดู ──'
W 'ส่วนนี้เขียนขึ้นจากตัวเลขในตารางข้างบนโดยตรง ใช้ตอบคำถามที่ถามหาฤดูที่ดีที่สุดหรือแย่ที่สุด'
W ''
$u1 = Best 'UNDETERMINED LOSSES' $true
$u2 = Best 'UNDETERMINED LOSSES' $false
W ("การสูญเสียน้ำตาลที่ไม่ทราบสาเหตุ (UDL) สูงที่สุดคือฤดู {0} ที่ {1:N2}% และต่ำที่สุด (ดีที่สุด) คือฤดู {2} ที่ {3:N2}%" -f $u1.S, $u1.V, $u2.S, $u2.V)
$r1 = Best 'OVERALL RECOVERY' $true
$r2 = Best 'OVERALL RECOVERY' $false
W ("Overall Recovery สูงที่สุดคือฤดู {0} ที่ {1:N2}% และต่ำที่สุดคือฤดู {2} ที่ {3:N2}%" -f $r1.S, $r1.V, $r2.S, $r2.V)
$c1 = Best 'TONS CANE CRUSHED' $true
W ("ฤดูที่หีบอ้อยได้มากที่สุดคือฤดู {0} ที่ {1:N0} ตัน" -f $c1.S, $c1.V)
$b1 = Best '% BURNT CANE' $true
$b2 = Best '% BURNT CANE' $false
W ("อ้อยไฟไหม้สูงที่สุดคือฤดู {0} ที่ {1:N2}% และต่ำที่สุดคือฤดู {2} ที่ {3:N2}%" -f $b1.S, $b1.V, $b2.S, $b2.V)
$h1 = Best 'BHR' $true
$h2 = Best 'BHR' $false
W ("Boiling House Recovery (BHR) สูงที่สุดคือฤดู {0} ที่ {1:N2}% และต่ำที่สุดคือฤดู {2} ที่ {3:N2}%" -f $h1.S, $h1.V, $h2.S, $h2.V)
$t1 = Best 'OVERALL TIME EFFICIENCY' $true
$t2 = Best 'OVERALL TIME EFFICIENCY' $false
W ("Time Efficiency สูงที่สุดคือฤดู {0} ที่ {1:N2}% และต่ำที่สุดคือฤดู {2} ที่ {3:N2}%" -f $t1.S, $t1.V, $t2.S, $t2.V)
W ''
W 'คำถามที่เอกสารนี้ตอบได้ — ปีไหนผลผลิตดีที่สุด · ฤดูไหนน้ำตาลหายมากที่สุด'
W '· recovery ปีนี้เทียบปีที่แล้วเป็นอย่างไร · แนวโน้ม CCS และอ้อยไฟไหม้ย้อนหลัง 12 ปี'
W '· BHR และ Extraction ของโรงงานอยู่ระดับไหนเมื่อเทียบข้ามฤดู'
W '· เปรียบเทียบฤดูการผลิต ปีการผลิต ผลการดำเนินงานรายฤดู สถิติย้อนหลัง'
W ''

W '── วิธีใช้ ──'
W 'ใช้ตอบคำถามแนวเทียบฤดู เช่น "ปีนี้ recovery ดีขึ้นหรือแย่ลงกว่าปีที่แล้ว"'
W '"UDL สูงสุดฤดูไหน" "อ้อยไฟไหม้แนวโน้มเป็นอย่างไร"'
W 'เมื่ออ้างตัวเลขให้ระบุเสมอว่าเป็นค่าสะสม TO-DATE ของฤดูนั้น ไม่ใช่ค่ารายวัน'
W 'ถ้าผู้ใช้ต้องการค่ารายวันหรือรายกะ ต้องเปิดไฟล์รายวันของฤดูนั้นโดยตรง คลังยังไม่มีระดับรายวัน'

[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host ("`nเขียนแล้ว: {0}  ({1:N0} KB)" -f $OutFile, ((Get-Item $OutFile).Length/1KB)) -ForegroundColor Cyan
