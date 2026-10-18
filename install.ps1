<#
.SYNOPSIS
  Installs agent-crew into a Claude Code user folder (default: $HOME\.claude).
  Windows PowerShell 5.1 and PowerShell 7 compatible.

.DESCRIPTION
  - agents\*.md     -> <ClaudeHome>\agents\
  - skills\*        -> <ClaudeHome>\skills\
  - hooks, scripts, data, templates, catalog, docs\RULES.md, VERSION
                    -> <ClaudeHome>\agent-crew\   (the hooks run from here)
  - templates\USER.md -> <ClaudeHome>\team\USER.md  (only if it does not exist yet)
  - hook entries    -> merged into <ClaudeHome>\settings.json (backup first, idempotent). The ram-guard entries
                       for Bash/PowerShell carry an `if` filter built from the ram-guard.json files: re-run the
                       installer after you change `hook_if` or add a shell kind to your own ram-guard.json.
  What was installed, with a hash of each file, is recorded in <ClaudeHome>\agent-crew\installed.json.

  Re-running is safe. A file that differs from this version is only replaced with -Update, and
  only when it is still exactly what the installer wrote; a file you edited (or one that already
  existed) is never overwritten: the new version is written next to it as "<file>.new".

.PARAMETER ClaudeHome  Target folder (default: $HOME\.claude). Use a temp folder to try it out.
.PARAMETER NoSettings  Do not touch settings.json (hooks then only work through the agents' own front matter).
.PARAMETER Update      Replace installed files that are unchanged by you with the new version; remove files
                       that no longer exist in agent-crew.
.PARAMETER Uninstall   Remove what was installed (files you edited are kept) and the hook entries.
#>
[CmdletBinding()]
param(
  [string]$ClaudeHome = (Join-Path $HOME '.claude'),
  [switch]$NoSettings,
  [switch]$Update,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Source = $PSScriptRoot
$ClaudeHome = [System.IO.Path]::GetFullPath($ClaudeHome)
$CrewDir = Join-Path $ClaudeHome 'agent-crew'
$RecordPath = Join-Path $CrewDir 'installed.json'
$SettingsPath = Join-Path $ClaudeHome 'settings.json'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $Source 'hooks\crew-common.ps1')

# event -> list of @{ Event; Matcher; Script; If }. `If` is a permission-rule filter (Claude Code starts the
# hook only for tool calls that match it); the ram-guard Bash/PowerShell entries get one per command glob
# (`hook_if`) of the kinds in the shipped and the user ram-guard.json, so an ordinary command does not start
# a PowerShell process at all. A user kind with patterns and no hook_if, or "scan_all_commands": true in the
# user file, gives one unconditional Bash|PowerShell entry instead (slower).
$HookPlan = @(
  @{ Event = 'PreToolUse';   Matcher = 'Edit|Write|MultiEdit|NotebookEdit'; Script = 'guard-paths'; If = $null },
  @{ Event = 'PreToolUse';   Matcher = 'Agent|Task'; Script = 'ram-guard'; If = $null }
)
$ramIf = Get-RamHookIfRules @((Join-Path (Join-Path $Source 'data') 'ram-guard.json'), (Join-Path (Join-Path $ClaudeHome 'team') 'ram-guard.json'))
if ($ramIf.All) {
  $HookPlan += @{ Event = 'PreToolUse'; Matcher = 'Bash|PowerShell'; Script = 'ram-guard'; If = $null }
} else {
  foreach ($tool in 'Bash', 'PowerShell') {
    foreach ($glob in $ramIf.Globs) { $HookPlan += @{ Event = 'PreToolUse'; Matcher = $tool; Script = 'ram-guard'; If = "$tool($glob)" } }
  }
}
# no-session-links: only for git commit / gh commands (a `git commit*` call is the only one that starts it).
foreach ($tool in 'Bash', 'PowerShell') {
  foreach ($glob in 'git commit*', 'git commit-tree*', 'gh pr create*', 'gh pr edit*', 'gh pr comment*', 'gh issue*') {
    $HookPlan += @{ Event = 'PreToolUse'; Matcher = $tool; Script = 'no-session-links'; If = "$tool($glob)" }
  }
}
$HookPlan += @(
  @{ Event = 'PostToolUse';  Matcher = 'Edit|Write|MultiEdit|NotebookEdit'; Script = 'check-caps'; If = $null },
  @{ Event = 'PreCompact';   Matcher = $null; Script = 'pre-compact'; If = $null },
  @{ Event = 'PostCompact';  Matcher = $null; Script = 'post-compact'; If = $null },
  @{ Event = 'SessionStart'; Matcher = $null; Script = 'session-start'; If = $null }
)

# ---------- helpers ----------

function Get-Sha256([byte[]]$Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-RelKey([string]$Full) {
  $base = $ClaudeHome.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  return $Full.Substring($base.Length).Replace('\', '/')
}

function Get-HookCommand([string]$Script) {
  $path = Join-Path (Join-Path $CrewDir 'hooks') "$Script.ps1"
  return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $path)
}

# Exactly the commands this installer writes (plus the ones recorded by an earlier run in
# installed.json). A user's own hook that merely points into some agent-crew folder is never ours.
$script:OurCommands = @($HookPlan | ForEach-Object { Get-HookCommand $_.Script })

function Test-IsOurHook([string]$Command) {
  return ($script:OurCommands -contains $Command)
}

function Read-Record {
  $rec = [ordered]@{ version = $null; files = [ordered]@{}; hookCommands = @() }
  if (Test-Path -LiteralPath $RecordPath -PathType Leaf) {
    $j = [System.IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json
    $rec.version = $j.version
    if ($j.files) { foreach ($p in $j.files.PSObject.Properties) { $rec.files[$p.Name] = [string]$p.Value } }
    if ($j.hookCommands) { $rec.hookCommands = @($j.hookCommands | ForEach-Object { [string]$_ }) }
    $script:OurCommands = @($script:OurCommands) + @($rec.hookCommands) | Select-Object -Unique
  }
  return $rec
}

function Save-Record($Rec) {
  if (-not (Test-Path -LiteralPath $CrewDir)) { New-Item -ItemType Directory -Path $CrewDir | Out-Null }
  $obj = [ordered]@{
    version     = $Rec.version
    installedAt = (Get-Date).ToString('o')
    claudeHome  = $ClaudeHome
    hookCommands = @($script:OurCommands | Select-Object -First $HookPlan.Count)
    files       = $Rec.files
  }
  [System.IO.File]::WriteAllText($RecordPath, ($obj | ConvertTo-Json -Depth 5), $Utf8)
}

function New-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# The files to install: @{ Src; Dest; IfMissing }
function Get-Plan {
  $plan = New-Object System.Collections.Generic.List[object]
  foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $Source 'agents') -Filter '*.md' -File)) {
    $plan.Add(@{ Src = $f.FullName; Dest = (Join-Path $ClaudeHome "agents\$($f.Name)"); IfMissing = $false })
  }
  $skillsRoot = Join-Path $Source 'skills'
  foreach ($f in (Get-ChildItem -LiteralPath $skillsRoot -Recurse -File)) {
    $rel = $f.FullName.Substring($skillsRoot.Length).TrimStart('\', '/')
    $plan.Add(@{ Src = $f.FullName; Dest = (Join-Path $ClaudeHome "skills\$rel"); IfMissing = $false })
  }
  foreach ($dir in 'hooks', 'scripts', 'data', 'templates', 'catalog') {
    $root = Join-Path $Source $dir
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
      $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
      $plan.Add(@{ Src = $f.FullName; Dest = (Join-Path $CrewDir "$dir\$rel"); IfMissing = $false })
    }
  }
  $plan.Add(@{ Src = (Join-Path $Source 'docs\RULES.md'); Dest = (Join-Path $CrewDir 'docs\RULES.md'); IfMissing = $false })
  $plan.Add(@{ Src = (Join-Path $Source 'VERSION'); Dest = (Join-Path $CrewDir 'VERSION'); IfMissing = $false })
  $plan.Add(@{ Src = (Join-Path $Source 'templates\USER.md'); Dest = (Join-Path $ClaudeHome 'team\USER.md'); IfMissing = $true })
  return $plan
}

