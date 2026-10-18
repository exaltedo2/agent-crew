<#
.SYNOPSIS
  SessionStart hook. Whatever it prints on stdout is added to Claude's context.
  - source "compact": prints state.md and says it is authoritative over the summary.
  - source startup/resume/clear: says "run the crew-retro skill now" when .last-retro is
    missing or older than 7 days or a capped team file is over its cap; says so when
    PROJECT.md agent_crew_version differs from the installed VERSION.
  Also copies .claude/team/session.json lead_compact_window into the project settings.local.json autoCompactWindow.
  No-op without .claude/team.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')
$retroDays = 7

try {
  $in = Read-HookInput
  $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }
  $team = Join-Path $root '.claude/team'
  $source = if ($in -and $in.source) { [string]$in.source } else { 'startup' }

  if ($source -eq 'compact') {
    $state = Join-Path $team 'state.md'
    Write-Output 'agent-crew: this session was just compacted. .claude/team/state.md is authoritative over the compaction summary for open tasks and running agents; re-read it before acting.'
    if (Test-Path -LiteralPath $state -PathType Leaf) {
      Write-Output '----- .claude/team/state.md -----'
      Write-Output ([System.IO.File]::ReadAllText($state))
      Write-Output '----- end of state.md -----'
    }
    exit 0
  }

  # The lead owns its compact window (.claude/team/session.json): copy it into the project settings.
  foreach ($line in @(Invoke-CompactWindowSync $team $root (Get-UserClaudeHomes))) { Write-Output $line }

  $reasons = @()
  $marker = Join-Path $team '.last-retro'
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    $reasons += 'the retro never ran'
  } else {
    $age = (Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime
    if ($age.TotalDays -gt $retroDays) { $reasons += ("the last retro was {0} days ago" -f [int]$age.TotalDays) }
  }
  foreach ($v in @(Get-CapViolations $team)) { $reasons += $v }
  if ($reasons.Count -gt 0) {
    Write-Output ('agent-crew: run the crew-retro skill now (' + ($reasons -join '; ') + ').')
  }

  $project = Get-FrontMatter (Join-Path $team 'PROJECT.md')
  $installed = Get-CrewVersion
  $declared = $project['agent_crew_version']
  if ($installed -and $declared -and ([string]$declared -ne $installed)) {
    Write-Output "agent-crew: PROJECT.md was written for agent-crew $declared but $installed is installed; check the CHANGELOG for template changes."
  }
  exit 0
} catch {
  exit 0
}
