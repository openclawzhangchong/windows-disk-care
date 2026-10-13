<#
  apply.ps1 -- execute a plan.json produced by plan.ps1.

  Safety model (all three layers, do not remove any):
    1. absolute-path allowlist taken from the plan itself; anything outside is refused
    2. age filter: only files older than -AgeDays are deleted
    3. in-use handling: a file that cannot be deleted is counted and skipped, never retried blindly
  Moves never delete: they copy, verify file count and byte total, then RENAME the original
  to <name>.cubackup and leave a junction. Space is only reclaimed by a separate -Reclaim pass
  after verify.ps1 says the junction returns identical bytes.

  usage:
    powershell -File apply.ps1 -Plan ..\out\plan.json                     # dry run
    powershell -File apply.ps1 -Plan ..\out\plan.json -Do clean           # delete junk
    powershell -File apply.ps1 -Plan ..\out\plan.json -Do archive         # 7z logs to dest drive
    powershell -File apply.ps1 -Plan ..\out\plan.json -Do move -Apply     # relocate + junction
    powershell -File apply.ps1 -Plan ..\out\plan.json -Reclaim -Apply     # remove verified backups
#>
param(
  [string]$Plan = '',
  [string]$Do = 'clean',
  [switch]$Apply,
  [switch]$Reclaim
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $Plan) { throw 'pass -Plan <plan.json>' }
$p = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
$cut = (Get-Date).AddDays(-([int]$p.ageDays))
$allow = @($p.allowRoots | Where-Object { $_ })

function Test-Allowed([string]$file) {
  foreach ($r in $allow) { if ($r -and ($file -like ($r + '\*'))) { return $true } }
  return $false
}
function Get-Stats([string]$path) {
  $f = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
  $b = (($f | Measure-Object Length -Sum).Sum); if ($null -eq $b) { $b = 0 }
  [pscustomobject]@{ Files = $f.Count; Bytes = $b }
}
$freed = [double]0

if ($Reclaim) {
  if (-not $Apply) { "DRY-RUN: would remove verified .cubackup copies. Pass -Apply." }
  foreach ($m in @($p.move)) {
    if (-not $m.Path) { continue }
    $leaf = Split-Path $m.Path -Leaf
    $bk = Join-Path (Split-Path $m.Path -Parent) ($leaf + '.cubackup')
    if (-not (Test-Path -LiteralPath $bk)) { continue }
    $src = Get-Item -LiteralPath $m.Path -Force
    if (-not ($src.Attributes -match 'ReparsePoint')) { "REFUSE: $($m.Path) is not a junction, keeping $bk"; continue }
    $sz = (Get-ChildItem -LiteralPath $bk -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($Apply) {
      Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $bk) { "  PARTIAL: $bk still present" } else { "  reclaimed " + [math]::Round($sz/1GB,2) + " GB from $bk" }
    } else { "  would reclaim " + [math]::Round($sz/1GB,2) + " GB from $bk" }
  }
  "C: free = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB"
  return
}

if ($Do -eq 'clean') {
  foreach ($c in @($p.clean)) {
    if (-not $c.Path -or -not (Test-Path -LiteralPath $c.Path)) { continue }
    $items = @(Get-ChildItem -LiteralPath $c.Path -Recurse -File -Force -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
    $bytes = (($items | Measure-Object Length -Sum).Sum); if ($null -eq $bytes) { $bytes = 0 }
    "{0,-18} {1,6} files {2,7:N3} GB   {3}" -f $c.Id, $items.Count, ($bytes/1GB), $c.Path
    if ($Apply) {
      $gone = 0
      foreach ($f in $items) {
        if (-not (Test-Allowed $f.FullName)) { continue }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f.FullName)) { $gone++; $freed += $f.Length }
      }
      "    deleted $gone / $($items.Count) (rest were locked or outside the allowlist)"
    }
  }
  if ($Apply) { "C: free now = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB (reclaimed " + [math]::Round($freed/1GB,2) + " GB)" }
  elseif (@($p.clean).Count -eq 0) { "nothing categorised as junk in this plan" }
  "`nallowlist in force:"; $allow | ForEach-Object { "  $_" }
  return
}

