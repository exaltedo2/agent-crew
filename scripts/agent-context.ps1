<#
.SYNOPSIS
  How full each subagent's context is, so the lead can decide: resume it, or hand off to a fresh agent.

.DESCRIPTION
  Reads <ProjectsRoot>\<slug>\<session>\subagents\agent-*.jsonl (+ .meta.json). For each agent: the context it would
  re-read on its next turn (input + cache creation + cache read tokens of its last request), its compact window
  (`autoCompactWindow` from the project's .claude\agents\<type>.md, else the user's agents folder, else unknown), the
  percentage, how many times it already auto-compacted (compact_boundary lines) and the advice:
    resume    under the threshold: SendMessage keeps its context and is cheap.
    handoff   at or over the threshold (default 60% of the window) or already compacted: ask it to write a handoff
              note, then start a fresh agent with that note (a "lead-managed compaction").
  Read only. Without -Agent it lists the most recent agents of the newest session.

.PARAMETER Project       Project folder (default: current folder).
.PARAMETER ProjectsRoot  Where Claude Code keeps transcripts (default: $env:CLAUDE_CONFIG_DIR\projects, else $HOME\.claude\projects).
.PARAMETER ClaudeHome    User Claude folder for agent files (default: $env:CLAUDE_CONFIG_DIR, else $HOME\.claude).
.PARAMETER Agent         Agent id (or prefix), agent type, or a word of its description.
.PARAMETER Session       Session id (default: the newest session that has subagents).
.PARAMETER Last          How many agents to list (default 10).
.PARAMETER Threshold     Fraction of the window that triggers "handoff" (default 0.6).
.PARAMETER Format        table (default) or json.
#>
[CmdletBinding()]
param(
  [string]$Project = (Get-Location).Path,
  [string]$ProjectsRoot,
  [string]$ClaudeHome,
  [string]$Agent,
  [string]$Session,
  [int]$Last = 10,
  [double]$Threshold = 0.6,
  [ValidateSet('table', 'json')]
  [string]$Format = 'table'
)
$ErrorActionPreference = 'Stop'

if (-not $ClaudeHome) { $ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' } }
if (-not $ProjectsRoot) { $ProjectsRoot = Join-Path $ClaudeHome 'projects' }

function Get-ProjectSlug([string]$Path) {
  # Same rule as ledger.ps1: every non-alphanumeric character of the full path becomes '-'.
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  return ($full -replace '[^A-Za-z0-9]', '-')
}

function Get-Window([string]$Type) {
  foreach ($dir in @((Join-Path $Project '.claude\agents'), (Join-Path $ClaudeHome 'agents'))) {
    $f = Join-Path $dir "$Type.md"
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    $lines = [System.IO.File]::ReadAllLines($f)
    if ($lines.Count -lt 2 -or $lines[0].Trim([char]0xFEFF).Trim() -ne '---') { continue }
    for ($i = 1; $i -lt $lines.Count; $i++) {
      if ($lines[$i].Trim() -eq '---') { break }
      if ($lines[$i] -match '^autoCompactWindow:\s*(\d+)\s*$') { return @{ Value = [long]$Matches[1]; Source = $f } }
    }
    return @{ Value = $null; Source = $f }
  }
  return @{ Value = $null; Source = '' }
}

$folder = Join-Path $ProjectsRoot (Get-ProjectSlug $Project)
if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
  $hit = if (Test-Path -LiteralPath $ProjectsRoot) { Get-ChildItem -LiteralPath $ProjectsRoot -Directory | Where-Object { $_.Name -ieq (Get-ProjectSlug $Project) } | Select-Object -First 1 }
  if (-not $hit) { Write-Output "agent-context: no transcripts for $Project under $ProjectsRoot"; exit 0 }
  $folder = $hit.FullName
}

$files = @(Get-ChildItem -LiteralPath $folder -Directory | ForEach-Object {
    $sub = Join-Path $_.FullName 'subagents'
    if ((-not $Session -or $_.Name -eq $Session) -and (Test-Path -LiteralPath $sub)) { Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File }
  })
if ($files.Count -eq 0) { Write-Output 'agent-context: no subagent transcripts found'; exit 0 }
if (-not $Session -and -not $Agent) {
  $newest = ($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).Directory.Parent.Name
  $files = @($files | Where-Object { $_.Directory.Parent.Name -eq $newest })
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in ($files | Sort-Object LastWriteTimeUtc -Descending)) {
  $id = $f.BaseName -replace '^agent-', ''
  $meta = $null
  $mp = [System.IO.Path]::ChangeExtension($f.FullName, '.meta.json')
  if (Test-Path -LiteralPath $mp) { try { $meta = [System.IO.File]::ReadAllText($mp) | ConvertFrom-Json } catch { } }
  $type = if ($meta -and $meta.agentType) { [string]$meta.agentType } else { '?' }
  $desc = if ($meta -and $meta.description) { [string]$meta.description } else { '' }
  if ($Agent -and -not ($id.StartsWith($Agent) -or $type -ieq $Agent -or $desc -like "*$Agent*")) { continue }
  $lines = [System.IO.File]::ReadAllLines($f.FullName)
  $compactions = @($lines | Where-Object { $_.Contains('"compact_boundary"') }).Count
  $ctx = $null; $model = ''; $when = ''
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i]
    if (-not ($l.Contains('"type":"assistant"') -and $l.Contains('"usage"'))) { continue }
    try {
      $j = $l | ConvertFrom-Json
      $u = $j.message.usage
      $ctx = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens
      $model = [string]$j.message.model; $when = [string]$j.timestamp
      break
    } catch { continue }
  }
  if ($null -eq $ctx) { continue }
  $w = Get-Window $type
  $pct = if ($w.Value) { [Math]::Round(100.0 * $ctx / $w.Value) } else { $null }
  $advice = if ($compactions -gt 0) { 'handoff (already compacted)' }
  elseif ($null -ne $pct -and $pct -ge 100 * $Threshold) { 'handoff' }
  elseif ($null -eq $pct -and $ctx -ge 120000) { 'handoff (window unknown, context large)' }
  else { 'resume' }
  $rows.Add([pscustomobject]@{
      id = $id; type = $type; description = $desc; model = $model; context = $ctx; window = $w.Value
      percent = $pct; compactions = $compactions; finished = [bool]($meta -and $meta.finished); last = $when; advice = $advice
    })
  if ($rows.Count -ge $Last) { break }
}

if ($Format -eq 'json') { $rows | ConvertTo-Json -Depth 3; exit 0 }
if ($rows.Count -eq 0) { Write-Output 'agent-context: no matching agent with usage data'; exit 0 }
Write-Output ('{0,-19} {1,-16} {2,8} {3,8} {4,5} {5,4}  {6}' -f 'id', 'type', 'context', 'window', '%', 'cmp', 'advice')
foreach ($r in $rows) {
  $win = if ($r.window) { $r.window } else { '?' }
  $p = if ($null -ne $r.percent) { $r.percent } else { '?' }
  $t = if ($r.type.Length -gt 16) { $r.type.Substring(0, 16) } else { $r.type }
  Write-Output ('{0,-19} {1,-16} {2,8} {3,8} {4,5} {5,4}  {6}' -f $r.id, $t, $r.context, $win, $p, $r.compactions, $r.advice)
}
