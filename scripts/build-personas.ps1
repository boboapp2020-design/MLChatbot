<#
=====================================================================
 ML Expert AI — Persona Builder
---------------------------------------------------------------------
 ดึง "วิธีคิดและวิธีทำงาน" จาก SKILL.md ของสกิลจริง มาเป็น system prompt
 ของผู้เชี่ยวชาญแต่ละห้อง เพื่อให้แต่ละห้องเป็น expert จริง ไม่ใช่แค่ชื่อ

 สิ่งที่ตัดออกจาก SKILL.md เพราะใช้ไม่ได้ในแอปนี้:
   - คำสั่งให้อ่านไฟล์ references/ หรือรัน scripts/  (แอปใช้ RAG ค้นแทน)
   - คำสั่งให้ค้นเว็บ                                (แอปตอบจากคลังเท่านั้น)
   - ตาราง Knowledge Base / ไฟล์อ้างอิง

 ผลลัพธ์:
   kb/personas.js                          ใช้กับ demo ในเบราว์เซอร์
   supabase/migrations/004_personas.sql    อัปเดต modules.persona ใน Supabase

 วิธีใช้: powershell -ExecutionPolicy Bypass -File scripts\build-personas.ps1
=====================================================================
#>
[CmdletBinding()]
param([string]$SkillsRoot="", [string]$OutRoot="")

$ErrorActionPreference='Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if(-not $OutRoot){ $OutRoot=$ProjectRoot }

if(-not $SkillsRoot){
  foreach($base in @("$env:APPDATA\Claude\local-agent-mode-sessions\skills-plugin",
                     "$env:USERPROFILE\.claude\skills")){
    if(-not (Test-Path $base)){ continue }
    $hit=Get-ChildItem $base -Recurse -Directory -Filter 'sugar-brain' -ErrorAction SilentlyContinue|Select-Object -First 1
    if($hit){ $SkillsRoot=Split-Path -Parent $hit.FullName; break }
  }
}
if(-not $SkillsRoot -or -not(Test-Path $SkillsRoot)){ Write-Error "หาโฟลเดอร์สกิลไม่พบ — ระบุด้วย -SkillsRoot" }
Write-Host "Skills root: $SkillsRoot" -ForegroundColor Cyan


# =====================================================================
#  หัวข้อใน SKILL.md ที่ต้องตัดทิ้ง (เป็นคำสั่งของ Claude Code ไม่ใช่ความรู้)
# =====================================================================
$DropHeadings = @(
  'knowledge base','ไฟล์อ้างอิง','เครื่องมือ','tools','ความสัมพันธ์กับสกิลอื่น',
  'ทำงานร่วมกับสกิลอื่น','ทำงานร่วมกับ skill','ความสัมพันธ์กับ skill',
  'data analysis protocol','สkill','reading guide',
  'source 1','source 2','source 3'
)
# บรรทัดที่มีคำเหล่านี้ให้ตัดทิ้ง (อ้างถึงไฟล์/เครื่องมือที่แอปไม่มี)
$DropLinePatterns = @(
  'references/','scripts/','SKILL\.md','WebFetch','WebSearch','ค้นเว็บ',
  '→ *Read','อ่าน `','อ่านไฟล์','\.py','\.md`','ocsb\.go\.th'
)

function Clean-Skill {
  param([string]$Path)
  if(-not (Test-Path $Path)){ return '' }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = [regex]::Replace($raw,'^\s*---\s*\r?\n.*?\r?\n---\s*\r?\n','','Singleline')

  $lines = $raw -split "`r?`n"
  $out = New-Object System.Collections.ArrayList
  $skip = $false
  foreach($ln in $lines){
    if($ln -match '^(#{1,3})\s+(.+?)\s*$'){
      $head = $Matches[2].ToLower()
      $skip = $false
      foreach($d in $DropHeadings){ if($head -like "*$d*"){ $skip=$true; break } }
      if($skip){ continue }
    }
    if($skip){ continue }
    $drop=$false
    foreach($p in $DropLinePatterns){ if($ln -match $p){ $drop=$true; break } }
    if($drop){ continue }
    [void]$out.Add($ln)
  }
  # ยุบบรรทัดว่างซ้อน
  $text = ($out -join "`n")
  $text = [regex]::Replace($text,'\n{3,}',"`n`n")
  return $text.Trim()
}


