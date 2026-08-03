#Requires -Version 5.1
<#
=====================================================================
 ML Expert AI — สรุปรายงานรายวัน 2 ชุด เป็นสถิติรายฤดู
---------------------------------------------------------------------
 โฟลเดอร์ Support Document\expert โรงงาน\<ฤดู>\ มีรายงานรายวันหลายร้อยไฟล์ต่อฤดู
   รายงานหยุดหีบ (Stoptime YYMMDD.xlsx)   — ชั่วโมงหยุดแยกประเภท + บันทึกเหตุการณ์รายครั้ง
   รายงานน้ำและไฟฟ้า (Water YYMMDD.xlsx)   — ไอน้ำ ไฟฟ้า เชื้อเพลิง คุณภาพน้ำ
   (รายงานผลวิเคราะห์น้ำตาลรายวันซ้ำกับ Daily Report รายฤดู จึงไม่ทำซ้ำที่นี่)

 บทเรียนตอนเขียนสคริปต์นี้ — อย่าหยิบ "ไฟล์ล่าสุดตามชื่อ" มาเป็นค่าสะสมของฤดู
 เพราะไฟล์ท้ายฤดูบางไฟล์เป็นแบบฟอร์มเปล่าหรือเป็นวันที่หยุดหีบแล้ว ค่า TO-DATE จึงเป็น 0
 วิธีที่ถูกคือกวาดทุกไฟล์แล้วเอา **ค่าสูงสุด** ของแต่ละตัวชี้วัด เพราะค่าสะสมมีแต่เพิ่มขึ้น

 ตำแหน่งคอลัมน์ (ยืนยันจากไฟล์จริงแล้ว)
   Stoptime : label=col0 · TO-DAY=col6/7 · PERIOD=col8/9 · TO-DATE=col10/11 · TARGET=col12/13
              ตารางสาเหตุอยู่ใต้เซลล์ "สาเหตุการหยุดหีบ" — ช่วงเวลา=col0 แผนก=col4
   Water    : บล็อก BOILER label=col0 Today=col2 Todate=col4
              บล็อก TG     label=col7 Today=col11 (ไม่มีคอลัมน์ Todate แยกในบล็อกนี้)

   powershell -File scripts\build-daily-stats.ps1
=====================================================================
#>
[CmdletBinding()]
param([string]$SrcRoot = "", [string]$OutFile = "", [string]$OutFile2 = "")

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'xlsx-lib.ps1')

if (-not $SrcRoot)  { $SrcRoot  = Join-Path $Root 'Support Document\expert โรงงาน' }
if (-not $OutFile)  { $OutFile  = Join-Path $Root 'Support Document\_text\สถิติการหยุดหีบ รายฤดู.txt' }
if (-not $OutFile2) { $OutFile2 = Join-Path $Root 'Support Document\_text\สถิติหม้อไอน้ำและระบบไฟฟ้า รายฤดู.txt' }

# เขียนสองไฟล์แยกกัน เพราะเนื้อหาเป็นของคนละห้อง
# การหยุดหีบเป็นเรื่องของห้องโรงงาน ส่วนหม้อไอน้ำและไฟฟ้าเป็นของห้องโรงไฟฟ้าชีวมวล
# รอบแรกเขียนรวมไฟล์เดียวแล้วจัดเข้าห้องโรงงานทั้งก้อน ผลคือคำถาม "หม้อไอน้ำมีกี่ลูก"
# ในห้องโรงไฟฟ้าไปได้ตำราวิศวกรรมโรงจักรแทนข้อมูลจริงของโรงงาน
$sb  = New-Object Text.StringBuilder
$sb2 = New-Object Text.StringBuilder
function W($t)  { [void]$sb.AppendLine($t) }
function W2($t) { [void]$sb2.AppendLine($t) }