function Get-SourceBytes($Item) {
  return , [System.IO.File]::ReadAllBytes($Item.Src)
}

# ---------- settings.json ----------

function Read-Settings {
  if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return [pscustomobject]@{} }
  $text = [System.IO.File]::ReadAllText($SettingsPath)
  if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
  try { return ($text | ConvertFrom-Json) }
  catch { throw "settings.json is not valid JSON, not touching it: $SettingsPath ($($_.Exception.Message))" }
}

function Save-Settings($Settings) {
  $backup = $null
  if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $backup = "$SettingsPath.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    Copy-Item -LiteralPath $SettingsPath -Destination $backup
    # Keep only the newest 3 backups.
    $old = @(Get-ChildItem -LiteralPath (Split-Path -Parent $SettingsPath) -Filter 'settings.json.bak-*' -File | Sort-Object Name -Descending | Select-Object -Skip 3)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force }
  } else {
    New-Dir (Split-Path -Parent $SettingsPath)
  }
  [System.IO.File]::WriteAllText($SettingsPath, ($Settings | ConvertTo-Json -Depth 30), $Utf8)
  if ($backup) { Write-Host "  settings.json updated (backup: $backup)" } else { Write-Host '  settings.json created' }
}

function Get-EventGroups($Settings, [string]$Event) {
  if ($Settings.PSObject.Properties['hooks'] -and $Settings.hooks.PSObject.Properties[$Event]) { return @($Settings.hooks.$Event) }
  return @()
}