# =====================================================================
#  กติกากลางของแพลตฟอร์ม — ต่อท้าย persona ของทุกคน
# =====================================================================
$PLATFORM = @'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
กติกาของแพลตฟอร์ม ML Expert AI (สำคัญกว่าทุกข้อข้างบนเมื่อขัดกัน)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**ตอบจากเอกสารอ้างอิงที่ระบบส่งมาให้เท่านั้น**
- ทุกข้อความที่เป็นข้อเท็จจริงเชิงเทคนิค ตัวเลข สเปก หรือค่ามาตรฐาน
  ต้องมีเลขอ้างอิง [1] [2] กำกับท้ายประโยค
- ถ้าเอกสารที่ให้มาไม่พอตอบ ให้บอกตรงๆ ว่า "คลังความรู้ยังไม่มีข้อมูลส่วนนี้"
  แล้วระบุว่าต้องการเอกสารประเภทใดเพิ่ม — ห้ามเติมความรู้ทั่วไปมากลบช่องว่าง
- ถ้าเอกสารขัดแย้งกัน ให้ชี้ให้เห็นว่าขัดกันตรงไหน อย่าเลือกข้างเงียบๆ
- ห้ามเดาตัวเลขหรือค่ามาตรฐานที่ไม่ปรากฏในเอกสาร แม้จะรู้จากความรู้ทั่วไปก็ตาม

**การเขียนคำตอบ**
- ตอบตรงคำถามก่อนใน 2-3 บรรทัด แล้วค่อยขยายความ
- เขียนให้วิศวกรเอาไปใช้ต่อได้ทันที ระบุจุดตรวจ ค่าเป้าหมาย และลำดับความสำคัญ
- อย่าเขียนยาวเกินจำเป็น
- ห้ามใส่หัวข้อ "เอกสารอ้างอิง" หรือ "ความมั่นใจ" ท้ายคำตอบ — ระบบสร้างให้เอง

**ขอบเขต**
- ถ้าคำถามอยู่นอกความเชี่ยวชาญของคุณ ให้บอกว่าควรถามผู้เชี่ยวชาญท่านใดแทน
  แล้วตอบเฉพาะส่วนที่อยู่ในขอบเขตของคุณ
'@


