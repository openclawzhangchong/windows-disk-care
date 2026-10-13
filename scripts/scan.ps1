<#
  scan.ps1 -- machine-independent C-drive inventory.
  Reads config/patterns.json (a signature library). Never hardcodes an app name.
  Reports: volume layout, same-disk trap, per-pattern size + age split + in-use verdict,
  already-existing junctions, and UNRECOGNIZED big folders so the next AI knows what to add.

  Read-only. Writes only the JSON report you point -Out at.

  usage:
    powershell -File scan.ps1
    powershell -File scan.ps1 -PatternsFile .\config\patterns.json -Out .\out\scan.json -AgeDays 7
#>
param(
  [string]$PatternsFile = '',
  [string]$Out = '',
  [int]$AgeDays = 7,
  [double]$UnrecognizedMinGB = 0.3,
  [switch]$IncludeRecycleBin
)
$ErrorActionPreference = 'SilentlyContinue'

# Render Chinese folder names correctly instead of mojibake in the captured output.
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Resolve the script directory absolutely: calling with -File .\scripts\scan.ps1 makes
# $MyInvocation...Path relative, which silently points at the wrong config folder.
$scriptPath = $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
  $scriptPath = Join-Path (Get-Location -PSProvider FileSystem).Provider.CurrentPath $scriptPath
}
$scriptPath = (Resolve-Path -LiteralPath $scriptPath).Path
$here = Split-Path $scriptPath -Parent
$repoRoot = Split-Path $here -Parent
if (-not $PatternsFile) { $PatternsFile = Join-Path $repoRoot 'config\patterns.json' }
if (-not (Test-Path -LiteralPath $PatternsFile)) { throw "patterns file not found: $PatternsFile" }

$cfg = Get-Content -LiteralPath $PatternsFile -Raw | ConvertFrom-Json
$cut = (Get-Date).AddDays(-$AgeDays)

function Expand-Token([string]$tpl) {
  $map = @{
    '%LOCALAPPDATA%' = $env:LOCALAPPDATA
    '%APPDATA%'      = $env:APPDATA
    '%USERPROFILE%'  = $env:USERPROFILE
    '%TEMP%'         = $env:TEMP
    '%PROGRAMDATA%'  = $env:ProgramData
    '%SYSTEMDRIVE%'  = $env:SystemDrive
  }
  $s = $tpl
  foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
  return $s
}

function Get-FolderStats([string]$path) {
  $f = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
  $bytes = (($f | Measure-Object Length -Sum).Sum)
  if ($null -eq $bytes) { $bytes = 0 }
  $old = @($f | Where-Object { $_.LastWriteTime -lt $cut })
  $oldBytes = (($old | Measure-Object Length -Sum).Sum)
  if ($null -eq $oldBytes) { $oldBytes = 0 }
  [pscustomobject]@{
    Files = $f.Count; GB = [math]::Round($bytes/1GB,3)
    OldFiles = $old.Count; OldGB = [math]::Round($oldBytes/1GB,3)
  }
}

# ---- who is running: build a list of on-disk paths and command lines ----
$procs = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -ne 'WmiPrvSE.exe' })
$procPaths = @($procs | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ })
$procCmds  = @($procs | ForEach-Object { $_.CommandLine } | Where-Object { $_ })

function Test-InUse([string]$dir) {
  $hits = @()
  foreach ($p in $procPaths) { if ($p -like ($dir + '\*')) { $hits += "exe: $p" } }
  foreach ($c in $procCmds)  { if ($c -and $c -like ('*' + $dir + '*')) { $hits += "cmdline: " + $c.Substring(0,[Math]::Min(90,$c.Length)) } }
  $hits
}

function Get-LinkTarget([string]$dir) {
  $i = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
  if ($i -and ($i.Attributes -match 'ReparsePoint')) { return ($i.Target -join ';') }
  return ''
}

