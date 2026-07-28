<#
=====================================================================
 ML Expert AI — ดึงคลังความรู้จากเว็บ
---------------------------------------------------------------------
 ดาวน์โหลดหน้าเว็บ แปลง HTML เป็นข้อความที่ยังคงโครงหัวข้อไว้
 แล้วเก็บลง Support Document\_text\ เพื่อให้ build-kb.ps1 นำเข้าคลังต่อ

 วิธีใช้:
   powershell -ExecutionPolicy Bypass -File scripts\fetch-web.ps1
   powershell -ExecutionPolicy Bypass -File scripts\fetch-web.ps1 -Url "https://..." -Name "ชื่อไฟล์"
=====================================================================
#>
[CmdletBinding()]
param(
  [string] $Url  = "https://boboapp2020-design.github.io/MLSugartech/",
  [string] $Name = "MLSugartech",
  [string] $OutDir = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'Support Document\_text' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "ดาวน์โหลด: $Url" -ForegroundColor Cyan
$res = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
$html = $res.Content
Write-Host ("  ได้ {0:N0} ตัวอักษร" -f $html.Length)

# ── HTML -> ข้อความ ────────────────────────────────────────────────
# ตัดส่วนที่ไม่ใช่เนื้อหาออกก่อน ไม่งั้นโค้ด JS/CSS จะปนเข้าคลัง
$t = $html
$t = [regex]::Replace($t,'(?is)<script\b.*?</script>',"`n")
$t = [regex]::Replace($t,'(?is)<style\b.*?</style>',"`n")
$t = [regex]::Replace($t,'(?is)<noscript\b.*?</noscript>',"`n")
$t = [regex]::Replace($t,'(?is)<svg\b.*?</svg>',' ')
$t = [regex]::Replace($t,'(?is)<!--.*?-->',' ')

# เก็บโครงหัวข้อไว้เป็น Markdown เพื่อให้ตัวตัด chunk จับหัวข้อได้
for ($i = 1; $i -le 6; $i++) {
  $hashes = '#' * $i
  $t = [regex]::Replace($t,"(?is)<h$i\b[^>]*>(.*?)</h$i>", "`n`n$hashes `$1`n")
}
# ตารางกับรายการ: คงโครงพอให้อ่านรู้เรื่อง
$t = [regex]::Replace($t,'(?is)</t[dh]>\s*<t[dh][^>]*>',' | ')
$t = [regex]::Replace($t,'(?is)<tr[^>]*>',"`n| ")
$t = [regex]::Replace($t,'(?is)</tr>'," |")
$t = [regex]::Replace($t,'(?is)<li\b[^>]*>',"`n- ")
$t = [regex]::Replace($t,'(?is)<br\s*/?>',"`n")
$t = [regex]::Replace($t,'(?is)</(p|div|section|article|tr|table|ul|ol)>',"`n")

# ตัดแท็กที่เหลือทั้งหมด
$t = [regex]::Replace($t,'(?s)<[^>]+>',' ')

# ถอด HTML entity ที่พบบ่อย
$map = @{ '&nbsp;'=' '; '&amp;'='&'; '&lt;'='<'; '&gt;'='>'; '&quot;'='"'; '&#39;'="'";
          '&rsquo;'="'"; '&lsquo;'="'"; '&ldquo;'='"'; '&rdquo;'='"'; '&mdash;'='—';
          '&ndash;'='–'; '&hellip;'='…'; '&deg;'='°'; '&times;'='×'; '&rarr;'='→'; '&bull;'='•' }
foreach ($k in $map.Keys) { $t = $t.Replace($k, $map[$k]) }
$t = [regex]::Replace($t,'&#(\d+);', { param($m) [char][int]$m.Groups[1].Value })

# จัดระเบียบช่องว่าง
$t = [regex]::Replace($t,'[ \t]{2,}',' ')
$t = [regex]::Replace($t,'(?m)^[ \t]+','')
$t = [regex]::Replace($t,'(\r?\n){3,}',"`n`n")
# บรรทัดที่มีแต่สัญลักษณ์/ช่องว่าง ตัดทิ้ง
$t = [regex]::Replace($t,'(?m)^[\s|•\-–—]{0,6}$','')
$t = [regex]::Replace($t,'(\r?\n){3,}',"`n`n")
$t = $t.Trim()

$out = Join-Path $OutDir "$Name.txt"
[IO.File]::WriteAllText($out, $t, (New-Object Text.UTF8Encoding($false)))

$thai  = ([regex]::Matches($t,'[฀-๿]')).Count
$latin = ([regex]::Matches($t,'[A-Za-z]')).Count
$heads = ([regex]::Matches($t,'(?m)^#{1,6}\s')).Count
Write-Host ("  -> {0}" -f $out) -ForegroundColor Green
Write-Host ("     {0:N0} KB · ไทย {1:N0} / อังกฤษ {2:N0} · หัวข้อ {3}" -f `
  ((Get-Item $out).Length/1KB), $thai, $latin, $heads)
