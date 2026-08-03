<#
=====================================================================
 ML Expert AI — แกะรูปหน้าเอกสารออกจาก PDF สแกน
---------------------------------------------------------------------
 ใช้เมื่อ PDF เป็นภาพสแกนล้วน (pdftotext ได้ไฟล์เปล่า) และเครื่องไม่มี
 poppler/ghostscript ที่ render PDF เป็นภาพได้

 รองรับสองแบบที่เจอจริงในเอกสารของโรงงาน:
   1) /DCTDecode ตรงๆ           — ข้อมูล JPEG วางในไฟล์เลย หาได้จาก FFD8FF..FFD9
   2) /FlateDecode + /DCTDecode — JPEG ถูกบีบ zlib อีกชั้น ต้องคลายก่อนถึงจะเจอ
      (ไฟล์ระเบียบภายในของบริษัทเป็นแบบนี้ แบบที่ 1 หาเจอแค่รูปเดียวทั้งเล่ม)

 ไม่รองรับ /JPXDecode (JPEG 2000) — Read tool เปิดไม่ได้อยู่ดี

   powershell -File scripts\pdf-extract-images.ps1 -Pdf "x.pdf" -OutDir "out"
=====================================================================
#>
param(
  [Parameter(Mandatory=$true)][string]$Pdf,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [int]$MinBytes = 20000    # ข้ามรูปจิ๋ว (โลโก้ ลายเซ็น thumbnail)
)

$ErrorActionPreference = 'Stop'
$bytes = [IO.File]::ReadAllBytes($Pdf)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$script:n = 0

function Save-Jpeg([byte[]]$data, [string]$dir, [int]$min) {
  if ($data.Length -lt $min) { return }
  $script:n++
  [IO.File]::WriteAllBytes((Join-Path $dir ("page{0:D2}.jpg" -f $script:n)), $data)
}

# ── แบบที่ 1: JPEG วางตรงๆ ────────────────────────────────────────────
for ($i = 0; $i -lt $bytes.Length - 3; $i++) {
  if ($bytes[$i] -ne 0xFF -or $bytes[$i+1] -ne 0xD8 -or $bytes[$i+2] -ne 0xFF) { continue }
  for ($j = $i + 3; $j -lt $bytes.Length - 1; $j++) {
    if ($bytes[$j] -eq 0xFF -and $bytes[$j+1] -eq 0xD9) {
      $len = $j + 2 - $i
      $seg = New-Object byte[] $len
      [Array]::Copy($bytes, $i, $seg, 0, $len)
      Save-Jpeg $seg $OutDir $MinBytes
      $i = $j + 1
      break
    }
  }
}

# ── แบบที่ 2: JPEG ที่ถูกบีบ zlib อีกชั้น ──────────────────────────────
# หา keyword "stream" แล้วลองคลาย ถ้าคลายแล้วขึ้นต้นด้วย FFD8 แปลว่าเป็น JPEG
# ข้าม 2 ไบต์แรก (หัว zlib) เพราะ DeflateStream ของ .NET รับ raw deflate เท่านั้น
# ทำเสมอ ไม่ใช่เฉพาะตอนแบบที่ 1 ไม่เจอ — ไฟล์จริงมักปนกันทั้งสองแบบในเล่มเดียว
# (ระเบียบภายในของบริษัท: หน้าปกเป็น JPEG ตรงๆ ที่เหลืออีก 44 หน้าถูกบีบ zlib)
$kw = [Text.Encoding]::ASCII.GetBytes('stream')
for ($i = 0; $i -lt $bytes.Length - 6; $i++) {
  if ($bytes[$i] -ne $kw[0]) { continue }
  $hit = $true
  for ($k = 1; $k -lt 6; $k++) { if ($bytes[$i+$k] -ne $kw[$k]) { $hit = $false; break } }
  if (-not $hit) { continue }

  # ข้าม CR/LF หลังคำว่า stream
  $p = $i + 6
  while ($p -lt $bytes.Length -and ($bytes[$p] -eq 13 -or $bytes[$p] -eq 10)) { $p++ }
  if ($p -ge $bytes.Length -or $bytes[$p] -ne 0x78) { continue }   # หัว zlib ต้องเป็น 0x78

  try {
    $ms = New-Object IO.MemoryStream(,$bytes)
    $ms.Position = $p + 2
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    $buf = New-Object byte[] 65536
    while (($r = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $r) }
    $ds.Dispose(); $ms.Dispose()
    $data = $out.ToArray(); $out.Dispose()
    if ($data.Length -gt 3 -and $data[0] -eq 0xFF -and $data[1] -eq 0xD8) {
      Save-Jpeg $data $OutDir $MinBytes
    }
  } catch { }
}

Write-Host "extracted: $($script:n) images -> $OutDir"
