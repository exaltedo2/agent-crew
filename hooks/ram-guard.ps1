<#
.SYNOPSIS
  PreToolUse hook for Agent|Task|Bash|PowerShell. Blocks starting NEW heavy work (a subagent,
  or a shell command that matches a configured pattern) while the free physical memory is
  below the threshold of that kind of job. Block = exit code 2 with the reason on stderr.
  It never kills or stops anything that already runs.

  Thresholds (kinds of jobs, patterns, MB) come from three JSON files, merged in this order,
  a later one replacing a kind of the same name field by field:
    1. <agent-crew>/data/ram-guard.json        shipped defaults (guesses)
    2. <claude home>/team/ram-guard.json       the user's override (CLAUDE_CONFIG_DIR or ~/.claude)
    3. <project>/.claude/team/ram-guard.json   project-specific heavy commands
  `"enabled": false` at the top level switches the guard off.

  Fails open: a malformed config file or entry is skipped with a warning (the lower layers
  still apply), unreadable memory allows the call with a warning. Warnings reach Claude as
  additionalContext, once per 12 hours per distinct text (marker files in the temp folder).

  Test hooks (environment variables, not for normal use):
    AGENT_CREW_FREE_MB    a number = pretend that much memory is free; "unreadable" = pretend it cannot be read
    AGENT_CREW_USER_DIR   use this folder as the user's Claude folder
#>
$ErrorActionPreference = 'Stop'

$rawInput = ''
try {
  $stream = [Console]::OpenStandardInput()
  $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
  $rawInput = $reader.ReadToEnd()
} catch { exit 0 }
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }

. (Join-Path $PSScriptRoot 'crew-common.ps1')

$script:RamWarnings = New-Object System.Collections.Generic.List[string]

function Add-RamWarning([string]$Text) { $script:RamWarnings.Add($Text) }

function Get-FreePhysicalMemoryMB {
  # Available physical memory in MB (free plus cache that can be dropped), or $null if it cannot be read.
  if ($env:AGENT_CREW_FREE_MB) {
    $fake = 0.0
    if ([double]::TryParse($env:AGENT_CREW_FREE_MB, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$fake)) { return $fake }
    return $null
  }
  try {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
      try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $bytes = (New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory
        if ($bytes -gt 0) { return [double]$bytes / 1MB }
      } catch { }
      $kb = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory
      if ($kb -gt 0) { return [double]$kb / 1024 }
      return $null
    }
    if ([System.IO.File]::Exists('/proc/meminfo')) {
      foreach ($line in [System.IO.File]::ReadAllLines('/proc/meminfo')) {
        if ($line -match '^MemAvailable:\s+(\d+)\s+kB') { return [double]$Matches[1] / 1024 }
      }
      return $null
    }
    # macOS: free + inactive + speculative pages (what the system can hand out without swapping).
    $vm = & vm_stat 2>$null
    $size = 4096
    $pages = 0.0
    foreach ($line in @($vm)) {
      if ($line -match 'page size of (\d+) bytes') { $size = [int]$Matches[1] }
      elseif ($line -match '^Pages (free|inactive|speculative):\s+(\d+)') { $pages += [double]$Matches[2] }
    }
    if ($pages -gt 0) { return $pages * $size / 1MB }
  } catch { }
  return $null
}

function Get-WarningsOnce {
  # Returns the warnings that have not been shown in the last 12 hours, and marks them as shown.
  param([string[]]$Texts)
  $out = @()
  $dir = [System.IO.Path]::GetTempPath()
  $md5 = [System.Security.Cryptography.MD5]::Create()
  foreach ($t in $Texts) {
    try {
      $hash = ([BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($t)))).Replace('-', '').ToLowerInvariant()
      $marker = Join-Path $dir "agent-crew-ram-guard-$hash.warned"
      if ((Test-Path -LiteralPath $marker) -and (((Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime).TotalHours -lt 12)) { continue }
      [System.IO.File]::WriteAllText($marker, $t)
      $out += $t
    } catch { $out += $t }
  }
  $md5.Dispose()
  return $out
}

