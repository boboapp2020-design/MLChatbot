<#
=====================================================================
 ML Expert AI — Sync to GitHub
---------------------------------------------------------------------
 commit สิ่งที่เปลี่ยนแล้ว push ขึ้น GitHub ด้วยคำสั่งเดียว

 ครั้งแรกต้องผูก remote ก่อน (ทำครั้งเดียว):
   powershell -File scripts\sync-github.ps1 -Remote https://github.com/USER/REPO.git

 ครั้งต่อไป:
   powershell -File scripts\sync-github.ps1
   powershell -File scripts\sync-github.ps1 -Message "แก้ไอคอนผู้เชี่ยวชาญ"

 ดูว่ามีอะไรเปลี่ยนโดยยังไม่ push:
   powershell -File scripts\sync-github.ps1 -DryRun
=====================================================================
#>
[CmdletBinding()]
param(
  [string] $Message = "",
  [string] $Remote  = "",
  [switch] $DryRun,
  [switch] $Rebuild        # สร้างคลังความรู้ใหม่ก่อน commit
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Fail($m){ Write-Host $m -ForegroundColor Red; exit 1 }

# git เขียนข้อความปกติลง stderr ด้วย และ PowerShell จะแปลงเป็น ErrorRecord
# ทำให้สคริปต์หยุดทั้งที่ไม่ได้ผิดอะไร (เช่นตอนถาม remote ที่ยังไม่มี)
# จึงต้องปิด ErrorActionPreference ชั่วคราวและกลืน stderr ทิ้ง
function Git-Quiet {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $out = & git @args 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    return $out
  } finally { $ErrorActionPreference = $prev }
}

# ── ตรวจว่าเป็น repo ────────────────────────────────────────────────
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { Fail "โฟลเดอร์นี้ยังไม่ใช่ git repo — รัน git init ก่อน" }

# ── ผูก remote (ถ้าระบุมา) ──────────────────────────────────────────
if ($Remote) {
  $existing = Git-Quiet remote get-url origin
  if ($existing) {
    git remote set-url origin $Remote
    Write-Host "เปลี่ยน remote เป็น: $Remote" -ForegroundColor Cyan
  } else {
    git remote add origin $Remote
    Write-Host "ผูก remote: $Remote" -ForegroundColor Cyan
  }
}

$origin = Git-Quiet remote get-url origin
if (-not $origin) {
  Fail @"
ยังไม่ได้ผูก GitHub repo

  1) สร้าง repo เปล่าที่ https://github.com/new  (อย่าติ๊ก Add README)
  2) รันคำสั่งนี้ พร้อม URL ที่ได้:
     powershell -File scripts\sync-github.ps1 -Remote https://github.com/USER/REPO.git
"@
}

# ── สร้างคลังใหม่ถ้าสั่ง ────────────────────────────────────────────
if ($Rebuild) {
  Write-Host "`nสร้างคลังความรู้ใหม่..." -ForegroundColor Cyan
  & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-kb.ps1')      | Select-Object -Last 3
  & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-personas.ps1') | Select-Object -Last 2
}

# ── ดูว่ามีอะไรเปลี่ยน ──────────────────────────────────────────────
$changes = git status --porcelain
if (-not $changes) {
  Write-Host "ไม่มีอะไรเปลี่ยนแปลง" -ForegroundColor DarkGray
  $ahead = Git-Quiet rev-list --count "@{u}..HEAD"
  if ($ahead -and [int]$ahead -gt 0) {
    Write-Host "แต่มี $ahead commit ที่ยังไม่ได้ push" -ForegroundColor Yellow
  } else { exit 0 }
} else {
  Write-Host "`nไฟล์ที่เปลี่ยน:" -ForegroundColor Cyan
  $changes | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" }
  if ($changes.Count -gt 25) { Write-Host "  ... และอีก $($changes.Count - 25) ไฟล์" }
}

# ── ตรวจไฟล์ใหญ่เกินลิมิต GitHub ก่อน push ──────────────────────────
git add -A
$big = @()
foreach ($f in (git diff --cached --name-only)) {
  $p = Join-Path $ProjectRoot $f
  if (Test-Path -LiteralPath $p) {
    $mb = (Get-Item -LiteralPath $p).Length / 1MB
    if ($mb -gt 95) { $big += ("{0,7:N1} MB  {1}" -f $mb, $f) }
  }
}
if ($big.Count -gt 0) {
  git reset *> $null
  Fail @"
มีไฟล์เกิน 95 MB — GitHub จะปฏิเสธทั้ง commit

$($big -join "`n")

เพิ่มไฟล์เหล่านี้ใน .gitignore หรือใช้ Git LFS
"@
}

if ($DryRun) {
  git reset *> $null
  Write-Host "`n(DryRun) ยังไม่ commit และไม่ push" -ForegroundColor Yellow
  exit 0
}

# ── commit ──────────────────────────────────────────────────────────
if ($changes) {
  if (-not $Message) { $Message = "อัปเดต $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
  git commit -q -m "$Message`n`nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  Write-Host "`ncommit: $Message" -ForegroundColor Green
}

# ── push ────────────────────────────────────────────────────────────
Write-Host "`npush ไปที่ $origin ..." -ForegroundColor Cyan
$branch = git rev-parse --abbrev-ref HEAD
git push -u origin $branch
if ($LASTEXITCODE -ne 0) {
  Fail @"

push ไม่สำเร็จ — มักเกิดจากยังไม่ได้ล็อกอิน GitHub บนเครื่องนี้

วิธีแก้: รันคำสั่งนี้ในหน้าต่าง PowerShell ของคุณเอง (ไม่ใช่ในแชท)
เพราะมันจะเปิดเบราว์เซอร์ให้ล็อกอิน
    git push -u origin $branch

ล็อกอินครั้งเดียว Windows จะจำไว้ ครั้งต่อไปสคริปต์นี้จะ push ได้เลย
"@
}

Write-Host "`nเสร็จแล้ว" -ForegroundColor Green
git log --oneline -1
