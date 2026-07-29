#Requires -Version 5.1
<#
=====================================================================
 รวมเช็คลิสต์ตรวจติดตามภายในจากไฟล์ Excel จริง เข้ากับเกณฑ์ตัดสิน
---------------------------------------------------------------------
 ไฟล์ Excel ให้ "คำถาม + เลขข้อกำหนดที่อ้างอิง" ซึ่งเป็นของที่ไฟล์ JSON เดิมไม่มี
 ส่วนไฟล์ JSON ให้ "เกณฑ์ที่ถือว่าผ่าน + ข้อบกพร่องที่มักพบ + หลักฐานที่ต้องขอ"
 เอามารวมกันจึงได้ทั้งคำถาม ข้อกำหนด และวิธีตัดสิน อยู่ในท่อนความรู้เดียว

   powershell -ExecutionPolicy Bypass -File scripts\build-iqa-checklist.ps1
=====================================================================
#>
[CmdletBinding()]
param(
  [string] $XlsxDir = 'D:\Claude Code Test\กำหนดการตรวจติดตามภายในระบบ  ISO 9001 _ 2015 และ ระบบ FSSC 22000 v.6 ,GHP,HACCP ครั้งที่ 1_2026',
  [string] $GuideJson = 'D:\Claude Code Test\guide_compact_with_q.json',
  [string] $OutFile = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $Root 'Support Document\_text\IQA-เช็คลิสต์ตรวจติดตามภายใน.txt' }

if (-not (Test-Path -LiteralPath $XlsxDir)) { Write-Error "ไม่พบโฟลเดอร์: $XlsxDir" }

# ── โหลดเกณฑ์ตัดสินจาก JSON มาทำดัชนีด้วยข้อความคำถาม ──────────────
# เทียบด้วยข้อความที่ตัดช่องว่างและวรรคตอนออก เพราะสองแหล่งพิมพ์ไม่เหมือนกันเป๊ะ
function Normalize([string]$s) {
  if (-not $s) { return '' }
  return ($s -replace '[\s\?\.\,\-\(\)/]','').ToLower()
}

$byQuestion = @{}
if (Test-Path -LiteralPath $GuideJson) {
  $raw = [IO.File]::ReadAllText($GuideJson, [Text.Encoding]::UTF8) -replace '^\uFEFF',''
  $guide = $raw | ConvertFrom-Json
  foreach ($p in $guide.PSObject.Properties) {
    foreach ($it in $p.Value) {
      $k = Normalize $it.q
      if ($k -and -not $byQuestion.ContainsKey($k)) { $byQuestion[$k] = $it }
    }
  }
  Write-Host "โหลดเกณฑ์ตัดสิน $($byQuestion.Count) รายการ" -ForegroundColor Cyan
}

# ── อ่านเช็คลิสต์จาก Excel ────────────────────────────────────────
. (Join-Path $PSScriptRoot 'xlsx-lib.ps1')

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('# เช็คลิสต์ตรวจติดตามภายใน (Integrated Audit Checklist)')
[void]$sb.AppendLine('# ISO 9001:2015 + FSSC 22000 v6 + GHPs + HACCP — บริษัท น้ำตาลมิตรลาว จำกัด')
[void]$sb.AppendLine()
[void]$sb.AppendLine('เช็คลิสต์ที่ใช้ตรวจจริงในโรงงาน แต่ละข้อระบุคำถามที่ผู้ตรวจถาม')
[void]$sb.AppendLine('เลขข้อกำหนดที่อ้างอิง เกณฑ์ที่ถือว่าผ่าน ข้อบกพร่องที่มักพบ และหลักฐานที่ต้องขอดู')
[void]$sb.AppendLine('ผลการตรวจติ๊กเป็น C (Conformity) / NC (Non-conformity) / OBS (ข้อสังเกต)')
[void]$sb.AppendLine()

$totalQ = 0; $matched = 0; $deptCount = 0
$files = Get-ChildItem -LiteralPath $XlsxDir -Filter '*.xlsx' -File | Sort-Object Name

foreach ($f in $files) {
  # ชื่อไฟล์เป็น "01.FSST.xlsx" หรือ "11.แผนกหม้อต้ม.xlsx" — ตัดเลขนำหน้าออก
  $dept = [IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '^\d+\.\s*',''
  $rows = @()
  try   { $rows = Read-XlsxRows -Path $f.FullName }
  catch { Write-Warning "อ่านไม่ได้: $($f.Name) — $_"; continue }

  $items = @()
  foreach ($r in $rows) {
    # แถวข้อมูลคือแถวที่คอลัมน์แรกเป็นตัวเลขล้วน และคอลัมน์ที่ 2 มีข้อความคำถาม
    if ($r.Count -lt 2) { continue }
    $no = "$($r[0])".Trim()
    if ($no -notmatch '^\d+$') { continue }
    $q = "$($r[1])".Trim()
    if ($q.Length -lt 12) { continue }
    # คอลัมน์ข้อกำหนดคือช่องที่มีคำว่า ISO / FSSC / HACCP / GHP อยู่
    $clause = ''
    for ($i = 2; $i -lt $r.Count; $i++) {
      $v = "$($r[$i])".Trim()
      if ($v -match '(ISO|FSSC|HACCP|GHP|TS 22002|PAS)') { $clause = $v; break }
    }
    $items += [pscustomobject]@{ No=[int]$no; Q=$q; Clause=$clause }
  }
  if ($items.Count -eq 0) { continue }

  $deptCount++
  [void]$sb.AppendLine("## เช็คลิสต์ตรวจติดตามภายใน แผนก$dept")
  [void]$sb.AppendLine()

  $seen = @{}
  foreach ($it in ($items | Sort-Object No)) {
    $key = Normalize $it.Q
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $totalQ++

    [void]$sb.AppendLine("### $dept ข้อ $($it.No)")
    [void]$sb.AppendLine("**คำถามที่ผู้ตรวจถาม:** $($it.Q)")
    if ($it.Clause) { [void]$sb.AppendLine("**ข้อกำหนดที่อ้างอิง:** $($it.Clause)") }

    $g = $null
    if ($byQuestion.ContainsKey($key)) { $g = $byQuestion[$key]; $matched++ }
    if ($g) {
      if ($g.cc) { [void]$sb.AppendLine("**เกณฑ์ที่ถือว่าผ่าน:** $($g.cc)") }
      if ($g.nc) { [void]$sb.AppendLine("**ข้อบกพร่องที่มักพบ:** $($g.nc)") }
      if ($g.d)  { [void]$sb.AppendLine("**หลักฐานที่ต้องขอดู:** $($g.d)") }
    }
    [void]$sb.AppendLine()
  }
}

[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host "แผนก      : $deptCount" -ForegroundColor Green
Write-Host "คำถามรวม  : $totalQ"    -ForegroundColor Green
Write-Host "จับคู่เกณฑ์ตัดสินได้: $matched ข้อ ($([math]::Round($matched*100/[Math]::Max(1,$totalQ)))%)" -ForegroundColor Green
Write-Host "เขียนไฟล์ : $OutFile"
Write-Host ""
Write-Host "ขั้นต่อไป: powershell -File scripts\build-kb.ps1" -ForegroundColor Yellow