function Write-RamContext([string[]]$Texts) {
  $shown = @(Get-WarningsOnce $Texts)
  if ($shown.Count -eq 0) { return }
  $payload = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = ('agent-crew: ' + ($shown -join ' ')) } }
  Write-Output ($payload | ConvertTo-Json -Compress -Depth 5)
}

try {
  $in = ConvertFrom-HookText $rawInput
  if ($null -eq $in) { exit 0 }
  $tool = [string]$in.tool_name
  if (-not $tool) { exit 0 }
  $command = ''
  if ($in.tool_input -and $in.tool_input.PSObject.Properties['command'] -and $in.tool_input.command) { $command = [string]$in.tool_input.command }

  # Layers: plugin defaults < user < project.
  $config = @{ enabled = $true; kinds = [ordered]@{} }
  $pluginFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'data') 'ram-guard.json'
  if (-not [System.IO.File]::Exists($pluginFile)) { Add-RamWarning "ram-guard: the shipped defaults file is missing ($pluginFile), nothing is guarded." }
  Read-RamLayer $config $pluginFile 'shipped' $script:RamWarnings

  $userDir = Get-RamGuardUserDir
  if ($userDir) { Read-RamLayer $config (Join-Path (Join-Path $userDir 'team') 'ram-guard.json') 'user' $script:RamWarnings }

  $root = Find-TeamRoot ([string]$in.cwd)
  if ($root) { Read-RamLayer $config (Join-Path $root '.claude/team/ram-guard.json') 'project' $script:RamWarnings }

  if (-not $config.enabled) { exit 0 }

  # Which kinds does this call belong to?
  $matched = @()
  foreach ($name in $config.kinds.Keys) {
    $kind = $config.kinds[$name]
    if (-not $kind.enabled) { continue }
    $tools = @($kind.tools)
    if ($tools.Count -eq 0 -and @($kind.patterns).Count -gt 0) { $tools = @('Bash', 'PowerShell') }
    if ($tools.Count -eq 0 -or $null -eq $kind.min_free_mb) {
      Add-RamWarning "ram-guard: kind '$name' needs min_free_mb and either tools or patterns, skipped."
      continue
    }
    if (@($tools | Where-Object { $_ -ieq $tool }).Count -eq 0) { continue }
    $patterns = @($kind.patterns)
    $hit = ($patterns.Count -eq 0)
    foreach ($pat in $patterns) {
      if ($command -and [regex]::IsMatch($command, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $hit = $true; break }
    }
    if ($hit) { $matched += [pscustomobject]@{ Name = $name; Need = [double]$kind.min_free_mb } }
  }

  if ($matched.Count -eq 0) { Write-RamContext $script:RamWarnings; exit 0 }
  $worst = $matched | Sort-Object Need -Descending | Select-Object -First 1

  $free = Get-FreePhysicalMemoryMB
  if ($null -eq $free) {
    Add-RamWarning 'ram-guard: free memory could not be read on this machine, so the RAM guard allows everything.'
    Write-RamContext $script:RamWarnings
    exit 0
  }

  if ($free -ge $worst.Need) { Write-RamContext $script:RamWarnings; exit 0 }

  $msg = ("agent-crew RAM guard: free RAM {0} MB < needed {1} MB for '{2}'. Do not start this now: wait for the running work to finish (do not retry in a loop) and tell the user that memory is low. " +
    "The guard never kills anything. Thresholds are in ram-guard.json (user: team/ram-guard.json in the Claude folder, project: .claude/team/ram-guard.json); the user can lower a number or set enabled to false.") -f [int][Math]::Floor($free), [int][Math]::Ceiling($worst.Need), $worst.Name
  foreach ($w in $script:RamWarnings) { $msg += " [$w]" }
  [Console]::Error.WriteLine($msg)
  exit 2
} catch {
  # A broken hook must never block work.
  exit 0
}
