<#
.SYNOPSIS
  OPT-IN end-to-end test of the crew-bootstrap skill with a real headless Claude Code run.
  NOT called by tests\run.ps1: it spends real usage (a few minutes, capped by -MaxBudgetUsd).
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e-bootstrap.ps1 [-Keep]

.DESCRIPTION
  1. Makes a fresh git project in $env:TEMP (README, one source file, one commit on the branch
     `trunk`, so default-branch detection is exercised).
  2. Runs `claude -p --agent lead --permission-mode acceptEdits` in it, asking the lead to run
     crew-bootstrap with the answers given up front (non-interactive path of the skill).
  3. Asserts: the four team files exist, PROJECT.md names `trunk` and the installed
     agent_crew_version, and scripts\check-team.ps1 passes. PASS/FAIL per check, exit 1 on failure.

  Which Claude home is used: the REAL installed one (~/.claude, or -ClaudeHome). A temporary
  CLAUDE_CONFIG_DIR would need a copy of the login file, and a refreshed token in the copy can
  invalidate the real login, so it is not used. Nothing in ~/.claude is modified by this script
  (Claude Code itself writes its normal session logs there). agent-crew must already be installed
  (install.ps1). To test the skill in THIS checkout rather than the installed one, the skill
  folder is copied into the temp project's .claude\skills\ (project skills win over user skills);
  agents, hooks, templates and scripts come from the installed copy, and the installed VERSION is
  what PROJECT.md must record (a warning says when it differs from this checkout's VERSION).

.PARAMETER Keep           Keep the temp project (its path is printed) instead of deleting it.
.PARAMETER MaxBudgetUsd   Spending cap passed to claude (default 3).
.PARAMETER Model          Optional model alias for the run (default: your Claude Code default).
.PARAMETER ClaudeHome     Installed Claude folder (default: $HOME\.claude).
.PARAMETER MaxMemoryMB    Kill the whole claude process tree above this total working set (default 3000).
.PARAMETER TimeoutSec     Kill the whole tree after this many seconds (default 600).
.PARAMETER MinFreeMB      Refuse to start when free physical memory is below this (default 4096).
.PARAMETER GuardSelfTest  Test the watchdog only (no claude, no usage): runs a memory-hungry dummy
                          process tree and passes when the guard kills it.

.NOTES
  Safety guards (added after a headless run exhausted RAM, probably through subagent processes):
  the Agent and SendMessage tools are disallowed (bootstrap needs no subagents), claude runs as a
  watched process, its whole process tree is killed over the memory or time limit and in `finally`,
  and the run does not start when free memory is low. claude has no --max-turns flag; the dollar
  cap and the timeout bound the run instead.
#>
[CmdletBinding()]
param(
  [switch]$Keep,
  [double]$MaxBudgetUsd = 3,
  [string]$Model = '',
  [string]$ClaudeHome = (Join-Path $HOME '.claude'),
  [int]$MaxMemoryMB = 3000,
  [int]$TimeoutSec = 600,
  [int]$MinFreeMB = 4096,
  [switch]$GuardSelfTest
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Crew = Join-Path $ClaudeHome 'agent-crew'
$results = New-Object System.Collections.Generic.List[object]
# git writes warnings to stderr; with ErrorActionPreference Stop that would abort.
function GitP { $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & git -C $proj @args 2>&1 } finally { $ErrorActionPreference = $old } }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add($Ok)
  if ($Ok) { Write-Host "  PASS $Name" } else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red }
}

