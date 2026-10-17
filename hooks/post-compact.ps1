<#
.SYNOPSIS
  PostCompact hook. Appends the trigger (manual/auto) and the compact_summary to
  .claude/team/compact_log.md and keeps the newest 20 entries. No-op without .claude/team.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'crew-common.ps1')
$keep = 20
$marker = '=== compact '

try {
  $in = Read-HookInput
  if ($null -eq $in) { exit 0 }
  $root = Find-TeamRoot ([string]$in.cwd)
  if (-not $root) { exit 0 }

  $log = Join-Path $root '.claude/team/compact_log.md'
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $summary = [string]$in.compact_summary
  $entry = "$marker$stamp trigger=$($in.trigger) ===`n$summary`n"

  $entries = @()
  if (Test-Path -LiteralPath $log -PathType Leaf) {
    $text = [System.IO.File]::ReadAllText($log)
    $entries = @([regex]::Split($text, "(?m)^(?==== compact )") | Where-Object { $_.Trim() -ne '' })
  }
  $entries = @($entries) + @($entry)
  if ($entries.Count -gt $keep) { $entries = $entries[($entries.Count - $keep)..($entries.Count - 1)] }

  $out = ($entries | ForEach-Object { $_.TrimEnd("`r", "`n") + "`n" }) -join ''
  [System.IO.File]::WriteAllText($log, $out, (New-Object System.Text.UTF8Encoding($false)))
  exit 0
} catch {
  exit 0
}