function Remove-OurHooks($Settings) {
  # Removes every hook command of agent-crew; returns $true if anything was removed.
  $changed = $false
  if (-not $Settings.PSObject.Properties['hooks']) { return $false }
  foreach ($prop in @($Settings.hooks.PSObject.Properties)) {
    $kept = @()
    foreach ($group in @($prop.Value)) {
      $inner = @($group.hooks)
      $left = @($inner | Where-Object { -not ($_.command -and (Test-IsOurHook ([string]$_.command))) })
      if ($left.Count -ne $inner.Count) { $changed = $true }
      if ($left.Count -gt 0) { $group.hooks = $left; $kept += $group }
    }
    if ($kept.Count -eq 0) { $Settings.hooks.PSObject.Properties.Remove($prop.Name) } else { $Settings.hooks.$($prop.Name) = $kept }
  }
  if ($Settings.hooks.PSObject.Properties.Count -eq 0) { $Settings.PSObject.Properties.Remove('hooks') }
  return $changed
}

function Test-HooksCurrent($Settings) {
  # True when exactly the expected entries exist (each once) and nothing else of ours.
  $ours = 0
  if ($Settings.PSObject.Properties['hooks']) {
    foreach ($prop in $Settings.hooks.PSObject.Properties) {
      foreach ($group in @($prop.Value)) { foreach ($h in @($group.hooks)) { if ($h.command -and (Test-IsOurHook ([string]$h.command))) { $ours++ } } }
    }
  }
  if ($ours -ne $HookPlan.Count) { return $false }
  foreach ($p in $HookPlan) {
    $cmd = Get-HookCommand $p.Script
    $found = 0
    foreach ($group in (Get-EventGroups $Settings $p.Event)) {
      $groupMatcher = if ($group.PSObject.Properties['matcher']) { [string]$group.matcher } else { $null }
      foreach ($h in @($group.hooks)) {
        $hookIf = if ($h.PSObject.Properties['if']) { [string]$h.if } else { '' }
        if ([string]$h.command -eq $cmd -and $groupMatcher -eq $p.Matcher -and $hookIf -eq [string]$p.If) { $found++ }
      }
    }
    if ($found -ne 1) { return $false }
  }
  return $true
}

