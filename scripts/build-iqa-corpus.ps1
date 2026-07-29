#Requires -Version 5.1
<#
=====================================================================
 แปลงเอกสารงานตรวจติดตามภายใน (IQA) ให้เป็นข้อความสำหรับคลังความรู้
---------------------------------------------------------------------
 อ่านจากโฟลเดอร์งาน Internal Audit แล้วเขียนไฟล์ .txt ลง
 Support Document\_text\  ซึ่ง build-kb.ps1 จะเก็บเข้าคลังให้เอง

 ทำไมต้องแปลงก่อน ไม่โยน JSON เข้าไปตรงๆ:
 JSON ดิบเต็มไปด้วยวงเล็บและชื่อฟิลด์ ซึ่งกินที่ใน chunk โดยไม่ให้ความหมาย
 และทำให้การค้นเจอแต่โครงสร้าง ไม่เจอเนื้อความ

 วิธีใช้:
   powershell -ExecutionPolicy Bypass -File scripts\build-iqa-corpus.ps1
=====================================================================
#>

[CmdletBinding()]
param(
  [string] $Source = 'D:\Claude Code Test',
  [string] $OutDir = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'Support Document\_text' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

if (-not (Test-Path -LiteralPath $Source)) {
  Write-Error "ไม่พบโฟลเดอร์ต้นทาง: $Source"
}

Write-Host "ต้นทาง : $Source"   -ForegroundColor Cyan
Write-Host "ปลายทาง: $OutDir`n" -ForegroundColor Cyan

function Read-Json($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  $raw = $raw -replace '^\uFEFF', ''
  try { return $raw | ConvertFrom-Json } catch { Write-Warning "อ่านไม่ได้: $path"; return $null }
}

# ชื่อบุคคลในรายงานไม่ได้ช่วยให้ค้นเจอความรู้ แต่ทำให้คำวิจารณ์เพื่อนร่วมงาน
# กลายเป็นสิ่งที่ใครก็ค้นเจอได้ในระบบที่เปิดให้คนทั้งโรงงานใช้
# เก็บบทเรียนไว้ ตัดชื่อออก
function Remove-PersonName([string]$t) {
  if (-not $t) { return $t }
  $t = $t -replace '(คุณ|พี่|น้อง|นาย|นาง|นางสาว|ผู้ตรวจ|ผู้รับตรวจ)\s*[ก-๙A-Za-z]{2,20}', '[ผู้ปฏิบัติงาน]'
  return $t
}

$written = @()

# =====================================================================
#  1) เช็คลิสต์ตรวจติดตามภายใน — คำถาม + ข้อบกพร่องที่พบบ่อย
#     + เกณฑ์ตัดสิน + หลักฐานที่ต้องขอ
#     นี่คือแก่นของคลัง เพราะเป็นของโรงงานเองไม่ใช่ตำราต่างประเทศ
# =====================================================================
$guide = Read-Json (Join-Path $Source 'guide_compact_with_q.json')
if ($guide) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# เช็คลิสต์ตรวจติดตามภายใน (Internal Audit) รายแผนก')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('เช็คลิสต์ที่ใช้ตรวจจริงในโรงงาน แต่ละข้อประกอบด้วย คำถามที่ผู้ตรวจถาม')
  [void]$sb.AppendLine('ข้อบกพร่องที่มักพบ เกณฑ์ที่ถือว่าผ่าน และหลักฐานที่ต้องขอดู')
  [void]$sb.AppendLine()

  $nDept = 0; $nQ = 0
  foreach ($p in $guide.PSObject.Properties) {
    $dept  = $p.Name
    $items = $p.Value
    if (-not $items) { continue }
    $nDept++
    [void]$sb.AppendLine("## แผนก$dept — เช็คลิสต์ตรวจติดตามภายใน")
    [void]$sb.AppendLine()

    $seen = @{}
    $i = 0
    foreach ($it in $items) {
      $q = "$($it.q)".Trim()
      if (-not $q) { continue }
      # ไฟล์ต้นทางมีคำถามซ้ำอยู่หลายจุด ถ้าไม่กรองจะได้ chunk ซ้ำเต็มคลัง
      if ($seen.ContainsKey($q)) { continue }
      $seen[$q] = $true
      $i++; $nQ++
      [void]$sb.AppendLine("### $dept ข้อ $i")
      [void]$sb.AppendLine("**คำถามที่ผู้ตรวจถาม:** $q")
      if ($it.cc) { [void]$sb.AppendLine("**เกณฑ์ที่ถือว่าผ่าน:** $($it.cc)") }
      if ($it.nc) { [void]$sb.AppendLine("**ข้อบกพร่องที่มักพบ:** $($it.nc)") }
      if ($it.d)  { [void]$sb.AppendLine("**หลักฐานที่ต้องขอดู:** $($it.d)") }
      [void]$sb.AppendLine()
    }
  }
  $out = Join-Path $OutDir 'IQA-เช็คลิสต์ตรวจติดตามภายใน.txt'
  [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
  $written += [pscustomobject]@{ 'ไฟล์'='IQA-เช็คลิสต์ตรวจติดตามภายใน.txt'; 'รายละเอียด'="$nDept แผนก · $nQ คำถาม"; 'ขนาดKB'=[math]::Round((Get-Item $out).Length/1KB) }
}

# =====================================================================
#  2) เกณฑ์ตัดสินผลตรวจ — แปลง AuditorBrain JSON เป็นข้อความอ่านได้
# =====================================================================
$brainPath = @('IQA_AuditorBrain_v5.json','IQA_AuditorBrain_v4.json','IQA_AuditorBrain_v3.json') |
             ForEach-Object { Join-Path $Source $_ } |
             Where-Object { Test-Path -LiteralPath $_ } |
             Select-Object -First 1

if ($brainPath) {
  $brain = Read-Json $brainPath
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# เกณฑ์ตัดสินผลตรวจติดตามภายใน (C / NC / B) ตาม ISO 19011:2018')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('หลักการตัดสินว่า Finding ที่ผู้ตรวจเขียน สนับสนุนผลที่ติ๊กหรือไม่')
  [void]$sb.AppendLine('หลักฐานเพียงพอและทวนสอบย้อนกลับได้หรือไม่ และเขียนถูกรูปแบบหรือไม่')
  [void]$sb.AppendLine()

  # เดินโครง JSON แบบ recursive แล้วแปลงเป็นหัวข้อ + ย่อหน้า
  # ตัวชื่อฟิลด์ภาษาอังกฤษยังมีประโยชน์ เพราะสื่อว่าหัวข้อนั้นคืออะไร
  function Write-Node($node, [int]$depth, [string]$name) {
    if ($depth -gt 5) { return }
    if ($null -eq $node) { return }

    if ($node -is [string]) {
      $v = (Remove-PersonName $node).Trim()
      if ($v.Length -ge 3) {
        if ($name) { [void]$sb.AppendLine("**$name** — $v") } else { [void]$sb.AppendLine($v) }
        [void]$sb.AppendLine()
      }
      return
    }
    if ($node -is [bool] -or $node -is [int] -or $node -is [double]) {
      if ($name) { [void]$sb.AppendLine("**$name** — $node"); [void]$sb.AppendLine() }
      return
    }
    if ($node -is [Array]) {
      foreach ($x in $node) { Write-Node $x ($depth+1) '' }
      return
    }
    if ($node.PSObject -and $node.PSObject.Properties) {
      if ($name) {
        $h = '#' * [Math]::Min(6, $depth + 1)
        [void]$sb.AppendLine("$h $name")
        [void]$sb.AppendLine()
      }
      foreach ($pr in $node.PSObject.Properties) {
        Write-Node $pr.Value ($depth+1) $pr.Name
      }
    }
  }

  foreach ($pr in $brain.PSObject.Properties) {
    if ($pr.Name -eq 'metadata') { continue }
    Write-Node $pr.Value 1 $pr.Name
  }

  $out = Join-Path $OutDir 'IQA-เกณฑ์ตัดสินผลตรวจ.txt'
  [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
  $written += [pscustomobject]@{ 'ไฟล์'='IQA-เกณฑ์ตัดสินผลตรวจ.txt'; 'รายละเอียด'="จาก $(Split-Path -Leaf $brainPath)"; 'ขนาดKB'=[math]::Round((Get-Item $out).Length/1KB) }
}

# =====================================================================
#  3) บทเรียนจากรายงานตรวจจริง — ตัวอย่างที่เขียนใช้ได้และใช้ไม่ได้
#     ค่าอยู่ที่การเห็นของจริงว่าเขียนแบบไหนแล้วทวนสอบไม่ได้
# =====================================================================
$review = Join-Path $Source 'IQA_SampleReview_Findings.md'
$sampleDir = Join-Path $Source 'Sample'
if ((Test-Path -LiteralPath $review) -or (Test-Path -LiteralPath $sampleDir)) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# บทเรียนจากรายงานตรวจติดตามภายในของจริง')
  [void]$sb.AppendLine()

  if (Test-Path -LiteralPath $review) {
    $t = [IO.File]::ReadAllText($review, [Text.Encoding]::UTF8)
    [void]$sb.AppendLine('## ผลทบทวนรายงานตรวจโดย Lead Auditor')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine((Remove-PersonName $t))
    [void]$sb.AppendLine()
  }

  if (Test-Path -LiteralPath $sampleDir) {
    [void]$sb.AppendLine('## ตัวอย่าง Finding จากรายงานจริง พร้อมผลที่ติ๊ก')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('ใช้เทียบว่าข้อความแบบไหนถือเป็นหลักฐานเชิงประจักษ์ที่ทวนสอบย้อนกลับได้')
    [void]$sb.AppendLine('และแบบไหนเป็นเพียงความเห็นซึ่งใช้เป็นผลตรวจไม่ได้')
    [void]$sb.AppendLine()

    foreach ($f in (Get-ChildItem -LiteralPath $sampleDir -Filter 'audit_*.json' -File)) {
      $a = Read-Json $f.FullName
      if (-not $a) { continue }
      $dept = "$($a.deptName)".Trim(); if (-not $dept) { $dept = $f.BaseName }
      [void]$sb.AppendLine("### ตัวอย่าง Finding แผนก$dept")
      [void]$sb.AppendLine()
      $n = 0
      foreach ($q in $a.questionData) {
        $res = (Remove-PersonName "$($q._result)").Trim()
        if (-not $res -or $res -eq '-' ) { continue }
        $n++; if ($n -gt 12) { break }
        # ขึ้นบรรทัดใหม่ก่อน elseif จะทำให้ PowerShell ปิด statement ไปแล้ว ต้องอยู่บรรทัดเดียว
        $mark = if ($q._sel_C) { 'C (สอดคล้อง)' } elseif ($q._sel_NC) { 'NC (ไม่สอดคล้อง)' } elseif ($q._sel_B) { 'B (ข้อสังเกต)' } else { 'ยังไม่ได้ติ๊กผล' }
        [void]$sb.AppendLine("- ข้อ $($q.n) · ผลที่ติ๊ก: $mark · สิ่งที่ผู้ตรวจเขียน: ""$res""")
        $rm = (Remove-PersonName "$($q._remark)").Trim()
        if ($rm -and $rm -ne '-') { [void]$sb.AppendLine("  หมายเหตุที่บันทึกไว้: ""$rm""") }
      }
      [void]$sb.AppendLine()
    }
  }

  $out = Join-Path $OutDir 'IQA-บทเรียนจากรายงานตรวจจริง.txt'
  [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
  $written += [pscustomobject]@{ 'ไฟล์'='IQA-บทเรียนจากรายงานตรวจจริง.txt'; 'รายละเอียด'='ผลทบทวน + Finding จริง'; 'ขนาดKB'=[math]::Round((Get-Item $out).Length/1KB) }
}

# =====================================================================
#  4) FSSC 22000 v6 + PRP — มาตรฐานที่เปิดเผยได้
#     ISO 19011 และ ISO/TS 22002-1 เป็นเอกสารลิขสิทธิ์ที่ต้องซื้อ
#     จึงไม่นำข้อความเต็มเข้าคลัง ใช้การอ้างเลขข้อในสกิลแทน
# =====================================================================
foreach ($pair in @(
  @{ src='fssc22000-v6.txt'; dst='FSSC22000-v6-ข้อกำหนด.txt'; head='# FSSC 22000 version 6 — ข้อกำหนดของโครงการรับรอง' },
  @{ src='annex2-v6.txt';    dst='FSSC22000-v6-ภาคผนวก.txt';  head='# FSSC 22000 version 6 — ภาคผนวก 2 ข้อกำหนดเพิ่มเติม' },
  @{ src='prp_text.txt';     dst='GHPs-PRP-โปรแกรมพื้นฐาน.txt'; head='# โปรแกรมพื้นฐานด้านสุขลักษณะ (PRPs / GHPs)' }
)) {
  $p = Join-Path $Source $pair.src
  if (-not (Test-Path -LiteralPath $p)) { continue }
  $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
  $body = $pair.head + "`r`n`r`n" + $t
  $out = Join-Path $OutDir $pair.dst
  [IO.File]::WriteAllText($out, $body, (New-Object Text.UTF8Encoding $false))
  $written += [pscustomobject]@{ 'ไฟล์'=$pair.dst; 'รายละเอียด'='มาตรฐานเปิดเผยได้'; 'ขนาดKB'=[math]::Round((Get-Item $out).Length/1KB) }
}

Write-Host "`nไฟล์ที่สร้าง:" -ForegroundColor Green
$written | Format-Table -AutoSize
Write-Host "ขั้นต่อไป: รัน scripts\build-kb.ps1 เพื่อเก็บเข้าคลังความรู้`n" -ForegroundColor Yellow
