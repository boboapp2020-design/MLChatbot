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
param([string]$SrcRoot = "", [string]$OutFile = "")

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'xlsx-lib.ps1')

if (-not $SrcRoot) { $SrcRoot = Join-Path $Root 'Support Document\expert โรงงาน' }
if (-not $OutFile) { $OutFile = Join-Path $Root 'Support Document\_text\สถิติหยุดหีบและระบบน้ำไฟฟ้า รายฤดู.txt' }

$sb = New-Object Text.StringBuilder
function W($t) { [void]$sb.AppendLine($t) }

W 'สถิติการหยุดหีบ และระบบน้ำ-ไฟฟ้า รายฤดู — บริษัท น้ำตาลมิตรลาว จำกัด'
W 'สรุปจากรายงานรายวันที่โรงงานบันทึกไว้ทุกวันตลอดฤดูการผลิต'
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

# ════════════ ส่วนที่ 2 — ระบบน้ำและไฟฟ้า ════════════
W '═══ ส่วนที่ 2 — ระบบน้ำและไฟฟ้า (Boiler / Turbine / เชื้อเพลิง) ═══'
W ''

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

  W ("ฤดู {0} — จากรายงาน {1} ฉบับ" -f $sd.Name, $files.Count)
  foreach ($k in $boilerWant.Keys) {
    if ($m.Contains($k)) { W ("  {0,-42} {1,14:N0}" -f $boilerWant[$k], $m[$k]) }
  }
  foreach ($k in $tgWant.Keys) {
    if ($m.Contains($k)) { W ("  {0,-42} {1,14:N0}" -f $tgWant[$k], $m[$k]) }
  }
  W ''
  Write-Host " เสร็จ" -ForegroundColor Green
}

W '── วิธีใช้ ──'
W 'ส่วนที่ 1 ใช้ตอบเรื่องเวลาหยุดหีบและแผนกที่เป็นต้นเหตุบ่อยที่สุด'
W 'ใช้คู่กับ "สถิติการผลิตรายฤดู 12 ฤดู" เพื่อโยงชั่วโมงหยุดกับการสูญเสียน้ำตาล (UDL)'
W 'ส่วนที่ 2 ค่าไอน้ำและน้ำดิบเป็นค่าสะสมของฤดู ส่วนค่าไฟฟ้าเป็นค่าสูงสุดรายวันที่พบในฤดู'
W 'เพราะรายงานบล็อกไฟฟ้าไม่มีคอลัมน์ค่าสะสมแยกไว้ให้'
W 'ถ้าต้องการค่ารายวันของวันใดวันหนึ่ง ต้องเปิดไฟล์รายงานของวันนั้นโดยตรง'

[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host ("`nเขียนแล้ว: {0}  ({1:N0} KB)" -f $OutFile, ((Get-Item $OutFile).Length/1KB)) -ForegroundColor Cyan
