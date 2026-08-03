# แกะ JPEG (DCTDecode) จาก PDF สแกน — หา FFD8FF ... FFD9
param([string]$Pdf, [string]$OutDir)
$bytes = [IO.File]::ReadAllBytes($Pdf)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$n = 0
for ($i = 0; $i -lt $bytes.Length - 3; $i++) {
  if ($bytes[$i] -eq 0xFF -and $bytes[$i+1] -eq 0xD8 -and $bytes[$i+2] -eq 0xFF) {
    # หา EOI ตั้งแต่จุดนี้
    for ($j = $i + 3; $j -lt $bytes.Length - 1; $j++) {
      if ($bytes[$j] -eq 0xFF -and $bytes[$j+1] -eq 0xD9) {
        $len = $j + 2 - $i
        if ($len -gt 50000) {  # ข้ามรูปจิ๋ว (โลโก้/thumbnail)
          $n++
          $out = Join-Path $OutDir ("page{0:D2}.jpg" -f $n)
          $seg = New-Object byte[] $len
          [Array]::Copy($bytes, $i, $seg, 0, $len)
          [IO.File]::WriteAllBytes($out, $seg)
        }
        $i = $j + 1
        break
      }
    }
  }
}
Write-Host "extracted: $n images -> $OutDir"
