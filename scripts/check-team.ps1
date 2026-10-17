<#
.SYNOPSIS
  Validates a project's .claude/team folder. Exit code 0 = fine, 1 = at least one violation.

.DESCRIPTION
  Checks: the four team files exist; state.md <= 50, routing.md <= 150, roster.md <= 80 lines;
  every agent in the roster's Active table has an agent file (project .claude/agents or
  <ClaudeHome>/agents); at most 7 active agents; every such agent file has a one-line
  `description:` in its front matter; the `lead` agent, if it has a `tools:` list, includes
  `Skill` (without it the lead cannot run crew-bootstrap, crew-retro, crew-hire, crew-retire).
  Warns (never fails) when a routing.md row names a model that is missing from the "Available
  models" list of <ClaudeHome>\team\USER.md and has no Fallback. Model names are free-form:
  unknown names are never rejected.

.PARAMETER Project     Project folder (default: current folder).
.PARAMETER ClaudeHome  User-level Claude folder (default: $HOME\.claude).
#>
[CmdletBinding()]
param(
  [string]$Project = (Get-Location).Path,
  [string]$ClaudeHome = (Join-Path $HOME '.claude')
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') 'crew-common.ps1')

$problems = New-Object System.Collections.Generic.List[string]
$team = Join-Path $Project '.claude/team'
if (-not (Test-Path -LiteralPath $team -PathType Container)) {
  Write-Output "FAIL: $team does not exist (run the crew-bootstrap skill)."
  exit 1
}

foreach ($name in 'PROJECT.md', 'routing.md', 'roster.md', 'state.md') {
  if (-not (Test-Path -LiteralPath (Join-Path $team $name) -PathType Leaf)) { $problems.Add("missing file .claude/team/$name") }
}
foreach ($v in @(Get-CapViolations $team)) { $problems.Add("over cap: $v") }

# Active agents from the roster table.
$active = New-Object System.Collections.Generic.List[string]
$rosterPath = Join-Path $team 'roster.md'
if (Test-Path -LiteralPath $rosterPath -PathType Leaf) {
  $inActive = $false
  foreach ($line in [System.IO.File]::ReadAllLines($rosterPath)) {
    if ($line -match '^##\s+(.+?)\s*$') { $inActive = ($Matches[1] -ieq 'Active'); continue }
    if (-not $inActive) { continue }
    if ($line -notmatch '^\s*\|') { continue }
    $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if ($cells.Count -eq 0) { continue }
    $first = $cells[0].Trim('`')
    if ($first -ieq 'Name' -or $first -match '^[-: ]*$' -or $first.StartsWith('<')) { continue }
    $active.Add($first)
  }
}
if ($active.Count -gt $script:CrewMaxActiveAgents) {
  $problems.Add("$($active.Count) active agents in roster.md (maximum $($script:CrewMaxActiveAgents))")
}

foreach ($agent in $active) {
  $candidates = @(
    (Join-Path $Project ".claude/agents/$agent.md"),
    (Join-Path $ClaudeHome "agents/$agent.md")
  )
  $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $found) { $problems.Add("roster lists '$agent' as active but no agent file exists (looked in .claude/agents and $ClaudeHome\agents)"); continue }

  $lines = [System.IO.File]::ReadAllLines($found)
  if ($lines.Length -eq 0 -or $lines[0].Trim() -ne '---') { $problems.Add("agent '$agent': $found has no front matter"); continue }
  $descIndex = -1; $end = -1
  for ($i = 1; $i -lt $lines.Length; $i++) {
    if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    if ($descIndex -lt 0 -and $lines[$i] -match '^description:') { $descIndex = $i }
  }
  if ($end -lt 0) { $problems.Add("agent '$agent': front matter is not closed"); continue }
  if ($descIndex -lt 0) { $problems.Add("agent '$agent': no description in front matter"); continue }
  $value = ($lines[$descIndex] -replace '^description:\s*', '').Trim()
  if ($value -eq '' -or $value -match '^[|>][+-]?$') { $problems.Add("agent '$agent': description must be one line of text"); continue }
  if ($descIndex + 1 -lt $end -and $lines[$descIndex + 1] -match '^\s+\S') { $problems.Add("agent '$agent': description spans several lines") }
  if ($agent -eq 'lead') {
    for ($i = 1; $i -lt $end; $i++) {
      if ($lines[$i] -match '^tools:\s*(.*)$') {
        # Accepts "A, B", "[A, B]", quoted items and a YAML block list ("- A" lines).
        $raw = $Matches[1].Trim()
        $items = @()
        if ($raw -eq '') {
          for ($j = $i + 1; $j -lt $end -and $lines[$j] -match '^\s*-\s*(.+?)\s*$'; $j++) { $items += $Matches[1] }
        } else {
          $items = @($raw.Trim('[', ']') -split ',')
        }
        $tools = @($items | ForEach-Object { $_.Trim().Trim('"', "'").Trim() } | Where-Object { $_ })
        if ($tools -notcontains 'Skill') { $problems.Add("agent 'lead' ($found): tools list lacks Skill, so the lead cannot run the crew skills") }
        break
      }
    }
  }
}

