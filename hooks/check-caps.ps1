<#
.SYNOPSIS
  PostToolUse hook for Edit|Write|MultiEdit|NotebookEdit. After a write to
  .claude/team/{state,routing,roster}.md it warns (never blocks) when the file is over its
  line cap: state 50, routing 150, roster 80. The warning goes to Claude as additionalContext.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')

try {
  $in = Read-HookInput
  if ($null -eq $in) { exit 0 }
  $cwd = [string]$in.cwd
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }

  $file = $null
  if ($in.tool_input) {
    if ($in.tool_input.file_path) { $file = [string]$in.tool_input.file_path }
    elseif ($in.tool_input.notebook_path) { $file = [string]$in.tool_input.notebook_path }
  }
  if (-not $file) { exit 0 }
  $rel = Get-RelativeToRoot -Root $root -File $file -Cwd $cwd
  if (-not $rel -or $rel -notmatch '(?i)^\.claude/team/(state|routing|roster)\.md$') { exit 0 }

  $name = ($rel -split '/')[-1].ToLowerInvariant()
  $path = Join-Path $root $rel
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }
  $count = Get-LineCount $path
  $cap = $script:CrewCaps[$name]
  if ($count -le $cap) { exit 0 }

  $msg = "agent-crew: .claude/team/$name has $count lines, over its cap of $cap. Prune it now: delete finished items and move lasting knowledge to its proper file (see the crew-retro skill)."
  $payload = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } }
  Write-Output ($payload | ConvertTo-Json -Compress -Depth 5)
  exit 0
} catch {
  exit 0
}
