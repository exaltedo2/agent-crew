<#
.SYNOPSIS
  Test runner for agent-crew. Plain PowerShell, no Pester. Exit code 0 = all passed.
  Runs: ledger.ps1 on the fixtures, check-team.ps1 on the fixtures, every hook with sample
  stdin JSON, and the installer against a temporary Claude folder.
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Work = Join-Path $PSScriptRoot ('.tmp\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$PS = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
if (-not $PS) { $PS = Get-Command pwsh -ErrorAction Stop }
$PsExe = $PS.Source

$script:Passed = 0
$script:Failed = 0

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { $script:Passed++; Write-Host "  ok   $Name" }
  else { $script:Failed++; Write-Host "  FAIL $Name $Detail" -ForegroundColor Red }
}
function Section([string]$Title) { Write-Host ""; Write-Host "== $Title" }

function Invoke-Script([string]$Script, [string[]]$Arguments = @(), [string]$StdIn = $null, [string]$WorkingDirectory = $Root) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PsExe
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
  foreach ($a in $Arguments) { $argLine += ' "' + $a + '"' }
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $WorkingDirectory
  $p = [System.Diagnostics.Process]::Start($psi)
  if ($null -ne $StdIn) {
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdIn)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
  }
  $p.StandardInput.Close()
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

