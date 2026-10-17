<#
.SYNOPSIS
  PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit. Keeps the lead and the report-only
  agents inside the places they may write. Block = exit code 2 with the reason on stderr.

  - lead: .claude/team/** (also ~/.claude/team/reports/**, never USER.md or ram-guard.json there) and the PROJECT.md `lead_writable` globs,
    plus files outside the project matching the optional USER.md `lead_writable` globs (never inside a git
    repository, settings*.json, hooks, agents), but NEVER PROJECT.md itself, .claude/settings*.json or hook scripts, even if a glob
    lists them: those changes go through the coder.
  - thinker, architect, reviewer (and ui-reviewer, security-reviewer, perf-profiler, plus
    PROJECT.md `report_only_agents`): only .claude/team/reports/**.
  - every other agent, and sessions without an agent identity: allowed.
  - No project .claude/team folder above the working directory: allowed (no-op). The user-wide
    ~/.claude folder is not a project.
  - Paths are resolved through junctions and symlinks before they are compared.

  Only the file-edit tools are guarded; writing files through Bash/PowerShell is not seen here.
  Reads the hook JSON from stdin: cwd, agent_type, tool_input.file_path (or notebook_path).
#>
$ErrorActionPreference = 'Stop'

# Fast path: read stdin first, and leave at once when there is no agent identity. This keeps the
# common case (no agent_type) cheap; the process start itself dominates the cost.
$rawInput = ''
try {
  $stream = [Console]::OpenStandardInput()
  $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
  $rawInput = $reader.ReadToEnd()
} catch { exit 0 }
if ($rawInput.IndexOf('"agent_type"', [System.StringComparison]::Ordinal) -lt 0) { exit 0 }

. (Join-Path $PSScriptRoot 'crew-common.ps1')

# Paths a lead may never write, whatever lead_writable says (relative to the project root).
$leadDenied = @(
  '^\.claude/team/PROJECT\.md$',
  '(^|/)\.claude/settings[^/]*\.json$',
  '^\.claude/hooks/',
  '(^|/)agent-crew/hooks/'
)

$leadChecking = $false
$leadMayWrite = 'The lead may write: project .claude/team/** (not PROJECT.md), the PROJECT.md lead_writable globs, ~/.claude/team/reports/**, and the USER.md lead_writable globs. ~/.claude/team/USER.md and ram-guard.json are never writable.'

try {
  $in = ConvertFrom-HookText $rawInput
  if ($null -eq $in) { exit 0 }

  $agent = Get-AgentName $in.agent_type
  if (-not $agent) { exit 0 }
  # From here on, any error while checking the lead denies the write (fail closed); other agents fail open.
  $leadChecking = ($agent -eq 'lead')

  $cwd = [string]$in.cwd
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }

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

  # Resolve junctions / symlinks (also in parent folders) on both sides before comparing.
  $abs = $file
  if (-not [System.IO.Path]::IsPathRooted($abs)) { $abs = Join-Path $cwd $abs }
  # NTFS alternate data streams (PROJECT.md::$DATA) write the main stream: reject any ':' after the drive letter.
  if ($abs.Substring([Math]::Min(2, $abs.Length)).Contains(':')) {
    [Console]::Error.WriteLine("agent-crew: '$agent' may not write to a path containing ':' after the drive letter (alternate data stream): $file")
    exit 2
  }

  $realRoot = Resolve-RealPath (Get-LongPath $root)
  $realFile = Resolve-RealPath (Get-LongPath $abs)
  $rel = Get-RelativeToRoot -Root $realRoot -File $realFile -Cwd $cwd

  if ($isReportOnly) {
    if ($rel -and $rel -match '(?i)^\.claude/team/reports/.+') { exit 0 }
    [Console]::Error.WriteLine("agent-crew: '$agent' may write only to .claude/team/reports/ (tried: $file). Put your result in a report file there and return its path.")
    exit 2
  }

  # The lead.
  if ($rel) {
    foreach ($pattern in $leadDenied) {
      if ($rel -match ('(?i)' + $pattern)) {
        [Console]::Error.WriteLine("agent-crew: the lead may not edit $rel (PROJECT.md, settings and hook scripts are changed by the coder). Draft the change in .claude/team/reports/ and delegate it.")
        exit 2
      }
    }
    if ($rel -match '(?i)^\.claude/team/.+') { exit 0 }
    if (Test-GlobMatch -RelPath $rel -Globs @($project['lead_writable'])) { exit 0 }
  } else {
    # Outside the project: ~/.claude/team/reports/** and the USER.md lead_writable globs. Never the rest of
    # the user team folder (USER.md and ram-guard.json define the lead's own rights and the RAM guard).
    # Fail closed: any problem in this branch denies the write.
    try {
      $full = ConvertTo-SlashPath $realFile
      foreach ($userDir in (Get-UserClaudeDirs)) {
        $userReports = ConvertTo-SlashPath (Resolve-RealPath (Get-LongPath (Join-Path (Join-Path $userDir 'team') 'reports') -Strict))
        if ($full.StartsWith($userReports.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
      }
      if (Test-UserLeadWritable $realFile) { exit 0 }
    } catch {
      [Console]::Error.WriteLine("agent-crew: the lead may not write $file (checking the user lead_writable list failed: $($_.Exception.Message))")
      exit 2
    }
  }
  [Console]::Error.WriteLine("agent-crew: the lead may not write $file. $leadMayWrite Delegate this change to the coder.")
  exit 2
} catch {
  if ($leadChecking) {
    [Console]::Error.WriteLine("agent-crew: the lead may not write this file (the permission check failed: $($_.Exception.Message)). $leadMayWrite")
    exit 2
  }
  # A broken hook must never block work for the other agents.
  exit 0
}
