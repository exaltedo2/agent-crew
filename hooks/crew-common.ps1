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

function Read-HookInput {
  # Reads the hook JSON from stdin as UTF-8. Returns $null when there is none or it is invalid.
  try {
    $stream = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
    $text = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Find-TeamRoot {
  # Walks up from $Start to the first folder that contains .claude/team. Returns $null if none.
  param([string]$Start)
  if ([string]::IsNullOrWhiteSpace($Start)) { return $null }
  try { $dir = [System.IO.Path]::GetFullPath($Start) } catch { return $null }
  while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir '.claude/team') -PathType Container) { return $dir }
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
