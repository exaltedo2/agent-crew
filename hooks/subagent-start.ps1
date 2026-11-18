<#
.SYNOPSIS
  SubagentStart hook. Gives every subagent that can write files its own working-state file,
  .claude/team/agent-state/<type>-<agent_id>.md (like the lead's state.md), through additionalContext.
  No-op without .claude/team, without agent_id, or for read-only agents (scout, Explore, Plan, ...).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')

try {
  $in = Read-HookInput
  if ($null -eq $in -or -not $in.agent_id -or -not $in.agent_type) { exit 0 }
  $cwd = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }
  $type = [string]$in.agent_type
  if ($type -eq 'lead' -or -not (Test-AgentCanWrite $root $type)) { exit 0 }
  $path = Get-AgentStatePath $root $type ([string]$in.agent_id)
  if (-not $path) { exit 0 }
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  try { Add-SessionJsonToGitignore $root '.claude/team/agent-state/' } catch { }
  $rel = '.claude/team/agent-state/' + (Split-Path -Leaf $path)
  $out = @{ hookSpecificOutput = @{ hookEventName = 'SubagentStart'; additionalContext = (Get-AgentStateBrief $rel) } }
  [Console]::Out.Write(($out | ConvertTo-Json -Compress -Depth 4))
  exit 0
} catch {
  exit 0
}