"==== 1. volumes and the same-disk trap ===="
$diskOf = @{}
Get-Disk | ForEach-Object { $diskOf[$_.Number] = @{ Model = $_.FriendlyName; Media = $_.MediaType } }
$cDisk = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
Get-Partition | Where-Object { $_.DriveLetter } | ForEach-Object {
  $dl = $_.DriveLetter
  $d = Get-PSDrive "$dl"
  $same = if ($_.DiskNumber -eq $cDisk) { '  <-- SAME PHYSICAL DISK AS C: (moving here frees nothing)' } else { '  (separate disk - valid relocation target)' }
  "{0}: disk#{1} {2,-24} free {3,7} GB{4}" -f $dl, $_.DiskNumber, $diskOf[$_.DiskNumber].Model, [math]::Round($d.Free/1GB,1), $same
}

"`n==== 2. known patterns from config ($(@($cfg.patterns).Count) entries loaded) ===="
$rows = @()
foreach ($p in $cfg.patterns) {
  $dir = Expand-Token $p.pathTemplate
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  if ($dir -like '*$Recycle.Bin*' -and -not $IncludeRecycleBin) { continue }
  $st = Get-FolderStats $dir
  if ($st.Files -eq 0 -and $st.GB -eq 0) { continue }
  $link = Get-LinkTarget $dir
  $inuse = @(Test-InUse $dir)
  # order matters: an already-relocated folder must never be offered for action again,
  # even though its bytes still count under the C: path when read through the junction.
  if ($link)                                        { $verdict = 'ALREADY-RELOCATED' }
  elseif ($inuse.Count -gt 0)                       { $verdict = 'IN-USE' }
  elseif ($p.category -in @('junk','rebuildable','evidence')) { $verdict = 'ACTIONABLE' }
  else                                              { $verdict = 'report-only' }
  $rows += [pscustomobject]@{
    Id = $p.id; GB = $st.GB; OldGB = $st.OldGB; Files = $st.Files
    Category = $p.category; Verdict = $verdict
    Link = $link; InUse = $inuse.Count; Path = $dir
  }
}
$rows | Sort-Object GB -Descending |
  ForEach-Object { "{0,7} GB (older-than-${AgeDays}d {1,6}) {2,-11} {3,-12} {4,-18} {5}" -f $_.GB, $_.OldGB, $_.Category, $_.Verdict, $_.Id, $_.Path }

