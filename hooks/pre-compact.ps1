<#
.SYNOPSIS
  PreCompact hook. Copies .claude/team/state.md to .claude/team/snapshots/state-<timestamp>.md
  and keeps the newest 5 snapshots. No-op without .claude/team or without state.md.
  Inside a subagent (agent_id in the input) it instead prints compaction instructions (PreCompact stdout
  goes into the summary request): keep the agent's state file path and its current content, and re-read
  it first. Whether Claude Code runs PreCompact for a subagent's auto-compaction is not documented; the
  agent is also told at start to re-read its state file after any compaction summary.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')
$keep = 5

try {
  $in = Read-HookInput
  $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }
  if ($in -and $in.agent_id -and $in.agent_type -and [string]$in.agent_type -ne 'lead') {
    $sp = Get-AgentStatePath $root ([string]$in.agent_type) ([string]$in.agent_id)
    if ($sp -and (Test-Path -LiteralPath $sp -PathType Leaf)) {
      $rel = '.claude/team/agent-state/' + (Split-Path -Leaf $sp)
      $body = @([System.IO.File]::ReadAllLines($sp) | Select-Object -First 40) -join "`n"
      Write-Output "Keep in the summary, verbatim: 'Your working-state file is $rel; re-read it before doing anything else.' and this state as it was at compaction:"
      Write-Output $body
    }
    exit 0
  }
  $state = Join-Path $root '.claude/team/state.md'
  if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { exit 0 }

  $dir = Join-Path $root '.claude/team/snapshots'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  Copy-Item -LiteralPath $state -Destination (Join-Path $dir "state-$stamp.md")

  $old = @(Get-ChildItem -LiteralPath $dir -Filter 'state-*.md' -File | Sort-Object Name -Descending | Select-Object -Skip $keep)
  foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force }
  exit 0
} catch {
  exit 0
}
