<#
  plan.ps1 -- turn scan.ps1's JSON into an actionable plan.
  The plan is the ONLY place absolute paths are decided; apply.ps1 trusts nothing else.
  Refuses to schedule anything whose scan verdict was IN-USE or ALREADY-RELOCATED.

  usage:
    powershell -File plan.ps1 -ScanJson ..\out\scan.json -Out ..\out\plan.json -DestRoot 'E:\relocated'
#>
param(
  [string]$ScanJson = '',
  [string]$Out = '',
  [string]$DestRoot = 'E:\relocated',
  [int]$AgeDays = 7,
  [double]$MinMoveGB = 0.3
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $ScanJson) { throw 'pass -ScanJson produced by scan.ps1' }
if (-not (Test-Path -LiteralPath $ScanJson)) { throw "not found: $ScanJson" }
$scan = Get-Content -LiteralPath $ScanJson -Raw | ConvertFrom-Json

$destDrive = ([System.IO.Path]::GetPathRoot($DestRoot)).TrimEnd('\',' ')
$srcDrive = ([System.IO.Path]::GetPathRoot($env:USERPROFILE)).TrimEnd('\',' ')
if ($destDrive -eq $srcDrive) {
  throw "destination $destDrive is the same drive as the profile ($srcDrive): moving frees nothing. Pick a drive on another physical disk (see scan section 1)."
}

$clean = @(); $archive = @(); $move = @(); $skipped = @()
foreach ($p in @($scan.patterns)) {
  if (-not $p) { continue }
  $id = $p.Id; $path = $p.Path; $gb = [double]$p.GB; $old = [double]$p.OldGB; $cat = $p.Category; $v = $p.Verdict
  if ($v -eq 'ALREADY-RELOCATED') { $skipped += [pscustomobject]@{Id=$id; Reason='already a junction'; GB=$gb}; continue }
  # IN-USE only blocks categories where deleting is expensive or lossy. Temp is ALWAYS
  # referenced by some process, so blocking it would make junk uncleanable forever;
  # per-file locked-skip already handles the real hazard there.
  if ($v -eq 'IN-USE' -and $cat -ne 'junk') {
    $skipped += [pscustomobject]@{Id=$id; Reason='a running process references it'; GB=$gb}; continue
  }
  switch ($cat) {
    'junk'     { if ($old -gt 0) { $clean += [pscustomobject]@{Id=$id; Path=$path; OldGB=$old; Note=$p.Note} } }
    'evidence' { if ($old -gt 0.05) { $archive += [pscustomobject]@{Id=$id; Path=$path; OldGB=$old; Note=$p.Note} } }
    'rebuildable' {
      if ($gb -ge $MinMoveGB) {
        $move += [pscustomobject]@{ Id=$id; Path=$path; GB=$gb; Target=(Join-Path $DestRoot ("caches\$id")); Action='junction' }
      } elseif ($old -gt 0) {
        $clean += [pscustomobject]@{Id=$id; Path=$path; OldGB=$old; Note='small, delete instead of relocate'}
      }
    }
    'userdata' { if ($gb -ge $MinMoveGB * 4) { $move += [pscustomobject]@{ Id=$id; Path=$path; GB=$gb; Target=(Join-Path $DestRoot ("userdata\$id")); Action='junction-needs-approval' } } }
    default { $skipped += [pscustomobject]@{Id=$id; Reason="category '$cat' is not automatable; decide by hand"; GB=$gb} }
  }
}

$plan = [pscustomobject]@{
  generated   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  computer    = $env:COMPUTERNAME
  ageDays     = $AgeDays
  destRoot    = $DestRoot
  cFreeGB     = $scan.cFreeGB
  allowRoots  = @($clean.Path) + @($archive.Path)
  clean       = $clean
  archive     = $archive
  move        = $move
  skipped     = $skipped
}

"PLAN for $($plan.computer)  (C: free $($plan.cFreeGB) GB, age cutoff $AgeDays days)"
"  clean      : " + (@($clean | ForEach-Object { '{0}({1:0.00}GB)' -f $_.Id, $_.OldGB }) -join ', ')
"  archive    : " + (@($archive | ForEach-Object { '{0}({1:0.00}GB)' -f $_.Id, $_.OldGB }) -join ', ')
"  move       : " + (@($move | ForEach-Object { '{0}({1:0.00}GB)' -f $_.Id, $_.GB }) -join ', ')
"  skipped    : " + (@($skipped | ForEach-Object { '{0}[{1}]' -f $_.Id, $_.Reason }) -join '; ')
$totClean = ($clean | Measure-Object OldGB -Sum).Sum
$totMove  = ($move  | Measure-Object GB -Sum).Sum
"`nPOTENTIAL: clean $([math]::Round($totClean,2)) GB now + relocate $([math]::Round($totMove,2)) GB to $DestRoot"
if ($Out) { $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding UTF8; "wrote -> $Out" }
"=== done ==="