function Install-Hooks {
  $settings = $script:ParsedSettings
  if (Test-HooksCurrent $settings) { Write-Host '  settings.json: hook entries already current'; return }
  [void](Remove-OurHooks $settings)
  if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($p in $HookPlan) {
    $entry = [ordered]@{}
    if ($p.Matcher) { $entry['matcher'] = $p.Matcher }
    $hookObj = [ordered]@{ type = 'command'; command = (Get-HookCommand $p.Script) }
    if ($p.If) { $hookObj['if'] = $p.If }
    $entry['hooks'] = @([pscustomobject]$hookObj)
    $groups = @(Get-EventGroups $settings $p.Event) + @([pscustomobject]$entry)
    if ($settings.hooks.PSObject.Properties[$p.Event]) { $settings.hooks.$($p.Event) = $groups }
    else { $settings.hooks | Add-Member -NotePropertyName $p.Event -NotePropertyValue $groups }
  }
  Save-Settings $settings
}

function Uninstall-Hooks {
  if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return }
  $settings = $script:ParsedSettings
  if (Remove-OurHooks $settings) { Save-Settings $settings; Write-Host '  settings.json: hook entries removed' }
  else { Write-Host '  settings.json: no hook entries of agent-crew found' }
}

# ---------- validate settings.json FIRST ----------
# Nothing is copied, removed or recorded unless settings.json can be parsed (no half-installs).

$script:ParsedSettings = $null
if (-not $NoSettings) {
  try {
    $script:ParsedSettings = Read-Settings
    if ($script:ParsedSettings -isnot [System.Management.Automation.PSCustomObject]) { throw "settings.json must contain a JSON object: $SettingsPath" }
  } catch {
    Write-Host ("ERROR: " + $_.Exception.Message)
    Write-Host 'Nothing was changed. Fix or remove the file (comments are not allowed), or use -NoSettings.'
    exit 1
  }
}

# ---------- uninstall ----------

