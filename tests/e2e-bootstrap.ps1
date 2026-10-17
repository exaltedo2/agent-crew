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
$draftDir = ""
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
  # Windows command-line quoting: backslashes before a quote are doubled, a quote is escaped,
  # and backslashes at the end are doubled so they do not escape the closing quote.
  ($Items | ForEach-Object { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }) -join ' '
}
# cmd.exe strips the first and last quote of /c's argument unless /s is used with the whole thing wrapped.
function ConvertTo-CmdArgString([string]$CmdFile, [string[]]$Items) {
  '/s /c "' + (ConvertTo-ArgString (@($CmdFile) + $Items)) + '"'
}
# [pid, start time, memory] of the process and all its descendants, to kill leftovers after the root has exited.
function Get-TreeSnapshot([int]$RootId) {
  $snap = @()
  foreach ($id in (Get-Tree $RootId)) {
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($pr) { try { $snap += [pscustomobject]@{ Id = $id; Start = $pr.StartTime; MB = $pr.WorkingSet64 } } catch { } }
  }
  return $snap
}
function Stop-Leftovers($Snapshot, [datetime]$Began) {
  foreach ($e in $Snapshot) {
    $pr = Get-Process -Id $e.Id -ErrorAction SilentlyContinue
    # Same start time as when seen = same process (a reused PID has a different one).
    if ($pr -and $e.Start -ge $Began) { try { if ($pr.StartTime -eq $e.Start) { Stop-Process -Id $e.Id -Force -ErrorAction SilentlyContinue } } catch { } }
  }
}
# Runs a program as a watched process; kills its whole tree over the memory/time limit, on any error,
# and any descendant that outlives the root. $ArgString is the finished command line.
function Invoke-Guarded([string]$File, [string]$ArgString, [string]$WorkDir, [int]$MaxMB, [int]$TimeoutS, [string]$StdIn = '', [int]$PollMs = 1000) {
  $began = (Get-Date).AddSeconds(-1)
  $proc = $null; $outTask = $null; $errTask = $null
  $reason = ''; $peak = 0; $snap = @()
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $ArgString
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($StdIn) { $proc.StandardInput.Write($StdIn) }
    $proc.StandardInput.Close()
    while (-not $proc.HasExited) {
      Start-Sleep -Milliseconds $PollMs
      $snap = Get-TreeSnapshot $proc.Id
      $mb = [math]::Round((($snap | Measure-Object -Property MB -Sum).Sum) / 1MB)
      if ($mb -gt $peak) { $peak = $mb }
      if ($mb -gt $MaxMB) { $reason = "memory $mb MB over limit $MaxMB MB"; break }
      if ($sw.Elapsed.TotalSeconds -gt $TimeoutS) { $reason = "timeout after $TimeoutS s"; break }
    }
  } finally {
    # Ctrl+C, error, limit or normal exit: never leave the tree (or a child that outlived the root) running.
    if ($proc) {
      if (-not $proc.HasExited) { Stop-Tree $proc.Id }
      Stop-Leftovers $snap $began
    }
  }
  [void]$proc.WaitForExit(10000)
  $out = ''
  if ($outTask.Wait(5000)) { $out = $outTask.Result }
  $err = ''
  if ($errTask.Wait(2000)) { $err = $errTask.Result }
  return [pscustomobject]@{ Output = $out; Error = $err; ExitCode = $proc.ExitCode; Killed = [bool]$reason; Reason = $reason; PeakMB = $peak; Seconds = [math]::Round($sw.Elapsed.TotalSeconds); Pid = $proc.Id }
}
function Get-FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }

