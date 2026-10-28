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

# Hermetic wrappers: never read the real ~/.claude (a local price file, a USER.md) during tests.
function Invoke-Ledger([string[]]$Arguments) {
  if ($Arguments -notcontains '-LocalPrices') { $Arguments += @('-LocalPrices', (Join-Path $Work 'no-such-prices.local.json')) }
  return Invoke-Script (Join-Path $Root 'scripts\ledger.ps1') $Arguments
}
function Invoke-Check([string[]]$Arguments) {
  if ($Arguments -notcontains '-ClaudeHome') { $Arguments += @('-ClaudeHome', (Join-Path $Fixtures 'team-ok\claude-home')) }
  return Invoke-Script (Join-Path $Root 'scripts\check-team.ps1') $Arguments
}

function ConvertTo-Slash([string]$p) { return $p.Replace('\', '/') }

# Hermetic: the developer's own settings must not leak into check-team's output.
$envNames = 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS', 'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
$savedEnv = @{}; foreach ($n in $envNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
try {
  # ------------------------------------------------------------------ ledger
  Section 'ledger.ps1'
  $ledger = Join-Path $Root 'scripts\ledger.ps1'
  $projects = Join-Path $Fixtures 'projects'
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Alias', 'bug-hunter=reviewer', '-Format', 'json')
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

  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'without -Alias the agent keeps its own name' (@($g.byAgent | Where-Object { $_.Agent -eq 'bug-hunter' }).Count -eq 1)
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Since', '2026-01-15', '-Format', 'json', '-MainAgent', 'lead')
  $g = $r.Out | ConvertFrom-Json
  Check '-Since filters old requests' ($g.requests -eq 1 -and [Math]::Abs($g.totalCostUsd - 6.0) -lt 1e-6) $r.Out
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Session', 'nope', '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check '-Session filters sessions' ($g.requests -eq 0)
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-MainAgent', 'lead', '-Format', 'md')
  Check 'markdown output has a table and the main agent name' (($r.Out -match '\| lead \|') -and ($r.Out -match 'Share of usage'))
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects)
  Check 'table output runs' (($r.Exit -eq 0) -and ($r.Out -match 'By agent type'))
  $r = Invoke-Ledger @('-Project', 'C:\nowhere', '-ProjectsRoot', $projects)
  Check 'unknown project exits 1' ($r.Exit -eq 1)

  # Warnings and prices: ids without an exact price are flagged, legacy opus is priced at its own
  # rate, unparseable lines are reported, everything is labelled as an estimate.
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'json output is labelled estimated' ($g.estimated -eq $true)
  Check 'a new version of a known family (claude-opus-5-5) gives no warning' ((@($g.unknownModels).Count -eq 0) -and (@($g.warnings | Where-Object { $_ -match 'unknown model family' }).Count -eq 0))
  Check 'a request in a main file and a subagent file is counted once (subagent wins, any read order)' (($g.requests -eq 4) -and (@($g.byAgent | Where-Object { $_.Agent -eq 'bug-hunter' }).Count -eq 1))
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects)
  Check 'text output (usage mode) says estimated and has no dollars' (($r.Out -match 'ESTIMATES') -and ($r.Out -notmatch '\$') -and ($r.Out -match 'Share %') -and ($r.Out -match 'share of usage'))
  $r = Invoke-Ledger @('-Project', 'C:\fixture\proj', '-ProjectsRoot', $projects, '-Mode', 'cost')
  Check 'cost mode shows dollars and the estimated total' (($r.Out -match 'Total \(estimated\): \$') -and ($r.Out -match 'Est\. cost USD') -and ($r.Out -match 'Share %'))
  $r = Invoke-Ledger @('-Project', 'C:\fixture\legacy', '-ProjectsRoot', $projects, '-Format', 'json')
  $g = $r.Out | ConvertFrom-Json
  Check 'opus 4.1 at 15/MTok plus opus 4.5 at 5/MTok = 20' ([Math]::Abs($g.totalCostUsd - 20.0) -lt 1e-6) "got $($g.totalCostUsd)"
  Check 'override-priced ids give no warning' (@($g.unknownModels).Count -eq 0)
  Check 'an unparseable line is counted and warned about' (($g.unparsedLines -eq 1) -and (@($g.warnings | Where-Object { $_ -match 'could not be parsed' }).Count -eq 1))

  # Model families: priced by a whole-word match, new versions never warn, unknown families warn once.
  $nolocal = Join-Path $Work 'no-such-prices.local.json'
  $r = Invoke-Ledger @('-Project', 'C:\fixture\models', '-ProjectsRoot', $projects, '-Format', 'json', '-LocalPrices', $nolocal)
  $g = $r.Out | ConvertFrom-Json
  # opus-5-6 5 + opus alias 5 + sonnet 3.5 style 3 + fable 10 + opus-4-1 override 15 + upper-case haiku 1
  Check 'families: opus ids and alias, sonnet 3.5 id, fable, override, case-insensitive haiku priced right' ([Math]::Abs($g.totalCostUsd - 39.0) -lt 1e-6) "got $($g.totalCostUsd)"
  Check 'families: no model warning for known families' ((@($g.unknownModels).Count -eq 0) -and (@($g.warnings | Where-Object { $_ -match 'unknown model family' }).Count -eq 0))
  Check 'override beats family (opus 4.1 at 15, not 5)' (@($g.rows | Where-Object { $_.Model -eq 'claude-opus-4-1-20250805' })[0].Cost -eq 15)
  Check 'fable is priced with the fable family' (@($g.rows | Where-Object { $_.Model -eq 'claude-fable-1' })[0].Cost -eq 10)
  $sum = 0.0; foreach ($x in $g.byAgent) { $sum += $x.Share }
  Check 'shares of the agent table sum to about 100' ([Math]::Abs($sum - 100.0) -lt 0.1) "got $sum"
  $sum = 0.0; foreach ($x in $g.rows) { $sum += $x.Share }
  Check 'shares of the detail table sum to about 100' ([Math]::Abs($sum - 100.0) -lt 0.1) "got $sum"

  $r = Invoke-Ledger @('-Project', 'C:\fixture\zephyr', '-ProjectsRoot', $projects, '-Format', 'json', '-LocalPrices', $nolocal)
  $g = $r.Out | ConvertFrom-Json
  Check 'unknown family: default price (3+3+5), never fails' (($r.Exit -eq 0) -and ([Math]::Abs($g.totalCostUsd - 11.0) -lt 1e-6)) "got $($g.totalCostUsd)"
  Check 'unknown family: exactly ONE warning naming the models and how to add the family' ((@($g.warnings | Where-Object { $_ -match 'unknown model family' }).Count -eq 1) -and (@($g.unknownModels).Count -eq 2) -and ($g.warnings[0] -match 'zephyr-1') -and ($g.warnings[0] -match 'prices\.local\.json'))
  $local = Join-Path $Work 'prices.local.json'
  [System.IO.File]::WriteAllText($local, '{ "families": { "zephyr": { "match": ["zephyr"], "input": 1.0, "output": 2.0, "cache_write_5m": 1.0, "cache_write_1h": 1.0, "cache_read": 0.1 } } }')
  $r = Invoke-Ledger @('-Project', 'C:\fixture\zephyr', '-ProjectsRoot', $projects, '-Format', 'json', '-LocalPrices', $local)
  $g = $r.Out | ConvertFrom-Json
  Check 'local family file: no warning and its price is used (1+1+5)' ((@($g.unknownModels).Count -eq 0) -and ([Math]::Abs($g.totalCostUsd - 7.0) -lt 1e-6)) "got $($g.totalCostUsd) $($g.warnings -join '|')"
  $r = Invoke-Ledger @('-Project', 'C:\fixture\models', '-ProjectsRoot', $projects, '-LocalPrices', $local)
  Check 'usage mode table: Share % column, no dollar sign' (($r.Out -match 'Share %') -and ($r.Out -notmatch '\$'))

  # ------------------------------------------------------------------ check-team
  Section 'check-team.ps1'
  $check = Join-Path $Root 'scripts\check-team.ps1'
  $ok = Join-Path $Fixtures 'team-ok'
  $r = Invoke-Check @('-Project', $ok, '-ClaudeHome', (Join-Path $ok 'claude-home'))
  Check 'valid team passes' ($r.Exit -eq 0) $r.Out
  $bad = Join-Path $Fixtures 'team-bad'
  $r = Invoke-Check @('-Project', $bad, '-ClaudeHome', (Join-Path $bad 'claude-home'))
  Check 'cap-violation fixture fails' ($r.Exit -eq 1) $r.Out
  Check '... reports the state.md cap' ($r.Out -match 'state\.md has \d+ lines \(cap 50\)')
  Check '... reports too many active agents' ($r.Out -match '8 active agents')
  Check '... reports the missing agent file' ($r.Out -match "'ghost'")
  Check '... reports the multi-line description' ($r.Out -match "'tester': description")
  $r = Invoke-Check @('-Project', (Join-Path $Work 'empty'))
  Check 'no .claude/team fails' ($r.Exit -eq 1)
  # The lead needs Skill in its tools list; the shipped lead.md has it.
  $leadTools = (Get-Content (Join-Path $Root 'agents\lead.md') | Where-Object { $_ -match '^tools:' } | Select-Object -First 1)
  Check 'shipped lead.md allows the Skill tool' ($leadTools -match '\bSkill\b')
  $noSkill = Join-Path $Work 'noskill'
  Copy-Item -Recurse $ok $noSkill
  [System.IO.File]::WriteAllText((Join-Path $noSkill 'claude-home\agents\lead.md'), "---`nname: lead`ndescription: Fixture agent lead.`ntools: Read`n---`nBody.`n")
  $r = Invoke-Check @('-Project', $noSkill, '-ClaudeHome', (Join-Path $noSkill 'claude-home'))
  Check 'a lead without Skill in tools fails' (($r.Exit -eq 1) -and ($r.Out -match 'lacks Skill'))
  # Model names are free-form: an unavailable model with no fallback only warns, never fails.
  $mdl = Join-Path $Work 'models'
  Copy-Item -Recurse $ok $mdl
  New-Item -ItemType Directory -Force (Join-Path $mdl 'claude-home\team') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $mdl 'claude-home\team\USER.md'), "- Available models: opus, sonnet`n- Never use:`n")
  [System.IO.File]::WriteAllText((Join-Path $mdl '.claude\team\routing.md'), "| Job | Model | Effort | Fallback |`n|---|---|---|---|`n| easy | sonnet | low | - |`n| hard | fable | high | opus |`n| odd | zephyr-x | high | - |`n")
  $r = Invoke-Check @('-Project', $mdl, '-ClaudeHome', (Join-Path $mdl 'claude-home'))
  Check 'unknown model without fallback only warns' (($r.Exit -eq 0) -and ($r.Out -match "WARN: routing.md row 'odd'") -and ($r.Out -notmatch "row 'hard'") -and ($r.Out -notmatch "row 'easy'")) $r.Out


  # Review fixes: malformed local price files never crash; tools list formats; old USER.md layout.
  $bad1 = Join-Path $Work 'bad1.json'
  [System.IO.File]::WriteAllText($bad1, '{ this is not json')
  $r = Invoke-Ledger @('-Project', 'C:\fixture\zephyr', '-ProjectsRoot', $projects, '-Format', 'json', '-LocalPrices', $bad1)
  $g = $r.Out | ConvertFrom-Json
  Check 'malformed local price file: no crash, one warning, base prices kept' (($r.Exit -eq 0) -and (@($g.warnings | Where-Object { $_ -match 'not valid JSON' }).Count -eq 1) -and ([Math]::Abs($g.totalCostUsd - 11.0) -lt 1e-6)) $r.Err
  $bad2 = Join-Path $Work 'bad2.json'
  [System.IO.File]::WriteAllText($bad2, '{ "families": { "zephyr": { "match": ["zephyr"], "input": 1.0 }, "noMatch": { "match": [], "input": 1, "output": 1, "cache_write_5m": 1, "cache_write_1h": 1, "cache_read": 1 }, "str": { "match": ["x"], "input": "1", "output": 1, "cache_write_5m": 1, "cache_write_1h": 1, "cache_read": 1 } } }')
  $r = Invoke-Ledger @('-Project', 'C:\fixture\zephyr', '-ProjectsRoot', $projects, '-Format', 'json', '-LocalPrices', $bad2)
  $g = $r.Out | ConvertFrom-Json
  Check 'invalid local entries are skipped with a warning each, never priced at 0' (($r.Exit -eq 0) -and (@($g.warnings | Where-Object { $_ -match 'skipped' }).Count -eq 3) -and (@($g.unknownModels).Count -eq 2) -and ([Math]::Abs($g.totalCostUsd - 11.0) -lt 1e-6)) ($g.warnings -join '|')

  $tl = Join-Path $Work 'toolsfmt'
  New-Item -ItemType Directory -Force (Join-Path $tl 'claude-home\agents') | Out-Null
  Copy-Item -Recurse (Join-Path $ok '.claude') (Join-Path $tl '.claude')
  $okFormats = @{
    'flow' = "tools: [Read, `"Skill`"]"
    'quoted' = "tools: 'Read', 'Skill'"
    'block' = "tools:`n  - Read`n  - Skill"
  }
  foreach ($k in $okFormats.Keys) {
    [System.IO.File]::WriteAllText((Join-Path $tl 'claude-home\agents\lead.md'), "---`nname: lead`ndescription: Fixture agent lead.`n$($okFormats[$k])`n---`nBody.`n")
    Copy-Item (Join-Path $ok 'claude-home\agents\*') (Join-Path $tl 'claude-home\agents') -Exclude lead.md -Force
    $r = Invoke-Check @('-Project', $tl, '-ClaudeHome', (Join-Path $tl 'claude-home'))
    Check "lead tools in $k format with Skill passes" ($r.Exit -eq 0) $r.Out
  }
  [System.IO.File]::WriteAllText((Join-Path $tl 'claude-home\agents\lead.md'), "---`nname: lead`ndescription: Fixture agent lead.`ntools:`n  - Read`n  - Edit`n---`nBody.`n")
  $r = Invoke-Check @('-Project', $tl, '-ClaudeHome', (Join-Path $tl 'claude-home'))
  Check 'lead block-list tools without Skill fails and names the agent file' (($r.Exit -eq 1) -and ($r.Out -match 'lead\.md\): tools list lacks Skill'))

  $old = Join-Path $Work 'olduser'
  Copy-Item -Recurse $ok $old
  New-Item -ItemType Directory -Force (Join-Path $old 'claude-home\team') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $old '.claude\team\routing.md'), "| Job | Model | Effort | Fallback |`n|---|---|---|---|`n| a | sonnet | low | - |`n| b | haiku | low | - |`n| c | fable | low | - |`n")
  [System.IO.File]::WriteAllText((Join-Path $old 'claude-home\team\USER.md'), "- Models available to me: opus, sonnet`n  - haiku`n  - Never use: <none>`n- Other: x`n")
  $r = Invoke-Check @('-Project', $old, '-ClaudeHome', (Join-Path $old 'claude-home'))
  Check 'old USER.md layout is understood (haiku listed one per line; fable flagged)' (($r.Exit -eq 0) -and ($r.Out -match "row 'c'") -and ($r.Out -notmatch "row 'a'") -and ($r.Out -notmatch "row 'b'")) $r.Out
  [System.IO.File]::WriteAllText((Join-Path $old 'claude-home\team\USER.md'), "- Chat language: English`n")
  $r = Invoke-Check @('-Project', $old, '-ClaudeHome', (Join-Path $old 'claude-home'))
  Check 'USER.md without an available-models list warns instead of skipping silently' (($r.Exit -eq 0) -and ($r.Out -match "WARN: no 'Available models' list"))

  # Env overrides: warn only, from the environment or the env block of a settings file.
  Check 'check-team: no override variables, no override warning' ($r.Out -notmatch 'CLAUDE_CODE_')
  $r0 = Invoke-Check @('-Project', $ok, '-ClaudeHome', (Join-Path $ok 'claude-home'))
  Check 'check-team: clean environment warns about nothing' (($r0.Exit -eq 0) -and ($r0.Out -notmatch 'CLAUDE_CODE_')) $r0.Out
  $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = '1'; $env:CLAUDE_CODE_EFFORT_LEVEL = 'low'; $env:CLAUDE_CODE_SUBAGENT_MODEL = 'haiku'; $env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE = '1'
  $r1 = Invoke-Check @('-Project', $ok, '-ClaudeHome', (Join-Path $ok 'claude-home'))
  Check 'check-team: the four variables in the environment each warn, exit stays 0' (($r1.Exit -eq 0) -and ($r1.Out -match 'WARN: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is set') -and ($r1.Out -match 'WARN: CLAUDE_CODE_EFFORT_LEVEL is set') -and ($r1.Out -match 'WARN: CLAUDE_CODE_SUBAGENT_MODEL is set') -and ($r1.Out -match 'WARN: CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set')) $r1.Out
  $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = '0'; $env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE = '0'; $env:CLAUDE_CODE_EFFORT_LEVEL = ''; $env:CLAUDE_CODE_SUBAGENT_MODEL = ''
  $r1 = Invoke-Check @('-Project', $ok, '-ClaudeHome', (Join-Path $ok 'claude-home'))
  Check 'check-team: teams=0, force=0 and empty values do not warn' ($r1.Out -notmatch 'CLAUDE_CODE_') $r1.Out
  foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $null) }
  $envHome = Join-Path $Work 'envhome'
  $envProj = Join-Path $Work 'envproj'
  Copy-Item -Recurse -LiteralPath $ok -Destination $envProj
  New-Item -ItemType Directory -Force -Path (Join-Path $envHome 'team') | Out-Null
  Copy-Item (Join-Path $ok 'claude-home\agents') (Join-Path $envHome 'agents') -Recurse
  [System.IO.File]::WriteAllText((Join-Path $envHome 'settings.json'), '{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }')
  [System.IO.File]::WriteAllText((Join-Path $envProj '.claude\settings.local.json'), '{ "env": { "CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "0" } }')
  $r1 = Invoke-Check @('-Project', $envProj, '-ClaudeHome', $envHome)
  Check 'check-team: the env block of user and project settings is read' (($r1.Exit -eq 0) -and ($r1.Out -match 'WARN: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is set \(in .*settings\.json') -and ($r1.Out -match 'WARN: CLAUDE_CODE_EFFORT_LEVEL is set \(in .*settings\.local\.json') -and ($r1.Out -notmatch 'SUBAGENT_MODEL')) $r1.Out
  [System.IO.File]::WriteAllText((Join-Path $envHome 'settings.json'), '{ not json')
  $r1 = Invoke-Check @('-Project', $envProj, '-ClaudeHome', $envHome)
  Check 'check-team: an unreadable settings file is ignored without failing' (($r1.Exit -eq 0) -and ($r1.Out -notmatch 'AGENT_TEAMS')) $r1.Out

  # Lead compact window (check-team): session.json vs settings, overrides, idle compaction.
  $cw = Join-Path $Work 'cwproj'
  $cwHome = Join-Path $Work 'cwhome'
  Copy-Item -Recurse -LiteralPath $ok -Destination $cw
  New-Item -ItemType Directory -Force -Path (Join-Path $cwHome 'team') | Out-Null
  Copy-Item (Join-Path $ok 'claude-home\agents') (Join-Path $cwHome 'agents') -Recurse
  $sj = Join-Path $cw '.claude\team\session.json'
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: no session.json: INFO says the lead should create it, no warning' (($r1.Exit -eq 0) -and ($r1.Out -match 'INFO: no session\.json: the lead should create it') -and ($r1.Out -notmatch 'WARN')) $r1.Out
  [System.IO.File]::WriteAllText($sj, '{ "lead_compact_window": 200000, "reason": "t" }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: session.json not yet applied is reported as INFO' (($r1.Exit -eq 0) -and ($r1.Out -match 'INFO: lead compact window: session\.json says 200000') -and ($r1.Out -notmatch 'WARN')) $r1.Out
  [System.IO.File]::WriteAllText((Join-Path $cw '.claude\settings.local.json'), '{ "autoCompactWindow": 200000 }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: equal local setting: INFO names the winning file, no warning' (($r1.Exit -eq 0) -and ($r1.Out -match 'INFO: lead compact window: 200000 in effect from .*settings\.local\.json') -and ($r1.Out -notmatch 'WARN')) $r1.Out
  [System.IO.File]::WriteAllText((Join-Path $cw '.claude\settings.local.json'), '{ "autoCompactWindow": 350000 }')
  [System.IO.File]::WriteAllText((Join-Path $cw '.claude\settings.json'), '{ "autoCompactWindow": 250000 }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: differing local setting and project setting are named, local wins' (($r1.Exit -eq 0) -and ($r1.Out -match 'session\.json says 200000 but autoCompactWindow in .*settings\.local\.json is 350000') -and ($r1.Out -match 'the local file wins') -and ($r1.Out -match 'INFO: lead compact window: 350000 in effect from .*settings\.local\.json')) $r1.Out
  Remove-Item (Join-Path $cw '.claude\settings.local.json')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: project settings.json value differing from session.json warns' (($r1.Exit -eq 0) -and ($r1.Out -match 'autoCompactWindow in .*settings\.json is 250000') -and ($r1.Out -match 'INFO: lead compact window: 250000 in effect from .*settings\.json')) $r1.Out
  [System.IO.File]::WriteAllText((Join-Path $cwHome 'settings.json'), '{ "modelSettings": { "opus": { "autoCompactWindow": 300000 } }, "idleCompaction": false }')
  $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '150000'
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW
  Check 'check-team: env var, modelSettings and idleCompaction=false each warn and win' (($r1.Exit -eq 0) -and ($r1.Out -match "higher-priority setting wins") -and ($r1.Out -match 'CLAUDE_CODE_AUTO_COMPACT_WINDOW \(150000\)') -and ($r1.Out -match 'modelSettings\.opus\.autoCompactWindow \(300000\)') -and ($r1.Out -match 'idleCompaction is false')) $r1.Out
  Remove-Item Env:\AGENT_CREW_MANAGED_SETTINGS -ErrorAction SilentlyContinue
  $mg = Join-Path $Work 'managed-settings.json'
  [System.IO.File]::WriteAllText($mg, '{ "autoCompactWindow": 123000 }')
  $env:AGENT_CREW_MANAGED_SETTINGS = $mg
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', (Join-Path $Work 'no-such-home'))
  Remove-Item Env:\AGENT_CREW_MANAGED_SETTINGS
  Check 'check-team: managed settings are named as the winner' (($r1.Out -match 'higher-priority setting wins') -and ($r1.Out -match 'managed settings .*managed-settings\.json')) $r1.Out
  [System.IO.File]::WriteAllText((Join-Path $cwHome 'settings.json'), '{ "autoCompactWindow": 111000 }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: a user top-level key is not an override and does not beat the project value' (($r1.Out -notmatch 'higher-priority') -and ($r1.Out -match 'INFO: lead compact window: 250000 in effect from .*settings\.json')) $r1.Out
  [System.IO.File]::WriteAllText($sj, '{ "lead_compact_window": "big" }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', $cwHome)
  Check 'check-team: an invalid session.json warns' (($r1.Exit -eq 0) -and ($r1.Out -match 'WARN: session\.json is unusable')) $r1.Out
  [System.IO.File]::WriteAllText($sj, '{ "lead_compact_window": 900000 }')
  $r1 = Invoke-Check @('-Project', $cw, '-ClaudeHome', (Join-Path $Work 'no-such-home'))
  Check 'check-team: an out-of-range session.json value is reported as clamped' (($r1.Out -match 'outside 100000-400000; the hook uses 400000')) $r1.Out

  # ram-guard.json is validated when present: a bad project file fails, a bad user file only warns.
  $rg = Join-Path $Work 'ramcfg'
  Copy-Item -Recurse $ok $rg
  New-Item -ItemType Directory -Force (Join-Path $rg 'claude-home\team') | Out-Null
  $rgArgs = @('-Project', $rg, '-ClaudeHome', (Join-Path $rg 'claude-home'))
  $r = Invoke-Check $rgArgs
  Check 'check-team: no ram-guard.json anywhere is fine' (($r.Exit -eq 0) -and ($r.Out -notmatch 'ram-guard'))
  [System.IO.File]::WriteAllText((Join-Path $rg '.claude\team\ram-guard.json'), '{ "kinds": { "my-engine": { "patterns": ["my-engine"], "min_free_mb": 4000 } } }')
  $r = Invoke-Check $rgArgs
  Check 'check-team: a valid project ram-guard.json passes' (($r.Exit -eq 0) -and ($r.Out -notmatch 'ram-guard')) $r.Out
  [System.IO.File]::WriteAllText((Join-Path $rg '.claude\team\ram-guard.json'), '{ not json')
  $r = Invoke-Check $rgArgs
  Check 'check-team: a malformed project ram-guard.json fails' (($r.Exit -eq 1) -and ($r.Out -match 'FAIL: ram-guard: project config is not valid JSON')) $r.Out
  [System.IO.File]::WriteAllText((Join-Path $rg '.claude\team\ram-guard.json'), '{ "kinds": { "x": { "patterns": ["a"], "min_free_mb": "lots" } } }')
  $r = Invoke-Check $rgArgs
  Check 'check-team: a bad min_free_mb in the project file fails and the incomplete kind is named' (($r.Exit -eq 1) -and ($r.Out -match "min_free_mb' must be a number") -and ($r.Out -match "WARN: ram-guard: kind 'x' is skipped by the hook: it needs min_free_mb")) $r.Out
  Remove-Item (Join-Path $rg '.claude\team\ram-guard.json')
  [System.IO.File]::WriteAllText((Join-Path $rg 'claude-home\team\ram-guard.json'), '{ "kinds": { "agent-spawn": { "min_free_mb": -5 } }, "enabled": "yes" }')
  $r = Invoke-Check $rgArgs
  Check 'check-team: a bad user ram-guard.json only warns' (($r.Exit -eq 0) -and ($r.Out -match "WARN: ram-guard: kind 'agent-spawn': 'min_free_mb'") -and ($r.Out -match "WARN: ram-guard: 'enabled'")) $r.Out

  # Autonomous team: roster trial status and team_autonomy (warnings only, INFO when auto).
  $au = Join-Path $Work 'autonomy'
  Copy-Item -Recurse -LiteralPath $ok -Destination $au
  New-Item -ItemType Directory -Force -Path (Join-Path $au 'claude-home\team') | Out-Null
  $auArgs = @('-Project', $au, '-ClaudeHome', (Join-Path $au 'claude-home'))
  $auUser = Join-Path $au 'claude-home\team\USER.md'
  $auProj = Join-Path $au '.claude\team\PROJECT.md'
  $auRoster = Join-Path $au '.claude\team\roster.md'
  $auRosterOrig = [System.IO.File]::ReadAllText($auRoster)
  $auProjOrig = [System.IO.File]::ReadAllText($auProj)
  $r = Invoke-Check $auArgs
  Check 'check-team: no team_autonomy anywhere: no autonomy output, no trial warning' (($r.Exit -eq 0) -and ($r.Out -notmatch 'team_autonomy|trial'))  $r.Out
  [System.IO.File]::WriteAllText($auRoster, ($auRosterOrig -replace '\| scout \| cheap fact search \| core \| kept', '| scout | cheap fact search | core | trial'))
  $r = Invoke-Check $auArgs
  Check 'check-team: one trial agent is fine' (($r.Exit -eq 0) -and ($r.Out -notmatch 'trial')) $r.Out
  [System.IO.File]::WriteAllText($auRoster, ($auRosterOrig -replace '\| (scout|reviewer) \| ([a-z ]+) \| core \| kept', '| $1 | $2 | core | trial'))
  $r = Invoke-Check $auArgs
  Check 'check-team: two trial agents warn, exit stays 0' (($r.Exit -eq 0) -and ($r.Out -match "WARN: 2 agents are 'trial' in roster\.md \(reviewer, scout\)")) $r.Out
  [System.IO.File]::WriteAllText($auRoster, ($auRosterOrig -replace '\| scout \| cheap fact search \| core \| kept', '| scout | cheap fact search | core | probation'))
  $r = Invoke-Check $auArgs
  Check 'check-team: an unknown roster status warns, exit stays 0' (($r.Exit -eq 0) -and ($r.Out -match "WARN: roster\.md Status must be 'trial' or 'kept': scout \(probation\)")) $r.Out
  [System.IO.File]::WriteAllText($auRoster, $auRosterOrig)
  [System.IO.File]::WriteAllText($auUser, "---`nteam_autonomy: auto`n---`n- Available models: opus, sonnet, haiku`n")
  $r = Invoke-Check $auArgs
  Check 'check-team: team_autonomy auto in USER.md is accepted and reported as INFO' (($r.Exit -eq 0) -and ($r.Out -match 'INFO: team_autonomy: auto \(from USER\.md\)') -and ($r.Out -notmatch 'WARN')) $r.Out
  [System.IO.File]::WriteAllText($auProj, ($auProjOrig -replace '(?m)^report_only_agents:.*$', "`$0`nteam_autonomy: ask"))
  $r = Invoke-Check $auArgs
  Check 'check-team: PROJECT.md team_autonomy ask wins over USER.md auto' (($r.Exit -eq 0) -and ($r.Out -notmatch 'team_autonomy') -and ($r.Out -notmatch 'WARN')) $r.Out
  [System.IO.File]::WriteAllText($auUser, "---`nteam_autonomy: ask`n---`n- Available models: opus, sonnet, haiku`n")
  [System.IO.File]::WriteAllText($auProj, ($auProjOrig -replace '(?m)^report_only_agents:.*$', "`$0`nteam_autonomy: auto"))
  $r = Invoke-Check $auArgs
  Check 'check-team: PROJECT.md team_autonomy auto wins over USER.md ask' (($r.Exit -eq 0) -and ($r.Out -match 'INFO: team_autonomy: auto \(from PROJECT\.md\)')) $r.Out
  [System.IO.File]::WriteAllText($auProj, ($auProjOrig -replace '(?m)^report_only_agents:.*$', "`$0`nteam_autonomy: sometimes"))
  $r = Invoke-Check $auArgs
  Check 'check-team: an unknown team_autonomy value warns and counts as ask' (($r.Exit -eq 0) -and ($r.Out -match "WARN: PROJECT\.md team_autonomy 'sometimes' is not 'ask' or 'auto'") -and ($r.Out -notmatch 'INFO: team_autonomy')) $r.Out
  # The shipped templates carry the key (USER.md) and the documented override (PROJECT.md).
  Check 'templates: USER.md has team_autonomy ask, PROJECT.md documents the override' (((Get-Content -Raw (Join-Path $Root 'templates\USER.md')) -match '(?m)^team_autonomy: ask$') -and ((Get-Content -Raw (Join-Path $Root 'templates\PROJECT.md')) -match '(?m)^# team_autonomy: auto$'))

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

  # USER.md lead_writable: personal files outside the project, hermetic fake home (never the real ~/.claude).
  # Outside $Work: that lives inside this git repository, where the lead is never allowed.
  $guardTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('crew-guard-' + [guid]::NewGuid().ToString('N'))
  $fakeHome = Join-Path $guardTmp 'fakehome'
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude\team'), (Join-Path $fakeHome '.claude\notes'), (Join-Path $fakeHome '.claude\agents'), (Join-Path $guardTmp 'gitrepo\.git'), (Join-Path $guardTmp 'plain') | Out-Null
  $gitLn = (ConvertTo-Slash (Join-Path $guardTmp 'gitrepo'))
  $plainLn = (ConvertTo-Slash (Join-Path $guardTmp 'plain'))
  Set-Content -LiteralPath (Join-Path $fakeHome '.claude\team\USER.md') -Value "---`nlead_writable:`n  - '~/.claude/notes/**'`n  - '~/.claude/agents/**'`n  - '~/.claude/settings*.json'`n  - '$gitLn/**'`n  - '$plainLn/**'`n---`n"
  $saved = @{ H = $env:HOME; U = $env:USERPROFILE; C = $env:CLAUDE_CONFIG_DIR }
  $env:HOME = $fakeHome; $env:USERPROFILE = $fakeHome; $env:CLAUDE_CONFIG_DIR = $null
  $fh = ConvertTo-Slash $fakeHome
  try {
    Check 'guard: lead may write a ~-relative USER.md lead_writable file' ((Guard 'lead' "$fh/.claude/notes/me.md").Exit -eq 0)
    Check 'guard: ... also with other case and backslashes' ((Guard 'lead' ($fakeHome.ToUpper() + '\.CLAUDE\Notes\x.md')).Exit -eq 0)
    Check 'guard: ... an absolute listed folder works' ((Guard 'lead' "$plainLn/a.txt").Exit -eq 0)
    Check 'guard: ... unlisted files outside stay blocked' ((Guard 'lead' "$fh/.claude/other.md").Exit -eq 2)
    Check 'guard: USER.md list never allows agent files or settings' (((Guard 'lead' "$fh/.claude/agents/x.md").Exit -eq 2) -and ((Guard 'lead' "$fh/.claude/settings.json").Exit -eq 2))
    Check 'guard: USER.md list never allows a git repository' ((Guard 'lead' "$gitLn/a.txt").Exit -eq 2)
    Check 'guard: USER.md list does not widen a report-only agent' ((Guard 'thinker' "$fh/.claude/notes/me.md").Exit -eq 2)
    Check 'guard: USER.md list does not apply inside the project' ((Guard 'lead' "$pj/src/a.txt").Exit -eq 2)

    # --- review fixes: each attack on the user list ---
    $userMd = Join-Path $fakeHome '.claude\team\USER.md'
    function SetUserList([string[]]$items) {
      $body = "---`nlead_writable:`n" + (($items | ForEach-Object { "  - '$_'" }) -join "`n") + "`n---`n"
      [System.IO.File]::WriteAllText($userMd, $body)
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude\team\reports'), (Join-Path $fakeHome '.claude\skills'), (Join-Path $fakeHome 'Documents\WindowsPowerShell'), (Join-Path $guardTmp 'plain\Startup'), (Join-Path $guardTmp 'plain\longrepositoryname\.git'), (Join-Path $guardTmp 'bare\objects'), (Join-Path $guardTmp 'bare\refs') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fakeHome '.claude\team\ram-guard.json'), '{}')
    [System.IO.File]::WriteAllText((Join-Path $fakeHome '.claude\CLAUDE.md'), 'x')
    [System.IO.File]::WriteAllText((Join-Path $guardTmp 'bare\HEAD'), 'ref: refs/heads/main')
    $bareLn = ConvertTo-Slash (Join-Path $guardTmp 'bare')

    # A: the user team folder is reports/** only, even with a list that covers it
    SetUserList @('~/.claude/notes/**', "$fh/.claude/team/**")
    Check 'guard A: lead cannot write USER.md' ((Guard 'lead' "$fh/.claude/team/USER.md").Exit -eq 2)
    Check 'guard A: lead cannot write the user ram-guard.json' ((Guard 'lead' "$fh/.claude/team/ram-guard.json").Exit -eq 2)
    Check 'guard A: lead cannot write other user team files' ((Guard 'lead' "$fh/.claude/team/state.md").Exit -eq 2)
    Check 'guard A: lead may write ~/.claude/team/reports/**' ((Guard 'lead' "$fh/.claude/team/reports/r.md").Exit -eq 0)

    # B: inside ~/.claude only notes/** can be granted
    SetUserList @('~/.claude/notes/**', '~/.claude/**', "$fh/**")
    Check 'guard B: notes still work' ((Guard 'lead' "$fh/.claude/notes/me.md").Exit -eq 0)
    $bad = @('.claude/CLAUDE.md', '.claude/skills/s.md', '.claude/commands/c.md', '.claude/plugins/p.json', '.claude/agents/a.md', '.claude/hooks/h.ps1', '.claude/agent-crew/hooks/x.ps1', '.claude/keybindings.json', '.claude/settings.json', '.claude/settings.local.json', '.claude.json')
    $allDenied = $true
    foreach ($b in $bad) { if ((Guard 'lead' "$fh/$b").Exit -ne 2) { $allDenied = $false; Write-Host "    not denied: $b" } }
    Check 'guard B: CLAUDE.md, skills, commands, plugins, agents, hooks, agent-crew, keybindings, settings*, .claude.json are denied' $allDenied

    # C: refused globs and code-execution spots
    SetUserList @('relative/**', '/**', 'C:/**', '~/**', '~', "$plainLn/**")
    Check 'guard C: relative, root, drive-root and home globs grant nothing' (((Guard 'lead' "$fh/x.txt").Exit -eq 2) -and ((Guard 'lead' "$fh/Documents/d.txt").Exit -eq 2) -and ((Guard 'lead' "C:/Windows/Temp/x.txt").Exit -eq 2))
    Check 'guard C: a valid glob still works' ((Guard 'lead' "$plainLn/a.txt").Exit -eq 0)
    SetUserList @("$plainLn/**", '~/.bashrc', '~/.ssh/**', "$fh/**", '~/Documents/**')
    $spots = @("$plainLn/.bashrc", "$plainLn/.zshrc", "$plainLn/.profile", "$plainLn/.gitconfig", "$plainLn/.ssh/authorized_keys", "$plainLn/Startup/x.cmd", "$plainLn/Microsoft.PowerShell_profile.ps1", "$plainLn/WindowsPowerShell/profile.ps1", "$fh/Documents/WindowsPowerShell/profile.ps1", "$fh/.bashrc", "$fh/.ssh/id_rsa")
    $allDenied = $true
    foreach ($b in $spots) { if ((Guard 'lead' $b).Exit -ne 2) { $allDenied = $false; Write-Host "    not denied: $b" } }
    Check 'guard C: shell profiles, .ssh, Startup, .gitconfig, PowerShell profile folders are denied under a valid glob' $allDenied
    # credential spots are denied even under a valid glob
    SetUserList @("$plainLn/**", "$fh/**")
    $creds = @("$plainLn/.npmrc", "$plainLn/.aws/credentials", "$plainLn/.config/gh/hosts.yml", "$plainLn/.docker/config.json", "$plainLn/.netrc", "$plainLn/.git-credentials", "$fh/.npmrc", "$fh/.aws/config")
    $allDenied = $true
    foreach ($b in $creds) { if ((Guard 'lead' $b).Exit -ne 2) { $allDenied = $false; Write-Host "    not denied: $b" } }
    Check 'guard C: credential spots (.npmrc, .aws, .config/gh, .docker/config.json, .netrc, .git-credentials) are denied under a valid glob' $allDenied
    $r = Guard 'lead' "$plainLn/.npmrc"
    Check 'guard C: ... and an ordinary file next to them still works' ((Guard 'lead' "$plainLn/notes.txt").Exit -eq 0)
    $r = Guard 'lead' "$pj/src/a.txt"
    Check 'guard: the deny message lists what the lead may write' (($r.Err -match 'lead_writable') -and ($r.Err -match 'reports') -and ($r.Err -match 'USER\.md and ram-guard\.json are never writable')) $r.Err


    # D: 8.3 short names
    SetUserList @("$plainLn/**", "$guardTmp/**".Replace('\', '/'))
    $shortFile = (& cmd /c "for %I in (`"$fakeHome\.claude\CLAUDE.md`") do @echo %~sI").Trim()
    if ($shortFile -match '~') {
      Check 'guard D: a short-name alias of a denied ~/.claude file is denied' ((Guard 'lead' (ConvertTo-Slash $shortFile)).Exit -eq 2)
      $shortRepo = (& cmd /c "for %I in (`"$guardTmp\plain\longrepositoryname`") do @echo %~sI").Trim()
      Check 'guard D: a short-name alias of a git repository is denied (also for a new file)' ((Guard 'lead' ((ConvertTo-Slash $shortRepo) + '/new.txt')).Exit -eq 2)
    } else {
      Write-Host '  skip guard D: this volume makes no 8.3 short names'
    }

    # G: the project branch fails closed for the lead too (PROJECT.md locked so reading it throws), not for others
    $lockProj = Join-Path $guardTmp 'lockproj'
    Copy-Item -Recurse -LiteralPath $ok -Destination $lockProj
    $lp = ConvertTo-Slash $lockProj
    $lockFile = [System.IO.File]::Open((Join-Path $lockProj '.claude\team\PROJECT.md'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $r = Guard 'lead' "$lp/.claude/team/state.md" $lockProj
      $rc = Guard 'coder' "$lp/src/a.txt" $lockProj
      Check 'guard G: an error while checking a lead write in the project denies with a reason' (($r.Exit -eq 2) -and ($r.Err -match 'check failed') -and ($r.Err -match 'may write')) ($r.Exit.ToString() + ' ' + $r.Err)
      Check 'guard G: ... but a non-lead agent still fails open' ($rc.Exit -eq 0)
    } finally { $lockFile.Close() }

    # F: bare repositories
    SetUserList @("$plainLn/**", "$bareLn/**")
    Check 'guard F: a bare repository (HEAD + objects + refs) is denied' ((Guard 'lead' "$bareLn/config").Exit -eq 2)
    Check 'guard F: a .git work-tree repository is denied' ((Guard 'lead' "$plainLn/longrepositoryname/a.txt").Exit -eq 2)

    # E: fail closed when the list cannot be read
    SetUserList @('~/.claude/notes/**')
    Check 'guard E: before the lock the note is allowed' ((Guard 'lead' "$fh/.claude/notes/me.md").Exit -eq 0)
    $lock = [System.IO.File]::Open($userMd, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $r = Guard 'lead' "$fh/.claude/notes/me.md"
      Check 'guard E: an unreadable USER.md denies (fail closed) with a reason' (($r.Exit -eq 2) -and ($r.Err -match 'failed'))
    } finally { $lock.Close() }

    # check-team warns about every refused entry
    $uh2 = Join-Path $guardTmp 'userbad'
    New-Item -ItemType Directory -Force -Path (Join-Path $uh2 'team') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $uh2 'team\USER.md'), "---`nlead_writable:`n  - 'relative/x'`n  - '/**'`n  - 'C:/**'`n  - '~/**'`n  - '~/.claude/**'`n  - '~/.ssh/**'`n  - '~/.claude/notes/**'`n---`n")
    $r = Invoke-Check @('-Project', $ok, '-ClaudeHome', $uh2)
    $warned = @('relative/x', '/**', 'C:/**', '~/**', '~/.claude/**', '~/.ssh/**') | Where-Object { $r.Out -notmatch ("WARN: USER.md lead_writable '" + [regex]::Escape($_) + "' is ignored") }
    Check 'check-team: warns about relative, root, drive, home, ~/.claude/** and .ssh entries but not notes/**' ((@($warned).Count -eq 0) -and ($r.Out -notmatch "lead_writable '~/.claude/notes/\*\*'")) $r.Out
  } finally {
    $env:HOME = $saved.H; $env:USERPROFILE = $saved.U; $env:CLAUDE_CONFIG_DIR = $saved.C
  }
  $uh = Join-Path $guardTmp 'uservalid'
  New-Item -ItemType Directory -Force -Path (Join-Path $uh 'team') | Out-Null
  $uu = ''
  Set-Content -LiteralPath (Join-Path $uh 'team\USER.md') -Value ("---`nlead_writable:`n  - '~/.claude/notes/**'`n  - '~/.claude/settings.json'`n  - '$gitLn/**'`n  - 'relative/x'`n---`n" + $uu)
  $r = Invoke-Check @('-Project', $ok, '-ClaudeHome', $uh)
  Check 'check-team: warns about forbidden USER.md lead_writable entries' (($r.Out -match "WARN: USER.md lead_writable '~/.claude/settings.json'") -and ($r.Out -match "WARN: USER.md lead_writable '.*gitrepo/\*\*' is inside a git") -and ($r.Out -match "WARN: USER.md lead_writable 'relative/x'") -and ($r.Out -notmatch "WARN: USER.md lead_writable '~/.claude/notes")) $r.Out
  Remove-Item -Recurse -Force -LiteralPath $guardTmp -ErrorAction SilentlyContinue

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
  (Get-Content -Raw $proj2) -replace 'agent_crew_version: \S+', 'agent_crew_version: 0.0.1' | Set-Content -LiteralPath $proj2 -NoNewline
  $r = Start-Hook 'startup'
  Check 'session-start: version mismatch is reported' ($r.Out -match '0\.0\.1' -and $r.Out -match [regex]::Escape((Get-Content -Raw (Join-Path $Root 'VERSION')).Trim()))
  $r = Start-Hook 'startup' (ConvertTo-Slash $Work)
  Check 'session-start without .claude/team is silent' ($r.Out.Trim() -eq '')

  # session-start applies .claude/team/session.json to the project settings.local.json (user dirs are faked).
  $cwp = Join-Path $Work 'cwhook'
  $cwFake = Join-Path $Work 'cwhookhome'
  Copy-Item -Recurse -LiteralPath $ok -Destination $cwp
  New-Item -ItemType Directory -Force -Path (Join-Path $cwFake '.claude') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $cwp '.claude\team\.last-retro'), (Get-Date).ToString('o'))
  $cwSj = Join-Path $cwp '.claude\team\session.json'
  $cwSet = Join-Path $cwp '.claude\settings.local.json'
  $cwSaved = @{ H = $env:HOME; U = $env:USERPROFILE; C = $env:CLAUDE_CONFIG_DIR }
  $env:HOME = $cwFake; $env:USERPROFILE = $cwFake; $env:CLAUDE_CONFIG_DIR = $null
  try {
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: no session.json, nothing printed and no settings file' (($r.Out.Trim() -eq '') -and -not (Test-Path -LiteralPath $cwSet)) $r.Out
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 220000, "reason": "long design talks" }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $v = (Get-Content -Raw -LiteralPath $cwSet | ConvertFrom-Json)
    Check 'compact window: creates settings.local.json with only the key and says so' (($v.autoCompactWindow -eq 220000) -and (@($v.PSObject.Properties).Count -eq 1) -and ($r.Out -match 'set to 220000') -and ($r.Out -match 'long design talks') -and ($r.Out -match 'next session')) $r.Out
    $stamp = (Get-Item -LiteralPath $cwSet).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    $r = Start-Hook 'resume' (ConvertTo-Slash $cwp)
    Check 'compact window: unchanged value prints nothing and does not rewrite the file' (($r.Out.Trim() -eq '') -and ((Get-Item -LiteralPath $cwSet).LastWriteTimeUtc -eq $stamp)) $r.Out
    [System.IO.File]::WriteAllText($cwSet, '{ "agent": "lead", "idleCompaction": true, "permissions": { "allow": ["Bash(ls)"] }, "autoCompactWindow": 350000 }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $v = (Get-Content -Raw -LiteralPath $cwSet | ConvertFrom-Json)
    Check 'compact window: changes only its key and keeps every other one' (($v.autoCompactWindow -eq 220000) -and ($v.agent -eq 'lead') -and ($v.idleCompaction -eq $true) -and ($v.permissions.allow[0] -eq 'Bash(ls)') -and ($r.Out -match 'set to 220000')) $r.Out
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 50000 }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $v = (Get-Content -Raw -LiteralPath $cwSet | ConvertFrom-Json)
    Check 'compact window: clamps to the minimum and says so' (($v.autoCompactWindow -eq 100000) -and ($r.Out -match 'clamped')) $r.Out
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 220000 }')
    [System.IO.File]::WriteAllText($cwSet, '{ not json')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: an unreadable settings.local.json is left untouched with a warning' (($r.Out -match 'not plain valid JSON') -and ((Get-Content -Raw -LiteralPath $cwSet).Trim() -eq '{ not json')) $r.Out
    [System.IO.File]::WriteAllText($cwSet, '{ "agent": "lead" }')
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": "big" }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: invalid session.json leaves settings untouched and warns' (($r.Out -match 'session\.json is unusable') -and ((Get-Content -Raw -LiteralPath $cwSet).Trim() -eq '{ "agent": "lead" }')) $r.Out
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 220000 }')
    [System.IO.File]::WriteAllText((Join-Path $cwFake '.claude\settings.json'), '{ "modelSettings": { "opus": { "autoCompactWindow": 300000 } } }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: a user modelSettings value wins, settings untouched, warned' (($r.Out -match 'That value wins') -and ($r.Out -match 'modelSettings\.opus') -and ((Get-Content -Raw -LiteralPath $cwSet).Trim() -eq '{ "agent": "lead" }')) $r.Out
    Remove-Item -LiteralPath (Join-Path $cwFake '.claude\settings.json')
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '120000'
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW
    Check 'compact window: the environment variable wins, settings untouched, warned' (($r.Out -match 'That value wins') -and ($r.Out -match 'CLAUDE_CODE_AUTO_COMPACT_WINDOW') -and ((Get-Content -Raw -LiteralPath $cwSet).Trim() -eq '{ "agent": "lead" }')) $r.Out
    # --- formatting is preserved, byte for byte except the value ---
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $odd = "{`n  `"agent`": `"lead`",`n  `"note`": `"a < b > c & d 'e' é 2026-10-18T10:00:00Z /* not a comment */`",`n  `"when`": `"2026-10-18`",`n  `"autoCompactWindow`": 350000`n}`n"
    [System.IO.File]::WriteAllText($cwSet, $odd, $utf8)
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $after = [System.IO.File]::ReadAllText($cwSet, $utf8)
    Check 'compact window: replacing a value leaves every other byte alone (< > & quote, escapes, dates)' (($after -ceq $odd.Replace('350000', '220000')) -and ($r.Out -match 'set to 220000')) $after
    $odd2 = "{ `"permissions`": { `"allow`": [`"Bash(ls)`"] }, `"note`": `"x < y & 'z'`", `"nested`": { `"autoCompactWindow`": 1 } }"
    [System.IO.File]::WriteAllText($cwSet, $odd2, $utf8)
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $after = [System.IO.File]::ReadAllText($cwSet, $utf8)
    Check 'compact window: a missing key is inserted after the brace, a nested key of the same name is ignored' (($after -ceq $odd2.Replace('{ "permissions"', '{ "autoCompactWindow": 220000, "permissions"')) -and (($after | ConvertFrom-Json).nested.autoCompactWindow -eq 1)) $after
    $com = "{`n  // keep me`n  `"agent`": `"lead`" /* x */`n}`n"
    [System.IO.File]::WriteAllText($cwSet, $com, $utf8)
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: a settings file with comments is untouched, with a warning' (([System.IO.File]::ReadAllText($cwSet, $utf8) -ceq $com) -and ($r.Out -match 'not plain valid JSON')) $r.Out
    Check 'compact window: no .tmp or .bak files are left behind' (@(Get-ChildItem -LiteralPath (Join-Path $cwp '.claude') | Where-Object { $_.Name -match '.(tmp|bak)$' }).Count -eq 0)
    # --- two processes writing at once ---
    [System.IO.File]::WriteAllText($cwSet, "{`n  `"agent`": `"lead`"`n}`n", $utf8)
    $procs = @()
    foreach ($n in 1..2) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $PsExe
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $hooks 'session-start.ps1') + '"'
      $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $p.StandardInput.Write('{"cwd":"' + (ConvertTo-Slash $cwp) + '","source":"startup"}'); $p.StandardInput.Close()
      $procs += $p
    }
    foreach ($p in $procs) { $null = $p.StandardOutput.ReadToEnd(); $p.WaitForExit() }
    $v = $null; try { $v = ([System.IO.File]::ReadAllText($cwSet, $utf8) | ConvertFrom-Json) } catch { }
    Check 'compact window: two session starts at once leave valid JSON with the value and no temp files' (($v -and ($v.autoCompactWindow -eq 220000) -and ($v.agent -eq 'lead')) -and (@(Get-ChildItem -LiteralPath (Join-Path $cwp '.claude') | Where-Object { $_.Name -match '.(tmp|bak)$' }).Count -eq 0)) ([System.IO.File]::ReadAllText($cwSet, $utf8))
    # --- overrides in env blocks and managed settings ---
    $same = [System.IO.File]::ReadAllText($cwSet, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $cwFake '.claude\settings.json'), '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "130000" } }')
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 180000 }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: CLAUDE_CODE_AUTO_COMPACT_WINDOW in an env block wins and is named' (($r.Out -match 'That value wins') -and ($r.Out -match 'env block of') -and ([System.IO.File]::ReadAllText($cwSet, $utf8) -ceq $same)) $r.Out
    [System.IO.File]::WriteAllText((Join-Path $cwFake '.claude\settings.json'), '{ "autoCompactWindow": 111000 }')
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Check 'compact window: a user top-level key does not win over the project local value' (($r.Out -match 'set to 180000') -and ((Get-Content -Raw -LiteralPath $cwSet | ConvertFrom-Json).autoCompactWindow -eq 180000)) $r.Out
    Remove-Item -LiteralPath (Join-Path $cwFake '.claude\settings.json')
    $mgd = Join-Path $Work 'managed-hook.json'
    [System.IO.File]::WriteAllText($mgd, '{ "autoCompactWindow": 123000 }')
    $env:AGENT_CREW_MANAGED_SETTINGS = $mgd
    [System.IO.File]::WriteAllText($cwSj, '{ "lead_compact_window": 190000 }')
    $same = [System.IO.File]::ReadAllText($cwSet, $utf8)
    $r = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    Remove-Item Env:\AGENT_CREW_MANAGED_SETTINGS
    Check 'compact window: managed settings win and are named' (($r.Out -match 'That value wins') -and ($r.Out -match 'managed settings') -and ([System.IO.File]::ReadAllText($cwSet, $utf8) -ceq $same)) $r.Out
    # --- .gitignore ---
    Check 'compact window: no .gitignore is created outside a git work tree' (-not (Test-Path -LiteralPath (Join-Path $cwp '.gitignore')))
    New-Item -ItemType Directory -Force -Path (Join-Path $cwp '.git') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cwp '.gitignore'), "node_modules/")
    $null = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $null = Start-Hook 'startup' (ConvertTo-Slash $cwp)
    $gi = [System.IO.File]::ReadAllText((Join-Path $cwp '.gitignore'))
    Check 'compact window: session.json is added to .gitignore once' (($gi -ceq "node_modules/`n.claude/team/session.json`n")) $gi
    $r = Start-Hook 'compact' (ConvertTo-Slash $cwp)
    Check 'compact window: not applied on the compact source' (-not ($r.Out -match 'compact window')) $r.Out
  } finally {
    $env:HOME = $cwSaved.H; $env:USERPROFILE = $cwSaved.U; $env:CLAUDE_CONFIG_DIR = $cwSaved.C
  }

  # no-session-links: hermetic (user folder faked, message files in the work folder)
  $nslHook = Join-Path $hooks 'no-session-links.ps1'
  $nslUser = Join-Path $Work 'nsl-user'
  New-Item -ItemType Directory -Path "$nslUser\team" -Force | Out-Null
  $nslDir = Join-Path $Work 'nsl-files'
  New-Item -ItemType Directory -Path $nslDir -Force | Out-Null
  $trailer = 'Claude-' + 'Session: https://claude.ai/code/' + 'session_abc'
  [System.IO.File]::WriteAllText("$nslDir\bad.txt", "Fix`n`n$trailer`n")
  [System.IO.File]::WriteAllText("$nslDir\good.txt", "Fix`n`nCo-Authored-By: someone`n")
  function Nsl([string]$Command, [string]$Tool = 'Bash') {
    $env:AGENT_CREW_USER_DIR = $nslUser
    $json = @{ cwd = (ConvertTo-Slash $nslDir); hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress
    $r = Invoke-Script $nslHook @() $json
    Remove-Item Env:\AGENT_CREW_USER_DIR -ErrorAction SilentlyContinue
    return $r
  }
  $r = Nsl "git commit -m 'Fix`n`n$trailer'"
  Check 'no-session-links: a trailer in -m is denied with a message' (($r.Exit -eq 2) -and ($r.Err -match 'session link') -and ($r.Err -match 'allow_session_links')) $r.Err
  Check 'no-session-links: a session URL in a PR body is denied (PowerShell too)' ((Nsl 'gh pr create --body "see https://claude.ai/code/session_x"' 'PowerShell').Exit -eq 2)
  Check 'no-session-links: a clean commit is allowed' ((Nsl "git commit -m 'Fix thing'").Exit -eq 0)
  Check 'no-session-links: the claude.com/claude-code footer is allowed' ((Nsl 'gh pr create --body "Generated with [Claude Code](https://claude.com/claude-code)"').Exit -eq 0)
  $r = Nsl 'git commit -F bad.txt'
  Check 'no-session-links: a trailer in a -F file (relative to cwd) is denied' (($r.Exit -eq 2) -and ($r.Err -match 'bad\.txt')) $r.Err
  Check 'no-session-links: other forms are denied: git -C, cd && git, git -c, gh -R, tag, notes, commit-tree' (((Nsl "git -C ../x commit -m '$trailer'").Exit -eq 2) -and ((Nsl "cd x && git commit -m '$trailer'").Exit -eq 2) -and ((Nsl "git -c user.name=a commit -m '$trailer'").Exit -eq 2) -and ((Nsl "gh -R o/r pr create --body '$trailer'").Exit -eq 2) -and ((Nsl "ls; gh issue comment 4 -b '$trailer'").Exit -eq 2) -and ((Nsl "git tag -a v1 -m '$trailer'").Exit -eq 2) -and ((Nsl "git notes add -m '$trailer'").Exit -eq 2) -and ((Nsl "git commit-tree HEAD^{tree} -m '$trailer'").Exit -eq 2))
  Check 'no-session-links: a non-message command that merely contains the text is ignored' (((Nsl "echo '$trailer'").Exit -eq 0) -and ((Nsl "git log --grep='$trailer'").Exit -eq 0))
  Check 'no-session-links: --body-file and --file with a bad file are denied' (((Nsl 'gh pr edit 3 --body-file bad.txt').Exit -eq 2) -and ((Nsl 'git commit --file=bad.txt').Exit -eq 2))
  Check 'no-session-links: a clean file, a missing file and stdin (-F -) are allowed' (((Nsl 'git commit -F good.txt').Exit -eq 0) -and ((Nsl 'git commit -F nope.txt').Exit -eq 0) -and ((Nsl 'git commit -F -').Exit -eq 0))
  Check 'no-session-links: invalid or empty stdin fails open' (((Invoke-Script $nslHook @() 'not json').Exit -eq 0) -and ((Invoke-Script $nslHook @() '').Exit -eq 0))
  [System.IO.File]::WriteAllText("$nslUser\team\USER.md", "---`nallow_session_links: true`n---`nbody`n")
  Check 'no-session-links: allow_session_links: true in USER.md allows it' ((Nsl 'git commit -F bad.txt').Exit -eq 0)
  [System.IO.File]::WriteAllText("$nslUser\team\USER.md", "---`nallow_session_links: false`n---`n")
  Check 'no-session-links: allow_session_links: false still denies' ((Nsl 'git commit -F bad.txt').Exit -eq 2)

  # ram-guard: free memory is faked with AGENT_CREW_FREE_MB, the user's Claude folder with AGENT_CREW_USER_DIR
  # and the temp folder (warn-once markers) is redirected, so nothing here reads the real ~/.claude.
  $ramUser = Join-Path $Work 'ram-user'
  $ramTemp = Join-Path $Work 'ram-temp'
  New-Item -ItemType Directory -Force -Path (Join-Path $ramUser 'team'), $ramTemp | Out-Null
  $ramUserFile = Join-Path $ramUser 'team\ram-guard.json'
  $ramProjFile = Join-Path $proj '.claude\team\ram-guard.json'
  $ramHook = Join-Path $hooks 'ram-guard.ps1'
  $savedEnv = @{}
  foreach ($n in 'AGENT_CREW_FREE_MB', 'AGENT_CREW_USER_DIR', 'TEMP', 'TMP') { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
  function Ram($tool, $command, $free, $cwd = $Work) {
    [Environment]::SetEnvironmentVariable('AGENT_CREW_FREE_MB', $free)
    [Environment]::SetEnvironmentVariable('AGENT_CREW_USER_DIR', $ramUser)
    [Environment]::SetEnvironmentVariable('TEMP', $ramTemp)
    [Environment]::SetEnvironmentVariable('TMP', $ramTemp)
    $json = @{ cwd = (ConvertTo-Slash $cwd); hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = @{ command = $command; prompt = 'do it' } } | ConvertTo-Json -Compress
    return Invoke-Script $ramHook @() $json
  }
  function Clear-RamState {
    Remove-Item -LiteralPath $ramUserFile, $ramProjFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $ramTemp -Force | Remove-Item -Force
  }
  try {
    $r = Ram 'Agent' '' '100'
    Check 'ram-guard: Agent spawn with 100 MB free is blocked (exit 2)' ($r.Exit -eq 2) "$($r.Exit) $($r.Err)"
    Check '... message names free MB, needed MB and the kind' ($r.Err -match "free RAM 100 MB < needed 1500 MB for 'agent-spawn'") $r.Err
    Check '... message says wait, no retry loop, tell the user' (($r.Err -match 'wait') -and ($r.Err -match 'not retry in a loop') -and ($r.Err -match 'tell the user')) $r.Err
    Check '... and says it never kills anything' ($r.Err -match 'never kills') $r.Err
    Check 'ram-guard: a Task spawn is guarded too' ((Ram 'Task' '' '100').Exit -eq 2)
    $r = Ram 'Agent' '' '5000'
    Check 'ram-guard: Agent spawn with 5000 MB free is allowed and silent' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq '') -and ($r.Err.Trim() -eq '')) "$($r.Out) $($r.Err)"
    Check 'ram-guard: free memory exactly at the threshold is allowed' ((Ram 'Agent' '' '1500').Exit -eq 0)
    Check 'ram-guard: free memory just below the threshold is blocked' ((Ram 'Agent' '' '1499.9').Exit -eq 2)
    Check 'ram-guard: an ordinary command is never blocked, even with 1 MB free' ((Ram 'Bash' 'ls -la' '1').Exit -eq 0)
    Check 'ram-guard: other tools are never blocked' ((Ram 'Read' '' '1').Exit -eq 0)
    $r = Ram 'Bash' 'claude -p "summarise this"' '2000'
    Check 'ram-guard: headless claude (Bash) needs 2500 MB and is blocked at 2000' (($r.Exit -eq 2) -and ($r.Err -match "needed 2500 MB for 'claude-headless'")) $r.Err
    Check '... and is allowed at 3000' ((Ram 'Bash' 'claude -p "summarise this"' '3000').Exit -eq 0)
    Check 'ram-guard: headless claude through PowerShell and with --print is blocked' ((Ram 'PowerShell' 'cd x; claude.exe --model sonnet --print hi' '2000').Exit -eq 2)
    foreach ($cmd in 'claude -p "x"', 'cd a && claude --print', 'FOO=1 claude -p x', 'echo hi | claude -p', 'x=$(claude -p y)', "cd a`nclaude -p z", '/usr/local/bin/claude -p q', 'ls; claude --model sonnet -p hi', 'claude.exe -p hi') {
      Check "ram-guard: true positive blocked: $($cmd -replace "`n", '\n')" ((Ram 'Bash' $cmd '2000').Exit -eq 2)
    }
    foreach ($cmd in 'git commit -m "document claude -p"', 'echo claude -p', "grep -r 'claude -p' docs", 'bash -c "claude -p hi"', 'claude doctor; echo -p', 'cat claude -p.txt', 'echo hi > claude -p', 'my-claude -p x', 'ls claude.md --print') {
      Check "ram-guard: false positive not blocked: $cmd" ((Ram 'Bash' $cmd '1').Exit -eq 0)
    }
    Check 'ram-guard: interactive claude and other claude subcommands are not matched' (((Ram 'Bash' 'claude' '1').Exit -eq 0) -and ((Ram 'Bash' 'claude doctor' '1').Exit -eq 0) -and ((Ram 'Bash' 'echo not-claude -p' '1').Exit -eq 0))
    Check 'ram-guard: invalid or empty stdin never blocks' (((Invoke-Script $ramHook @() 'not json').Exit -eq 0) -and ((Invoke-Script $ramHook @() '').Exit -eq 0))

    # memory that cannot be read: allow, warn once
    Clear-RamState
    $r = Ram 'Agent' '' 'unreadable'
    Check 'ram-guard: unreadable memory allows the call and warns via additionalContext' (($r.Exit -eq 0) -and ($r.Out -match 'additionalContext') -and ($r.Out -match 'could not be read')) $r.Out
    $r = Ram 'Agent' '' 'unreadable'
    Check '... and warns only once' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq '')) $r.Out
    Check '... a command that matches nothing never needs the memory (no warning)' ((Ram 'Bash' 'ls' 'unreadable').Out.Trim() -eq '')

    # the real memory reading of this platform (no fake value): a tiny and an absurd threshold
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "agent-spawn": { "min_free_mb": 1 } } }')
    $r = Ram 'Agent' '' ''
    Check 'ram-guard: real free memory is read (needing 1 MB passes, no warning)' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq '')) "$($r.Out) $($r.Err)"
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "agent-spawn": { "min_free_mb": 99999999 } } }')
    $r = Ram 'Agent' '' ''
    Check '... and needing 99999999 MB blocks, naming a plausible free amount' (($r.Exit -eq 2) -and ($r.Err -match 'free RAM [1-9]\d* MB < needed 99999999 MB')) $r.Err

    # user override
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "agent-spawn": { "min_free_mb": 200 } } }')
    Check 'ram-guard: user override lowers the Agent threshold (300 MB passes)' ((Ram 'Agent' '' '300').Exit -eq 0)
    $r = Ram 'Agent' '' '100'
    Check '... and 100 MB is blocked with the user number' (($r.Exit -eq 2) -and ($r.Err -match 'needed 200 MB')) $r.Err
    Check '... kinds the user file does not mention keep their shipped values' ((Ram 'Bash' 'claude -p x' '2000').Exit -eq 2)

    # project override: it may add kinds and RAISE thresholds, nothing else
    [System.IO.File]::WriteAllText($ramProjFile, '{ "kinds": { "my-engine": { "description": "heavy", "patterns": ["my-engine\\s+--headless", "\\bmy-tests\\b"], "min_free_mb": 4000 }, "agent-spawn": { "min_free_mb": 800 } } }')
    $r = Ram 'Bash' 'tools/my-engine --headless --run' '3000' $proj
    Check 'ram-guard: project kind with its own patterns blocks (3000 < 4000)' (($r.Exit -eq 2) -and ($r.Err -match "needed 4000 MB for 'my-engine'")) $r.Err
    Check '... the second pattern of the kind matches too' ((Ram 'PowerShell' 'run my-tests now' '3000' $proj).Exit -eq 2)
    Check '... and passes with enough memory' ((Ram 'Bash' 'tools/my-engine --headless --run' '5000' $proj).Exit -eq 0)
    Check '... a command that merely mentions the engine without the pattern passes' ((Ram 'Bash' 'ls my-engine-docs' '1' $proj).Exit -eq 0)
    Check '... the project file is not applied outside that project' ((Ram 'Bash' 'tools/my-engine --headless --run' '1' $Work).Exit -eq 0)
    Check 'ram-guard: a project can raise a threshold (user 200 -> project 800)' (((Ram 'Agent' '' '700' $proj).Exit -eq 2) -and ((Ram 'Agent' '' '900' $proj).Exit -eq 0))
    $r = Ram 'Bash' 'claude -p "my-engine --headless"' '3000' $proj
    Check 'ram-guard: when several kinds match, the highest threshold decides' (($r.Exit -eq 2) -and ($r.Err -match "needed 4000 MB for 'my-engine'")) $r.Err

    # project trust boundary: no lowering, no switching off, no own cap, clamped to the user's project_max_mb
    Clear-RamState
    [System.IO.File]::WriteAllText($ramProjFile, '{ "enabled": false, "project_max_mb": 99999, "kinds": { "agent-spawn": { "min_free_mb": 10, "enabled": false }, "claude-headless": { "enabled": false, "min_free_mb": 1 } } }')
    $r = Ram 'Agent' '' '1400' $proj
    Check 'ram-guard: a project cannot lower a threshold, switch a kind or the guard off (still blocked at the shipped 1500)' (($r.Exit -eq 2) -and ($r.Err -match 'needed 1500 MB')) $r.Err
    Check '... the shipped headless-claude kind also stays on' ((Ram 'Bash' 'claude -p x' '2400' $proj).Exit -eq 2)
    $r = Ram 'Agent' '' '5000' $proj
    $ctx = ''
    try { $ctx = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check '... each ignored entry is reported once as a warning' (($r.Exit -eq 0) -and ($ctx -match "project config cannot change 'enabled'") -and ($ctx -match "project config cannot set 'project_max_mb'") -and ($ctx -match "kind 'agent-spawn': the project config can only raise min_free_mb") -and ($ctx -match "kind 'agent-spawn': the project config cannot switch a kind")) $r.Out
    Check '... and not repeated on the next call' ((Ram 'Agent' '' '5000' $proj).Out.Trim() -eq '')
    Clear-RamState
    [System.IO.File]::WriteAllText($ramProjFile, '{ "kinds": { "my-engine": { "patterns": ["my-engine"], "min_free_mb": 20000 } } }')
    $r = Ram 'Bash' 'run my-engine' '7000' $proj
    Check 'ram-guard: a project threshold is clamped to project_max_mb (default 8000)' (($r.Exit -eq 2) -and ($r.Err -match 'needed 8000 MB') -and ($r.Err -match 'project_max_mb')) $r.Err
    Check '... 8000 MB free is enough' ((Ram 'Bash' 'run my-engine' '8000' $proj).Exit -eq 0)
    [System.IO.File]::WriteAllText($ramUserFile, '{ "project_max_mb": 3000 }')
    $r = Ram 'Bash' 'run my-engine' '2500' $proj
    Check '... and the user can set the cap (3000 MB)' (($r.Exit -eq 2) -and ($r.Err -match "needed 3000 MB for 'my-engine'")) $r.Err
    Check '... 3500 MB free passes under that cap' ((Ram 'Bash' 'run my-engine' '3500' $proj).Exit -eq 0)
    Clear-RamState
    [System.IO.File]::WriteAllText($ramProjFile, '{ "kinds": { "claude-headless": { "patterns": ["zzz-heavy"] }, "agent-spawn": { "patterns": ["agentpat"], "tools": ["Bash"] } } }')
    Check 'ram-guard: a project adds patterns to a shipped kind without dropping the shipped one' (((Ram 'Bash' 'zzz-heavy go' '2000' $proj).Exit -eq 2) -and ((Ram 'Bash' 'claude -p x' '2000' $proj).Exit -eq 2))
    Check '... tools are only added: the Agent kind still guards spawns and now also guards its own pattern in Bash' (((Ram 'Agent' '' '1400' $proj).Exit -eq 2) -and ((Ram 'Bash' 'agentpat' '1400' $proj).Exit -eq 2) -and ((Ram 'Bash' 'ls' '1' $proj).Exit -eq 0))

    # a user may change everything the project may not
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "enabled": false }')
    Check 'ram-guard: "enabled": false in the user file disables the whole guard' (((Ram 'Agent' '' '1').Exit -eq 0) -and ((Ram 'Bash' 'claude -p x' '1').Exit -eq 0))
    [System.IO.File]::WriteAllText($ramProjFile, '{ "enabled": true }')
    Check '... and a project file cannot switch it on again' ((Ram 'Agent' '' '1' $proj).Exit -eq 0)
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "claude-headless": { "enabled": false } } }')
    Check 'ram-guard: the user can switch a kind off alone' (((Ram 'Bash' 'claude -p x' '1').Exit -eq 0) -and ((Ram 'Agent' '' '1').Exit -eq 2))

    # kinds that cannot work are skipped, never "match everything"
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "all-bash": { "tools": ["Bash"], "min_free_mb": 9000 } } }')
    $r = Ram 'Bash' 'ls' '1'
    $ctx = ''
    try { $ctx = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check 'ram-guard: a shell kind without patterns is skipped with a warning, not applied to every command' (($r.Exit -eq 0) -and ($ctx -match "kind 'all-bash' skipped: a kind for shell commands needs at least one valid pattern")) $r.Out
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "all-bash": { "patterns": ["["], "min_free_mb": 9000 } } }')
    Check 'ram-guard: a kind whose only pattern is invalid is skipped too' ((Ram 'Bash' 'ls' '1').Exit -eq 0)
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "agent-spawn": { "patterns": ["something"] } } }')
    Check 'ram-guard: a patterns-only override of the Agent kind does not turn it off (patterns do not apply to spawns)' (((Ram 'Agent' '' '100').Exit -eq 2) -and ((Ram 'Agent' '' '5000').Exit -eq 0))
    Check '... and Bash commands matching those patterns are not guarded by it (it lists no shell tool)' ((Ram 'Bash' 'something' '1').Exit -eq 0)
    Clear-RamState
    [System.IO.File]::WriteAllText($ramProjFile, '{ "kinds": { "agent-spawn": { "patterns": ["something"] } } }')
    Check 'ram-guard: the same from a project file keeps the Agent kind on' ((Ram 'Agent' '' '100' $proj).Exit -eq 2)

    # a pathological pattern is cut off by the 200 ms match timeout
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "evil": { "patterns": ["(a+)+$"], "min_free_mb": 9000 } } }')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Ram 'Bash' (('a' * 45) + 'b') '1'
    $ms = $sw.ElapsedMilliseconds
    $ctx = ''
    try { $ctx = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check 'ram-guard: a catastrophic pattern times out, is skipped with a warning and the call is allowed' (($r.Exit -eq 0) -and ($ctx -match "kind 'evil': pattern .* took over 200 ms") -and ($ms -lt 5000)) "$ms ms $($r.Out)"

    # malformed config: warn and fall back, never block everything, never crash
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ this is not json')
    $r = Ram 'Agent' '' '5000'
    Check 'ram-guard: a malformed user file warns and the call is allowed' (($r.Exit -eq 0) -and ($r.Out -match 'not valid JSON')) $r.Out
    Check '... the second call is silent (warned once)' ((Ram 'Agent' '' '5000').Out.Trim() -eq '')
    $r = Ram 'Agent' '' '100'
    Check '... and the shipped defaults still apply (blocks at 100 MB, message mentions the broken file)' (($r.Exit -eq 2) -and ($r.Err -match 'needed 1500 MB') -and ($r.Err -match 'not valid JSON')) $r.Err
    Check '... a command that matches nothing is allowed' ((Ram 'Bash' 'ls' '1').Exit -eq 0)
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '{ "kinds": { "agent-spawn": { "min_free_mb": "lots" }, "bad": { "patterns": ["["], "min_free_mb": 10 }, "nominimum": { "patterns": ["x"] }, "notools": { "min_free_mb": 5 }, "str": 7, "ok": { "patterns": ["ok-cmd", "[", 5], "min_free_mb": 900, "tools": ["Bash"] } } }')
    $r = Ram 'Bash' 'ls' '1'
    $ctx = ''
    try { $ctx = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check 'ram-guard: bad fields and kinds are skipped with warnings, nothing crashes' (($r.Exit -eq 0) -and ($ctx -match 'min_free_mb') -and ($ctx -match 'not a valid regular expression') -and ($ctx -match "kind 'str' .* must be an object") -and ($ctx -match "kind 'nominimum' skipped: it needs min_free_mb") -and ($ctx -match "kind 'notools' skipped: it needs")) $r.Out
    Check '... a kind with a bad min_free_mb keeps the shipped number' ((Ram 'Agent' '' '1400').Exit -eq 2)
    Check '... and the valid kind in the same file works (invalid patterns dropped)' (((Ram 'Bash' 'run ok-cmd' '800').Exit -eq 2) -and ((Ram 'Bash' 'run ok-cmd' '1000').Exit -eq 0))
    Clear-RamState
    [System.IO.File]::WriteAllText($ramUserFile, '[1, 2]')
    $r = Ram 'Agent' '' '5000'
    Check 'ram-guard: a config file that is not an object is ignored with a warning' (($r.Exit -eq 0) -and ($r.Out -match 'must be a JSON object')) $r.Out
    Clear-RamState
    [System.IO.File]::WriteAllText($ramProjFile, '{ broken')
    $r = Ram 'Agent' '' '5000' $proj
    Check 'ram-guard: a malformed project file warns and is ignored' (($r.Exit -eq 0) -and ($r.Out -match 'project config is not valid JSON')) $r.Out
    Clear-RamState
  } finally {
    foreach ($n in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
  }

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
  Check 'runtime payload installed' ((Test-Path "$home1\agent-crew\hooks\guard-paths.ps1") -and (Test-Path "$home1\agent-crew\hooks\ram-guard.ps1") -and (Test-Path "$home1\agent-crew\data\ram-guard.json") -and (Test-Path "$home1\agent-crew\scripts\ledger.ps1") -and (Test-Path "$home1\agent-crew\VERSION") -and (Test-Path "$home1\agent-crew\installed.json"))
  Check 'USER.md copied when missing' (Test-Path "$home1\team\USER.md")
  Check 'agents: scout has omitClaudeMd and maxTurns, reviewer has maxTurns (runaway guards)' (((Get-Content -Raw "$Root\agents\scout.md") -match '(?m)^omitClaudeMd: true\r?$') -and ((Get-Content -Raw "$Root\agents\scout.md") -match '(?m)^maxTurns: \d+') -and ((Get-Content -Raw "$Root\agents\reviewer.md") -match '(?m)^maxTurns: \d+'))
  Check 'agents carry no hooks front matter and no tokens (the guard is registered once, in settings.json)' (-not (Select-String -Path "$home1\agents\*.md" -Pattern '^hooks:|@@HOOK' -Quiet))
  Check 'a backup of settings.json was made' (@(Get-ChildItem $home1 -Filter 'settings.json.bak-*').Count -eq 1)
  $s = Get-Content -Raw "$home1\settings.json" | ConvertFrom-Json
  Check 'settings: own keys kept' (($s.model -eq 'opus') -and ($s.other.keep -eq 'me'))
  Check 'settings: user hook kept' (@($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash' -and $_.hooks[0].command -eq 'echo mine' }).Count -eq 1)
  foreach ($hk in @(@('PreToolUse', 'guard-paths'), @('PostToolUse', 'check-caps'), @('PreCompact', 'pre-compact'), @('PostCompact', 'post-compact'), @('SessionStart', 'session-start'))) {
    $n = @(@($s.hooks.($hk[0])) | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -match [regex]::Escape("$home1" + [char]92 + 'agent-crew') -and $_.command -match [regex]::Escape($hk[1] + '.ps1') }).Count
    Check "settings: exactly one $($hk[0]) entry for $($hk[1])" ($n -eq 1) "found $n"
  }
  $ramHooks = @(@($s.hooks.PreToolUse) | Where-Object { $_.hooks[0].command -match 'ram-guard\.ps1' })
  Check 'settings: ram-guard has one unconditional entry for Agent|Task' (@($ramHooks | Where-Object { $_.matcher -eq 'Agent|Task' -and -not $_.hooks[0].PSObject.Properties['if'] }).Count -eq 1)
  foreach ($rule in 'Bash(claude *)', 'Bash(claude.exe *)', 'PowerShell(claude *)', 'PowerShell(claude.cmd *)') {
    Check "settings: ram-guard shell entry filtered with if = $rule" (@($ramHooks | Where-Object { $_.hooks[0].PSObject.Properties['if'] -and $_.hooks[0].if -eq $rule -and $_.matcher -eq $rule.Split('(')[0] }).Count -eq 1)
  }
  $nslHooks = @(@($s.hooks.PreToolUse) | Where-Object { $_.hooks[0].command -match 'no-session-links\.ps1' })
  Check 'settings: no-session-links has 4 if-filtered Bash and PowerShell entries, none unconditional' (($nslHooks.Count -eq 4) -and (@($nslHooks | Where-Object { -not $_.hooks[0].PSObject.Properties['if'] }).Count -eq 0) -and (@($nslHooks | Where-Object { $_.hooks[0].if -eq 'Bash(*git *)' }).Count -eq 1) -and (@($nslHooks | Where-Object { $_.hooks[0].if -eq 'PowerShell(*gh *)' }).Count -eq 1))
  Check 'settings: no unconditional ram-guard entry for every shell command' (@($ramHooks | Where-Object { $_.matcher -match 'Bash' -and -not $_.hooks[0].PSObject.Properties['if'] }).Count -eq 0)
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

  # ram-guard hook entries follow the user's ram-guard.json (hook_if globs, scan_all_commands)
  $home7 = Join-Path $Work 'claude-home7'
  New-Item -ItemType Directory -Path "$home7\team" | Out-Null
  function Get-RamEntries($homeDir) {
    $st = Get-Content -Raw "$homeDir\settings.json" | ConvertFrom-Json
    return @(@($st.hooks.PreToolUse) | Where-Object { $_ -and $_.hooks -and ($_.hooks[0].command -match 'ram-guard\.ps1') } | ForEach-Object { '{0}|{1}' -f $_.matcher, $(if ($_.hooks[0].PSObject.Properties['if']) { $_.hooks[0].if } else { '' }) })
  }
  [void](Invoke-Script $install @('-ClaudeHome', $home7))
  $e = Get-RamEntries $home7
  Check 'ram-guard entries: default is Agent|Task plus claude-filtered Bash and PowerShell entries (7)' (($e.Count -eq 7) -and ($e -contains 'Agent|Task|') -and ($e -contains 'Bash|Bash(claude *)') -and ($e -contains 'PowerShell|PowerShell(claude.exe *)')) ($e -join '; ')
  [System.IO.File]::WriteAllText("$home7\team\ram-guard.json", '{ "kinds": { "my-engine": { "patterns": ["my-engine"], "hook_if": ["my-engine *"], "min_free_mb": 100 } } }')
  [void](Invoke-Script $install @('-ClaudeHome', $home7))
  $e = Get-RamEntries $home7
  Check 'ram-guard entries: a user kind with hook_if adds filtered entries and no duplicates' (($e.Count -eq 9) -and ($e -contains 'Bash|Bash(my-engine *)') -and ($e -contains 'PowerShell|PowerShell(my-engine *)') -and ($e -contains 'Bash|Bash(claude *)')) ($e -join '; ')
  [System.IO.File]::WriteAllText("$home7\team\ram-guard.json", '{ "kinds": { "my-engine": { "patterns": ["my-engine"], "min_free_mb": 100 } } }')
  [void](Invoke-Script $install @('-ClaudeHome', $home7))
  $e = Get-RamEntries $home7
  Check 'ram-guard entries: a user shell kind without hook_if gives one unconditional Bash|PowerShell entry instead' (($e.Count -eq 2) -and ($e -contains 'Agent|Task|') -and ($e -contains 'Bash|PowerShell|')) ($e -join '; ')
  [System.IO.File]::WriteAllText("$home7\team\ram-guard.json", '{ "scan_all_commands": true }')
  [void](Invoke-Script $install @('-ClaudeHome', $home7))
  $e = Get-RamEntries $home7
  Check 'ram-guard entries: "scan_all_commands": true does the same' (($e.Count -eq 2) -and ($e -contains 'Bash|PowerShell|')) ($e -join '; ')
  Remove-Item "$home7\team\ram-guard.json"
  [void](Invoke-Script $install @('-ClaudeHome', $home7))
  $e = Get-RamEntries $home7
  Check 'ram-guard entries: removing the file brings the filtered entries back' ($e.Count -eq 7) ($e -join '; ')
  $r = Invoke-Script $install @('-ClaudeHome', $home7, '-Uninstall')
  Check 'ram-guard entries: uninstall removes all of them' (-not (Test-Path "$home7\settings.json") -or (@(Get-RamEntries $home7).Count -eq 0))

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

foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
