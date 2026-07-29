<#
=====================================================================
 ML Expert AI — Knowledge Base Builder
---------------------------------------------------------------------
 อ่านสกิลที่ติดตั้งอยู่แล้ว -> ตัดเป็น chunk -> จัดเข้าโมดูล -> เขียนออก 2 รูปแบบ

   1) kb/chunks.jsonl                     ใช้กับ demo ในเบราว์เซอร์ (ไม่ต้องมี Supabase)
   2) supabase/migrations/003_seed_kb.sql ใช้นำเข้า Supabase

 วิธีใช้:
   powershell -ExecutionPolicy Bypass -File scripts\build-kb.ps1
   powershell -ExecutionPolicy Bypass -File scripts\build-kb.ps1 -SkillsRoot "D:\my-skills"
=====================================================================
#>

[CmdletBinding()]
param(
  [string] $SkillsRoot = "",
  [string] $OutRoot    = "",
  [int]    $MaxChars   = 1800,   # ขนาด chunk สูงสุด (ตัวอักษร)
  [int]    $MinChars   = 220,    # chunk เล็กกว่านี้จะถูกผนวกกับอันถัดไป
  [int]    $Overlap    = 180,    # ตัวอักษรที่ซ้อนทับระหว่าง chunk
  [bool]   $IncludeRein = $true  # รวม Peter Rein ฉบับเต็ม (OCR คุณภาพต่ำ — วัดผลก่อนใช้จริง)
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

# ── ระบุตำแหน่งโปรเจกต์ ──────────────────────────────────────────────
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutRoot) { $OutRoot = $ProjectRoot }

# ── ค้นหาโฟลเดอร์สกิลอัตโนมัติ ────────────────────────────────────────
if (-not $SkillsRoot) {
  $candidates = @(
    "$env:APPDATA\Claude\local-agent-mode-sessions\skills-plugin",
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.claude\plugins"
  )
  foreach ($base in $candidates) {
    if (-not (Test-Path $base)) { continue }
    $hit = Get-ChildItem $base -Recurse -Directory -Filter 'sugar-brain' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $SkillsRoot = Split-Path -Parent $hit.FullName; break }
  }
}

if (-not $SkillsRoot -or -not (Test-Path $SkillsRoot)) {
  Write-Error "หาโฟลเดอร์สกิลไม่พบ — ระบุเองด้วย -SkillsRoot 'C:\path\to\skills'"
}
Write-Host "Skills root : $SkillsRoot" -ForegroundColor Cyan
Write-Host "Project root: $ProjectRoot" -ForegroundColor Cyan


