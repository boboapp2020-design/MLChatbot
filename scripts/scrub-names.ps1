<#
=====================================================================
 ML Expert AI — ลบชื่อบุคคลออกจากเอกสารก่อนเข้าคลังความรู้
---------------------------------------------------------------------
 ทำไมต้องมี:
   เว็บนี้เปิดสาธารณะบน GitHub Pages และค้นด้วย Google ได้
   รายงานตรวจประเมินมีชื่อพนักงานผูกกับข้อบกพร่องที่ถูกจับได้
   ("สัมภาษณ์ X พบว่าไม่ทราบขั้นตอน...") ซึ่งเป็นการประเมินการทำงาน
   ของบุคคล ไม่ควรกลายเป็นสิ่งที่ใครก็ค้นเจอ

   ความรู้ที่ระบบต้องใช้คือ "พบข้อบกพร่องอะไร แก้ยังไง"
   ไม่ใช่ "ใครทำผิด" การตัดชื่อออกจึงไม่ทำให้คลังด้อยลงเลย

 วิธีใช้:
   powershell -File scripts\scrub-names.ps1 -Path "Support Document\_text\ไฟล์.txt"
   powershell -File scripts\scrub-names.ps1 -Path "โฟลเดอร์" -Filter "*.txt"

 หมายเหตุ: แก้ไฟล์ทับที่เดิม ใช้กับไฟล์ใน _text ซึ่งสร้างใหม่ได้เสมอ
=====================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$Filter = '*.txt',
  [switch]$WhatIfOnly,
  [switch]$ThaiHonorific   # เปิดกฎคำนำหน้าไทย — ดูคำเตือนในฟังก์ชัน Scrub
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

# ── รายชื่อที่พบในรายงานตรวจของโรงงาน (ผู้ตรวจ LRQA + พนักงาน) ──────
# เก็บเป็นรายการตรงๆ ไม่ใช้ heuristic เดา เพราะการเดาจากตัวพิมพ์ใหญ่
# จะไปโดนศัพท์เทคนิคอย่าง Raw Sugar / Food Safety / Critical Control ด้วย
$FullNames = @(
  'Amphaiphone Souvinkham','Amphayvanh Sysouksavanh','Aoupekha Subsadee',
  'Athiporn Rahulpan','Boon Raksa','Chanchalerm Kaewsaithong',
  'Inpone Syvannavong','Juraporn Pramsakstien','Khamsai Bupphawong',
  'Khamtun Sonepoukpaseuth','Khamtun Sonepukpaserth','Kouy Chanthamalin',
  'Manady Southiborom','Nokham Sikuexay','Norkham Siluexay',
  'Phoukhong Khemmavong','Phouthong Sihachack','Pirot Kamtongkhieo',
  'Pornpimol Chaweewan','Rawiwan Wongmaneethet','Sangsawan Kaewmaneewan',
  'Saranpong Sripanya','Seksun Yhvanmavong','Somkong Sypatum',
  'Sumalee Kasempongtongdee','Surasak Namwan','Thana Wongkaew',
  'Thongkhai Xaysombuth','Valin Leanmechai'
)

# ชื่อต้นและนามสกุลที่โผล่เดี่ยวๆ ต้องตัดด้วย ไม่งั้นยังระบุตัวคนได้
# (เอกสารบางที่เขียนแค่นามสกุล เช่น ช่องลงนาม)
$FirstNames = @(
  'Amphaiphone','Amphayvanh','Aoupekha','Athiporn','Chanchalerm','Inpone',
  'Juraporn','Khamsai','Khamtun','Kouy','Manady','Nokham','Norkham',
  'Phoukhong','Phouthong','Pirot','Pornpimol','Rawiwan','Sangsawan',
  'Saranpong','Seksun','Somkong','Sumalee','Surasak','Thana','Thongkhai','Valin',
  'Chomana','Phuang','Sukhsawan',
  # นามสกุล
  'Souvinkham','Sysouksavanh','Subsadee','Rahulpan','Kaewsaithong',
  'Syvannavong','Pramsakstien','Bupphawong','Sonepoukpaseuth','Sonepukpaserth',
  'Chanthamalin','Southiborom','Sikuexay','Siluexay','Khemmavong','Sihachack',
  'Kamtongkhieo','Chaweewan','Wongmaneethet','Kaewmaneewan','Sripanya',
  'Yhvanmavong','Sypatum','Kasempongtongdee','Namwan','Wongkaew',
  'Xaysombuth','Leanmechai'
)

