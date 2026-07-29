#Requires -Version 5.1
<#
=====================================================================
 ฟังก์ชันอ่าน .xlsx โดยไม่ต้องมี Excel ติดตั้ง
---------------------------------------------------------------------
 .xlsx คือไฟล์ zip ที่มี XML อยู่ข้างใน อ่านตรงได้เลย
 ไม่ต้องพึ่ง Excel COM ซึ่งเครื่องที่ไม่มี Office จะใช้ไม่ได้

 ใช้ด้วยการ dot-source:  . scripts\xlsx-lib.ps1
=====================================================================
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem

# โหนด XML อาจเป็นสตริงตรงๆ หรือเป็น object ที่มี #text เมื่อมีแอตทริบิวต์ xml:space
function Get-XmlText($node) {
  if ($null -eq $node) { return '' }
  if ($node -is [string]) { return $node }
  if ($node.'#text') { return [string]$node.'#text' }
  return ''
}

function Convert-ColumnToIndex([string]$ref) {
  # "BC12" -> 55  (นับจาก 1)
  $letters = ($ref -replace '\d','')
  $n = 0
  foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
  return $n
}

function Read-XlsxRows {
  <# คืนค่าเป็น array ของ array — แต่ละแถวคือค่าตามคอลัมน์ 1..n #>
  param([Parameter(Mandatory=$true)][string]$Path)

  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    # ── ตารางข้อความที่ใช้ร่วมกัน ────────────────────────────────
    # เซลล์ข้อความเก็บแค่เลขดัชนีชี้มาที่ตารางนี้ ไม่ได้เก็บข้อความตรงๆ
    $shared = New-Object System.Collections.ArrayList
    $e = $zip.Entries | Where-Object { $_.FullName -eq 'xl/sharedStrings.xml' }
    if ($e) {
      $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
      [xml]$sx = $sr.ReadToEnd(); $sr.Close()
      foreach ($si in $sx.sst.si) {
        if ($si.t) { [void]$shared.Add((Get-XmlText $si.t)) }
        else {
          # ข้อความถูกแบ่งเป็นหลายท่อน (<r>) เมื่อมีการจัดรูปแบบต่างกันในเซลล์เดียว
          [void]$shared.Add((($si.r | ForEach-Object { Get-XmlText $_.t }) -join ''))
        }
      }
    }

    $rows = New-Object System.Collections.ArrayList
    $sheets = $zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' } |
              Sort-Object { [int]([regex]::Match($_.FullName,'sheet(\d+)').Groups[1].Value) }

    foreach ($sh in $sheets) {
      $sr = New-Object IO.StreamReader($sh.Open(), [Text.Encoding]::UTF8)
      [xml]$wx = $sr.ReadToEnd(); $sr.Close()

      foreach ($row in $wx.worksheet.sheetData.row) {
        $cells = @{}
        $maxc = 0
        foreach ($c in $row.c) {
          $ci = Convert-ColumnToIndex $c.r
          if ($ci -gt $maxc) { $maxc = $ci }
          $v = ''
          if     ($c.t -eq 's')         { $idx = [int]$c.v; if ($idx -lt $shared.Count) { $v = $shared[$idx] } }
          elseif ($c.t -eq 'inlineStr') { $v = Get-XmlText $c.is.t }
          elseif ($null -ne $c.v)       { $v = [string]$c.v }
          $cells[$ci] = ($v -replace '\s+',' ').Trim()
        }
        if ($maxc -eq 0) { continue }
        $arr = @()
        for ($i = 1; $i -le $maxc; $i++) { $arr += $(if ($cells.ContainsKey($i)) { $cells[$i] } else { '' }) }
        if (($arr -join '').Trim()) { [void]$rows.Add($arr) }
      }
    }
    return $rows
  } finally { $zip.Dispose() }
}
