<#
.SYNOPSIS
  PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit. Keeps the lead and the report-only
  agents inside the places they may write. Block = exit code 2 with the reason on stderr.

  - lead: .claude/team/** (also ~/.claude/team/**) and the PROJECT.md `lead_writable` globs.
  - thinker, architect, reviewer (and ui-reviewer, security-reviewer, perf-profiler, plus
    PROJECT.md `report_only_agents`): only .claude/team/reports/**.
  - every other agent, and sessions without an agent identity: allowed.
  - No .claude/team folder above the working directory: allowed (no-op).

  Reads the hook JSON from stdin: cwd, agent_type, tool_input.file_path (or notebook_path).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')

try {
  $in = Read-HookInput
  if ($null -eq $in) { exit 0 }

  $cwd = [string]$in.cwd
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }

  $agent = Get-AgentName $in.agent_type
  if (-not $agent) { exit 0 }

  $file = $null
  if ($in.tool_input) {
    if ($in.tool_input.file_path) { $file = [string]$in.tool_input.file_path }
    elseif ($in.tool_input.notebook_path) { $file = [string]$in.tool_input.notebook_path }
  }
  if (-not $file) { exit 0 }

  $project = Get-FrontMatter (Join-Path $root '.claude/team/PROJECT.md')
  $reportOnly = @($script:CrewReportOnlyAgents) + @($project['report_only_agents'] | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })

  $isLead = ($agent -eq 'lead')
  $isReportOnly = ($reportOnly -contains $agent)
  if (-not $isLead -and -not $isReportOnly) { exit 0 }

  $rel = Get-RelativeToRoot -Root $root -File $file -Cwd $cwd

  if ($isReportOnly) {
    if ($rel -and $rel -match '(?i)^\.claude/team/reports/.+') { exit 0 }
    [Console]::Error.WriteLine("agent-crew: '$agent' may write only to .claude/team/reports/ (tried: $file). Put your result in a report file there and return its path.")
    exit 2
  }

  # The lead.
  if ($rel -and $rel -match '(?i)^\.claude/team/.+') { exit 0 }
  if ($rel -and (Test-GlobMatch -RelPath $rel -Globs @($project['lead_writable']))) { exit 0 }
  if (-not $rel) {
    # Outside the project: only the user-wide team folder is allowed.
    $userTeam = ConvertTo-SlashPath (Join-Path $HOME '.claude/team')
    try {
      if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $cwd $file }
      $full = ConvertTo-SlashPath ([System.IO.Path]::GetFullPath($file))
      if ($full.StartsWith($userTeam.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    } catch { }
  }
  [Console]::Error.WriteLine("agent-crew: the lead may edit only .claude/team/** and the PROJECT.md lead_writable globs (tried: $file). Delegate this change to the coder.")
  exit 2
} catch {
  # A broken hook must never block work.
  exit 0
}