$MASK = '[ผู้ปฏิบัติงาน]'

function Scrub([string]$t) {
  if (-not $t) { return $t }

  # 1) ชื่อ-นามสกุลเต็ม (ยาวสุดก่อน ไม่งั้นชื่อต้นจะโดนตัดก่อนแล้วนามสกุลค้าง)
  foreach ($n in ($FullNames | Sort-Object { $_.Length } -Descending)) {
    $t = [regex]::Replace($t, [regex]::Escape($n), $MASK, 'IgnoreCase')
  }

  # 2) คำนำหน้าลาว Thao/Tao/Nang + ชื่อ  (Thao Somkong)
  $t = [regex]::Replace($t, '\b(Thao|Tao|Nang|Mr\.?|Ms\.?|Mrs\.?)\s+[A-Z][a-z]{2,}\b', $MASK)

  # 3) ชื่อเดี่ยวที่หลุดมา
  foreach ($n in $FirstNames) {
    $t = [regex]::Replace($t, "(?<![A-Za-z])$([regex]::Escape($n))(?![A-Za-z])", $MASK)
  }

  # 4) คำนำหน้าไทย + ชื่อ — ปิดไว้เป็นค่าตั้งต้น เปิดด้วย -ThaiHonorific
  #
  #    ห้ามใช้ \s* กับคำนำหน้าไทยเด็ดขาด เพราะภาษาไทยไม่มีช่องว่างระหว่างคำ
  #    'คุณ\s*[ก-๙]{2,20}' จะไปกิน คุณภาพ คุณสมบัติ คุณค่า คุณลักษณะ
  #    'นาย' จะกิน นายจ้าง / 'นาง' จะกิน นางสาว
  #    เคยรันแล้วทำให้คำว่า "คุณภาพ" หายไปจากคลังทั้งหมด 430 จุด
  #    ต้องบังคับให้มีช่องว่างคั่นจริง และยังต้องกันคำพ้องอีกชั้น
  if ($ThaiHonorific) {
    $t = [regex]::Replace($t,
      '(?:คุณ|พี่|น้อง|นาย|นาง|นางสาว)\s+(?!ภาพ|สมบัติ|ค่า|ลักษณะ|จ้าง|สาว|งาน)[ก-๙]{2,20}',
      $MASK)
  }

  # 5) ยุบ mask ที่ติดกันจากการแทนหลายชั้น
  $t = [regex]::Replace($t, '(\[ผู้ปฏิบัติงาน\]\s*){2,}', "$MASK ")

  return $t
}

$files = if (Test-Path -LiteralPath $Path -PathType Container) {
  Get-ChildItem -LiteralPath $Path -Filter $Filter -File
} else {
  @(Get-Item -LiteralPath $Path)
}

$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($f in $files) {
  $orig = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $new  = Scrub $orig
  $hits = ([regex]::Matches($new, '\[ผู้ปฏิบัติงาน\]')).Count

  if ($WhatIfOnly) {
    Write-Host ("  {0,-50} จะลบ {1,4} จุด" -f $f.Name, $hits)
  } else {
    [IO.File]::WriteAllText($f.FullName, $new, $utf8)
    Write-Host ("  {0,-50} ลบชื่อ {1,4} จุด" -f $f.Name, $hits)
  }
}