# =====================================================================
#  แผนที่ไฟล์ -> โมดูลตั้งต้น  (chunk แต่ละอันยังถูกจัดใหม่ด้วย keyword ได้)
# =====================================================================
$FileMap = @(
  @{ Path='cane-brain\SKILL.md';                              Module='cane';        Type='BOOK';     Title='คู่มือผู้เชี่ยวชาญอ้อย — หลักการวินิจฉัยภาคสนาม'; Code='CANE-GUIDE' }
  @{ Path='cane-brain\references\agronomy.md';                Module='cane';        Type='BOOK';     Title='พืชไร่อ้อย — พันธุ์ ดิน ปุ๋ย น้ำ การจัดการตอ';    Code='CANE-AGRO' }
  @{ Path='cane-brain\references\diseases.md';                Module='cane';        Type='BOOK';     Title='โรคอ้อย — การวินิจฉัยและการจัดการ';              Code='CANE-DIS' }
  @{ Path='cane-brain\references\pests-weeds.md';             Module='cane';        Type='BOOK';     Title='แมลงศัตรูอ้อยและวัชพืช';                        Code='CANE-PEST' }
  @{ Path='cane-brain\references\downstream-economics.md';    Module='cane';        Type='BOOK';     Title='ความสุกแก่ CCS การเก็บเกี่ยว และเศรษฐศาสตร์อ้อย'; Code='CANE-ECON' }

  @{ Path='sugar-brain\SKILL.md';                             Module='dashboard';   Type='BOOK';     Title='กรอบการวิเคราะห์กระบวนการผลิตน้ำตาล';            Code='SUG-FRAME' }
  # ไฟล์นี้ครอบคลุมทุกสถานีในโรงงาน จึงไม่ให้ bias กับโมดูลใด — ปล่อยให้ keyword ตัดสินรายหัวข้อ
  @{ Path='sugar-brain\references\peter-rein-knowledge.md';   Module='crushing';    Type='BOOK';     Title='Peter Rein — Cane Sugar Engineering';           Code='REIN-2007'; NoBias=$true }
  @{ Path='sugar-brain\references\benchmarks.md';             Module='dashboard';   Type='STANDARD'; Title='ค่าเปรียบเทียบมาตรฐานระดับโลก (Benchmarks)';      Code='BENCH-WC' }
  @{ Path='sugar-brain\references\production-data-guide.md';  Module='dashboard';   Type='MANUAL';   Title='คู่มือข้อมูลการผลิตและ KPI';                      Code='PROD-DATA' }
  @{ Path='sugar-brain\references\smart-factory.md';          Module='dashboard';   Type='MANUAL';   Title='Smart Factory และการวิเคราะห์เชิงคาดการณ์';       Code='SMART-FAC' }

  @{ Path='steam-brain\SKILL.md';                             Module='powerplant';  Type='BOOK';     Title='ระบบไอน้ำและพลังงานในโรงงานน้ำตาล';              Code='STM-FRAME' }
  @{ Path='steam-brain\references\boiler.md';                 Module='powerplant';  Type='MANUAL';   Title='หม้อไอน้ำ — หลักการและการเดินเครื่อง';           Code='STM-BOIL' }
  @{ Path='steam-brain\references\bagasse-power-plant.md';    Module='powerplant';  Type='MANUAL';   Title='โรงไฟฟ้าชานอ้อย';                               Code='STM-BAG' }
  @{ Path='steam-brain\references\building-boiler-maintenance.md'; Module='powerplant'; Type='MANUAL'; Title='การบำรุงรักษาหม้อไอน้ำ';                     Code='STM-MAINT' }
  @{ Path='steam-brain\references\water-treatment.md';        Module='powerplant';  Type='MANUAL';   Title='การปรับสภาพน้ำสำหรับหม้อไอน้ำ';                  Code='STM-WATER' }
  @{ Path='steam-brain\references\turbine-cogen.md';          Module='powerplant';  Type='MANUAL';   Title='กังหันไอน้ำและระบบผลิตไฟฟ้าร่วม';                Code='STM-TURB' }
  @{ Path='steam-brain\references\power-plant-cycles.md';     Module='powerplant';  Type='BOOK';     Title='วัฏจักรโรงไฟฟ้าไอน้ำ';                          Code='STM-CYCLE' }
  @{ Path='steam-brain\references\safety-law-inspection.md';  Module='safety';      Type='STANDARD'; Title='ความปลอดภัยและการตรวจสอบตามกฎหมาย';              Code='STM-SAFE' }
  @{ Path='steam-brain\references\sugar-factory-steam.md';    Module='evaporation'; Type='MANUAL';   Title='สมดุลไอน้ำในโรงงานน้ำตาล';                       Code='STM-SUG' }
  @{ Path='steam-brain\references\condensate-flash.md';       Module='evaporation'; Type='MANUAL';   Title='คอนเดนเสทและไอแฟลช';                            Code='STM-COND' }
  @{ Path='steam-brain\references\distribution-traps.md';     Module='evaporation'; Type='MANUAL';   Title='ระบบจ่ายไอน้ำและกับดักไอน้ำ';                    Code='STM-TRAP' }
  @{ Path='steam-brain\references\calculations.md';           Module='evaporation'; Type='MANUAL';   Title='สูตรคำนวณระบบไอน้ำ';                            Code='STM-CALC' }

  # สกิล HSE — ห้องความปลอดภัยเดิมมีความรู้ของตัวเองแค่ 28 ท่อน และยืมมาจากสกิลอื่นเกือบหมด
  @{ Path='hse-brain\SKILL.md';                               Module='safety';      Type='BOOK';     Title='กรอบงานความปลอดภัย อาชีวอนามัย และสิ่งแวดล้อม';  Code='HSE-FRAME' }
  @{ Path='hse-brain\references\sector-sugar-biomass.md';     Module='safety';      Type='MANUAL';   Title='ความปลอดภัยโรงงานน้ำตาลและโรงไฟฟ้าชานอ้อย';      Code='HSE-SUGAR' }
  @{ Path='hse-brain\references\thai-law.md';                 Module='safety';      Type='STANDARD'; Title='ทะเบียนกฎหมายความปลอดภัยไทย';                    Code='HSE-LAW' }
  @{ Path='hse-brain\references\high-risk-work.md';           Module='safety';      Type='MANUAL';   Title='งานเสี่ยงสูง ใบอนุญาตทำงาน และ LOTO';            Code='HSE-PTW' }
  @{ Path='hse-brain\references\risk-methods.md';             Module='safety';      Type='MANUAL';   Title='วิธีประเมินความเสี่ยง (JSA/HAZID/HAZOP)';        Code='HSE-RISK' }
  @{ Path='hse-brain\references\incident-rca.md';             Module='safety';      Type='MANUAL';   Title='การสอบสวนอุบัติเหตุและหาสาเหตุราก';              Code='HSE-RCA' }
  @{ Path='hse-brain\references\hygiene-health.md';           Module='safety';      Type='MANUAL';   Title='สุขศาสตร์อุตสาหกรรมและอาชีวอนามัย';              Code='HSE-HYG' }
  @{ Path='hse-brain\references\templates.md';                Module='safety';      Type='FAQ';      Title='แม่แบบเอกสาร HSE';                              Code='HSE-TMPL' }
  @{ Path='hse-brain\references\sector-construction.md';      Module='safety';      Type='MANUAL';   Title='ความปลอดภัยงานก่อสร้างและผู้รับเหมา';            Code='HSE-CONS' }
  # แผนที่มาตรฐานสากลครอบคลุม ISO ทั้งตระกูล ให้ไปอยู่ห้องคุณภาพ&มาตรฐานซึ่งอ่อนที่สุด
  @{ Path='hse-brain\references\standards-map.md';            Module='foodsafety';  Type='STANDARD'; Title='แผนที่มาตรฐานสากล (ISO และมาตรฐานระบบจัดการ)';   Code='HSE-STD' }

  # สกิลบำบัดน้ำเสีย — ห้องนี้เดิมมีความรู้ของตัวเองแค่ 15 ท่อน อ่อนที่สุดอันดับต้นๆ
  @{ Path='wastewater-expert\SKILL.md';                       Module='etreatment';  Type='BOOK';     Title='กรอบการวินิจฉัยระบบบำบัดน้ำเสีย';                Code='WW-FRAME' }
  @{ Path='wastewater-expert\references\diagnostics.md';      Module='etreatment';  Type='MANUAL';   Title='ตารางวินิจฉัยปัญหาระบบบำบัดน้ำเสีย (ตามอาการ)';  Code='WW-DIAG' }
  @{ Path='wastewater-expert\references\thai-regulations.md'; Module='etreatment';  Type='STANDARD'; Title='กฎหมายและมาตรฐานสิ่งแวดล้อมไทย';                 Code='WW-LAW' }
  @{ Path='wastewater-expert\references\sugar-wastewater.md'; Module='etreatment';  Type='BOOK';     Title='น้ำเสียโรงงานน้ำตาล — แหล่งกำเนิดและลักษณะ';     Code='WW-SUGAR' }
  @{ Path='wastewater-expert\references\calculations.md';     Module='etreatment';  Type='MANUAL';   Title='สูตรคำนวณวิศวกรรมน้ำเสีย';                       Code='WW-CALC' }
  @{ Path='wastewater-expert\references\plant-baseline.md';   Module='etreatment';  Type='MANUAL';   Title='ระบบรายงานคุณภาพน้ำของโรงงานน้ำตาลไทย';          Code='WW-BASE' }
  @{ Path='wastewater-expert\references\authoritative-sources.md'; Module='etreatment'; Type='BOOK'; Title='แหล่งอ้างอิงมาตรฐานวิศวกรรมสิ่งแวดล้อม';       Code='WW-REF' }

  @{ Path='sugar-qc-brain\SKILL.md';                          Module='quality';     Type='BOOK';     Title='กรอบการวินิจฉัยคุณภาพน้ำตาล';                    Code='QC-FRAME' }
  @{ Path='sugar-qc-brain\references\parameters-and-specs.md';Module='quality';     Type='STANDARD'; Title='พารามิเตอร์คุณภาพและเกณฑ์สเปก (ICUMSA/มอก.56)';  Code='QC-SPEC' }
  @{ Path='sugar-qc-brain\references\diagnostic-decision-tree.md'; Module='quality'; Type='MANUAL';  Title='Decision Tree วินิจฉัยผลวิเคราะห์';              Code='QC-TREE' }
  @{ Path='sugar-qc-brain\references\standards-and-training.md';   Module='quality'; Type='STANDARD'; Title='มาตรฐานและวิธีวิเคราะห์';                      Code='QC-STD' }
  @{ Path='sugar-qc-brain\references\cheat-sheet.md';         Module='quality';     Type='FAQ';      Title='สรุปค่ามาตรฐานและ pattern วินิจฉัย';             Code='QC-CHEAT' }

  # สกิลจัดซื้อ — ห้องจัดซื้อ/คลังเดิมมีความรู้ของตัวเองแค่ 14 ท่อน ต้องยืมจากคนอื่นทุกคำถาม
  @{ Path='procurement-management\SKILL.md';                  Module='warehouse';   Type='BOOK';     Title='งานจัดซื้อ PR-PO และการบริหารผู้ขาย';            Code='PROC-FRAME' }

  @{ Path='motor-expert\SKILL.md';                            Module='maintenance'; Type='BOOK';     Title='กรอบการวินิจฉัยมอเตอร์และระบบไฟฟ้า';             Code='MTR-FRAME' }
  @{ Path='motor-expert\references\failure-modes.md';         Module='maintenance'; Type='MANUAL';   Title='รูปแบบความเสียหายของมอเตอร์';                    Code='MTR-FAIL' }
  @{ Path='motor-expert\references\standards-thresholds.md';  Module='maintenance'; Type='STANDARD'; Title='เกณฑ์มาตรฐานการสั่นและฉนวน (ISO/NEMA/IEEE)';     Code='MTR-STD' }
  @{ Path='motor-expert\references\transformer-power-supply.md'; Module='maintenance'; Type='MANUAL'; Title='หม้อแปลงและระบบจ่ายไฟ';                       Code='MTR-TRF' }
  @{ Path='motor-expert\references\training-data-guide.md';   Module='maintenance'; Type='MANUAL';   Title='ข้อมูลสำหรับวิเคราะห์เชิงคาดการณ์';              Code='MTR-DATA' }
)