if ($Uninstall) {
  Write-Host "Uninstalling agent-crew from $ClaudeHome"
  $rec = Read-Record
  $removed = 0; $kept = 0
  foreach ($key in @($rec.files.Keys)) {
    $dest = Join-Path $ClaudeHome ($key.Replace('/', '\'))
    if (Test-Path -LiteralPath "$dest.new") { Remove-Item -LiteralPath "$dest.new" -Force }
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { continue }
    if ((Get-Sha256 ([System.IO.File]::ReadAllBytes($dest))) -eq $rec.files[$key]) {
      Remove-Item -LiteralPath $dest -Force; $removed++
    } else {
      Write-Host "  kept (you edited it): $key"; $kept++
    }
  }
  # Remove folders that became empty, deepest first, but never the Claude home or its agents, skills and team folders.
  $protected = @($ClaudeHome, (Join-Path $ClaudeHome 'agents'), (Join-Path $ClaudeHome 'skills'), (Join-Path $ClaudeHome 'team')) | ForEach-Object { $_.TrimEnd([char]92, [char]47).ToLowerInvariant() }
  foreach ($key in ($rec.files.Keys | Sort-Object { $_.Length } -Descending)) {
    $dir = Split-Path -Parent (Join-Path $ClaudeHome ($key.Replace('/', [string][char]92)))
    while ($dir.Length -gt $ClaudeHome.Length -and ($protected -notcontains $dir.TrimEnd([char]92, [char]47).ToLowerInvariant())) {
      if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
      $dir = Split-Path -Parent $dir
    }
  }
  if (Test-Path -LiteralPath $RecordPath) { Remove-Item -LiteralPath $RecordPath -Force }
  if ((Test-Path -LiteralPath $CrewDir) -and -not (Get-ChildItem -LiteralPath $CrewDir -Force)) { Remove-Item -LiteralPath $CrewDir -Force }
  if (-not $NoSettings) { Uninstall-Hooks }
  Write-Host "Done: $removed file(s) removed, $kept kept."
  exit 0
}

# ---------- install / update ----------

$version = ([System.IO.File]::ReadAllText((Join-Path $Source 'VERSION'))).Trim()
$rec = Read-Record
$first = ($null -eq $rec.version)
Write-Host ("{0} agent-crew {1} in {2}" -f $(if ($Update) { 'Updating' } elseif ($first) { 'Installing' } else { 'Re-checking' }), $version, $ClaudeHome)

$plan = Get-Plan
$planKeys = @{}
$counts = @{ new = 0; same = 0; updated = 0; pending = 0; dotnew = 0; skipped = 0 }

foreach ($item in $plan) {
  $key = Get-RelKey $item.Dest
  $planKeys[$key] = $true
  $bytes = Get-SourceBytes $item
  $newHash = Get-Sha256 $bytes
  $dest = $item.Dest

  if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
    if ($item.IfMissing -and $rec.files.Contains($key)) { $counts.skipped++; continue }  # the user deleted it on purpose
    New-Dir (Split-Path -Parent $dest)
    [System.IO.File]::WriteAllBytes($dest, $bytes)
    $rec.files[$key] = $newHash
    $counts.new++
    continue
  }
  if ($item.IfMissing) { $counts.skipped++; continue }

  $curHash = Get-Sha256 ([System.IO.File]::ReadAllBytes($dest))
  if ($curHash -eq $newHash) {
    $rec.files[$key] = $newHash
    $counts.same++
    if (Test-Path -LiteralPath "$dest.new") { Remove-Item -LiteralPath "$dest.new" -Force }
  } elseif ($rec.files.Contains($key) -and $curHash -eq $rec.files[$key]) {
    if ($Update) {
      [System.IO.File]::WriteAllBytes($dest, $bytes)
      $rec.files[$key] = $newHash
      $counts.updated++
      if (Test-Path -LiteralPath "$dest.new") { Remove-Item -LiteralPath "$dest.new" -Force }
    } else {
      Write-Host "  newer version available (run with -Update): $key"
      $counts.pending++
    }
  } else {
    [System.IO.File]::WriteAllBytes("$dest.new", $bytes)
    Write-Host "  differs from your copy, new version written next to it: $key.new"
    $counts.dotnew++
  }
}

# Files that were installed earlier but no longer exist in agent-crew.
if ($Update) {
  foreach ($key in @($rec.files.Keys)) {
    if ($planKeys.ContainsKey($key)) { continue }
    $dest = Join-Path $ClaudeHome ($key.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $rec.files.Remove($key); continue }
    if ((Get-Sha256 ([System.IO.File]::ReadAllBytes($dest))) -eq $rec.files[$key]) {
      Remove-Item -LiteralPath $dest -Force; $rec.files.Remove($key)
      Write-Host "  removed (no longer in agent-crew): $key"
    } else {
      Write-Host "  no longer in agent-crew but you edited it, kept: $key"
    }
  }
}

$rec.version = $version
Save-Record $rec

if ($NoSettings) {
  Write-Host '  settings.json: skipped (-NoSettings). The guard and the other hooks are then NOT registered.'
} else {
  Install-Hooks
}

Write-Host ("Done: {0} new, {1} updated, {2} unchanged, {3} update(s) pending, {4} .new file(s) written." -f $counts.new, $counts.updated, $counts.same, $counts.pending, $counts.dotnew)
Write-Host 'Restart Claude Code (or open /hooks) so it picks up the hooks and agents.'
