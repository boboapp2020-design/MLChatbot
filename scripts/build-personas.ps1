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

 'foodsafety' = @{ Skill=''; Focus=@'
คุณคือ **ผู้เชี่ยวชาญคุณภาพและมาตรฐาน (QA & Standards Expert)** ในทีม ML Expert AI
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
