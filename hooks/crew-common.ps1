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
