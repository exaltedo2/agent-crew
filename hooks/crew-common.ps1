<#
.SYNOPSIS
  Shared helpers for the agent-crew hooks and scripts (dot-source this file).
  Windows PowerShell 5.1 and PowerShell 7 compatible. No output when dot-sourced.
#>

# Line caps of the team files. The retro prunes files back under these.
$script:CrewCaps = [ordered]@{ 'state.md' = 50; 'routing.md' = 150; 'roster.md' = 80 }
$script:CrewMaxActiveAgents = 7
# Agents that may write only into .claude/team/reports/ (PROJECT.md report_only_agents adds to it).
$script:CrewReportOnlyAgents = @('thinker', 'architect', 'reviewer', 'ui-reviewer', 'security-reviewer', 'perf-profiler')

function Read-StdinText {
  # Reads all of stdin as UTF-8. Returns '' when there is none.
  try {
    $stream = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
    return $reader.ReadToEnd()
  } catch {
    return ''
  }
}

function ConvertFrom-HookText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Read-HookInput {
  # Reads the hook JSON from stdin as UTF-8. Returns $null when there is none or it is invalid.
  return (ConvertFrom-HookText (Read-StdinText))
}

function Get-UserClaudeDirs {
  # The user-wide Claude folders (they hold team/USER.md; they are never a project's team folder).
  $dirs = New-Object System.Collections.Generic.List[string]
  try {
    if ($HOME) { $dirs.Add([System.IO.Path]::GetFullPath((Join-Path $HOME '.claude'))) }
    if ($env:CLAUDE_CONFIG_DIR) { $dirs.Add([System.IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR)) }
    # This script lives in the agent-crew folder inside the Claude home when installed.
    $crew = Split-Path -Parent $PSScriptRoot
    if ((Split-Path -Leaf $crew) -eq 'agent-crew' -and [System.IO.File]::Exists((Join-Path $crew 'installed.json'))) { $dirs.Add([System.IO.Path]::GetFullPath((Split-Path -Parent $crew))) }
  } catch { }
  return @($dirs | ForEach-Object { $_.TrimEnd([char]92, [char]47).ToLowerInvariant() })
}