function ConvertTo-Slash([string]$p) { return $p.Replace('\', '/') }

try {
  # ------------------------------------------------------------------ ledger
  Section 'ledger.ps1'
  $ledger = Join-Path $Root 'scripts\ledger.ps1'
  $projects = Join-Path $Fixtures 'projects'
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Alias', 'bug-hunter=reviewer', '-Format', 'json')
  Check 'ledger exits 0' ($r.Exit -eq 0) $r.Err
  $got = $r.Out | ConvertFrom-Json
  $exp = Get-Content -Raw (Join-Path $PSScriptRoot 'expected\ledger.json') | ConvertFrom-Json
  Check 'request count (dedupe, synthetic and user lines ignored)' ($got.requests -eq $exp.requests) "got $($got.requests)"
  Check 'total cost' ([Math]::Abs($got.totalCostUsd - $exp.totalCostUsd) -lt 1e-6) "got $($got.totalCostUsd)"
  foreach ($prop in $exp.byAgent.PSObject.Properties) {
    $e = $prop.Value
    $g = @($got.byAgent | Where-Object { $_.Agent -eq $prop.Name })
    Check "agent '$($prop.Name)' present" ($g.Count -eq 1)
    if ($g.Count -eq 1) {
      $g = $g[0]
      Check "agent '$($prop.Name)' tokens" (($g.Spawns -eq $e.spawns) -and ($g.Input -eq $e.input) -and ($g.CacheWrite -eq $e.cacheWrite) -and ($g.CacheRead -eq $e.cacheRead) -and ($g.Output -eq $e.output)) ($g | ConvertTo-Json -Compress)
      Check "agent '$($prop.Name)' cost" ([Math]::Abs($g.Cost - $e.cost) -lt 1e-6) "got $($g.Cost)"
    }
  }
  $rowsOk = ($got.rows.Count -eq $exp.rows.Count)
  for ($i = 0; $rowsOk -and $i -lt $exp.rows.Count; $i++) {
    $a = $got.rows[$i]; $b = $exp.rows[$i]
    if (-not (($a.Agent -eq $b.agent) -and ($a.Model -eq $b.model) -and ($a.Effort -eq $b.effort) -and ($a.Output -eq $b.output))) { $rowsOk = $false }
  }
  Check 'detail rows (sorted by cost; meta model/effort, fallback to message model and "default")' $rowsOk ($got.rows | ConvertTo-Json -Compress)

  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'without -Alias the agent keeps its own name' (@($g.byAgent | Where-Object { $_.Agent -eq 'bug-hunter' }).Count -eq 1)
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Since', '2026-01-15', '-Format', 'json', '-MainAgent', 'lead')
  $g = $r.Out | ConvertFrom-Json
  Check '-Since filters old requests' ($g.requests -eq 1 -and [Math]::Abs($g.totalCostUsd - 6.0) -lt 1e-6) $r.Out
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Session', 'nope', '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check '-Session filters sessions' ($g.requests -eq 0)
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-MainAgent', 'lead', '-Format', 'md')
  Check 'markdown output has a table and the main agent name' (($r.Out -match '\| lead \|') -and ($r.Out -match '\*\*Total'))
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects)
  Check 'table output runs' (($r.Exit -eq 0) -and ($r.Out -match 'By agent type'))
  $r = Invoke-Script $ledger @('-Project', 'C:\nowhere', '-ProjectsRoot', $projects)
  Check 'unknown project exits 1' ($r.Exit -eq 1)

  # Warnings and prices: ids without an exact price are flagged, legacy opus is priced at its own
  # rate, unparseable lines are reported, everything is labelled as an estimate.
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'json output is labelled estimated' ($g.estimated -eq $true)
  Check 'family-fallback priced models are flagged' (@($g.fallbackPricedModels) -contains 'claude-opus-5-5')
  Check 'exactly priced models are not flagged' (@($g.fallbackPricedModels) -notcontains 'claude-haiku-4-5-20251001')
  Check 'a request in a main file and a subagent file is counted once (subagent wins, any read order)' (($g.requests -eq 4) -and (@($g.byAgent | Where-Object { $_.Agent -eq 'bug-hunter' }).Count -eq 1))
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects)
  Check 'text output has the warning and says estimated' (($r.Out -match 'WARNING: model\(s\) claude-opus-5-5') -and ($r.Out -match 'Total \(estimated\)'))
  $r = Invoke-Script $ledger @('-Project', 'C:\fixture\legacy', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'opus 4.1 at 15/MTok plus opus 4.5 at 5/MTok = 20' ([Math]::Abs($g.totalCostUsd - 20.0) -lt 1e-6) "got $($g.totalCostUsd)"
  Check 'exactly priced ids give no fallback warning' (@($g.fallbackPricedModels).Count -eq 0)
  Check 'an unparseable line is counted and warned about' (($g.unparsedLines -eq 1) -and (@($g.warnings | Where-Object { $_ -match 'could not be parsed' }).Count -eq 1))

  # ------------------------------------------------------------------ check-team
  Section 'check-team.ps1'
  $check = Join-Path $Root 'scripts\check-team.ps1'
  $ok = Join-Path $Fixtures 'team-ok'
  $r = Invoke-Script $check @('-Project', $ok, '-ClaudeHome', (Join-Path $ok 'claude-home'))
  Check 'valid team passes' ($r.Exit -eq 0) $r.Out
  $bad = Join-Path $Fixtures 'team-bad'
  $r = Invoke-Script $check @('-Project', $bad, '-ClaudeHome', (Join-Path $bad 'claude-home'))
  Check 'cap-violation fixture fails' ($r.Exit -eq 1) $r.Out
  Check '... reports the state.md cap' ($r.Out -match 'state\.md has \d+ lines \(cap 50\)')
  Check '... reports too many active agents' ($r.Out -match '8 active agents')
  Check '... reports the missing agent file' ($r.Out -match "'ghost'")
  Check '... reports the multi-line description' ($r.Out -match "'tester': description")
  $r = Invoke-Script $check @('-Project', (Join-Path $Work 'empty'))
  Check 'no .claude/team fails' ($r.Exit -eq 1)

  # ------------------------------------------------------------------ hooks
  Section 'hooks'
  $hooks = Join-Path $Root 'hooks'
  $proj = Join-Path $Work 'proj'
  Copy-Item -Recurse -LiteralPath $ok -Destination $proj
  New-Item -ItemType Directory -Path (Join-Path $proj 'src') | Out-Null
  $pj = ConvertTo-Slash $proj

  function Guard($agent, $file, $cwd = $proj, $extra = '') {
    $agentJson = if ($agent) { '"agent_type":"' + $agent + '",' } else { '' }
    $json = '{"cwd":"' + (ConvertTo-Slash $cwd) + '","hook_event_name":"PreToolUse","tool_name":"Write",' + $agentJson + '"tool_input":{"file_path":"' + ($file.Replace('\', '/')) + '"}}'
    return Invoke-Script (Join-Path $hooks 'guard-paths.ps1') @() $json
  }

  $r = Guard 'lead' "$pj/src/a.txt"
  Check 'guard: lead blocked outside .claude/team (exit 2 + reason)' (($r.Exit -eq 2) -and ($r.Err -match 'lead'))
  Check 'guard: lead may write .claude/team/state.md' ((Guard 'lead' "$pj/.claude/team/state.md").Exit -eq 0)
  Check 'guard: lead blocked on alternate data streams' (((Guard 'lead' "$pj/.claude/team/PROJECT.md::`$DATA").Exit -eq 2) -and ((Guard 'lead' "$pj/.claude/team/state.md:stream").Exit -eq 2))
  Check 'guard: lead may write a lead_writable glob' ((Guard 'lead' "$pj/docs/ROADMAP.md").Exit -eq 0)
  Check 'guard: lead can never write settings, even if lead_writable lists it' (((Guard 'lead' "$pj/.claude/settings.local.json").Exit -eq 2) -and ((Guard 'lead' "$pj/.claude/settings.json").Exit -eq 2))
  Check 'guard: lead can never write PROJECT.md' (((Guard 'lead' "$pj/.claude/team/PROJECT.md").Exit -eq 2) -and ((Guard 'lead' "$pj/.claude/team/project.md").Exit -eq 2))
  Check 'guard: lead can never write hook scripts' (((Guard 'lead' "$pj/.claude/hooks/x.ps1").Exit -eq 2) -and ((Guard 'lead' "$pj/tools/agent-crew/hooks/x.ps1").Exit -eq 2))

  # A wide lead_writable glob widens the lead, but never to the protected files.
  $wide = Join-Path $Work 'wide'
  Copy-Item -Recurse -LiteralPath $ok -Destination $wide
  $widePj = ConvertTo-Slash $wide
  Set-Content -LiteralPath (Join-Path $wide '.claude/team/PROJECT.md') -Value "---`nlead_writable:`n  - '**'`n---`n"
  Check 'guard: a wide lead_writable allows ordinary files' ((Guard 'lead' "$widePj/src/a.txt" $wide).Exit -eq 0)
  Check 'guard: ... but not PROJECT.md, settings or hooks' (((Guard 'lead' "$widePj/.claude/team/PROJECT.md" $wide).Exit -eq 2) -and ((Guard 'lead' "$widePj/.claude/settings.local.json" $wide).Exit -eq 2) -and ((Guard 'lead' "$widePj/.claude/hooks/a.ps1" $wide).Exit -eq 2))

  # Junctions: a link inside an allowed folder must not lead outside it.
  $outside = Join-Path $Work 'outside'
  New-Item -ItemType Directory -Path $outside | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $proj '.claude/team/reports') -Force | Out-Null
  & cmd.exe /c mklink /J (Join-Path $proj '.claude\team\lnk') $outside | Out-Null
  & cmd.exe /c mklink /J (Join-Path $proj '.claude\team\reports\lnk2') $outside | Out-Null
  $junctionsMade = (Test-Path (Join-Path $proj '.claude\team\lnk')) -and (Test-Path (Join-Path $proj '.claude\team\reports\lnk2'))
  Check 'guard: test junctions were created' $junctionsMade
  Check 'guard: lead cannot write through a junction in .claude/team' ((Guard 'lead' "$pj/.claude/team/lnk/pwn.txt").Exit -eq 2)
  Check 'guard: thinker cannot write through a junction in reports/' ((Guard 'thinker' "$pj/.claude/team/reports/lnk2/pwn.txt").Exit -eq 2)
  Check 'guard: ... and a normal report still works' ((Guard 'thinker' "$pj/.claude/team/reports/ok.md").Exit -eq 0)
  Check 'guard: lead relative path resolved against cwd' ((Guard 'lead' 'src/a.txt').Exit -eq 2)
  Check 'guard: lead cannot escape with ..' ((Guard 'lead' "$pj/.claude/team/../../src/a.txt").Exit -eq 2)
  Check 'guard: lead blocked outside the project' ((Guard 'lead' "$(ConvertTo-Slash $Work)/other.txt").Exit -eq 2)
  Check 'guard: plugin-prefixed agent name is recognised' ((Guard 'agent-crew:lead' "$pj/src/a.txt").Exit -eq 2)
  Check 'guard: lead found from a subfolder cwd' ((Guard 'lead' "$pj/src/a.txt" (Join-Path $proj 'src')).Exit -eq 2)
  Check 'guard: thinker may write a report' ((Guard 'thinker' "$pj/.claude/team/reports/2026-x.md").Exit -eq 0)
  Check 'guard: thinker blocked elsewhere' ((Guard 'thinker' "$pj/src/a.txt").Exit -eq 2)
  Check 'guard: thinker blocked on state.md' ((Guard 'thinker' "$pj/.claude/team/state.md").Exit -eq 2)
  Check 'guard: reviewer and architect are report-only too' (((Guard 'reviewer' "$pj/src/a.txt").Exit -eq 2) -and ((Guard 'architect' "$pj/src/a.txt").Exit -eq 2))
  Check 'guard: report_only_agents from PROJECT.md' ((Guard 'ui-tester' "$pj/src/a.txt").Exit -eq 2)
  Check 'guard: coder allowed' ((Guard 'coder' "$pj/src/a.txt").Exit -eq 0)
  Check 'guard: no agent identity allowed' ((Guard $null "$pj/src/a.txt").Exit -eq 0)
  Check 'guard: no .claude/team above cwd is a no-op' ((Guard 'lead' "$(ConvertTo-Slash $Work)/x.txt" $Work).Exit -eq 0)
  $r = Invoke-Script (Join-Path $hooks 'guard-paths.ps1') @() 'not json'
  Check 'guard: invalid stdin does not block' ($r.Exit -eq 0)
  $r = Invoke-Script (Join-Path $hooks 'guard-paths.ps1') @() ''
  Check 'guard: empty stdin does not block' ($r.Exit -eq 0)

  # check-caps
  function Caps($file) {
    $json = '{"cwd":"' + $pj + '","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"' + $file + '"}}'
    return Invoke-Script (Join-Path $hooks 'check-caps.ps1') @() $json
  }
  $state = Join-Path $proj '.claude/team/state.md'
  $r = Caps "$pj/.claude/team/state.md"
  Check 'caps: under the cap is silent' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq ''))
  Add-Content -LiteralPath $state -Value (1..60 | ForEach-Object { "line $_" })
  $r = Caps "$pj/.claude/team/state.md"
  Check 'caps: over the cap warns with additionalContext and does not block' (($r.Exit -eq 0) -and ($r.Out -match 'additionalContext') -and ($r.Out -match 'cap of 50'))
  $r = Caps "$pj/src/a.txt"
  Check 'caps: other files are silent' ($r.Out.Trim() -eq '')
  $r = Caps "$pj/.claude/team/reports/a.md"
  Check 'caps: reports are silent' ($r.Out.Trim() -eq '')

  # pre-compact / post-compact
  $snap = Join-Path $proj '.claude/team/snapshots'
  1..7 | ForEach-Object {
    [void](Invoke-Script (Join-Path $hooks 'pre-compact.ps1') @() ('{"cwd":"' + $pj + '","hook_event_name":"PreCompact","trigger":"auto"}'))
  }
  $snaps = @(Get-ChildItem -LiteralPath $snap -Filter 'state-*.md')
  Check 'pre-compact: keeps the newest 5 snapshots' ($snaps.Count -eq 5) "found $($snaps.Count)"
  Check 'pre-compact: snapshot is a copy of state.md' ((Get-Content -Raw $snaps[0].FullName) -eq (Get-Content -Raw $state))
  $log = Join-Path $proj '.claude/team/compact_log.md'
  1..22 | ForEach-Object {
    $j = '{"cwd":"' + $pj + '","hook_event_name":"PostCompact","trigger":"manual","compact_summary":"summary number ' + $_ + '\nsecond line"}'
    [void](Invoke-Script (Join-Path $hooks 'post-compact.ps1') @() $j)
  }
  $logText = Get-Content -Raw $log
  $entries = @([regex]::Matches($logText, '(?m)^=== compact ')).Count
  Check 'post-compact: keeps the newest 20 entries' ($entries -eq 20) "found $entries"
  Check 'post-compact: newest kept, oldest dropped' (($logText -match 'summary number 22') -and ($logText -notmatch 'summary number 2\r?\n') -and ($logText -match 'trigger=manual'))
  $r = Invoke-Script (Join-Path $hooks 'pre-compact.ps1') @() ('{"cwd":"' + (ConvertTo-Slash $Work) + '"}')
  Check 'pre/post-compact without .claude/team are no-ops' (($r.Exit -eq 0) -and -not (Test-Path (Join-Path $Work 'snapshots')))

  # session-start
  function Start-Hook($source, $cwd = $pj) {
    return Invoke-Script (Join-Path $hooks 'session-start.ps1') @() ('{"cwd":"' + $cwd + '","hook_event_name":"SessionStart","source":"' + $source + '"}')
  }
  $r = Start-Hook 'compact'
  Check 'session-start compact: prints state.md and says it is authoritative' (($r.Out -match 'authoritative') -and ($r.Out -match 'Session state'))
  # state.md is over its cap here (the caps test added 60 lines): startup must ask for the retro.
  $marker = Join-Path $proj '.claude/team/.last-retro'
  $r = Start-Hook 'startup'
  Check 'session-start startup: retro never ran' ($r.Out -match 'crew-retro' -and $r.Out -match 'never ran')
  Set-Content -LiteralPath $marker -Value (Get-Date).ToString('o')
  $r = Start-Hook 'startup'
  Check 'session-start startup: over-cap file asks for the retro' ($r.Out -match 'crew-retro' -and $r.Out -match 'state\.md has')
  # restore state.md from the template
  Copy-Item -LiteralPath (Join-Path $Root 'templates\state.md') -Destination $state -Force
  $r = Start-Hook 'startup'
  Check 'session-start startup: fresh marker and no cap violation is silent' ($r.Out.Trim() -eq '') $r.Out
  (Get-Item -LiteralPath $marker).LastWriteTime = (Get-Date).AddDays(-10)
  $r = Start-Hook 'resume'
  Check 'session-start resume: old marker asks for the retro' ($r.Out -match 'crew-retro' -and $r.Out -match '10 days')
  Set-Content -LiteralPath $marker -Value (Get-Date).ToString('o')
  $proj2 = Join-Path $proj '.claude/team/PROJECT.md'
  (Get-Content -Raw $proj2) -replace 'agent_crew_version: 0.1.0', 'agent_crew_version: 0.0.1' | Set-Content -LiteralPath $proj2 -NoNewline
  $r = Start-Hook 'startup'
  Check 'session-start: version mismatch is reported' ($r.Out -match '0\.0\.1' -and $r.Out -match '0\.1\.0')
  $r = Start-Hook 'startup' (ConvertTo-Slash $Work)
  Check 'session-start without .claude/team is silent' ($r.Out.Trim() -eq '')

  # ------------------------------------------------------------------ installer
  Section 'install.ps1'
  $install = Join-Path $Root 'install.ps1'
  $home1 = Join-Path $Work 'claude-home'
  New-Item -ItemType Directory -Path $home1 | Out-Null
  $mineCmd = 'powershell -File "C:\somewhere\agent-crew\hooks\mine.ps1"'
  $existing = @{ model = 'opus'; hooks = @{ PreToolUse = @(@{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'echo mine' }) }, @{ matcher = 'Edit'; hooks = @(@{ type = 'command'; command = $mineCmd }) }) }; other = @{ keep = 'me' } }
  [System.IO.File]::WriteAllText((Join-Path $home1 'settings.json'), ($existing | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

  $r = Invoke-Script $install @('-ClaudeHome', $home1)
  Check 'install exits 0' ($r.Exit -eq 0) ($r.Out + $r.Err)
  Check 'agents installed' ((Test-Path "$home1\agents\lead.md") -and (Test-Path "$home1\agents\reviewer.md"))
  Check 'skills installed' (Test-Path "$home1\skills\crew-retro\SKILL.md")
  Check 'runtime payload installed' ((Test-Path "$home1\agent-crew\hooks\guard-paths.ps1") -and (Test-Path "$home1\agent-crew\scripts\ledger.ps1") -and (Test-Path "$home1\agent-crew\VERSION") -and (Test-Path "$home1\agent-crew\installed.json"))
  Check 'USER.md copied when missing' (Test-Path "$home1\team\USER.md")
  Check 'agents carry no hooks front matter and no tokens (the guard is registered once, in settings.json)' (-not (Select-String -Path "$home1\agents\*.md" -Pattern '^hooks:|@@HOOK' -Quiet))
  Check 'a backup of settings.json was made' (@(Get-ChildItem $home1 -Filter 'settings.json.bak-*').Count -eq 1)
  $s = Get-Content -Raw "$home1\settings.json" | ConvertFrom-Json
  Check 'settings: own keys kept' (($s.model -eq 'opus') -and ($s.other.keep -eq 'me'))
  Check 'settings: user hook kept' (@($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash' }).Count -eq 1)
  foreach ($ev in 'PreToolUse', 'PostToolUse', 'PreCompact', 'PostCompact', 'SessionStart') {
    $n = @(@($s.hooks.$ev) | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -match [regex]::Escape("$home1" + [char]92 + 'agent-crew') }).Count
    Check "settings: exactly one $ev entry of agent-crew" ($n -eq 1) "found $n"
  }
  $before = Get-Content -Raw "$home1\settings.json"
  $r = Invoke-Script $install @('-ClaudeHome', $home1)
  Check 'second install is idempotent (settings.json byte-identical)' ((Get-Content -Raw "$home1\settings.json") -eq $before)
  Check '... and makes no extra backup' (@(Get-ChildItem $home1 -Filter 'settings.json.bak-*').Count -eq 1)
  Check '... and reports nothing new' ($r.Out -match '0 new')

  # the installed hook runs from the installed copy
  $r = Invoke-Script "$home1\agent-crew\hooks\guard-paths.ps1" @() ('{"cwd":"' + $pj + '","agent_type":"lead","tool_input":{"file_path":"' + $pj + '/src/a.txt"}}')
  Check 'installed copy of a hook works' ($r.Exit -eq 2)

  # -Update: an edited file gets a .new, an untouched file is updated, USER.md is never touched
  $edited = "$home1\agents\coder.md"
  Add-Content -LiteralPath $edited -Value 'MY LOCAL EDIT'
  Add-Content -LiteralPath "$home1\team\USER.md" -Value 'my prefs'
  $untouched = "$home1\agents\scout.md"
  # simulate "an older version was installed": change the file AND its recorded hash
  $recPath = "$home1\agent-crew\installed.json"
  $rec = Get-Content -Raw $recPath | ConvertFrom-Json
  Add-Content -LiteralPath $untouched -Value 'OLD CONTENT'
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $rec.files.'agents/scout.md' = ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($untouched)))).Replace('-', '').ToLowerInvariant()
  [System.IO.File]::WriteAllText($recPath, ($rec | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  $r = Invoke-Script $install @('-ClaudeHome', $home1)
  Check 'plain re-run only reports a pending update' (($r.Out -match 'run with -Update') -and ((Get-Content -Raw $untouched) -match 'OLD CONTENT'))
  $r = Invoke-Script $install @('-ClaudeHome', $home1, '-Update')
  Check '-Update replaces an unmodified older file' ((Get-Content -Raw $untouched) -notmatch 'OLD CONTENT')
  Check '-Update keeps a user-edited file' ((Get-Content -Raw $edited) -match 'MY LOCAL EDIT')
  Check '-Update writes a .new next to the edited file' ((Test-Path "$edited.new") -and ((Get-Content -Raw "$edited.new") -notmatch 'MY LOCAL EDIT'))
  Check '-Update never touches USER.md' ((Get-Content -Raw "$home1\team\USER.md") -match 'my prefs')
  $s = Get-Content -Raw "$home1\settings.json" | ConvertFrom-Json
  Check '-Update keeps one entry per hook' (@(@($s.hooks.SessionStart) | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -match [regex]::Escape("$home1" + [char]92 + 'agent-crew') }).Count -eq 1)

  # -Uninstall
  $r = Invoke-Script $install @('-ClaudeHome', $home1, '-Uninstall')
  Check 'uninstall exits 0' ($r.Exit -eq 0) ($r.Out + $r.Err)
  Check 'uninstall removes unmodified agents and skills' (-not (Test-Path "$home1\agents\lead.md") -and -not (Test-Path "$home1\skills\crew-retro") -and -not (Test-Path "$home1\agents\scout.md"))
  Check 'uninstall keeps the file the user edited' ((Test-Path $edited) -and -not (Test-Path "$edited.new"))
  Check 'uninstall keeps an edited USER.md' (Test-Path "$home1\team\USER.md")
  Check 'uninstall removes the runtime copy' (-not (Test-Path "$home1\agent-crew"))
  $s = Get-Content -Raw "$home1\settings.json" | ConvertFrom-Json
  $left = @($s.hooks.PSObject.Properties | ForEach-Object { @($_.Value) } | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -match [regex]::Escape("$home1" + [char]92 + 'agent-crew') }).Count
  Check 'uninstall removes the hook entries' ($left -eq 0)
  Check 'uninstall keeps a user hook that merely points into some agent-crew folder' (@($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Edit' -and $_.hooks[0].command -eq $mineCmd }).Count -eq 1)
  Check 'uninstall keeps the user hook and keys' (($s.model -eq 'opus') -and (@($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash' }).Count -eq 1) -and ($s.other.keep -eq 'me'))

  # -NoSettings on a fresh folder
  $home2 = Join-Path $Work 'claude-home2'
  $r = Invoke-Script $install @('-ClaudeHome', $home2, '-NoSettings')
  Check '-NoSettings does not create settings.json' (($r.Exit -eq 0) -and -not (Test-Path "$home2\settings.json") -and (Test-Path "$home2\agents\lead.md"))
  # an invalid settings.json (JSONC comment) is refused before anything is changed
  $home3 = Join-Path $Work 'claude-home3'
  New-Item -ItemType Directory -Path $home3 | Out-Null
  Set-Content -LiteralPath "$home3\settings.json" -Value "{ // comment`n  `"a`": 1 }"
  $r = Invoke-Script $install @('-ClaudeHome', $home3)
  Check 'invalid settings.json: install refuses with exit 1 and a message' (($r.Exit -eq 1) -and ($r.Out -match 'Nothing was changed'))
  Check '... and leaves no half-install behind' (-not (Test-Path "$home3\agents") -and -not (Test-Path "$home3\agent-crew") -and -not (Test-Path "$home3\skills") -and ((Get-Content -Raw "$home3\settings.json") -match 'comment'))
  # ... also for -Uninstall: files stay, so the hook entries never point to deleted scripts
  $home4 = Join-Path $Work 'claude-home4'
  [void](Invoke-Script $install @('-ClaudeHome', $home4))
  Add-Content -LiteralPath "$home4\settings.json" -Value '// trailing comment'
  $r = Invoke-Script $install @('-ClaudeHome', $home4, '-Uninstall')
  Check 'invalid settings.json: uninstall refuses and removes nothing' (($r.Exit -eq 1) -and (Test-Path "$home4\agents\lead.md") -and (Test-Path "$home4\agent-crew\hooks\guard-paths.ps1") -and (Test-Path "$home4\agent-crew\installed.json"))

  # empty-folder cleanup never removes agents/, skills/ or team/
  $home5 = Join-Path $Work 'claude-home5'
  [void](Invoke-Script $install @('-ClaudeHome', $home5, '-NoSettings'))
  [void](Invoke-Script $install @('-ClaudeHome', $home5, '-NoSettings', '-Uninstall'))
  Check 'uninstall keeps the agents, skills and team folders' ((Test-Path "$home5\agents") -and (Test-Path "$home5\skills") -and (Test-Path "$home5\team"))
  Check '... but removes the crew skill folders and agent-crew' (-not (Test-Path "$home5\skills\crew-retro") -and -not (Test-Path "$home5\agent-crew"))

  # at most 3 settings.json backups
  $home6 = Join-Path $Work 'claude-home6'
  New-Item -ItemType Directory -Path $home6 | Out-Null
  Set-Content -LiteralPath "$home6\settings.json" -Value '{ "model": "opus" }'
  1..4 | ForEach-Object {
    [void](Invoke-Script $install @('-ClaudeHome', $home6))
    [void](Invoke-Script $install @('-ClaudeHome', $home6, '-Uninstall'))
  }
  $baks = @(Get-ChildItem $home6 -Filter 'settings.json.bak-*').Count
  Check 'at most 3 settings.json backups are kept' ($baks -eq 3) "found $baks"

  # A project under a user home that has ~/.claude/team (from USER.md) is not mistaken for a team folder.
  $fh = Join-Path $Work 'fakehome'
  [void](Invoke-Script $install @('-ClaudeHome', "$fh\.claude", '-NoSettings'))
  $newproj = Join-Path (Join-Path $fh 'code') 'newproj'
  New-Item -ItemType Directory -Path $newproj -Force | Out-Null
  $fhHooks = "$fh\.claude\agent-crew\hooks"
  $np = ConvertTo-Slash $newproj
  $json = '{"cwd":"' + $np + '","agent_type":"lead","tool_input":{"file_path":"' + $np + '/.claude/team/routing.md"}}'
  $r = Invoke-Script "$fhHooks\guard-paths.ps1" @() $json
  Check 'bootstrap: the lead may create .claude/team in a project under a home that has ~/.claude/team' ($r.Exit -eq 0) $r.Err
  $json = '{"cwd":"' + $np + '","agent_type":"lead","tool_input":{"file_path":"' + $np + '/src/a.txt"}}'
  Check 'bootstrap: ... the guard stays a no-op there' ((Invoke-Script "$fhHooks\guard-paths.ps1" @() $json).Exit -eq 0)
  $r = Invoke-Script "$fhHooks\session-start.ps1" @() ('{"cwd":"' + $np + '","source":"startup"}')
  Check 'session-start: no retro nag in a project without its own .claude/team' ($r.Out.Trim() -eq '') $r.Out
  # ... while a real project team folder below that home still works
  New-Item -ItemType Directory -Path "$newproj\.claude\team" -Force | Out-Null
  $json = '{"cwd":"' + $np + '","agent_type":"lead","tool_input":{"file_path":"' + $np + '/src/a.txt"}}'
  Check 'a real .claude/team in the project is found again' ((Invoke-Script "$fhHooks\guard-paths.ps1" @() $json).Exit -eq 2)
}
finally {
  # Junctions first, so recursive removal never follows them.
  foreach ($j in @(Get-ChildItem -LiteralPath $Work -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)) { & cmd.exe /c rmdir "$($j.FullName)" | Out-Null }
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