function Get-Tree([int]$RootId) {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
  $ids = New-Object System.Collections.Generic.HashSet[int]
  [void]$ids.Add($RootId)
  $grew = $true
  while ($grew) {
    $grew = $false
    foreach ($p in $all) { if ($ids.Contains([int]$p.ParentProcessId) -and $ids.Add([int]$p.ProcessId)) { $grew = $true } }
  }
  return @($ids)
}
function Get-TreeMB([int]$RootId) {
  $sum = 0
  foreach ($id in (Get-Tree $RootId)) {
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($pr) { $sum += $pr.WorkingSet64 }
  }
  return [math]::Round($sum / 1MB)
}
function Stop-Tree([int]$RootId) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & taskkill /T /F /PID $RootId 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
}
function ConvertTo-ArgString([string[]]$Items) {
  ($Items | ForEach-Object { '"' + (($_ -replace '(\*)"', '$1$1\"') -replace '(\+)$', '$1$1') + '"' }) -join ' '
}
# Runs a program as a watched process; kills its whole tree over the memory/time limit or on any error.
function Invoke-Guarded([string]$File, [string[]]$ArgItems, [string]$WorkDir, [int]$MaxMB, [int]$TimeoutS, [string]$StdIn = '') {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = ConvertTo-ArgString $ArgItems
  $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  if ($StdIn) { $proc.StandardInput.Write($StdIn) }
  $proc.StandardInput.Close()
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $reason = ''
  $peak = 0
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    while (-not $proc.HasExited) {
      Start-Sleep -Seconds 2
      $mb = Get-TreeMB $proc.Id
      if ($mb -gt $peak) { $peak = $mb }
      if ($mb -gt $MaxMB) { $reason = "memory $mb MB over limit $MaxMB MB"; break }
      if ($sw.Elapsed.TotalSeconds -gt $TimeoutS) { $reason = "timeout after $TimeoutS s"; break }
    }
  } finally {
    # Ctrl+C, error or limit: never leave the tree running.
    if (-not $proc.HasExited) { Stop-Tree $proc.Id }
  }
  if ($reason) { Stop-Tree $proc.Id }
  [void]$proc.WaitForExit(10000)
  $out = ''
  if ($outTask.Wait(5000)) { $out = $outTask.Result }
  $err = ''
  if ($errTask.Wait(2000)) { $err = $errTask.Result }
  return [pscustomobject]@{ Output = $out; Error = $err; ExitCode = $proc.ExitCode; Killed = [bool]$reason; Reason = $reason; PeakMB = $peak; Seconds = [math]::Round($sw.Elapsed.TotalSeconds); Pid = $proc.Id }
}
function Get-FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }

