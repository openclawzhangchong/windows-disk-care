<#
  lint-ascii.ps1 -- fail loudly if any .ps1 contains non-ASCII bytes.

  Why this exists: Windows PowerShell 5.1 reads a .ps1 without a UTF-8 BOM as ANSI.
  A single Chinese character in a comment or string then breaks the parser with a
  misleading UnexpectedToken error that looks unrelated to the text you added.
  Run this before every hand-off to another machine.
#>
param([string]$Root = '.')
$ErrorActionPreference = 'Stop'
$fail = 0

Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File | ForEach-Object {
  $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
  $bad = @()
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -gt 127) {
      $ctx = [System.Text.Encoding]::UTF8.GetString($bytes[[Math]::Max(0,$i-25)..[Math]::Min($bytes.Length-1,$i+25)])
      $bad += "    byte offset $i (0x{0:X2}) near: {1}" -f $bytes[$i], ($ctx -replace '[\r\n]+',' ')
      if ($bad.Count -ge 3) { break }
    }
  }
  if ($bad.Count -gt 0) {
    $fail++
    "FAIL  " + $_.FullName
    $bad | ForEach-Object { $_ }
    "      fix: rewrite that text in ASCII, or move it into a .md file / a UTF-8 JSON config."
  } else {
    "ok    " + $_.FullName
  }
}
if ($fail -gt 0) {
  "`n$fail file(s) would break Windows PowerShell 5.1. Fix before pushing."
  exit 1
}
"`nAll .ps1 files are ASCII-clean."