"`n==== 3. reparse points under the profile, classified ===="
# Classification rule (machine independent, and deliberately contains NO non-ASCII text):
#   target on a DIFFERENT drive than the profile  -> relocation junction made by this toolkit
#   target on the SAME drive as the profile        -> Windows built-in per-user alias, leave alone
#   target empty or missing                        -> broken link, investigate
$profileDrive = ([System.IO.Path]::GetPathRoot($env:USERPROFILE)).TrimEnd('\').ToUpper()
$foundLinks = @(Get-ChildItem $env:USERPROFILE -Directory -Force -Recurse -Depth 3 -ErrorAction SilentlyContinue |
  Where-Object { $_.Attributes -match 'ReparsePoint' })
# Windows' built-in per-user aliases, matched by shape rather than by a Chinese folder name
# (a literal like the Start-Menu alias would break PS 5.1 parsing -- see lint-ascii.ps1).
$aliasShape = '\\AppData\\|\\Start Menu\\|\\Documents\\My |\\My Music$|\\My Pictures$|\\My Videos$'
$created = @(); $broken = @(); $staleAlias = @(); $relative = @(); $otherLinks = @(); $aliasCount = 0
foreach ($l in $foundLinks) {
  $tgt = ($l.Target -join ';')
  if (-not [System.IO.Path]::IsPathRooted($tgt)) {
    $relative += "  [RELATIVE link, resolves from its own parent] $($l.FullName) -> $tgt"
    continue
  }
  $isAlias = ($tgt -match $aliasShape -and $tgt -like "*$([System.IO.Path]::GetFileName($env:USERPROFILE))*") -or `
             ($l.Name -match '^(Application Data|Local Settings|Cookies|History|Temporary Internet Files|NetHood|PrintHood|Recent|SendTo|Templates|My Documents|My Music|My Pictures|My Videos)$')
  if ($isAlias) {
    if (Test-Path -LiteralPath $tgt) { $aliasCount++ }
    else { $staleAlias += "  [STALE Windows alias -- target gone: $tgt] $($l.FullName)" }
    continue
  }
  if (-not (Test-Path -LiteralPath $tgt)) { $broken += "  [DEAD relocation link -- app may be failing] $($l.FullName) -> $tgt"; continue }
  $tgtDrive = ([System.IO.Path]::GetPathRoot($tgt)).TrimEnd('\').ToUpper()
  if ($tgtDrive -eq $profileDrive) {
    # same-drive link: made by some tool to dedupe its own folders, not by this toolkit
    $otherLinks += ("  [same-drive link, not ours] {0} -> {1}" -f $l.FullName, $tgt)
    continue
  }
  $created += ("  [RELOCATION] {0} -> {1}" -f $l.FullName, $tgt)
}
if ($created.Count) {
  "  -- relocation junctions (created by this toolkit or a previous run) --"
  $created | ForEach-Object { $_ }
}
"  -- Windows built-in per-user aliases that are healthy: $aliasCount (normal, never delete or 'fix') --"
if ($staleAlias.Count) {
  "  -- STALE Windows aliases: these point somewhere that no longer exists. Pre-existing OS state,"
  "     NOT caused by this toolkit. Usually a profile that was once relocated and moved back."
  "     Do not 'repair' them by deleting; that can break shell folders. Note them and move on. --"
  $staleAlias | ForEach-Object { $_ }
}
if ($relative.Count) { "  -- relative links (not a problem, just not resolvable by Test-Path here) --"; $relative | ForEach-Object { $_ } }
if ($otherLinks.Count) { "  -- same-drive links created by other tools ($($otherLinks.Count)) --"; $otherLinks | ForEach-Object { $_ } }
if ($broken.Count) {
  "  -- DEAD RELOCATION LINKS: a junction we/this toolkit made points at a missing target --"
  $broken | ForEach-Object { $_ }
}
if ($foundLinks.Count -eq 0) { "  (no reparse points under the profile)" }

"`n==== 4. UNRECOGNIZED big folders (>$UnrecognizedMinGB GB) ===="
"     these are the ones you should add to config/patterns.json after deciding what they are"
$known = @($rows | ForEach-Object { $_.Path })
$roots = @("$env:LOCALAPPDATA", "$env:APPDATA", "$env:USERPROFILE")
foreach ($r in $roots) {
  foreach ($d in @(Get-ChildItem $r -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($known | Where-Object { $d.FullName -like ($_ + '*') -or ($_ -like ($d.FullName + '*')) }) { continue }
    $st = Get-FolderStats $d.FullName
    if ($st.GB -lt $UnrecognizedMinGB) { continue }
    if ($d.Attributes -match 'ReparsePoint') { continue }
    $exts = @($d | Get-ChildItem -Recurse -File -Force -EA SilentlyContinue | Group-Object Extension |
              Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending | Select-Object -First 3 |
              ForEach-Object { $_.Name })
    "{0,7} GB  {1}" -f $st.GB, $d.FullName
    "            top extensions: " + ($exts -join ', ')
  }
}

$report = [pscustomobject]@{
  generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  ageDays = $AgeDays
  user = $env:USERNAME
  computer = $env:COMPUTERNAME
  cFreeGB = [math]::Round((Get-PSDrive C).Free/1GB,2)
  patterns = $rows
  junctions = @{ relocation = $created; broken = $broken; sameDriveAliasCount = $aliasCount }
}
if ($Out) {
  $od = Split-Path $Out -Parent
  if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Path $od -Force | Out-Null }
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding UTF8
  "`nwrote machine-readable report -> $Out"
}
"`nC: free = " + [math]::Round((Get-PSDrive C).Free/1GB,2) + " GB   (computer=$env:COMPUTERNAME user=$env:USERNAME)"
"=== done ==="