if ($GuardSelfTest) {
  # Parent powershell starts a child powershell that allocates ~600 MB; limit is 300 MB.
  $code = '$h = New-Object System.Collections.ArrayList; Start-Process powershell -ArgumentList ''-NoProfile'',''-Command'',''$a=New-Object byte[] 400MB; for($i=0;$i -lt $a.Length;$i+=4096){$a[$i]=1}; Start-Sleep 120'' ; $a=New-Object byte[] 400MB; for($i=0;$i -lt $a.Length;$i+=4096){$a[$i]=1}; Start-Sleep 120'
  $r = Invoke-Guarded 'powershell.exe' @('-NoProfile', '-Command', $code) $env:TEMP 300 60
  Start-Sleep -Seconds 2
  $left = @(Get-Tree $r.Pid | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  Write-Host "  guard: killed=$($r.Killed) reason='$($r.Reason)' peak=$($r.PeakMB) MB after $($r.Seconds) s, survivors=$($left.Count)"
  if ($r.Killed -and $left.Count -eq 0 -and $r.Reason -like 'memory*') { Write-Host 'GUARD SELFTEST PASSED'; exit 0 }
  Write-Host 'GUARD SELFTEST FAILED' -ForegroundColor Red; exit 1
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Host 'claude not found on PATH'; exit 2 }
$installedVersionFile = Join-Path $Crew 'VERSION'
if (-not (Test-Path -LiteralPath $installedVersionFile)) { Write-Host "agent-crew is not installed in $ClaudeHome (run install.ps1)"; exit 2 }
$installed = (Get-Content -LiteralPath $installedVersionFile -Raw).Trim()
$repoVersion = (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -Raw).Trim()
if ($installed -ne $repoVersion) { Write-Host "WARNING: installed $installed differs from this checkout $repoVersion; agents/templates come from the installed copy." -ForegroundColor Yellow }

$free = Get-FreeMB
if ($free -lt $MinFreeMB) { Write-Host "Refusing to start: only $free MB free physical memory (need $MinFreeMB)."; exit 2 }

$proj = Join-Path $env:TEMP ('crew-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $proj | Out-Null
try {
  # --- 1. fresh project on a branch that is not called main
  GitP init -q -b trunk 2>&1 | Out-Null
  GitP config user.email 'e2e@example.invalid'
  GitP config user.name 'e2e'
  Set-Content -LiteralPath (Join-Path $proj 'README.md') -Value "# Tiny calc`nA tiny example project. Run the tests with: python -m unittest"
  Set-Content -LiteralPath (Join-Path $proj 'calc.py') -Value "def add(a, b):`n    return a + b"
  GitP add -A 2>&1 | Out-Null
  GitP commit -q -m 'Initial commit' 2>&1 | Out-Null
  $branch = (GitP branch --show-current | Out-String).Trim()
  Check 'fixture project is on branch trunk' ($branch -eq 'trunk') $branch

  # --- 2. the skill under test, as a project skill
  $skillDst = Join-Path $proj '.claude\skills\crew-bootstrap'
  New-Item -ItemType Directory -Path $skillDst -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'skills\crew-bootstrap\SKILL.md') -Destination $skillDst

  # --- 3. headless run
  $prompt = @"
Run the crew-bootstrap skill for this project now. This is a non-interactive run: do not ask me questions, use these answers (for any I did not give, use the skill's defaults and say which):
1. Deliverable: a small Python library change with passing unit tests.
2. Correctness: python -m unittest (not installed here, record it as the intended command).
3. Risky areas: none.
4. Languages: English for chat and repository.
5. I approve and merge; nothing goes straight to the default branch.
Roster: the minimal core only. Do the whole bootstrap yourself, including PROJECT.md: subagents are disabled in this run, so write it directly instead of delegating to the coder. If a write is refused, report it. Reply in at most 8 lines.
"@
  $argList = @('-p', '--agent', 'lead', '--permission-mode', 'acceptEdits', '--max-budget-usd', "$MaxBudgetUsd", '--output-format', 'json', '--add-dir', $Crew, '--disallowedTools=Agent,Task,SendMessage')
  if ($Model) { $argList += @('--model', $Model) }
  # A nested run must not think it is inside the caller's session.
  $saved = @{}
  foreach ($e in @(Get-ChildItem Env: | Where-Object { $_.Name -eq 'CLAUDECODE' -or $_.Name -like 'CLAUDE_CODE_*' -or $_.Name -eq 'CLAUDE_PID' })) {
    $saved[$e.Name] = $e.Value
    Remove-Item "Env:$($e.Name)"
  }
  Write-Host "Running claude headless in $proj (cap `$$MaxBudgetUsd) ..."
  # The prompt goes through stdin: a newline in a cmd.exe command line cuts it off.
  # --add-dir lets the headless run read the installed templates (outside the project).
  # claude is an npm shim: prefer a real exe, else the .cmd through cmd.exe (taskkill /T covers the chain).
  $cl = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cl.Source -match '\.exe$') { $file = $cl.Source; $fargs = $argList }
  else { $file = $env:ComSpec; $fargs = @('/c', $cl.Source) + $argList }
  $out = ''
  try { $run = Invoke-Guarded $file $fargs $proj $MaxMemoryMB $TimeoutSec $prompt }
  finally { foreach ($k in $saved.Keys) { Set-Item "Env:$k" $saved[$k] } }
  $out = $run.Output
  if ($run.Error.Trim()) { Write-Host ('  claude stderr: ' + $run.Error.Trim().Substring(0, [math]::Min(600, $run.Error.Trim().Length))) }
  Write-Host "  run: $($run.Seconds) s, peak tree memory $($run.PeakMB) MB"
  if ($run.Killed) { Check 'claude run stayed within limits' $false "KILLED: $($run.Reason)" }
  try {
    $json = $out | ConvertFrom-Json
    $said = ("$($json.result)") -replace '\s+', ' '
    Write-Host ('  usage: cost $' + $json.total_cost_usd + ', turns ' + $json.num_turns + ', ' + [math]::Round($json.duration_ms / 1000) + ' s')
    Write-Host ('  claude said: ' + $said.Substring(0, [math]::Min(500, $said.Length)))
  } catch { Write-Host "  (claude output was not JSON) $($out.Substring(0, [math]::Min(600, $out.Length)))" }

  # --- 4. assertions
  $team = Join-Path $proj '.claude\team'
  foreach ($f in 'PROJECT.md', 'routing.md', 'roster.md', 'state.md') {
    Check "$f exists" (Test-Path -LiteralPath (Join-Path $team $f))
  }
  $pm = Join-Path $team 'PROJECT.md'
  if (Test-Path -LiteralPath $pm) {
    $text = Get-Content -LiteralPath $pm -Raw
    Check 'PROJECT.md records the default branch trunk' ($text -match '\btrunk\b')
    Check "PROJECT.md records agent_crew_version $installed" ($text -match ('(?m)^agent_crew_version:\s*"?' + [regex]::Escape($installed) + '"?\s*$'))
  } else {
    Check 'PROJECT.md records the default branch trunk' $false 'PROJECT.md missing'
    Check "PROJECT.md records agent_crew_version $installed" $false 'PROJECT.md missing'
  }
  $ct = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\check-team.ps1') -Project $proj -ClaudeHome $ClaudeHome 2>&1 | Out-String
  Check 'check-team.ps1 passes' ($LASTEXITCODE -eq 0) $ct.Trim()
} finally {
  if ($Keep) { Write-Host "Kept: $proj" }
  else { Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue }
}
$failed = @($results | Where-Object { -not $_ }).Count
Write-Host ''
if ($failed -gt 0) { Write-Host "E2E FAILED: $failed check(s)" -ForegroundColor Red; exit 1 }
Write-Host 'E2E PASSED'
exit 0