if ($Do -eq 'archive') {
  $seven = 'C:\Program Files\7-Zip\7z.exe'
  if (-not (Test-Path $seven)) { throw '7-Zip not found at C:\Program Files\7-Zip\7z.exe - install it or edit this line' }
  $aroot = Join-Path $p.destRoot 'log-archive'
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  foreach ($a in @($p.archive)) {
    if (-not $a.Path -or -not (Test-Path -LiteralPath $a.Path)) { continue }
    $files = @(Get-ChildItem -LiteralPath $a.Path -Recurse -File -Force -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
    $bytes = (($files | Measure-Object Length -Sum).Sum); if ($null -eq $bytes) { $bytes = 0 }
    "{0,-18} {1,6} files {2,7:N3} GB -> archive" -f $a.Id, $files.Count, ($bytes/1GB)
    if (-not $Apply) { continue }
    if ($files.Count -eq 0) { "    nothing older than cutoff"; continue }
    if (-not (Test-Path -LiteralPath $aroot)) { New-Item -ItemType Directory -Path $aroot -Force | Out-Null }
    $stage = Join-Path $aroot ("stage-$stamp-" + $a.Id)
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($a.Path.Length).TrimStart('\')
      $dst = Join-Path $stage $rel
      $d = Split-Path $dst -Parent
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
      Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
    }
    $st = Get-Stats $stage
    if ($st.Files -lt $files.Count -or $st.Bytes -lt $bytes) {
      "    INCOMPLETE staging ($($st.Files)/$($files.Count)) - refusing to delete any source file"
      Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
      continue
    }
    $arch = Join-Path $aroot ("$($a.Id)-$stamp.7z")
    & $seven a -t7z -mx=5 -mmt=on $arch "$stage\*" | Out-Null
    $rca = $LASTEXITCODE
    & $seven t $arch | Out-Null
    $rct = $LASTEXITCODE
    if ($rca -ne 0 -or $rct -ne 0) { "    archive failed (add=$rca test=$rct) - source untouched"; Remove-Item -LiteralPath $stage -Recurse -Force; continue }
    $ab = (Get-Item -LiteralPath $arch).Length
    "    archived -> $arch ($([math]::Round($ab/1MB,1)) MB, integrity test passed)"
    Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
    foreach ($f in $files) {
      if (-not (Test-Allowed $f.FullName)) { continue }
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $f.FullName)) { $freed += $f.Length }
    }
  }
  if ($Apply) { "C: free now = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB (reclaimed " + [math]::Round($freed/1GB,2) + " GB)" }
  return
}

if ($Do -eq 'move') {
  foreach ($m in @($p.move)) {
    if (-not $m.Path) { continue }
    if (-not (Test-Path -LiteralPath $m.Path)) { "skip missing: $($m.Path)"; continue }
    $src = Get-Item -LiteralPath $m.Path -Force
    if ($src.Attributes -match 'ReparsePoint') { "skip already relocated: $($m.Path)"; continue }
    if ($m.Action -eq 'junction-needs-approval') { "REFUSE auto-move of userdata id=$($m.Id) ($($m.Path)) - it holds user files. Get explicit approval and use the manual route." ; continue }
    $st = Get-Stats $m.Path
    "=== relocate $($m.Id): $($st.Files) files, $([math]::Round($st.Bytes/1GB,2)) GB -> $($m.Target)"
    if (-not $Apply) { "    dry run"; continue }
    New-Item -ItemType Directory -Path (Split-Path $m.Target -Parent) -Force | Out-Null
    & robocopy.exe $m.Path $m.Target /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /MT:8 /XJ "/LOG+$($m.Target)_robocopy.log" | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { "    robocopy FAILED ($rc), source untouched"; continue }
    $tt = Get-Stats $m.Target
    if ($tt.Files -lt $st.Files -or $tt.Bytes -lt $st.Bytes) { "    verify FAILED (target $($tt.Files)/$($st.Files) files), source untouched"; continue }
    $leaf = Split-Path $m.Path -Leaf
    $bk = Join-Path (Split-Path $m.Path -Parent) ($leaf + '.cubackup')
    if (Test-Path -LiteralPath $bk) { "    a $bk already exists - resolve first"; continue }
    try { Rename-Item -LiteralPath $m.Path -NewName ($leaf + '.cubackup') -ErrorAction Stop }
    catch { "    cannot rename (still in use): $($_.Exception.Message.Split([Environment]::NewLine)[0]) - removing the copy we just made"
            Remove-Item -LiteralPath $m.Target -Recurse -Force -EA SilentlyContinue; continue }
    & cmd.exe /c "mklink /J `"$($m.Path)`" `"$($m.Target)`"" | Out-Null
    if (-not (Test-Path -LiteralPath $m.Path)) {
      "    junction failed - restoring original name"
      Rename-Item -LiteralPath $bk -NewName $leaf -EA SilentlyContinue
      continue
    }
    "    junction live: $($m.Path) -> $($m.Target)   backup kept at $bk ($([math]::Round($st.Bytes/1GB,2)) GB)"
    "    NEXT: run verify.ps1, then apply.ps1 -Reclaim -Apply to actually free the space"
  }
  "C: free = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB   (unchanged until -Reclaim)"
  return
}
throw "unknown -Do '$Do' (clean|archive|move)"
