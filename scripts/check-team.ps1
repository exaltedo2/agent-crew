<#
.SYNOPSIS
  Validates a project's .claude/team folder. Exit code 0 = fine, 1 = at least one violation.

.DESCRIPTION
  Checks: the four team files exist; state.md <= 50, routing.md <= 150, roster.md <= 80 lines;
  every agent in the roster's Active table has an agent file (project .claude/agents or
  <ClaudeHome>/agents); at most 7 active agents; every such agent file has a one-line
  `description:` in its front matter.

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
}

if ($problems.Count -eq 0) {
  Write-Output "OK: .claude/team passes ($($active.Count) active agents)."
  exit 0
}
foreach ($p in $problems) { Write-Output "FAIL: $p" }
exit 1