# =====================================================================
#  คำสำคัญสำหรับจัด chunk เข้าโมดูล  (ใช้ทับ default เมื่อคะแนนชนะชัดเจน)
# =====================================================================
$ModuleKeywords = @{
  'cane'          = @('อ้อย','พันธุ์','ปลูก','ไว้ตอ','ตอ','ปุ๋ย','ดิน','โรค','แมลง','วัชพืช','แปลง','ไร่','เก็บเกี่ยว','ratoon','variety','soil','fertilizer','disease','pest','yield','harvest','CCS','ความสุกแก่')
  'crushing'      = @('ลูกหีบ','หีบ','mill','milling','tandem','shredder','knife','ใบมีด','imbibition','น้ำอิ่ม','extraction','bagasse','ชานอ้อย','fiber','preparation index','PI','roll','hydraulic','cane carrier','การเตรียมอ้อย')
  'clarification' = @('clarifier','clarification','ทำใส','ปูน','lime','liming','pH','flocculant','mud','ตะกอน','filter press','sulphitation','defecation','turbidity','mixed juice','น้ำอ้อยรวม','juice heater','settling')
  'evaporation'   = @('evaporator','evaporation','ระเหย','multiple effect','steam economy','vapour','vapor bleeding','scale','ตะกรัน','condensate','คอนเดนเสท','BPE','boiling point elevation','syrup','ไซรัป','heat transfer','HTC','steam trap','กับดักไอน้ำ','flash')
  'panboiling'    = @('vacuum pan','หม้อเคี่ยว','เคี่ยว','strike','seed','graining','crystal','ผลึก','supersaturation','false grain','massecuite','mother liquor','crystallizer','crystallization','การตกผลึก','exhaustion')
  'centrifugal'   = @('centrifugal','ปั่น','เครื่องปั่น','basket','ตะแกรง','screen','wash water','น้ำล้าง','purging','molasses','กากน้ำตาล','crystal breakage','spinning','cycle time','affination')
  'quality'       = @('ICUMSA','Pol','Brix','Purity','ความบริสุทธิ์','สี','color','ash','เถ้า','moisture','ความชื้น','reducing sugar','conductivity','มอก','spec','สเปก','dextran','starch','SO2','แล็บ','laboratory','particle size','grain size','caking')
  'powerplant'    = @('boiler','หม้อไอน้ำ','turbine','กังหัน','generator','superheater','economizer','deaerator','feed water','น้ำป้อน','blowdown','excess air','ไอเสีย','flue gas','GCV','cogeneration','trip','safety valve','condenser','โรงไฟฟ้า')
  'maintenance'   = @('bearing','แบริ่ง','vibration','การสั่น','alignment','ตั้งศูนย์','lubrication','หล่อลื่น','gearbox','เกียร์','pump','ปั๊ม','motor','มอเตอร์','cavitation','thermography','insulation','megger','transformer','หม้อแปลง','ISO 10816','NEMA','ซ่อมบำรุง','preventive','predictive')
  'foodsafety'    = @('FSSC','ISO 22000','ISO22000','HACCP','GMP','PRP','OPRP','audit','ตรวจประเมิน','CAR','corrective action','CCP','traceability','recall','allergen','foreign matter','ความปลอดภัยอาหาร','risk assessment','ISO 9001','มาตรฐาน','ควบคุมคุณภาพ')
  'warehouse'     = @('warehouse','คลัง','inventory','สต็อก','FIFO','FEFO','storage','การจัดเก็บ','pallet','กระสอบ','barcode','stock take','shelf life','fumigation','จัดซื้อ','procurement','ผู้ขาย','vendor','purchase order','วัตถุดิบ')
  'dashboard'     = @('KPI','OEE','recovery','BHR','benchmark','dashboard','daily report','รายงานประจำวัน','trend','แนวโน้ม','anomaly','forecast','undetermined loss','time efficiency','availability','downtime','steam % cane','executive summary')

  # ── ผู้เชี่ยวชาญใหม่ตาม ICON.png ──────────────────────────────────
  'etreatment'    = @('บำบัดน้ำเสีย','wastewater','น้ำทิ้ง','BOD','COD','บ่อบำบัด','สิ่งแวดล้อม','environment','effluent','กากตะกอนน้ำเสีย','aeration','เติมอากาศ','บ่อผึ่ง','คุณภาพน้ำทิ้ง','มลพิษ','การระบายน้ำ','recycle water','น้ำหมุนเวียน')
  'safety'        = @('ความปลอดภัย','safety','อุบัติเหตุ','accident','PPE','อุปกรณ์ป้องกัน','LOTO','lockout','tagout','confined space','ที่อับอากาศ','safety valve','วาล์วนิรภัย','ตรวจสอบตามกฎหมาย','กฎหมาย','ใบอนุญาต','อาชีวอนามัย','occupational','ดับเพลิง','fire','เซฟตี้','JSA','งานเสี่ยง','permit to work')
  'hr'            = @('บุคลากร','พนักงาน','HR','human resource','ทรัพยากรบุคคล','สวัสดิการ','ฝึกอบรม','training','ประเมินผล','แรงงาน','กฎหมายแรงงาน','สรรหา','recruitment','โครงสร้างองค์กร','กะทำงาน','shift','OT','ค่าจ้าง','competency','สมรรถนะ')
}