# Routing rows vs the user's available models: a warning only, names are free-form aliases.
$warnings = New-Object System.Collections.Generic.List[string]
$userPath = Join-Path $ClaudeHome 'team/USER.md'
$routingPath = Join-Path $team 'routing.md'
if ((Test-Path -LiteralPath $userPath -PathType Leaf) -and (Test-Path -LiteralPath $routingPath -PathType Leaf)) {
  # Accepts "- Available models: a, b" and the old "- Models available to me: a, b", with models
  # comma separated and/or one per indented line; "Never use" works the same (also as a sub-bullet).
  $available = @(); $never = @(); $mode = $null
  function Add-Names([string]$Text, [string]$Into) {
    $t = ($Text -replace '<!--.*?-->', '').Trim()
    foreach ($x in ($t -split '[,;]')) {
      $x = $x.Trim().Trim('`', '"', "'").Trim().ToLowerInvariant()
      if ($x -and -not $x.StartsWith('<')) {
        if ($Into -eq 'avail') { $script:available += $x } else { $script:never += $x }
      }
    }
  }
  foreach ($l in [System.IO.File]::ReadAllLines($userPath)) {
    if ($l -match '^\s*-?\s*(Available models|Models available to me)[^:]*:\s*(.*)$') { $mode = 'avail'; Add-Names $Matches[2] 'avail' }
    elseif ($l -match '^\s*-?\s*Never use[^:]*:\s*(.*)$') { $mode = 'never'; Add-Names $Matches[1] 'never' }
    elseif ($mode -and $l -match '^\s+-?\s*(\S.*)$') { Add-Names $Matches[1] $mode }
    else { $mode = $null }
  }
  $available = @($available | Where-Object { $never -notcontains $_ })
  if ($available.Count -eq 0) {
    $warnings.Add("no 'Available models' list found in $userPath, so the model names in routing.md were not checked")
  }
  if ($available.Count -gt 0) {
    $modelCol = -1; $fallbackCol = -1
    foreach ($l in [System.IO.File]::ReadAllLines($routingPath)) {
      if ($l -notmatch '^\s*\|') { continue }
      $cells = @($l.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
      if ($cells.Count -gt 1 -and $cells[1] -ieq 'Model') {
        $modelCol = 1; $fallbackCol = -1
        for ($c = 0; $c -lt $cells.Count; $c++) { if ($cells[$c] -ieq 'Fallback') { $fallbackCol = $c } }
        continue
      }
      if ($modelCol -lt 0 -or $cells.Count -le $modelCol -or $cells[$modelCol] -match '^[-: ]*$') { continue }
      $m = $cells[$modelCol].ToLowerInvariant()
      $fb = ''
      if ($fallbackCol -ge 0 -and $cells.Count -gt $fallbackCol) { $fb = $cells[$fallbackCol] }
      if (($available -notcontains $m -or $never -contains $m) -and ($fb -match '^[-: ]*$')) {
        $warnings.Add("routing.md row '$($cells[0])' names model '$($cells[$modelCol])', which is not in USER.md Available models, and has no Fallback")
      }
    }
  }
}

foreach ($w in $warnings) { Write-Output "WARN: $w" }
if ($problems.Count -eq 0) {
  Write-Output "OK: .claude/team passes ($($active.Count) active agents)."
  exit 0
}
foreach ($p in $problems) { Write-Output "FAIL: $p" }
exit 1