function Get-LongPath {
  # Expands 8.3 short names (PROGRA~1) so a short alias cannot dodge a path comparison. For a file that
  # does not exist yet the existing parent is expanded. Short names always contain '~', so paths without
  # one are returned at once (no cost). With -Strict a failure throws instead of returning the input.
  param([string]$Path, [switch]$Strict)
  if ($Path.IndexOf('~') -lt 0) { return $Path }
  try {
    if (-not ('Crew.Native' -as [type])) {
      Add-Type -Namespace Crew -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $existing = $full
    $rest = @()
    while ($existing -and -not (Test-Path -LiteralPath $existing)) {
      $rest = @(Split-Path -Leaf $existing) + $rest
      $existing = Split-Path -Parent $existing
    }
    if (-not $existing) { return $full }
    $sb = New-Object System.Text.StringBuilder 32768
    if ([Crew.Native]::GetLongPathName($existing, $sb, 32768) -gt 0) { $existing = $sb.ToString() }
    elseif ($Strict) { throw "GetLongPathName failed for $existing" }
    foreach ($r in $rest) { $existing = Join-Path $existing $r }
    return $existing
  } catch {
    if ($Strict) { throw }
    return $Path
  }
}

function Get-UserClaudeSlashDirs {
  # Every user-wide Claude folder as a slash path (long names, symlinks resolved).
  $out = New-Object System.Collections.Generic.List[string]
  $all = @(Get-UserClaudeDirs)
  if ($HOME) { $all += (Join-Path $HOME '.claude') }
  foreach ($d in $all) {
    $x = (ConvertTo-SlashPath (Resolve-RealPath (Get-LongPath $d))).TrimEnd('/')
    if (-not $out.Contains($x)) { $out.Add($x) }
  }
  return @($out)
}

function Test-UserLeadDeniedPath {
  # String-only part of the rules for what a user lead_writable glob can never grant (slash path, no
  # filesystem access): settings, hooks, agents, PROJECT.md, ~/.claude beyond notes/, code-execution spots.
  param([string]$Path)
  $p = (ConvertTo-SlashPath $Path).TrimEnd('/')
  if ($p -match '(?i)(^|/)settings[^/]*\.json$') { return $true }
  if ($p -match '(?i)(^|/)(hooks|agents)(/|$)') { return $true }
  if ($p -match '(?i)(^|/)PROJECT\.md$') { return $true }
  if ($p -match '(?i)(^|/)\.claude\.json$') { return $true }
  # Shell profiles, ssh, startup folders, git config: files that run code or hold keys.
  if ($p -match '(?i)(^|/)(\.ssh|WindowsPowerShell|PowerShell|startup)(/|$)') { return $true }
  if ($p -match '(?i)(^|/)\.config/(powershell|git|gh)(/|$)') { return $true }
  # Credential stores: tokens and passwords, never a place for the lead's personal edits.
  if ($p -match '(?i)(^|/)(\.aws|\.netrc|\.npmrc|\.git-credentials)(/|$)') { return $true }
  if ($p -match '(?i)(^|/)\.docker/config\.json$') { return $true }
  if ($p -match '(?i)(^|/)\.(bashrc|bash_profile|bash_login|bash_logout|zshrc|zshenv|zprofile|zlogin|profile|gitconfig|inputrc)$') { return $true }
  if ($p -match '(?i)(^|/)[^/]*profile\.ps1$') { return $true }
  foreach ($d in (Get-UserClaudeSlashDirs)) {
    $inside = $p.Equals($d, [System.StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($d + '/', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { continue }
    $notes = $d + '/notes'
    if ($p.Equals($notes, [System.StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($notes + '/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    return $true
  }
  return $false
}

function Expand-UserGlob([string]$Glob) {
  $t = (ConvertTo-SlashPath $Glob.Trim())
  if ($t -eq '~' -or $t.StartsWith('~/')) { $t = (ConvertTo-SlashPath $HOME).TrimEnd('/') + $t.Substring(1) }
  return $t
}

function Get-UserLeadGlobProblem {
  # Why a USER.md lead_writable entry is refused (the guard ignores it), or $null when it is usable.
  param([string]$Glob)
  $raw = $Glob.Trim()
  $t = ConvertTo-SlashPath $raw
  if ($t -notmatch '^(~(/|$)|/|[A-Za-z]:/)') { return 'it is not absolute or ~-relative' }
  $t = Expand-UserGlob $raw
  $wild = $t.IndexOfAny([char[]]@('*', '?'))
  $prefix = if ($wild -lt 0) { $t } else { $t.Substring(0, $wild) }
  if ($wild -ge 0 -and -not $prefix.EndsWith('/')) { $prefix = $prefix.Substring(0, [Math]::Max(0, $prefix.LastIndexOf('/') + 1)) }
  $prefix = $prefix.TrimEnd('/')
  $home1 = (ConvertTo-SlashPath $HOME).TrimEnd('/')
  if ($prefix -eq '' -or $prefix -match '^[A-Za-z]:$') { return 'its fixed start is empty or a drive root' }
  if ($prefix.Equals($home1, [System.StringComparison]::OrdinalIgnoreCase) -or $home1.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
    return 'its fixed start is the home folder or a folder above it'
  }
  if (Test-UserLeadDeniedPath $prefix) { return 'it names settings, hooks, agent files, PROJECT.md, other ~/.claude content (only ~/.claude/notes/** is possible) or a code-execution spot' }
  return $null
}

function Get-UserLeadWritable {
  # The optional `lead_writable` list in the front matter of <user .claude>/team/USER.md, as slash globs
  # with `~` expanded to the home folder. Refused entries (see Get-UserLeadGlobProblem) are dropped.
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($userDir in (Get-UserClaudeDirs)) {
    $user = Get-FrontMatter (Join-Path $userDir 'team/USER.md')
    foreach ($g in @($user['lead_writable'])) {
      if ([string]::IsNullOrWhiteSpace($g)) { continue }
      if (Get-UserLeadGlobProblem $g) { continue }
      $out.Add((Expand-UserGlob $g))
    }
  }
  return @($out)
}

function Test-UserLeadForbidden {
  # True for a path (long, real) the lead may never write through a user lead_writable glob: the string
  # rules above plus anything inside a git repository (work tree or bare).
  param([string]$FullPath)
  if (Test-UserLeadDeniedPath $FullPath) { return $true }
  $dir = Split-Path -Parent $FullPath
  while ($dir) {
    if ([System.IO.Directory]::Exists((Join-Path $dir '.git')) -or [System.IO.File]::Exists((Join-Path $dir '.git'))) { return $true }
    if ([System.IO.File]::Exists((Join-Path $dir 'HEAD')) -and [System.IO.Directory]::Exists((Join-Path $dir 'objects')) -and [System.IO.Directory]::Exists((Join-Path $dir 'refs'))) { return $true }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $false
}

function Test-UserLeadWritable {
  # Throws on any internal problem: the caller must treat that as "denied".
  param([string]$FullPath)
  $globs = @(Get-UserLeadWritable)
  if ($globs.Count -eq 0) { return $false }
  $real = Resolve-RealPath (Get-LongPath $FullPath -Strict)
  if (Test-UserLeadForbidden $real) { return $false }
  return (Test-GlobMatch -RelPath ((ConvertTo-SlashPath $real).TrimStart('/')) -Globs $globs)
}

function Resolve-RealPath {
  # Absolute path with junctions / symlinks resolved in every component (also parent folders), so a
  # link inside an allowed folder cannot lead outside it. Components that do not exist are kept as they are.
  param([string]$Path, [int]$Depth = 0)
  $full = [System.IO.Path]::GetFullPath($Path)
  if ($Depth -gt 16) { return $full }
  $root = [System.IO.Path]::GetPathRoot($full)
  $parts = @($full.Substring($root.Length).Split([char[]]@([char]92, [char]47), [System.StringSplitOptions]::RemoveEmptyEntries))
  $cur = $root
  for ($i = 0; $i -lt $parts.Length; $i++) {
    $next = [System.IO.Path]::Combine($cur, $parts[$i])
    $isLink = $false
    try { $isLink = (([System.IO.File]::GetAttributes($next) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
    if ($isLink) {
      $target = $null
      try { $target = @((Get-Item -LiteralPath $next -Force).Target)[0] } catch { }
      if ($target) {
        $target = [string]$target
        if ($target.Length -gt 4 -and $target[0] -eq [char]92 -and $target[1] -eq [char]63 -and $target[2] -eq [char]63 -and $target[3] -eq [char]92) { $target = $target.Substring(4) }
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = [System.IO.Path]::Combine($cur, $target) }
        if ($i + 1 -lt $parts.Length) { $target = [System.IO.Path]::Combine($target, ($parts[($i + 1)..($parts.Length - 1)] -join [string][char]92)) }
        return (Resolve-RealPath -Path $target -Depth ($Depth + 1))
      }
    }
    $cur = $next
  }
  return $cur
}

function Find-TeamRoot {
  # Walks up from $Start to the first folder that contains .claude/team, skipping the user-wide
  # ~/.claude folder (it holds team/USER.md but is not a project). Returns $null if none.
  param([string]$Start)
  if ([string]::IsNullOrWhiteSpace($Start)) { return $null }
  try { $dir = [System.IO.Path]::GetFullPath($Start) } catch { return $null }
  $userDirs = Get-UserClaudeDirs
  while ($dir) {
    $claude = (Join-Path $dir '.claude')
    if ([System.IO.Directory]::Exists((Join-Path $claude 'team')) -and
        ($userDirs -notcontains $claude.TrimEnd([char]92, [char]47).ToLowerInvariant())) { return $dir }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $null
}

function ConvertTo-SlashPath {
  param([string]$Path)
  return ($Path -replace '\\', '/')
}

function Get-RelativeToRoot {
  # Returns the path of $File relative to $Root with forward slashes, or $null if it is outside.
  param([string]$Root, [string]$File, [string]$Cwd)
  if ([string]::IsNullOrWhiteSpace($File)) { return $null }
  try {
    if (-not [System.IO.Path]::IsPathRooted($File)) { $File = Join-Path $Cwd $File }
    $full = ConvertTo-SlashPath ([System.IO.Path]::GetFullPath($File))
    $rootFull = (ConvertTo-SlashPath ([System.IO.Path]::GetFullPath($Root))).TrimEnd('/') + '/'
  } catch { return $null }
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($rootFull.Length)
  }
  return $null
}

function Get-FrontMatter {
  # Minimal YAML front matter reader: `key: value`, `key: [a, b]`, and block lists (`- item`).
  # Returns an ordered hashtable; list values are string arrays. Empty/missing file -> empty table.
  param([string]$Path)
  $result = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
  $lines = [System.IO.File]::ReadAllLines($Path)
  if ($lines.Length -eq 0 -or $lines[0].Trim() -ne '---') { return $result }
  $currentKey = $null
  for ($i = 1; $i -lt $lines.Length; $i++) {
    $line = $lines[$i]
    if ($line.Trim() -eq '---') { break }
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -match '^\s+-\s*(.*)$' -and $currentKey) {
      $item = $Matches[1].Trim().Trim('"').Trim("'")
      $result[$currentKey] = @($result[$currentKey]) + @($item)
      continue
    }
    if ($line -match '^([A-Za-z0-9_\-]+):\s*(.*)$') {
      $currentKey = $Matches[1]
      $value = $Matches[2].Trim()
      if ($value -eq '') {
        $result[$currentKey] = @()
      } elseif ($value -match '^\[(.*)\]$') {
        $inner = $Matches[1].Trim()
        if ($inner -eq '') { $result[$currentKey] = @() }
        else { $result[$currentKey] = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }) }
      } else {
        $result[$currentKey] = $value.Trim('"').Trim("'")
      }
    }
  }
  return $result
}

function ConvertTo-GlobRegex {
  # `**` matches anything, `*` matches within one folder, `?` one character. Case-insensitive use.
  param([string]$Glob)
  $g = (ConvertTo-SlashPath $Glob).TrimStart('/')
  if ($g.StartsWith('./')) { $g = $g.Substring(2) }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('^')
  for ($i = 0; $i -lt $g.Length; $i++) {
    $c = $g[$i]
    if ($c -eq '*') {
      if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
        $i++
        if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '/') { $i++; [void]$sb.Append('(?:.*/)?') }
        else { [void]$sb.Append('.*') }
      } else { [void]$sb.Append('[^/]*') }
    } elseif ($c -eq '?') {
      [void]$sb.Append('[^/]')
    } else {
      [void]$sb.Append([regex]::Escape([string]$c))
    }
  }
  [void]$sb.Append('$')
  return $sb.ToString()
}

function Test-GlobMatch {
  param([string]$RelPath, [string[]]$Globs)
  foreach ($glob in @($Globs)) {
    if ([string]::IsNullOrWhiteSpace($glob)) { continue }
    if ($RelPath -match ('(?i)' + (ConvertTo-GlobRegex $glob))) { return $true }
  }
  return $false
}

function Get-LineCount {
  param([string]$Path)
  return [System.IO.File]::ReadAllLines($Path).Length
}

function Get-CapViolations {
  # Returns strings like "state.md has 61 lines (cap 50)" for each capped file over its cap.
  param([string]$TeamDir)
  $out = @()
  foreach ($name in $script:CrewCaps.Keys) {
    $path = Join-Path $TeamDir $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $count = Get-LineCount $path
      if ($count -gt $script:CrewCaps[$name]) {
        $out += ("{0} has {1} lines (cap {2})" -f $name, $count, $script:CrewCaps[$name])
      }
    }
  }
  return $out
}

function Get-CrewVersion {
  # Version of the installed agent-crew payload (the VERSION file next to hooks/ and scripts/).
  $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
  if (Test-Path -LiteralPath $path) { return ([System.IO.File]::ReadAllText($path)).Trim() }
  return $null
}

function Get-AgentName {
  # Normalises an agent_type: drops a plugin prefix ("plugin:name") and lower-cases.
  param($AgentType)
  if ($null -eq $AgentType) { return '' }
  $name = [string]$AgentType
  $idx = $name.LastIndexOf(':')
  if ($idx -ge 0) { $name = $name.Substring($idx + 1) }
  return $name.Trim().ToLowerInvariant()
}

# ---- RAM guard config (used by hooks/ram-guard.ps1, scripts/check-team.ps1 and the installers) ----
# Trust boundary: the shipped file and the user's file may do anything; the PROJECT file (which an agent can
# edit) may only make things stricter: raise a threshold (up to the user's project_max_mb), add kinds, add
# patterns and tools to a kind. Anything else in it is ignored with a warning.

$script:RamRegexTimeoutMs = 200
$script:RamCommandTools = @('Bash', 'PowerShell')
$script:RamAgentTools = @('Agent', 'Task')

function Get-RamGuardUserDir {
  # The user's Claude folder for ram-guard.json. AGENT_CREW_USER_DIR is a test hook.
  if ($env:AGENT_CREW_USER_DIR) { return $env:AGENT_CREW_USER_DIR }
  if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
  if ($HOME) { return (Join-Path $HOME '.claude') }
  return $null
}

function Test-IsNumber($Value) {
  return (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [double]) -or ($Value -is [decimal]))
}

function New-RamRegex([string]$Pattern) {
  # Case-insensitive regex with a match timeout, so a pathological pattern cannot hang the hook.
  return (New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds($script:RamRegexTimeoutMs)))
}

function New-RamConfig {
  # project_max_mb: the most a project file may demand of one kind (a guess; the user file can change it).
  return @{ enabled = $true; project_max_mb = 8000.0; kinds = [ordered]@{} }
}

function Get-RamKindTools {
  # The tools a kind applies to. With patterns and no tools: the shell tools.
  param($Kind)
  $tools = @($Kind.tools)
  if ($tools.Count -eq 0 -and @($Kind.patterns).Count -gt 0) { return @($script:RamCommandTools) }
  return $tools
}

function Get-RamKindProblem {
  # Why a merged kind cannot work (so the hook skips it), or $null when it is fine.
  # Agent/Task: the kind matches every spawn (patterns do not apply to them). Bash/PowerShell: at least one
  # valid pattern is needed, a shell kind without patterns never matches everything.
  param($Kind)
  if ($null -eq $Kind.min_free_mb) { return 'it needs min_free_mb' }
  $tools = @(Get-RamKindTools $Kind)
  if ($tools.Count -eq 0) { return 'it needs tools or patterns' }
  $hasAgent = $false
  $hasShell = $false
  foreach ($t in $tools) {
    if (@($script:RamAgentTools | Where-Object { $_ -ieq $t }).Count -gt 0) { $hasAgent = $true }
    else { $hasShell = $true }
  }
  if ($hasShell -and -not $hasAgent -and @($Kind.patterns).Count -eq 0) { return 'a kind for shell commands needs at least one valid pattern' }
  return $null
}

function Read-RamLayer {
  # Reads one config file and merges it into $Config. Label: shipped | user | project. Problems become
  # warnings; this never throws.
  param([hashtable]$Config, [string]$Path, [string]$Label, $Warnings)
  if (-not [System.IO.File]::Exists($Path)) { return }
  $isProject = ($Label -eq 'project')
  $root = $null
  try { $root = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
  catch { $Warnings.Add("ram-guard: $Label config is not valid JSON, ignored ($Path)."); return }
  if ($root -isnot [System.Management.Automation.PSCustomObject]) { $Warnings.Add("ram-guard: $Label config must be a JSON object, ignored ($Path)."); return }

  if ($root.PSObject.Properties['enabled']) {
    if ($isProject) { $Warnings.Add("ram-guard: the project config cannot change 'enabled' (only the user config can switch the guard off), ignored ($Path).") }
    elseif ($root.enabled -is [bool]) { $Config.enabled = $root.enabled }
    else { $Warnings.Add("ram-guard: 'enabled' in the $Label config must be true or false, ignored ($Path).") }
  }
  if ($root.PSObject.Properties['project_max_mb']) {
    if ($isProject) { $Warnings.Add("ram-guard: the project config cannot set 'project_max_mb' (only the user config can), ignored ($Path).") }
    elseif ((Test-IsNumber $root.project_max_mb) -and ([double]$root.project_max_mb -gt 0)) { $Config.project_max_mb = [double]$root.project_max_mb }
    else { $Warnings.Add("ram-guard: 'project_max_mb' in the $Label config must be a number above 0, ignored ($Path).") }
  }
  if (-not $root.PSObject.Properties['kinds'] -or $null -eq $root.kinds) { return }
  if ($root.kinds -isnot [System.Management.Automation.PSCustomObject]) { $Warnings.Add("ram-guard: 'kinds' in the $Label config must be an object, ignored ($Path)."); return }

  foreach ($prop in $root.kinds.PSObject.Properties) {
    $name = $prop.Name
    $entry = $prop.Value
    if ($entry -isnot [System.Management.Automation.PSCustomObject]) { $Warnings.Add("ram-guard: kind '$name' in the $Label config must be an object, skipped ($Path)."); continue }
    $exists = $Config.kinds.Contains($name)
    if ($exists) { $kind = $Config.kinds[$name] }
    else { $kind = @{ enabled = $true; min_free_mb = $null; tools = @(); patterns = @() } }

    if ($entry.PSObject.Properties['enabled']) {
      if ($isProject) { $Warnings.Add("ram-guard: kind '$name': the project config cannot switch a kind on or off, ignored.") }
      elseif ($entry.enabled -is [bool]) { $kind.enabled = $entry.enabled }
      else { $Warnings.Add("ram-guard: kind '$name': 'enabled' must be true or false, ignored ($Label config).") }
    }
    if ($entry.PSObject.Properties['min_free_mb']) {
      if (-not ((Test-IsNumber $entry.min_free_mb) -and ([double]$entry.min_free_mb -gt 0))) {
        $Warnings.Add("ram-guard: kind '$name': 'min_free_mb' must be a number above 0, ignored ($Label config).")
      } else {
        $mb = [double]$entry.min_free_mb
        if ($isProject) {
          if ($mb -gt $Config.project_max_mb) {
            $Warnings.Add("ram-guard: kind '$name': the project asked for $([int]$mb) MB, lowered to the user's project_max_mb of $([int]$Config.project_max_mb) MB.")
            $mb = $Config.project_max_mb
          }
          if ($null -ne $kind.min_free_mb -and $mb -lt $kind.min_free_mb) {
            $Warnings.Add("ram-guard: kind '$name': the project config can only raise min_free_mb (now $([int]$kind.min_free_mb) MB), $([int]$mb) MB ignored.")
            $mb = $kind.min_free_mb
          }
        }
        $kind.min_free_mb = $mb
      }
    }
    if ($entry.PSObject.Properties['tools']) {
      $list = @($entry.tools)
      $names = @()
      $badTools = ($list.Count -eq 0)
      foreach ($t in $list) {
        if (($t -isnot [string]) -or [string]::IsNullOrWhiteSpace($t)) { $badTools = $true; break }
        $names += $t.Trim()
      }
      if ($badTools) { $Warnings.Add("ram-guard: kind '$name': 'tools' must be a list of tool names, ignored ($Label config).") }
      elseif ($isProject) {
        # A project may widen a kind, never narrow it.
        $merged = @(Get-RamKindTools $kind)
        foreach ($t in $names) { if (@($merged | Where-Object { $_ -ieq $t }).Count -eq 0) { $merged += $t } }
        $kind.tools = $merged
      } else { $kind.tools = $names }
    }
    if ($entry.PSObject.Properties['patterns']) {
      $good = @()
      foreach ($pat in @($entry.patterns)) {
        if (($pat -isnot [string]) -or [string]::IsNullOrWhiteSpace($pat)) { $Warnings.Add("ram-guard: kind '$name': a pattern must be a non-empty string, skipped ($Label config)."); continue }
        try { [void](New-RamRegex $pat); $good += $pat }
        catch { $Warnings.Add("ram-guard: kind '$name': pattern '$pat' is not a valid regular expression, skipped ($Label config).") }
      }
      if ($isProject) {
        # A project adds patterns to a kind; it never replaces the ones it inherited.
        $merged = @($kind.patterns)
        foreach ($pat in $good) { if ($merged -notcontains $pat) { $merged += $pat } }
        $kind.patterns = $merged
      } else { $kind.patterns = $good }
    }
    $Config.kinds[$name] = $kind
  }
}

function Get-RamHookIfRules {
  # Permission-rule filters for the Bash and PowerShell hook entries, from the `hook_if` command globs of the
  # kinds in the shipped and the user file (e.g. "claude *" -> "Bash(claude *)"). Returns an object with
  # All = $true when the entries must be unconditional (the user file sets "scan_all_commands": true, or a
  # shell kind has patterns but no hook_if), else Globs = the command globs.
  param([string[]]$Files)
  $globs = New-Object System.Collections.Generic.List[string]
  foreach ($file in $Files) {
    if (-not [System.IO.File]::Exists($file)) { continue }
    try { $root = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { continue }
    if ($root -isnot [System.Management.Automation.PSCustomObject]) { continue }
    if ($root.PSObject.Properties['scan_all_commands'] -and $root.scan_all_commands -eq $true) { return [pscustomobject]@{ All = $true; Globs = @() } }
    if (-not $root.PSObject.Properties['kinds'] -or $root.kinds -isnot [System.Management.Automation.PSCustomObject]) { continue }
    foreach ($prop in $root.kinds.PSObject.Properties) {
      $e = $prop.Value
      if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
      if ($e.PSObject.Properties['enabled'] -and $e.enabled -eq $false) { continue }
      $hasPatterns = ($e.PSObject.Properties['patterns'] -and @($e.patterns).Count -gt 0)
      if (-not $hasPatterns) { continue }
      $hasIf = ($e.PSObject.Properties['hook_if'] -and @($e.hook_if).Count -gt 0)
      if (-not $hasIf) { return [pscustomobject]@{ All = $true; Globs = @() } }
      foreach ($g in @($e.hook_if)) { if (($g -is [string]) -and $g.Trim() -and -not $globs.Contains($g.Trim())) { $globs.Add($g.Trim()) } }
    }
  }
  return [pscustomobject]@{ All = $false; Globs = @($globs) }
}

# ---------- lead compact window ----------
# The lead owns .claude/team/session.json {"lead_compact_window": N, "reason": "...", "updated": "..."}.
# The SessionStart hook copies N (clamped) into the project's .claude/settings.local.json `autoCompactWindow`, the only
# key it ever touches, unless the user set their own value (environment, user settings).
$script:CompactMin = 100000
$script:CompactMax = 400000

function Read-JsonFile {
  # Parsed JSON object, or $null when the file is missing or not valid JSON.
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-UserClaudeHomes {
  # The user's Claude config folders as they exist on disk (not lower-cased, unlike Get-UserClaudeDirs).
  $l = New-Object System.Collections.Generic.List[string]
  if ($HOME) { $l.Add((Join-Path $HOME '.claude')) }
  if ($env:CLAUDE_CONFIG_DIR) { $l.Add($env:CLAUDE_CONFIG_DIR) }
  return @($l)
}

function Get-CompactSession {
  # Reads <team>/session.json. Exists=$false when there is no file (feature unused). Problem is set when the file or
  # its value is unusable; otherwise Value is the requested window clamped to [CompactMin, CompactMax].
  param([string]$Team)
  $path = Join-Path $Team 'session.json'
  $r = @{ Path = $path; Exists = $false; Value = $null; Requested = $null; Clamped = $false; Reason = ''; Problem = '' }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $r }
  $r.Exists = $true
  $j = Read-JsonFile $path
  if ($null -eq $j) { $r.Problem = 'not valid JSON'; return $r }
  $prop = $j.PSObject.Properties['lead_compact_window']
  if (-not $prop -or $null -eq $prop.Value) { $r.Problem = 'no lead_compact_window'; return $r }
  $v = $prop.Value
  if ($v -is [string] -or $v -is [bool] -or -not ($v -is [ValueType])) { $r.Problem = 'lead_compact_window must be a number'; return $r }
  $d = [double]$v
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -ne [Math]::Floor($d)) { $r.Problem = 'lead_compact_window must be a whole number of tokens'; return $r }
  $r.Requested = [long]$d
  $clamped = [Math]::Min([Math]::Max($r.Requested, $script:CompactMin), $script:CompactMax)
  $r.Clamped = ($clamped -ne $r.Requested)
  $r.Value = [long]$clamped
  if ($j.PSObject.Properties['reason'] -and $j.reason) { $r.Reason = ([string]$j.reason).Trim() }
  return $r
}

function Get-CompactUserOverrides {
  # Settings the user made themselves that the hook must not fight (strings, one per source). The documented order
  # is env > --autocompact flag (invisible here) > modelSettings.<model> > top-level; a top-level user key is
  # reported too so the hook never overwrites what the user chose.
  param([string[]]$ClaudeHomes)
  $out = New-Object System.Collections.Generic.List[string]
  $e = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_AUTO_COMPACT_WINDOW')
  if (-not [string]::IsNullOrWhiteSpace($e)) { $out.Add("the environment variable CLAUDE_CODE_AUTO_COMPACT_WINDOW ($($e.Trim()))") }
  foreach ($h in @($ClaudeHomes | Where-Object { $_ } | Select-Object -Unique)) {
    $f = Join-Path $h 'settings.json'
    $j = Read-JsonFile $f
    if (-not $j) { continue }
    if ($j.PSObject.Properties['modelSettings'] -and $j.modelSettings) {
      foreach ($m in $j.modelSettings.PSObject.Properties) {
        if ($m.Value -and $m.Value.PSObject.Properties['autoCompactWindow'] -and $null -ne $m.Value.autoCompactWindow) {
          $out.Add("modelSettings.$($m.Name).autoCompactWindow ($($m.Value.autoCompactWindow)) in $f")
        }
      }
    }
    if ($j.PSObject.Properties['autoCompactWindow'] -and $null -ne $j.autoCompactWindow) { $out.Add("autoCompactWindow ($($j.autoCompactWindow)) in $f") }
  }
  return @($out)
}

function Set-ProjectCompactWindow {
  # Writes ONLY the autoCompactWindow key of <project>/.claude/settings.local.json (created if missing, every other key
  # kept, atomic replace). Returns 'unchanged', 'created', 'changed' or 'unreadable' (not valid JSON: left untouched).
  param([string]$Project, [long]$Value)
  $path = Join-Path $Project '.claude/settings.local.json'
  $existed = Test-Path -LiteralPath $path -PathType Leaf
  if ($existed) {
    $j = Read-JsonFile $path
    if ($null -eq $j -or $j -is [array] -or $j -is [string] -or $j -is [ValueType]) { return 'unreadable' }
    $prop = $j.PSObject.Properties['autoCompactWindow']
    if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -eq "$Value") { return 'unchanged' }
    if ($prop) { $j.autoCompactWindow = $Value } else { $j | Add-Member -NotePropertyName autoCompactWindow -NotePropertyValue $Value }
  } else {
    $j = [pscustomobject]@{ autoCompactWindow = $Value }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
  }
  $text = ($j | ConvertTo-Json -Depth 32) + "`n"
  $tmp = $path + '.agent-crew.tmp'
  [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
  if ($existed) {
    $bak = $path + '.agent-crew.bak'
    [System.IO.File]::Replace($tmp, $path, $bak)
    Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
  } else { [System.IO.File]::Move($tmp, $path) }
  if ($existed) { return 'changed' } else { return 'created' }
}

function Invoke-CompactWindowSync {
  # SessionStart: applies session.json to the project settings. Returns the lines to print (possibly none).
  param([string]$Team, [string]$Project, [string[]]$ClaudeHomes)
  $s = Get-CompactSession $Team
  if (-not $s.Exists) { return @() }
  if ($s.Problem) { return @("agent-crew: .claude/team/session.json is unusable ($($s.Problem)); autoCompactWindow in .claude/settings.local.json is left untouched. Fix the file.") }
  $over = @(Get-CompactUserOverrides $ClaudeHomes)
  if ($over.Count -gt 0) {
    return @("agent-crew: session.json asks for a lead compact window of $($s.Value) but you set your own value ($($over -join '; ')). Your value wins; settings.local.json is left untouched.")
  }
  $res = Set-ProjectCompactWindow $Project $s.Value
  if ($res -eq 'unreadable') { return @('agent-crew: .claude/settings.local.json is not valid JSON; autoCompactWindow was not updated.') }
  if ($res -eq 'unchanged') { return @() }
  $why = ''; if ($s.Reason) { $why = " Reason: $($s.Reason)." }
  $clamp = ''; if ($s.Clamped) { $clamp = " (requested $($s.Requested), clamped to $($script:CompactMin)-$($script:CompactMax))" }
  return @("agent-crew: lead compact window set to $($s.Value)$clamp in .claude/settings.local.json from .claude/team/session.json.$why It takes effect from the next session start (whether Claude Code picks up a settings change inside a running session is not verified).")
}
