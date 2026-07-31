<#
=====================================================================
 ML Expert AI — DOCX -> ข้อความ
---------------------------------------------------------------------
 .docx คือไฟล์ zip ที่มี word/document.xml อยู่ข้างใน
 สคริปต์นี้ดึง xml ออกมาแล้วแปลงเป็นข้อความธรรมดา โดยรักษาโครงสร้าง
 ที่จำเป็นต่อการตัด chunk ไว้:
   <w:p>   ย่อหน้า        -> ขึ้นบรรทัดใหม่
   <w:tab> แท็บ           -> เว้นวรรค
   <w:br>  ขึ้นบรรทัด     -> ขึ้นบรรทัดใหม่
   <w:tr>  แถวตาราง       -> ขึ้นบรรทัดใหม่
   <w:tc>  ช่องตาราง      -> คั่นด้วย " | "  (รายงานตรวจเป็นตารางเกือบทั้งฉบับ
                             ถ้าไม่คั่น ข้อความทุกช่องจะติดกันจนอ่านไม่ออก)

 วิธีใช้:
   powershell -File scripts\docx-to-text.ps1 -In "path\file.docx" -Out "path\out.txt"
   powershell -File scripts\docx-to-text.ps1 -In "โฟลเดอร์"       -OutDir "Support Document\_text"
=====================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$In,
  [string]$Out    = '',
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Convert-Docx {
  param([string]$Path)

  $zip = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
    if (-not $entry) { throw "ไม่พบ word/document.xml ใน $Path" }
    $sr  = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
    $xml = $sr.ReadToEnd()
    $sr.Close()
  } finally { $zip.Dispose() }

  # ── แปลงแท็กโครงสร้างเป็นตัวคั่นก่อน แล้วค่อยลอกแท็กที่เหลือทิ้ง ──
  # ต้องทำตามลำดับนี้ ไม่งั้นตัวคั่นจะโดนลอกไปด้วย
  $t = $xml
  $t = [regex]::Replace($t, '<w:tab[^>]*/>', ' ')
  $t = [regex]::Replace($t, '<w:br[^>]*/>', "`n")
  $t = [regex]::Replace($t, '</w:p>', "`n")
  $t = [regex]::Replace($t, '</w:tc>', ' | ')
  $t = [regex]::Replace($t, '</w:tr>', "`n")
  $t = [regex]::Replace($t, '<[^>]+>', '')

  # ── คืนค่า XML entity ──
  $t = $t -replace '&lt;','<' -replace '&gt;','>' -replace '&quot;','"' `
          -replace '&apos;',"'" -replace '&amp;','&'

  # ── เก็บกวาด ──
  $t = [regex]::Replace($t, '[ \t]+', ' ')          # ช่องว่างซ้อน
  $t = [regex]::Replace($t, '(\s*\|\s*)+', ' | ')   # ตัวคั่นตารางซ้อน
  $t = [regex]::Replace($t, '^\s*\|\s*|\s*\|\s*$', '', 'Multiline')  # ตัวคั่นหัว/ท้ายบรรทัด
  $t = [regex]::Replace($t, '\n{3,}', "`n`n")       # บรรทัดว่างซ้อน
  $t = ($t -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"

  return $t.Trim()
}

$utf8 = New-Object Text.UTF8Encoding($false)
$files = @()

if (Test-Path -LiteralPath $In -PathType Container) {
  $files = Get-ChildItem -LiteralPath $In -Filter '*.docx' -File -Recurse |
           Where-Object { $_.Name -notlike '~$*' }
} else {
  $files = @(Get-Item -LiteralPath $In)
}

if (-not $files) { Write-Warning 'ไม่พบไฟล์ .docx'; exit }

foreach ($f in $files) {
  $text = Convert-Docx -Path $f.FullName

  $target = if ($Out) { $Out }
            elseif ($OutDir) { Join-Path $OutDir ([IO.Path]::GetFileNameWithoutExtension($f.Name) + '.txt') }
            else { [IO.Path]::ChangeExtension($f.FullName, '.txt') }

  $dir = Split-Path -Parent $target
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  [IO.File]::WriteAllText($target, $text, $utf8)
  Write-Host ("  {0,-52} -> {1,9:N0} ตัวอักษร" -f $f.Name.Substring(0,[Math]::Min(52,$f.Name.Length)), $text.Length)
  Write-Host ("     {0}" -f $target) -ForegroundColor DarkGray
}