W 'สถิติการหยุดหีบ รายฤดู — บริษัท น้ำตาลมิตรลาว จำกัด'
W 'สรุปจากรายงานหยุดหีบ (Stoptime) ที่โรงงานบันทึกไว้ทุกวันตลอดฤดูการผลิต'
W ("สร้างอัตโนมัติด้วย scripts\build-daily-stats.ps1 เมื่อ {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
W ''
W 'วิธีคำนวณ: ค่าสะสมของฤดูคือค่าสูงสุดที่พบจากรายงานทุกฉบับในฤดูนั้น'
W '(ไม่ใช้ไฟล์วันสุดท้าย เพราะบางฤดูไฟล์ท้ายเป็นวันที่หยุดหีบแล้ว ค่าสะสมจะกลายเป็น 0)'
W 'ส่วนสาเหตุการหยุดหีบนับเป็นจำนวนครั้งที่บันทึกไว้ ไม่ใช่จำนวนชั่วโมง'
W ''

$seasonDirs = Get-ChildItem $SrcRoot -Directory | Where-Object { $_.Name -match '^\d\d-\d\d$' } | Sort-Object Name
Write-Host "ฤดูที่พบ: $($seasonDirs.Name -join ', ')" -ForegroundColor Cyan

function Max-Metric($store, $key, $val) {
  $n = 0.0
  if (-not [double]::TryParse([string]$val, [ref]$n)) { return }
  if (-not $store.Contains($key) -or $n -gt $store[$key]) { $store[$key] = $n }
}

# ════════════ ส่วนที่ 1 — การหยุดหีบ ════════════
W '═══ ส่วนที่ 1 — การหยุดหีบ (Stopped Time) ═══'
W ''

$stopWant = [ordered]@{
  'HOURS OPEN'                               = 'ชั่วโมงเปิดหีบ'
  'HOURS SCHEDULE STOPS'                     = 'หยุดตามแผน'
  'HOURS STOPPED NO CANE'                    = 'หยุดเพราะไม่มีอ้อย'
  'HOURS AVAILABLE'                          = 'ชั่วโมงที่พร้อมเดินเครื่อง'
  'TOTAL HOURS STOPPED PRODUCTION'           = 'หยุดผลิตรวม'
  'TOTAL HOUR STOPPED MECHANICAL/ELECTRICAL' = 'หยุดจากเครื่องกล/ไฟฟ้า'
  'TOTAL HOUSE STOPPED BOILING HOUSE'        = 'หยุดจากหม้อต้ม-เคี่ยว-ปั่น'
  'TOTAL HOUSE STOPPED OTHER'                = 'หยุดจากสาเหตุอื่น'
  'HOURS ACTUAL CRUSHING'                    = 'ชั่วโมงหีบจริง'
}

foreach ($sd in $seasonDirs) {
  $dir = Join-Path $sd.FullName 'รายงานหยุดหีบ'
  if (-not (Test-Path $dir)) { continue }
  $files = Get-ChildItem $dir -Filter '*.xlsx' -File | Sort-Object Name
  if (-not $files) { continue }
  Write-Host ("  {0} หยุดหีบ {1} ไฟล์ ..." -f $sd.Name, $files.Count) -NoNewline

  $m = @{}; $byDept = @{}; $events = 0
  foreach ($f in $files) {
    try { $r = Read-XlsxRows -Path $f.FullName } catch { continue }
    $inCause = $false
    for ($i = 0; $i -lt $r.Count; $i++) {
      $lab = ([string]$r[$i][0]).Trim()
      if ($lab -like '*สาเหตุการหยุดหีบ*') { $inCause = $true; continue }
      if ($inCause) {
        $dept = ([string]$r[$i][4]).Trim()
        # กรองแถวว่างที่เก็บเป็นเลข 0 และแถวหัวตาราง ไม่งั้น "0" จะกลายเป็นแผนกอันดับหนึ่ง
        $dz = 0.0
        if ($dept -and $dept -ne 'เนื่องจากแผนก' -and -not [double]::TryParse($dept, [ref]$dz)) {
          $byDept[$dept] = 1 + $byDept[$dept]; $events++
        }
        continue
      }
      foreach ($k in $stopWant.Keys) {
        if ($lab -like "$k*") { Max-Metric $m $k $r[$i][10] }
      }
    }
  }

  W ("ฤดู {0} — จากรายงาน {1} ฉบับ" -f $sd.Name, $files.Count)
  foreach ($k in $stopWant.Keys) {
    if ($m.Contains($k)) { W ("  {0,-30} {1,10:N2} ชม." -f $stopWant[$k], $m[$k]) }
  }
  if ($m.Contains('HOURS AVAILABLE') -and $m.Contains('HOURS ACTUAL CRUSHING') -and $m['HOURS AVAILABLE'] -gt 0) {
    W ("  {0,-30} {1,10:N2} %" -f 'Time Efficiency คำนวณได้', ($m['HOURS ACTUAL CRUSHING']*100/$m['HOURS AVAILABLE']))
  }
  if ($events -gt 0) {
    W ("  สาเหตุการหยุดหีบที่บันทึกไว้ {0} ครั้ง แยกตามแผนกต้นเหตุ" -f $events)
    $byDept.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 | ForEach-Object {
      W ("    {0,-26} {1,4} ครั้ง  ({2,5:N1}%)" -f $_.Key, $_.Value, ($_.Value*100/$events))
    }
  }
  W ''
  Write-Host " เสร็จ" -ForegroundColor Green
}

# ════════════ ไฟล์ที่ 2 — หม้อไอน้ำและระบบไฟฟ้า (ห้องโรงไฟฟ้าชีวมวล) ════════════
W2 'สถิติหม้อไอน้ำและระบบผลิตไฟฟ้า รายฤดู — บริษัท น้ำตาลมิตรลาว จำกัด'
W2 'โรงไฟฟ้าชีวมวลใช้ชานอ้อยเป็นเชื้อเพลิง ผลิตไอน้ำและไฟฟ้าป้อนกระบวนการผลิตน้ำตาล'
W2 'และขายไฟส่วนเกินให้ EDL (รัฐวิสาหกิจไฟฟ้าลาว)'
W2 'สรุปจากรายงานน้ำและไฟฟ้า (Water) ที่โรงงานบันทึกไว้ทุกวันตลอดฤดูการผลิต'
W2 ("สร้างอัตโนมัติด้วย scripts\build-daily-stats.ps1 เมื่อ {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
W2 ''
W2 'โรงงานมีหม้อไอน้ำ 3 ลูก (Boiler No.1 / No.2 / No.3) เดินคู่กันตลอดฤดูหีบ'
W2 'รายงานแต่ละวันวัดไอน้ำที่ผลิตได้รายลูกและรวม อัตราไหลเฉลี่ย ไอน้ำต่อชานอ้อย'
W2 'ความชื้นเชื้อเพลิงก่อนเข้าเตา น้ำดิบที่ใช้ ไฟฟ้าที่ผลิตได้ ที่ใช้ในกระบวนการ และที่ขายให้ EDL'
W2 'พร้อมคุณภาพน้ำ 10 จุด (Condenser เข้า-ออก · Feed Water 1-2 · Boiler Water 1-3'
W2 '· Soft Water · Raw Water · Cooling Tower) วัด pH TDS Hardness Chloride Alkalinity และ Sugar Content'
W2 ''
W2 'ค่าควบคุมที่ระบุไว้ในรายงาน: Sugar Content ในน้ำ Condenser < 200 ppm'
W2 '· คอนเดนเสท EVAP1 < 50 ppm และ EVAP2 < 100 ppm · น้ำร่องระบาย < 300 ppm'
W2 'หมายเหตุที่โรงงานเขียนไว้เอง: TDS สูงควรดู Blow Down และคุณภาพน้ำ Feed'
W2 ''
W2 'วิธีคำนวณ: ค่าสะสมของฤดูคือค่าสูงสุดที่พบจากรายงานทุกฉบับในฤดูนั้น'
W2 ''

# บล็อก BOILER (label col0 · Todate col4)
$boilerWant = [ordered]@{
  '*Steam Produced (Bioler No.1-3)*' = 'ไอน้ำที่ผลิตได้ทั้ง 3 ลูก (ตัน)'
  '*Steam Produced ( Bioler No.1)*'  = 'ไอน้ำจาก Boiler No.1 (ตัน)'
  '*Steam Produced ( Bioler No.2)*'  = 'ไอน้ำจาก Boiler No.2 (ตัน)'
  '*Steam Produced ( Bioler No.3)*'  = 'ไอน้ำจาก Boiler No.3 (ตัน)'
  'Raw Water Total Used*'            = 'น้ำดิบที่ใช้รวม (ลบ.ม.)'
}
# บล็อก TG (label col7 · ค่าที่ col11 เป็นค่าของวัน ไม่ใช่สะสม จึงรายงานเป็น "สูงสุดที่พบในฤดู")
$tgWant = [ordered]@{
  'Electrical Unit Generated*' = 'ไฟฟ้าที่ผลิตได้สูงสุดในวัน (kWh)'
  '- Used in Process*'         = 'ไฟฟ้าที่ใช้ในกระบวนการสูงสุดในวัน (kWh)'
  'KWH. FOR EDL*'              = 'ไฟฟ้าที่ขายให้ EDL สูงสุดในวัน (kWh)'
}

foreach ($sd in $seasonDirs) {
  $dir = Join-Path $sd.FullName 'รายงานน้ำและไฟฟ้า'
  if (-not (Test-Path $dir)) { continue }
  $files = Get-ChildItem $dir -Filter '*.xlsx' -File | Sort-Object Name
  if (-not $files) { continue }
  Write-Host ("  {0} น้ำ-ไฟฟ้า {1} ไฟล์ ..." -f $sd.Name, $files.Count) -NoNewline

  $m = @{}
  foreach ($f in $files) {
    try { $r = Read-XlsxRows -Path $f.FullName } catch { continue }
    for ($i = 0; $i -lt [Math]::Min(30, $r.Count); $i++) {
      $l0 = ([string]$r[$i][0]).Trim()
      foreach ($k in $boilerWant.Keys) { if ($l0 -like $k) { Max-Metric $m $k $r[$i][4] } }
      $l7 = ([string]$r[$i][7]).Trim()
      foreach ($k in $tgWant.Keys) { if ($l7 -like $k) { Max-Metric $m $k $r[$i][11] } }
    }
  }

  W2 ("ฤดู {0} — จากรายงาน {1} ฉบับ" -f $sd.Name, $files.Count)
  foreach ($k in $boilerWant.Keys) {
    if ($m.Contains($k)) { W2 ("  {0,-42} {1,14:N0}" -f $boilerWant[$k], $m[$k]) }
  }
  foreach ($k in $tgWant.Keys) {
    if ($m.Contains($k)) { W2 ("  {0,-42} {1,14:N0}" -f $tgWant[$k], $m[$k]) }
  }
  W2 ''
  Write-Host " เสร็จ" -ForegroundColor Green
}

W '── วิธีใช้ ──'
W 'ใช้ตอบเรื่องเวลาหยุดหีบและแผนกที่เป็นต้นเหตุบ่อยที่สุด'
W 'ใช้คู่กับ "สถิติการผลิตรายฤดู 12 ฤดู" เพื่อโยงชั่วโมงหยุดกับการสูญเสียน้ำตาล (UDL)'
W 'ตัวเลขเป็นค่าสะสมทั้งฤดู ไม่ใช่ค่ารายวัน ถ้าต้องการค่าของวันใดวันหนึ่งต้องเปิดไฟล์รายงานวันนั้นโดยตรง'
W 'ข้อมูลหม้อไอน้ำและไฟฟ้าแยกอยู่อีกไฟล์ (สถิติหม้อไอน้ำและระบบไฟฟ้า รายฤดู)'

W2 '── วิธีใช้ ──'
W2 'ค่าไอน้ำและน้ำดิบเป็นค่าสะสมของฤดู ส่วนค่าไฟฟ้าเป็นค่าสูงสุดรายวันที่พบในฤดู'
W2 'เพราะรายงานบล็อกไฟฟ้าไม่มีคอลัมน์ค่าสะสมแยกไว้ให้'
W2 'ถ้าต้องการค่ารายวันของวันใดวันหนึ่ง ต้องเปิดไฟล์รายงานของวันนั้นโดยตรง'
W2 'คำถามที่ไฟล์นี้ตอบได้ — โรงงานมีหม้อไอน้ำกี่ลูก · ผลิตไอน้ำได้เท่าไรต่อฤดู'
W2 '· ไอน้ำต่อชานอ้อยเท่าไร · ความชื้นเชื้อเพลิงเป็นอย่างไร · ขายไฟให้ EDL ได้เท่าไร'
W2 '· ใช้น้ำดิบเท่าไร · เทียบประสิทธิภาพหม้อไอน้ำข้ามฤดู'

[IO.File]::WriteAllText($OutFile,  $sb.ToString(),  (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($OutFile2, $sb2.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host ("`nเขียนแล้ว: {0}  ({1:N0} KB)" -f $OutFile,  ((Get-Item $OutFile).Length/1KB))  -ForegroundColor Cyan
Write-Host ("เขียนแล้ว: {0}  ({1:N0} KB)"   -f $OutFile2, ((Get-Item $OutFile2).Length/1KB)) -ForegroundColor Cyan