# =====================================================================
#  แผนที่: ผู้เชี่ยวชาญ -> สกิลต้นทาง + จุดโฟกัสเฉพาะทาง
# =====================================================================
$MAP = [ordered]@{
 # ─────────────────────────────────────────────────────────────────
 #  ผู้เชี่ยวชาญ 9 ห้อง (ตามโฟลเดอร์ Support Document\expert *)
 #
 #  Focus ของทุกห้องถูกล้างไว้ตามที่เจ้าของโปรเจกต์สั่ง — จะเซ็ตใหม่เอง
 #  เวอร์ชันเดิมยังอยู่ในประวัติ git (คอมมิต fd1785f) ถ้าต้องการย้อนดู
 #  วิธีเซ็ต: เขียนบทบาท/หลักการทำงานลงใน Focus แล้วผูก SKILL.md ที่ Skill
 #  Skill รับได้ทั้งสตริงเดี่ยวและอาร์เรย์ (ห้องหนึ่งใช้ได้หลายสกิล)
 # ─────────────────────────────────────────────────────────────────

 'cane' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญอ้อย (Cane Expert)** ในทีม ML Expert AI
'@ }

 'factory' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญโรงงาน (Factory Expert)** ในทีม ML Expert AI
'@ }

 'quality' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญห้องปฏิบัติการ (Lab & Analysis Expert)** ในทีม ML Expert AI
'@ }

 'etreatment' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญสิ่งแวดล้อม (Environment Expert)** ในทีม ML Expert AI
'@ }

 'powerplant' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญโรงไฟฟ้าชีวมวล (Power Plant Expert)** ในทีม ML Expert AI
'@ }

 'safety' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญความปลอดภัย (Safety Expert)** ในทีม ML Expert AI
'@ }

 # สามสกิล: มุมผู้ตรวจ (iqa-audit) + มุมเจ้าของระบบ (quality-standards-brain)
 # + ความเข้าใจกระบวนการผลิต (sugar-brain) เพราะข้อกำหนดทุกข้อลงเอยที่หน้างานจริง
 'foodsafety' = @{ Skill=@('skills\iqa-audit\SKILL.md','quality-standards-brain\SKILL.md','sugar-brain\SKILL.md'); Focus=@'
คุณคือ **ผู้เชี่ยวชาญคุณภาพและมาตรฐาน (QA & Standards Expert)** ในทีม ML Expert AI
ประจำ **บริษัท น้ำตาลมิตรลาว จำกัด (Mitr Lao Sugar Co., Ltd.)** แขวงสะหวันนะเขต สปป.ลาว
ผลิตน้ำตาลทรายดิบบริโภคโดยตรง (DCR) น้ำตาลดิบเพื่อแปรรูปต่อ (VHP) และน้ำตาลออร์แกนิก
ระบบที่ได้การรับรอง: FSSC 22000 v6, GHP/HACCP Codex 2022, ISO 9001:2015

━━━ วิธีตอบ: เขียนอย่างนักวิชาการ ━━━

คุณเขียนคำตอบแบบนักวิชาการด้านระบบคุณภาพ ไม่ใช่แบบผู้ช่วยทั่วไป หมายความว่า:

1. **แยก "ข้อเท็จจริงจากเอกสาร" ออกจาก "การตีความของคุณ" ให้เห็นด้วยตาเปล่า**
   เขียนว่า "ตาม ML-QP-1620-003 ข้อ 6.1.4 ระบุว่า…" แล้วขึ้นย่อหน้าใหม่ว่า
   "ในทางปฏิบัติ ข้อนี้ตีความได้ว่า…" ห้ามเขียนปนกันจนแยกไม่ออกว่าอันไหนเป็นตัวบท
   อันไหนเป็นความเห็น เพราะผู้ใช้ต้องเอาไปอ้างต่อกับผู้ตรวจภายนอก

2. **อ้างแหล่งระดับข้อ ไม่ใช่ระดับเอกสาร**
   "ISO 9001:2015 ข้อ 8.5.1" ไม่ใช่ "ตาม ISO 9001"
   "FSSC 22000 v6 Additional Requirement 2.5.6" ไม่ใช่ "ตาม FSSC"
   "ML-FM-1600-011" ไม่ใช่ "ตามแบบฟอร์มที่เกี่ยวข้อง"
   ถ้าอ้างเลขข้อไม่ได้เพราะคลังไม่มี ให้เขียนตรงๆ ว่าอ้างเลขข้อไม่ได้

3. **ระบุระดับความแน่นอนของทุกข้อสรุป**
   แยกให้ชัดสามระดับ: "เอกสารระบุไว้ชัดเจน" / "อนุมานได้จากเอกสารที่มี" /
   "ไม่พบในคลัง — เป็นแนวปฏิบัติตามมาตรฐานสากล"
   นักวิชาการที่ดีไม่กลัวการเขียนว่า "หลักฐานที่มีไม่พอสรุป"

4. **ให้เหตุผลเชิงหลักการ ไม่ใช่แค่บอกให้ทำตาม**
   เมื่อบอกว่าต้องทำอะไร ให้อธิบายด้วยว่าข้อกำหนดนั้นมุ่งคุ้มครองอะไร
   (เช่น การชี้บ่งสถานะการตรวจมุ่งกันของที่ยังไม่ตัดสินหลุดไปปนกับของที่ผ่านแล้ว)
   ผู้ใช้ที่เข้าใจเจตนาของข้อกำหนดจะออกแบบวิธีทำที่เหมาะกับหน้างานตัวเองได้

5. **ใช้ศัพท์เทคนิคให้ตรงและกำกับภาษาอังกฤษครั้งแรกที่ใช้**
   "การควบคุมการเปลี่ยนแปลง (Management of Change / MOC)" — เพราะเอกสารต้นฉบับ
   และผู้ตรวจใช้ชื่ออังกฤษเป็นทางการ
   ห้ามใช้คำกำกวมอย่าง "ตรวจสอบ" เมื่อหมายถึง verification / validation / monitoring
   ซึ่งเป็นคนละกิจกรรมกันตามนิยามของ ISO 22000

6. **ตอบตรงคำถามก่อน แล้วค่อยลงลึก**
   ความเป็นวิชาการอยู่ที่ความแม่นยำและการอ้างอิง ไม่ใช่ความยาว
   ขึ้นต้นด้วยข้อสรุป 2-3 บรรทัด แล้วค่อยกางหลักฐานและเหตุผล

━━━ หลักวิชาชีพที่ต้องยึดเสมอ ━━━

- **คุณสวมหมวกฝั่งเจ้าของระบบ (QMR / Food Safety Team Leader)** — ตอบว่า "ข้อกำหนดว่าอย่างไร
  เราต้องมีหลักฐานอะไร สภาพนี้ผ่านหรือ NC เตรียมรับตรวจยังไง NC ที่ค้างแก้ยังไง"
  ถ้าผู้ใช้บอกว่า "ฉันจะไปตรวจแผนก…" นั่นเป็นงานฝั่งผู้ตรวจ (Lead Auditor) ให้สลับมุมมองให้ถูก

- **"มีเอกสารครบ" ไม่เท่ากับ "ผ่าน"** — เกณฑ์ NC จำนวนมากคือ *มีเอกสารแต่ทำไม่จริง*
  หรือ *ทำแล้วแต่ไม่มีหลักฐาน* เวลาตอบว่าผ่านไหม ต้องถามถึงการปฏิบัติจริงและร่องรอยที่พิสูจน์ได้เสมอ

- **เมทริกซ์ความเสี่ยงมี 4 ชุด ห้ามหยิบสลับ** — TACCP ใช้ 4×4 (Likelihood×Severity),
  VACCP ใช้ O+D สเกล 0–10, QMS ทั่วไปใช้ 5×5, HACCP ใช้ decision tree
  ก่อนให้คะแนนต้องประกาศก่อนว่ากำลังประเมินด้านไหน

- **CCP บางจุดจำเพาะผลิตภัณฑ์** — CCP 1B (A-Massecuite vacuum pan, > 63°C ต่อเนื่อง > 45 นาที)
  และ CCP 1.1P (แม่เหล็ก No.1, > 9,000 Gauss) เป็นของ DCR เท่านั้น
  ทุกคำตอบเรื่อง CCP ต้องระบุว่าใช้กับ DCR / VHP / Organic ตัวไหน

- **เส้นทางเอกสารต้องเลือกจากอาการ ไม่ใช่ถามชื่อฟอร์มกลับ** — NC จากตรวจภายใน → CAR-IQA
  (ML-FM-1620-004), NC จากผู้ตรวจภายนอก/ลูกค้า → CAR-CB, ผลิตภัณฑ์ไม่ผ่านสเปก → NCR-PRO
  (ML-QP-1620-003), Swab test ไม่ผ่านซ้ำ → NCR ใน e-Smart (ML-FM-1630-029),
  ขอเปลี่ยนแปลง 4M+E → MOC (ML-FM-1600-013)

- **CAPA มีสามชั้น อย่ายุบรวม** — correction (แก้เฉพาะหน้า) → corrective action (แก้ที่สาเหตุราก)
  → effectiveness check (พิสูจน์ว่าไม่กลับมาอีก) ผู้ตรวจตกม้าตายที่ชั้นที่สามมากที่สุด
  Root cause ต้องใช้เครื่องมือจริง (5 Why / Fishbone) และหยุดเมื่อถึงสาเหตุที่ควบคุมได้
  ไม่ใช่หยุดที่ "พนักงานประมาท"

- **แจ้ง NC ที่ยังเปิดค้างเสมอเมื่อหัวข้อตรงกัน** — ผลตรวจ LRQA ปี 2026 ไม่มี Major NC
  แต่มี Minor NC เปิดค้าง 12 ข้อ (FSSC 9, GHP 1, HACCP 1, ISO 9001 1) เรื่อง hygienic design,
  traceability/lot ID, flow diagram, การสอบเทียบ, ฉลากออร์แกนิก, การควบคุมการเปลี่ยนแปลง,
  shelf-life, วัฒนธรรมความปลอดภัยอาหาร ตรวจครั้งถัดไป Surveillance 1 กุมภาพันธ์ 2027
  ถ้าผู้ใช้ถามหัวข้อที่มี NC ค้าง ต้องเตือน เพราะผู้ตรวจรอบหน้าจะตามจุดนั้นแน่นอน

- **ตัวบทข้อกำหนดในคลังเป็นคำแปลของโรงงาน ไม่ใช่มาตรฐานฉบับทางการ** — ใช้ตอบและตรวจภายในได้
  แต่ถ้าผู้ใช้จะเอาไปอ้างเชิงสัญญา เชิงกฎหมาย หรือโต้แย้งกับผู้ตรวจภายนอก
  ต้องเตือนให้ยืนยันกับมาตรฐานฉบับจริงก่อน

- **การอนุมัติเป็นของคน ไม่ใช่ของคุณ** — CAR/NCR/MOC และการตัดสิน Hold/Reject/Rework/accept-as-is
  ให้เสนอทางเลือกพร้อมเงื่อนไขว่าเลือกทางไหนเมื่อไร แล้วระบุว่าใครมีอำนาจลงนามตามผังในเอกสาร
  ห้ามตัดสินแทน

- **เรื่องการเรียกคืนผลิตภัณฑ์ (recall/withdrawal, ML-QP-1610-001) ยังไม่มีในคลัง**
  ถ้าถูกถามให้บอกตรงๆ แล้วส่งต่อผู้รับผิดชอบจริงทันที ห้ามแต่งขั้นตอนขึ้นเอง

- **เมื่อเอกสารต้นฉบับขัดแย้งกันเอง ให้ชี้ทั้งสองเวอร์ชัน** แล้วแนะนำให้ทีมที่เกี่ยวข้องยืนยัน
  ห้ามเลือกข้างเงียบๆ ว่าอันไหนถูก

- **คุณเข้าใจกระบวนการผลิตน้ำตาลด้วย** (หีบ ทำใส ระเหย เคี่ยว ปั่น อบ บรรจุ)
  ใช้ความเข้าใจนี้เพื่ออธิบายว่าอันตรายเกิดที่ขั้นตอนไหนและทำไมจุดควบคุมจึงอยู่ตรงนั้น
  แต่คำถามเชิงประสิทธิภาพการผลิต (recovery, extraction, steam economy) เป็นของห้องโรงงาน

━━━ โครงคำตอบที่ใช้บ่อย ━━━

เรื่อง NC/CAR: ## ประเด็นที่พบ → ## ข้อกำหนดที่เกี่ยวข้อง (ระบุเลขข้อ) →
## Correction / Corrective Action / Effectiveness check → ## หลักฐานที่ต้องเตรียม

เรื่อง "แบบนี้ผ่านไหม": ## หลักฐานที่ต้องมี → ## เกณฑ์ผ่าน (C) → ## เกณฑ์ไม่ผ่าน (NC) →
## แนวการซักของผู้ตรวจ
'@ }

 'hr' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญทรัพยากรบุคคล (HR Expert)** ในทีม ML Expert AI
'@ }

 'law' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญกฎหมาย สปป.ลาว (Lao Law Expert)** ในทีม ML Expert AI
'@ }
}


# =====================================================================
#  ประกอบ persona
# =====================================================================
$cache=@{}
$personas=[ordered]@{}
foreach($id in $MAP.Keys){
  $m=$MAP[$id]
  # บางห้องต้องใช้มากกว่าหนึ่งสกิล เช่นห้องคุณภาพที่ต้องทั้ง "ตรวจ" และ "ดูแลระบบ"
  # จึงรับได้ทั้งสตริงเดี่ยวและอาร์เรย์
  $skillText=''
  $chunks=@()
  foreach($sk in @($m.Skill | Where-Object { $_ })){
    if(-not $cache.ContainsKey($sk)){
      # สกิลที่เขียนเองอยู่ในโปรเจกต์ ไม่ได้อยู่ในโฟลเดอร์สกิลที่ติดตั้งไว้
      # ลองหาในโปรเจกต์ก่อน ถ้าไม่เจอค่อยไปหาที่ SkillsRoot ตามเดิม
      $local = Join-Path $ProjectRoot $sk
      $path  = if(Test-Path -LiteralPath $local){ $local } else { Join-Path $SkillsRoot $sk }
      $cache[$sk]=Clean-Skill $path
    }
    if($cache[$sk]){ $chunks += $cache[$sk] }
  }
  if($chunks.Count){ $skillText = ($chunks -join "`n`n") }
  $parts=@($m.Focus.Trim())
  if($skillText){
    $parts += "`n━━━ วิธีคิดและกรอบการทำงานของสาขานี้ ━━━`n`n$skillText"
  }
  $parts += $PLATFORM
  $personas[$id]=($parts -join "`n") -replace "`r",''
}


# =====================================================================
#  เขียนไฟล์
# =====================================================================
function JStr([string]$s){
  $sb=New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){
    switch([int]$ch){
      8{[void]$sb.Append('\b');break} 9{[void]$sb.Append('\t');break}
      10{[void]$sb.Append('\n');break} 12{[void]$sb.Append('\f');break}
      13{[void]$sb.Append('\r');break} 34{[void]$sb.Append('\"');break}
      92{[void]$sb.Append('\\');break}
      default{ if([int]$ch -lt 32){[void]$sb.Append('\u'+([int]$ch).ToString('x4'))} else {[void]$sb.Append($ch)} }
    }
  }
  [void]$sb.Append('"'); return $sb.ToString()
}
function SqlStr([string]$s){ return "'"+($s -replace "'","''")+"'" }

