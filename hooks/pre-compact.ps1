<#
.SYNOPSIS
  PreCompact hook. Copies .claude/team/state.md to .claude/team/snapshots/state-<timestamp>.md
  and keeps the newest 5 snapshots. No-op without .claude/team or without state.md.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')
$keep = 5

try {
  $in = Read-HookInput
  $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
  $root = Find-TeamRoot $cwd
  if (-not $root) { exit 0 }
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