# =====================================================================
#  ฟังก์ชันช่วย
# =====================================================================

# แคช regex ไว้ เพราะต้องเรียกซ้ำหลายพันครั้งตอนจัดหมวด
$script:KwRegex = @{}

function Get-KeywordRegex {
  param([string]$Keyword)
  if ($script:KwRegex.ContainsKey($Keyword)) { return $script:KwRegex[$Keyword] }

  $k = [regex]::Escape($Keyword.ToLower())
  # คำละตินต้องเทียบ "ขอบเขตคำ" ไม่ใช่ substring
  # ไม่งั้น "ot" (จาก overtime) จะไปแมตช์ใน n(ot), h(ot), r(ot)or, t(ot)al
  # ซึ่งเคยทำให้ตำราน้ำตาลของ Peter Rein 108 ท่อนหลุดไปอยู่ในห้องทรัพยากรบุคคล
  # ภาษาไทยไม่มีช่องว่างระหว่างคำ จึงยังต้องใช้ substring ตามเดิม
  $pattern = if ($Keyword -match '^[\x20-\x7E]+$') { "(?<![a-z0-9])$k(?![a-z0-9])" } else { $k }

  $re = New-Object System.Text.RegularExpressions.Regex($pattern,
          [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  $script:KwRegex[$Keyword] = $re
  return $re
}

function Get-ModuleScore {
  param([string]$Text, [string]$DefaultModule, [int]$Bias = 3)

  $lower  = $Text.ToLower()
  $scores = @{}
  foreach ($m in $ModuleKeywords.Keys) {
    $s = 0
    foreach ($kw in $ModuleKeywords[$m]) {
      $re = Get-KeywordRegex -Keyword $kw
      $n  = [Math]::Min(8, $re.Matches($lower).Count)
      if ($n -gt 0) {
        # คำสั้นมาก (ตัวย่อ 2-3 ตัว) ให้น้ำหนักน้อยลง เพราะกำกวมกว่าคำเต็ม
        $w = if ($kw.Length -le 3) { 1 } else { [Math]::Min(3, [Math]::Max(1, [int]($kw.Length / 4))) }
        $s += $n * $w
      }
    }
    $scores[$m] = $s
  }

  # ให้แต้มพิเศษกับโมดูลตั้งต้นของไฟล์ เพื่อไม่ให้ chunk กระเด็นไปมั่ว
  # ไฟล์ที่ครอบคลุมหลายสถานี (NoBias) จะได้ Bias = 0 ให้ keyword ตัดสินล้วน
  if ($Bias -gt 0) { $scores[$DefaultModule] = $scores[$DefaultModule] + $Bias }

  $best = $DefaultModule; $bestScore = -1
  foreach ($m in $scores.Keys) {
    if ($scores[$m] -gt $bestScore) { $bestScore = $scores[$m]; $best = $m }
  }
  return $best
}

function Split-Long {
  <#  ซอยข้อความที่ยาวเกินเพดานให้เป็นชิ้นละไม่เกิน $Max
      ตัดที่ขอบประโยคก่อน ถ้ายังยาวอยู่จึงตัดที่ช่องว่าง และตัดดิบเป็นทางสุดท้าย
      จำเป็นต้องมี เพราะย่อหน้าเดียวจาก PDF อาจยาวเป็นหมื่นตัวอักษร  #>
  param([string]$Text, [int]$Max)

  $out = New-Object System.Collections.ArrayList
  if($Text.Length -le $Max){ [void]$out.Add($Text); return $out }

  # ตัดที่ขอบประโยค (รองรับทั้งจุดแบบอังกฤษและช่องว่างยาวแบบไทย)
  $parts = [regex]::Split($Text,'(?<=[.!?。])\s+|(?<=[ก-๙])\s{2,}')
  $cur = New-Object System.Text.StringBuilder

  foreach($s in $parts){
    $seg = $s.Trim()
    if(-not $seg){ continue }

    # ประโยคเดียวยังยาวเกิน -> ซอยด้วยช่องว่าง
    if($seg.Length -gt $Max){
      if($cur.Length -gt 0){ [void]$out.Add($cur.ToString().Trim()); [void]$cur.Clear() }
      $words = $seg -split '\s+'
      $line = New-Object System.Text.StringBuilder
      foreach($w in $words){
        if($line.Length -gt 0 -and ($line.Length + $w.Length + 1) -gt $Max){
          [void]$out.Add($line.ToString().Trim()); [void]$line.Clear()
        }
        # คำเดียวยาวเกินเพดาน (ข้อความไทยไม่มีช่องว่าง) -> ตัดดิบ
        if($w.Length -gt $Max){
          for($i=0; $i -lt $w.Length; $i += $Max){
            [void]$out.Add($w.Substring($i,[Math]::Min($Max,$w.Length-$i)))
          }
        } else {
          if($line.Length -gt 0){ [void]$line.Append(' ') }
          [void]$line.Append($w)
        }
      }
      if($line.Length -gt 0){ [void]$out.Add($line.ToString().Trim()) }
      continue
    }

    if($cur.Length -gt 0 -and ($cur.Length + $seg.Length + 1) -gt $Max){
      [void]$out.Add($cur.ToString().Trim()); [void]$cur.Clear()
    }
    if($cur.Length -gt 0){ [void]$cur.Append(' ') }
    [void]$cur.Append($seg)
  }
  if($cur.Length -gt 0){ [void]$out.Add($cur.ToString().Trim()) }
  return ($out | Where-Object { $_.Trim().Length -gt 0 })
}

function Split-PlainText {
  <#  ตัดเอกสารข้อความล้วน (ที่สกัดจาก PDF) เป็น chunk
      ต่างจาก Markdown ตรงที่ไม่มี heading ให้ยึด จึงตัดตามย่อหน้า+ขนาด
      และพยายามจับหัวข้อจากบรรทัดสั้นที่ขึ้นต้นด้วยเลขข้อ  #>
  param([string]$Text, [int]$Max, [int]$Ov)

  # ต่อคำที่ถูกตัดด้วยยัติภังค์ท้ายบรรทัด (ancil-\nlary -> ancillary)
  $Text = [regex]::Replace($Text,'([A-Za-z])-\s*\r?\n\s*([a-z])','$1$2')
  # รวมบรรทัดที่เป็นประโยคเดียวกันให้เป็นย่อหน้า (บรรทัดที่ไม่จบด้วย . : ; )
  $Text = [regex]::Replace($Text,'(?<![.:;!?])\r?\n(?=[a-zก-๙])',' ')

  $paras = [regex]::Split($Text,'\r?\n\s*\r?\n') | Where-Object { $_.Trim().Length -gt 0 }
  $out = New-Object System.Collections.ArrayList
  $cur = New-Object System.Text.StringBuilder
  $head = ''
  $part = 1

  $flush = {
    param($body)
    [void]$out.Add(@{ Head = $head; Body = $body; Part = $part })
    $script:__part = $part
  }

  foreach($p in $paras){
    $line = $p.Trim()
    # บรรทัดสั้นที่ขึ้นต้นด้วยเลขข้อ = หัวข้อ
    if($line.Length -lt 90 -and $line -match '^\d+(\.\d+)*\s+\S'){
      $head = ($line -replace '\s+\d+\s*$','').Trim()
    }

    # ย่อหน้าเดียวยาวเกินเพดาน -> ต้องซอยก่อน ไม่งั้นจะหลุดเข้าไปทั้งก้อน
    foreach($seg in (Split-Long -Text $line -Max $Max)){
      if($cur.Length -gt 0 -and ($cur.Length + $seg.Length + 2) -gt $Max){
        $chunk = $cur.ToString().Trim()
        [void]$out.Add(@{ Head = $head; Body = $chunk; Part = $part }); $part++
        $tail = if($chunk.Length -gt $Ov){ $chunk.Substring($chunk.Length-$Ov) } else { '' }
        [void]$cur.Clear()
        if($tail){ [void]$cur.AppendLine($tail) }
      }
      [void]$cur.AppendLine($seg)
    }
  }
  if($cur.ToString().Trim().Length -gt 0){
    [void]$out.Add(@{ Head = $head; Body = $cur.ToString().Trim(); Part = $part })
  }
  return $out
}

function Split-Markdown {
  <# ตัดเอกสารตามหัวข้อ แล้วซอยต่อถ้ายาวเกิน MaxChars #>
  param([string]$Text, [int]$Max, [int]$Min, [int]$Ov)

  $lines    = $Text -split "`r?`n"
  $sections = New-Object System.Collections.ArrayList
  $curHead  = ''
  $buf      = New-Object System.Text.StringBuilder
  $inFence  = $false

  foreach ($line in $lines) {
    if ($line -match '^\s*```') { $inFence = -not $inFence }

    if (-not $inFence -and $line -match '^(#{1,4})\s+(.+?)\s*$') {
      if ($buf.Length -gt 0) {
        [void]$sections.Add(@{ Head = $curHead; Body = $buf.ToString().Trim() })
        [void]$buf.Clear()
      }
      $curHead = $Matches[2].Trim()
      continue
    }
    [void]$buf.AppendLine($line)
  }
  if ($buf.Length -gt 0) {
    [void]$sections.Add(@{ Head = $curHead; Body = $buf.ToString().Trim() })
  }

  # ผนวกส่วนที่สั้นเกินไปเข้ากับส่วนถัดไป
  $merged = New-Object System.Collections.ArrayList
  $pend   = $null
  foreach ($s in $sections) {
    if ([string]::IsNullOrWhiteSpace($s.Body)) { continue }
    if ($pend) {
      $s = @{ Head = $pend.Head; Body = ($pend.Body + "`n`n" + $s.Head + "`n" + $s.Body).Trim() }
      $pend = $null
    }
    if ($s.Body.Length -lt $Min) { $pend = $s; continue }
    [void]$merged.Add($s)
  }
  if ($pend) { [void]$merged.Add($pend) }

  # ซอยส่วนที่ยาวเกิน
  $out = New-Object System.Collections.ArrayList
  foreach ($s in $merged) {
    if ($s.Body.Length -le $Max) {
      [void]$out.Add(@{ Head = $s.Head; Body = $s.Body; Part = 0 })
      continue
    }
    $paras = $s.Body -split "`r?`n`r?`n"
    $cur = New-Object System.Text.StringBuilder
    $part = 1
    foreach ($p in $paras) {
      # ย่อหน้าเดียวอาจยาวเกินเพดาน (เช่น ตารางยาวๆ) ต้องซอยก่อนเสมอ
      foreach ($seg in (Split-Long -Text $p -Max $Max)) {
        if ($cur.Length -gt 0 -and ($cur.Length + $seg.Length + 2) -gt $Max) {
          $chunkText = $cur.ToString().Trim()
          [void]$out.Add(@{ Head = $s.Head; Body = $chunkText; Part = $part })
          $part++
          # ทำ overlap: ยกท้ายของ chunk เดิมมาขึ้นต้น chunk ใหม่
          $tail = if ($chunkText.Length -gt $Ov) { $chunkText.Substring($chunkText.Length - $Ov) } else { '' }
          [void]$cur.Clear()
          if ($tail) { [void]$cur.AppendLine($tail) }
        }
        [void]$cur.AppendLine($seg)
        [void]$cur.AppendLine('')
      }
    }
    if ($cur.ToString().Trim().Length -gt 0) {
      [void]$out.Add(@{ Head = $s.Head; Body = $cur.ToString().Trim(); Part = $part })
    }
  }
  return $out
}

function Test-NoiseChunk {
  <#  ตำราวิชาการมีดัชนีท้ายเล่มและบรรณานุกรมยาวมาก
      ส่วนนี้ไม่มีความรู้ให้ตอบคำถาม มีแต่ชื่อ-ปี-เลขหน้า
      ถ้าปล่อยเข้าคลังจะไปแย่งอันดับกับเนื้อหาจริง และทำให้ citation ไร้ประโยชน์  #>
  param([string]$Text, [string]$Head = '')
  $len = $Text.Length
  if ($len -lt 40) { return $true }

  # สารบัญของเอกสาร: มีแต่รายชื่อหัวข้อ ไม่มีคำตอบอยู่เลย
  # แต่ดันติดอันดับบ่อยเพราะอัดคำสำคัญไว้หนาแน่นกว่าเนื้อหาจริง
  # แล้วไปกินช่องอ้างอิง 1 ใน 6 ช่อง ทั้งที่เปิดไปก็ไม่เจออะไร
  if ($Head -match '^\s*(สารบัญ|Table of Contents|Contents)\b') { return $true }
  # สารบัญแบบ Markdown ที่ไม่ได้ตั้งหัวข้อว่าสารบัญ — ดูจากลิงก์ข้ามหัวข้อ
  if (([regex]::Matches($Text,'\]\(#')).Count -ge 4) { return $true }

  # ดัชนีท้ายเล่ม: "VLC sugar 364,483-485,489" -> ตัวเลขหนาแน่นผิดปกติ
  $digits = ([regex]::Matches($Text,'\d')).Count
  if (($digits / $len) -gt 0.18) { return $true }

  # บรรณานุกรม: "Doyle C.D.; Attard R.G. (1998): ..." ซ้ำหลายรายการ
  if (([regex]::Matches($Text,'\(\d{4}\)\s*:')).Count -ge 3) { return $true }

  # บรรทัดสารบัญที่เหลือรอด (จุดไข่ปลา + เลขหน้า)
  if (([regex]::Matches($Text,'\.{4,}')).Count -ge 3) { return $true }

  # ข้อความที่เป็น "คำสั่งบทบาท" จาก SKILL.md ไม่ใช่ความรู้ของสาขา
  # ส่วนนี้ถูกใช้เป็น persona อยู่แล้ว ถ้าปล่อยเข้าคลังด้วยจะกลายเป็น
  # ผู้เชี่ยวชาญค้นเจอคำสั่งของตัวเองแล้วเอามาตอบ ซึ่งไม่มีประโยชน์
  $instruction = @(
    'You are a ', 'Your Identity', 'Response Framework', 'Critical Rules',
    'Guardrails', 'Operating Modes', 'บทบาทของ Claude', 'Claude จะทำหน้าที่',
    'โหมดการทำงาน', 'คุณคือ', 'ตอบเป็นภาษาไทย', 'ตอบเป็น **ภาษาไทย',
    'รูปแบบคำตอบ', 'Response format', 'ALWAYS structure'
  )
  foreach ($p in $instruction) { if ($Text.Contains($p)) { return $true } }

  return $false
}

function ConvertTo-SqlLiteral {
  param([string]$s)
  if ($null -eq $s) { return 'null' }
  return "'" + ($s -replace "'", "''") + "'"
}

function ConvertTo-JsonString {
  param([string]$s)
  if ($null -eq $s) { return '""' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    switch ([int]$ch) {
      8  { [void]$sb.Append('\b');  break }
      9  { [void]$sb.Append('\t');  break }
      10 { [void]$sb.Append('\n');  break }
      12 { [void]$sb.Append('\f');  break }
      13 { [void]$sb.Append('\r');  break }
      34 { [void]$sb.Append('\"');  break }
      92 { [void]$sb.Append('\\');  break }
      default {
        if ([int]$ch -lt 32) { [void]$sb.Append('\u' + ([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}


# =====================================================================
#  ประมวลผล
# =====================================================================
# =====================================================================
#  เอกสารจริงของโรงงาน (สกัดจาก PDF ด้วย scripts/pdf-to-text.ps1)
#  ตั้ง IncludeRein = $false ถ้าพบว่า OCR ของ Peter Rein ทำให้ผลค้นแย่ลง
# =====================================================================
$SupportRoot = Join-Path $ProjectRoot 'Support Document\_text'
$SupportMap  = @(
  @{ File='preecha_book_01.txt'; Module='powerplant'; Type='BOOK'; Plain=$true
     Title='วิศวกรรมโรงจักรต้นกำลัง (ปรีชา ทุมมุ)'; Code='PREECHA-PP' }
  @{ File='คู่มือการปฏิบัติงาน_นายเอกรินทร์ ทิมมณี.txt'; Module='powerplant'; Type='MANUAL'; Plain=$true
     Title='คู่มือตรวจสอบและบำรุงรักษาระบบหม้อต้มไอน้ำ'; Code='WI-BOILER' }
  # เว็บความรู้ที่ทีมทำเอง — เนื้อหาไทยผสมอังกฤษ ครอบคลุมทุกสถานี
  # เป็น Markdown แล้ว (fetch-web.ps1 แปลงหัวข้อให้) จึงไม่ตั้ง Plain
  # NoBias เพราะครอบคลุมหลายสถานี ให้ keyword ตัดสินรายหัวข้อ
  @{ File='MLSugartech.txt'; Module='dashboard'; Type='BOOK'; NoBias=$true
     Title='ML SugarTech — คลังความรู้วิศวกรรมน้ำตาล'; Code='MLST' }
)
if ($IncludeRein) {
  $SupportMap += @{ File='Peter Rein - Cane sugar enginnering.txt'; Module='crushing'; Type='BOOK'
     Plain=$true; NoBias=$true; Title='Peter Rein — Cane Sugar Engineering (ฉบับเต็ม)'; Code='REIN-FULL' }
}

$allChunks = New-Object System.Collections.ArrayList
$docs      = New-Object System.Collections.ArrayList
$docNo     = 0
$skipped   = @()

# ── เอกสารที่วางเพิ่มเองโดยไม่ได้แก้ $SupportMap ────────────────────
# ให้การเพิ่มความรู้เป็นแค่ "วางไฟล์ .txt แล้วรันสคริปต์" ไม่ต้องมาแก้โค้ด
# ตั้ง NoBias ไว้ เพราะไม่รู้ว่าเอกสารเป็นของสถานีไหน ปล่อยให้ keyword ตัดสินรายท่อน
# ตั้งชื่อไฟล์ให้สื่อความหมาย เพราะชื่อไฟล์จะกลายเป็นชื่อเอกสารที่โชว์ในคำตอบ
$mapped = $SupportMap | ForEach-Object { $_.File }
$auto = @()
if (Test-Path $SupportRoot) {
  $auto = Get-ChildItem -LiteralPath $SupportRoot -Filter '*.txt' -File |
          Where-Object { $_.Name -notin $mapped -and $_.Name -notlike '~*' -and $_.Name -ne 'probe.txt' }
}
$autoNo = 0
foreach ($f in $auto) {
  $autoNo++
  $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  # โค้ดเอกสารไปโชว์ในรายการอ้างอิง ต้องสั้นและอ่านออก
  # ตัดคำไทยกลางคำแล้วอ่านไม่รู้เรื่อง จึงใช้เฉพาะตัวอักษรละติน/ตัวเลข
  # ถ้าชื่อไฟล์เป็นไทยล้วนก็ใช้เลขลำดับแทน ส่วนชื่อเต็มไปอยู่ที่ Title อยู่แล้ว
  $latin = [regex]::Matches($base,'[A-Za-z0-9]+') | ForEach-Object { $_.Value }
  $code = if ($latin) { (($latin -join '-').ToUpper()) } else { "DOC-$autoNo" }
  if ($code.Length -gt 14) { $code = $code.Substring(0,14).Trim('-') }
  $SupportMap += @{ File=$f.Name; Module='dashboard'; Type='DOC'; Plain=$true; NoBias=$true
                    Title=$base; Code=$code }
  Write-Host ("  พบเอกสารใหม่ที่ยังไม่ได้ลงทะเบียน: {0}  (code {1})" -f $f.Name, $code) -ForegroundColor Cyan
}

# รวมสองแหล่ง: สกิล + เอกสารจริง
$Sources = @()
foreach ($e in $FileMap)    { $Sources += @{ Root=$SkillsRoot;  Path=$e.Path; Entry=$e } }
foreach ($e in $SupportMap) { $Sources += @{ Root=$SupportRoot; Path=$e.File; Entry=$e } }

foreach ($src in $Sources) {
  $entry = $src.Entry
  $full = Join-Path $src.Root $src.Path
  if (-not (Test-Path -LiteralPath $full)) { $skipped += $src.Path; continue }

  $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8

  # ตัด YAML front-matter ออก
  $raw = [regex]::Replace($raw, '^\s*---\s*\r?\n.*?\r?\n---\s*\r?\n', '', 'Singleline')

  $docNo++
  $docId = "d{0:D3}" -f $docNo
  [void]$docs.Add(@{
    Id     = $docId
    Module = $entry.Module
    Title  = $entry.Title
    Type   = $entry.Type
    Code   = $entry.Code
    Path   = $src.Path
  })

  $pieces = if ($entry.Plain) {
    Split-PlainText -Text $raw -Max $MaxChars -Ov $Overlap
  } else {
    Split-Markdown  -Text $raw -Max $MaxChars -Min $MinChars -Ov $Overlap
  }

  $i = 0
  $dropped = 0
  foreach ($p in $pieces) {
    if ([string]::IsNullOrWhiteSpace($p.Body)) { continue }
    if (Test-NoiseChunk -Text $p.Body -Head $p.Head) { $dropped++; continue }

    $section = if ($p.Head) { $p.Head } else { $entry.Title }
    $bias    = if ($entry.NoBias) { 0 } else { 3 }
    # ให้น้ำหนักหัวข้อมากกว่าเนื้อหา — หัวข้อบอกได้ตรงกว่าว่า chunk พูดเรื่องอะไร
    $module  = Get-ModuleScore -Text ($section + ' ' + $section + ' ' + $p.Body) `
                               -DefaultModule $entry.Module -Bias $bias
    $pageRef = if ($p.Part -gt 0) { "$section (ตอนที่ $($p.Part))" } else { $section }

    [void]$allChunks.Add([pscustomobject]@{
      doc_id      = $docId
      doc_code    = $entry.Code
      doc_title   = $entry.Title
      doc_type    = $entry.Type
      module_id   = $module
      chunk_index = $i
      section     = $section
      page_ref    = $pageRef
      content     = $p.Body
      tokens      = [int]([Math]::Ceiling($p.Body.Length / 2.8))
    })
    $i++
  }

  $note = if ($dropped -gt 0) { "  (ตัดขยะ $dropped)" } else { '' }
  Write-Host ("  {0,-52} -> {1,4} chunks{2}" -f $src.Path, $i, $note)
}

if ($skipped.Count -gt 0) {
  Write-Host "`nข้ามไฟล์ที่ไม่พบ:" -ForegroundColor Yellow
  $skipped | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
}


# =====================================================================
#  เขียนผลลัพธ์
# =====================================================================
$kbDir = Join-Path $OutRoot 'kb'
$sqlDir = Join-Path $OutRoot 'supabase\migrations'
New-Item -ItemType Directory -Force -Path $kbDir  | Out-Null
New-Item -ItemType Directory -Force -Path $sqlDir | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 1) JSONL สำหรับ demo ในเบราว์เซอร์ ----
$jsonlPath = Join-Path $kbDir 'chunks.jsonl'
$sw = New-Object System.IO.StreamWriter($jsonlPath, $false, $utf8NoBom)
foreach ($c in $allChunks) {
  $line = '{' +
    '"id":'         + (ConvertTo-JsonString "$($c.doc_id)-$($c.chunk_index)") + ',' +
    '"module":'     + (ConvertTo-JsonString $c.module_id) + ',' +
    '"doc_code":'   + (ConvertTo-JsonString $c.doc_code)  + ',' +
    '"doc_title":'  + (ConvertTo-JsonString $c.doc_title) + ',' +
    '"doc_type":'   + (ConvertTo-JsonString $c.doc_type)  + ',' +
    '"section":'    + (ConvertTo-JsonString $c.section)   + ',' +
    '"page_ref":'   + (ConvertTo-JsonString $c.page_ref)  + ',' +
    '"content":'    + (ConvertTo-JsonString $c.content)   +
  '}'
  $sw.WriteLine($line)
}
$sw.Close()

# ---- 1b) ไฟล์ JS สำหรับเปิดจาก file:// (fetch อ่าน .jsonl ไม่ได้ตอนเปิดแบบไฟล์) ----
$jsPath = Join-Path $kbDir 'chunks.js'
$sw = New-Object System.IO.StreamWriter($jsPath, $false, $utf8NoBom)
$sw.WriteLine('// สร้างอัตโนมัติโดย scripts/build-kb.ps1 — ห้ามแก้ด้วยมือ')
$sw.WriteLine('window.SUGAR_KB = [')
$n = 0
foreach ($c in $allChunks) {
  $n++
  $comma = if ($n -lt $allChunks.Count) { ',' } else { '' }
  $line = '{' +
    '"id":'         + (ConvertTo-JsonString "$($c.doc_id)-$($c.chunk_index)") + ',' +
    '"module":'     + (ConvertTo-JsonString $c.module_id) + ',' +
    '"doc_code":'   + (ConvertTo-JsonString $c.doc_code)  + ',' +
    '"doc_title":'  + (ConvertTo-JsonString $c.doc_title) + ',' +
    '"doc_type":'   + (ConvertTo-JsonString $c.doc_type)  + ',' +
    '"section":'    + (ConvertTo-JsonString $c.section)   + ',' +
    '"page_ref":'   + (ConvertTo-JsonString $c.page_ref)  + ',' +
    '"content":'    + (ConvertTo-JsonString $c.content)   +
  '}' + $comma
  $sw.WriteLine($line)
}
$sw.WriteLine('];')
$sw.Close()

# ---- 2) SQL seed สำหรับ Supabase ----
$sqlPath = Join-Path $sqlDir '003_seed_kb.sql'
$sw = New-Object System.IO.StreamWriter($sqlPath, $false, $utf8NoBom)
$sw.WriteLine('-- =====================================================================')
$sw.WriteLine('--  ML Expert AI — Knowledge Base Seed')
$sw.WriteLine("--  สร้างอัตโนมัติ $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  $($docs.Count) เอกสาร  |  $($allChunks.Count) chunks")
$sw.WriteLine('--  รันหลังจาก 001_init.sql และ 002_modules.sql')
$sw.WriteLine('-- =====================================================================')
$sw.WriteLine('')
$sw.WriteLine('begin;')
$sw.WriteLine('')
$sw.WriteLine('-- ล้างข้อมูลเดิมที่มาจาก seed (ไม่แตะเอกสารที่ผู้ใช้อัปโหลดเอง)')
$sw.WriteLine("delete from kb_documents where metadata->>'origin' = 'skill-seed';")
$sw.WriteLine('')

foreach ($d in $docs) {
  $sw.WriteLine("insert into kb_documents (id, module_id, title, doc_type, doc_code, source_path, lang, metadata) values (")
  $sw.WriteLine("  uuid_generate_v4(), $(ConvertTo-SqlLiteral $d.Module), $(ConvertTo-SqlLiteral $d.Title),")
  $sw.WriteLine("  $(ConvertTo-SqlLiteral $d.Type), $(ConvertTo-SqlLiteral $d.Code), $(ConvertTo-SqlLiteral $d.Path), 'mixed',")
  $sw.WriteLine("  jsonb_build_object('origin','skill-seed','seed_id',$(ConvertTo-SqlLiteral $d.Id)));")
}
$sw.WriteLine('')

$sw.WriteLine('-- ---- chunks ----')
foreach ($c in $allChunks) {
  $sw.WriteLine("insert into kb_chunks (document_id, module_id, chunk_index, section, page_ref, content, token_estimate)")
  $sw.WriteLine("select id, $(ConvertTo-SqlLiteral $c.module_id), $($c.chunk_index), $(ConvertTo-SqlLiteral $c.section), $(ConvertTo-SqlLiteral $c.page_ref),")
  $sw.WriteLine("       $(ConvertTo-SqlLiteral $c.content), $($c.tokens)")
  $sw.WriteLine("from kb_documents where metadata->>'seed_id' = $(ConvertTo-SqlLiteral $c.doc_id);")
}

$sw.WriteLine('')
$sw.WriteLine('commit;')
$sw.WriteLine('')
$sw.WriteLine('-- ตรวจผล:  select * from kb_stats();')
$sw.Close()


# =====================================================================
#  สรุป
# =====================================================================
Write-Host "`n─────────── สรุปคลังความรู้ ───────────" -ForegroundColor Green
$allChunks | Group-Object module_id | Sort-Object Count -Descending | ForEach-Object {
  $chars = 0
  foreach ($g in $_.Group) { $chars += $g.content.Length }
  Write-Host ("  {0,-14} {1,4} chunks   {2,7:N0} ตัวอักษร" -f $_.Name, $_.Count, $chars)
}
Write-Host ("  {0,-14} {1,4} chunks" -f 'รวม', $allChunks.Count) -ForegroundColor Green

Write-Host "`nไฟล์ที่สร้าง:" -ForegroundColor Cyan
Write-Host "  $jsonlPath"
Write-Host "  $jsPath"
Write-Host "  $sqlPath"
Write-Host "`nขั้นต่อไป: เปิด web\index.html เพื่อดู demo  หรือ  รัน SQL ทั้ง 3 ไฟล์ใน Supabase" -ForegroundColor Yellow