if ($GuardSelfTest) {
  $bad = 0
  function Expect([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:bad++ }
  }
  # 1. memory: parent + grandchild allocate ~800 MB, limit 300 MB -> whole tree killed.
  $alloc = '$a=New-Object byte[] 400MB; for($i=0;$i -lt $a.Length;$i+=4096){$a[$i]=1}; Start-Sleep 120'
  $code = "Start-Process powershell -ArgumentList '-NoProfile','-Command','$alloc'; $alloc"
  $r = Invoke-Guarded 'powershell.exe' (ConvertTo-ArgString @('-NoProfile', '-Command', $code)) $env:TEMP 300 60
  Start-Sleep -Seconds 2
  $left = @(Get-Tree $r.Pid | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  Expect "memory limit kills the whole tree (peak $($r.PeakMB) MB, $($r.Seconds) s)" ($r.Killed -and $r.Reason -like 'memory*' -and $left.Count -eq 0) "survivors=$($left.Count)"
  # 2. the root exits early and leaves a child running -> the child must be killed.
  $code = '$c = Start-Process powershell -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep 120'' -PassThru; Write-Output $c.Id; Start-Sleep -Milliseconds 700'
  $r = Invoke-Guarded 'powershell.exe' (ConvertTo-ArgString @('-NoProfile', '-Command', $code)) $env:TEMP 3000 60 '' 100
  $childId = [int](($r.Output -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1))
  Start-Sleep -Seconds 1
  Expect 'a child that outlives the root is killed' ($childId -gt 0 -and -not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) "child=$childId"
  if ($childId -gt 0) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
  # 3. argument quoting: embedded quote, trailing backslash, spaces.
  $t = Join-Path $env:TEMP ('crew-guard-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Path "$t\dir with space" -Force | Out-Null
  $dump = "$t\dump.ps1"
  Set-Content -LiteralPath $dump -Value '$args | ForEach-Object { "[" + $_ + "]" }'
  $items = @('plain', 'a "quoted" word', 'trail\', 'C:\x y\', 'two  spaces')
  $r = Invoke-Guarded 'powershell.exe' (ConvertTo-ArgString (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dump) + $items)) $t 3000 60
  $got = @($r.Output -split "`r?`n" | Where-Object { $_ })
  Expect 'ConvertTo-ArgString keeps embedded quotes, trailing backslashes and spaces' (($got -join '|') -eq (($items | ForEach-Object { "[$_]" }) -join '|')) ($got -join '|')
  # 4. the .cmd launch form with a space in the path: all arguments arrive intact.
  Set-Content -LiteralPath "$t\dir with space\echo args.cmd" -Value '@echo off', 'echo ARGS:%1^|%2^|%3' -Encoding Ascii
  $r = Invoke-Guarded $env:ComSpec (ConvertTo-CmdArgString "$t\dir with space\echo args.cmd" @('-p', 'two words', '--x=a,b')) $t 3000 60
  Expect '.cmd launch with a space in the path passes the arguments' ($r.Output -match [regex]::Escape('ARGS:"-p"|"two words"|"--x=a,b"')) $r.Output.Trim()
  Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
  if ($bad -eq 0) { Write-Host 'GUARD SELFTEST PASSED'; exit 0 }
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
Roster: the minimal core only. The agent-crew install folder for this run (`$CREW) is $crewCopy . Do the whole bootstrap yourself, including PROJECT.md: subagents are disabled in this run. Writes to .claude/team are expected to be refused in this headless run: follow the skill's fallback (drafts in the folder crew-bootstrap-drafts/ in the project root) and end your reply with the line `DRAFTS: <absolute folder path>`. Reply in at most 8 lines.
"@
  # The headless run may edit what --add-dir grants, so it gets a COPY of the installed agent-crew,
  # never the real one. The prompt tells it that copy is $CREW.
  $crewCopy = $proj + '-crew'
  Copy-Item -LiteralPath $Crew -Destination $crewCopy -Recurse
  $argList = @('-p', '--agent', 'lead', '--permission-mode', 'acceptEdits', '--max-budget-usd', "$MaxBudgetUsd", '--output-format', 'json', '--add-dir', $crewCopy, '--disallowedTools=Agent,Task,SendMessage')
  if ($Model) { $argList += @('--model', $Model) }
  # Only the variables that make claude think it runs INSIDE the caller's session (its identity, message
  # socket and bridge) are removed for the child; everything else (PATH, proxies, CLAUDE_CODE_EXECPATH...) stays.
  $nested = 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED',
    'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN', 'CLAUDE_CODE_BRIDGE_SESSION_ID'
  $saved = @{}
  foreach ($name in $nested) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $v) { $saved[$name] = $v; Remove-Item "Env:$name" }
  }
  Write-Host "Running claude headless in $proj (cap `$$MaxBudgetUsd) ..."
  # The prompt goes through stdin: a newline in a cmd.exe command line cuts it off.
  # claude is an npm shim (claude.cmd) or a real exe; the guard kills the whole process tree either way.
  $cl = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cl.Source -match '\.exe$') { $file = $cl.Source; $fargs = ConvertTo-ArgString $argList }
  else { $file = $env:ComSpec; $fargs = ConvertTo-CmdArgString $cl.Source $argList }
  $out = ''
  try { $run = Invoke-Guarded $file $fargs $proj $MaxMemoryMB $TimeoutSec $prompt }
  finally { foreach ($k in $saved.Keys) { Set-Item "Env:$k" $saved[$k] } }
  $out = $run.Output
  if ($run.Error.Trim()) { Write-Host ('  claude stderr: ' + $run.Error.Trim().Substring(0, [math]::Min(600, $run.Error.Trim().Length))) }
  Write-Host "  run: $($run.Seconds) s, peak tree memory $($run.PeakMB) MB"
  if ($run.Killed) { Check 'claude run stayed within limits' $false "KILLED: $($run.Reason)" }
  $said = ''
  try {
    $json = $out | ConvertFrom-Json
    $said = ("$($json.result)") -replace '\s+', ' '
    Write-Host ('  usage: cost $' + $json.total_cost_usd + ', turns ' + $json.num_turns + ', ' + [math]::Round($json.duration_ms / 1000) + ' s')
    Write-Host ('  claude said: ' + $said.Substring(0, [math]::Min(500, $said.Length)))
  } catch { Write-Host "  (claude output was not JSON) $($out.Substring(0, [math]::Min(600, $out.Length)))" }

  # --- 4. assertions
  # The documented fallback of a headless run: writes to .claude/team are refused, so the skill
  # parks drafts in <project>/crew-bootstrap-drafts/ and names it on a `DRAFTS:` line. This script (not claude)
  # copies them into a throwaway copy of the project and checks that copy.
  $team = ''
  $draftDir = ''
  if ($said -match 'DRAFTS:\s*`?([^\s`*]+)') { $draftDir = $Matches[1].Trim() }
  $draftOk = [bool]($draftDir -and (Test-Path -LiteralPath $draftDir -PathType Container))
  Check 'reply has a DRAFTS: <folder> line naming an existing folder' $draftOk $draftDir
  if ($draftOk) { Check 'drafts are in <project>/crew-bootstrap-drafts' ((Resolve-Path -LiteralPath $draftDir).Path.TrimEnd([char[]]'\/') -ieq (Join-Path (Resolve-Path -LiteralPath $proj).Path 'crew-bootstrap-drafts')) $draftDir }
  $copy = $proj + '-copy'
  $team = Join-Path $copy '.claude\team'
  if ($draftOk) {
    Copy-Item -LiteralPath $proj -Destination $copy -Recurse
    New-Item -ItemType Directory -Path $team -Force | Out-Null
    foreach ($f in 'PROJECT.md', 'routing.md', 'roster.md', 'state.md') {
      $src = Join-Path $draftDir $f
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $team }
    }
  }
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
  $ct = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\check-team.ps1') -Project $(if ($draftOk) { $copy } else { $proj }) -ClaudeHome $ClaudeHome 2>&1 | Out-String
  Check 'check-team.ps1 passes' ($LASTEXITCODE -eq 0) $ct.Trim()
} finally {
  if ($Keep) { Write-Host "Kept: $proj (and $proj-copy, drafts: $draftDir)" }
  else {
    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($proj + '-copy') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($proj + '-crew') -Recurse -Force -ErrorAction SilentlyContinue
  }
}
$failed = @($results | Where-Object { -not $_ }).Count
Write-Host ''
if ($failed -gt 0) { Write-Host "E2E FAILED: $failed check(s)" -ForegroundColor Red; exit 1 }
Write-Host 'E2E PASSED'
exit 0
