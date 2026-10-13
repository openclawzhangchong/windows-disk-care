<#
  verify.ps1 -- prove a plan's relocations actually work before you reclaim space.
  Three checks per relocated folder:
    a) the C: path is a reparse point
    b) enumerating through the C: path yields the same file count as the E: target
    c) SHA256 of the largest file matches when read through the link and from the target
  Also prints a regression table for things that must never shrink (userdata categories),
  so an accidental deletion is visible immediately rather than a week later.
#>
param(
  [string]$Plan = '',
  [string]$ScanJson = ''
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if (-not $Plan) { throw 'pass -Plan <plan.json>' }
$p = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json

$allOk = $true
$anyMove = $false
foreach ($m in @($p.move)) {
  if (-not $m.Path) { continue }
  $anyMove = $true
  if (-not (Test-Path -LiteralPath $m.Path)) { "{0,-20} SOURCE-MISSING" -f $m.Id; $allOk = $false; continue }
  $item = Get-Item -LiteralPath $m.Path -Force
  if (-not ($item.Attributes -match 'ReparsePoint')) {
    "{0,-20} NOT-RELOCATED (still a normal folder on C:)" -f $m.Id
    continue
  }
  $tgt = ($item.Target -join ';')
  if (-not (Test-Path -LiteralPath $tgt)) { "{0,-20} DEAD-LINK -> {1}" -f $m.Id, $tgt; $allOk = $false; continue }
  $viaLink  = @(Get-ChildItem -LiteralPath $m.Path -Recurse -File -Force -EA SilentlyContinue)
  $onTarget = @(Get-ChildItem -LiteralPath $tgt  -Recurse -File -Force -EA SilentlyContinue)
  $count = if ($viaLink.Count -eq $onTarget.Count) { 'COUNT-OK' } else { 'COUNT-DIFF'; $script:allOk = $false }
  $hashState = 'NO-FILE'
  if ($viaLink.Count -gt 0) {
    $big = $viaLink | Sort-Object Length -Descending | Select-Object -First 1
    $rel = $big.FullName.Substring($m.Path.Length).TrimStart('\')
    $h1 = (Get-FileHash -LiteralPath $big.FullName -Algorithm SHA256 -EA SilentlyContinue).Hash
    $h2 = (Get-FileHash -LiteralPath (Join-Path $tgt $rel) -Algorithm SHA256 -EA SilentlyContinue).Hash
    if ($h1 -and $h1 -eq $h2) { $hashState = 'HASH-MATCH' } else { $hashState = 'HASH-DIFFER'; $script:allOk = $false }
  }
  if ($count -eq 'COUNT-DIFF') { $script:allOk = $false }
  "{0,-20} via-link {1,6} files  target {2,6} files  {3}  {4}" -f $m.Id, $viaLink.Count, $onTarget.Count, $count, $hashState
  "    -> $tgt"
}
if (-not $anyMove) { "(no relocations in this plan)" }

if ($ScanJson -and (Test-Path -LiteralPath $ScanJson)) {
  "`n--- regression watch: userdata must not have shrunk ---"
  $scan = Get-Content -LiteralPath $ScanJson -Raw | ConvertFrom-Json
  foreach ($s in @($scan.patterns)) {
    if ($s.Category -ne 'userdata') { continue }
    if (-not (Test-Path -LiteralPath $s.Path)) { "{0,-20} MISSING (was {1} GB)" -f $s.Id, $s.GB; continue }
    $now = (Get-ChildItem -LiteralPath $s.Path -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $now) { $now = 0 }
    $nowGB = [math]::Round($now/1GB,3)
    $flag = if ($nowGB -lt ([double]$s.GB - 0.05)) { 'SHRUNKEN - investigate' } else { 'ok' }
    "{0,-20} was {1,7} GB  now {2,7} GB  {3}" -f $s.Id, $s.GB, $nowGB, $flag
  }
}
"`nC: free = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB"
"VERDICT: " + $(if ($allOk) { 'ALL CHECKS PASSED - safe to run apply.ps1 -Reclaim -Apply' } else { 'FAILURES ABOVE - do not reclaim' })
"=== done ==="