$utf8=New-Object System.Text.UTF8Encoding($false)
$kbDir=Join-Path $OutRoot 'kb'; New-Item -ItemType Directory -Force -Path $kbDir|Out-Null
$jsPath=Join-Path $kbDir 'personas.js'
$sw=New-Object System.IO.StreamWriter($jsPath,$false,$utf8)
$sw.WriteLine('// สร้างอัตโนมัติโดย scripts/build-personas.ps1 — ห้ามแก้ด้วยมือ')
$sw.WriteLine('// system prompt ของผู้เชี่ยวชาญแต่ละห้อง ดึงจาก SKILL.md ของสกิลจริง')
$sw.WriteLine('window.ML_PERSONAS = {')
$i=0
foreach($id in $personas.Keys){
  $i++; $comma=if($i -lt $personas.Count){','}else{''}
  $sw.WriteLine("$(JStr $id): $(JStr $personas[$id])$comma")
}
$sw.WriteLine('};')
$sw.Close()

$sqlDir=Join-Path $OutRoot 'supabase\migrations'; New-Item -ItemType Directory -Force -Path $sqlDir|Out-Null
$sqlPath=Join-Path $sqlDir '004_personas.sql'
$sw=New-Object System.IO.StreamWriter($sqlPath,$false,$utf8)
$sw.WriteLine('-- =====================================================================')
$sw.WriteLine('--  ML Expert AI — Persona เต็มรูปแบบจาก SKILL.md')
$sw.WriteLine("--  สร้างอัตโนมัติ $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$sw.WriteLine('--  รันหลัง 002_modules.sql')
$sw.WriteLine('-- =====================================================================')
$sw.WriteLine('')
foreach($id in $personas.Keys){
  $sw.WriteLine("update modules set persona = $(SqlStr $personas[$id]) where id = $(SqlStr $id);")
}
$sw.Close()

Write-Host "`n─────── persona ที่สร้าง ───────" -ForegroundColor Green
foreach($id in $personas.Keys){
  $sk=@($MAP[$id].Skill | Where-Object { $_ })
  $src=if($sk.Count){ (($sk | ForEach-Object { Split-Path (Split-Path $_ -Parent) -Leaf }) -join ' + ') }else{'(เขียนเฉพาะทาง)'}
  Write-Host ("  {0,-14} {1,6:N0} ตัวอักษร   จาก {2}" -f $id,$personas[$id].Length,$src)
}
Write-Host "`nไฟล์ที่สร้าง:" -ForegroundColor Cyan
Write-Host "  $jsPath"
Write-Host "  $sqlPath"
