<#
.SYNOPSIS
  Token and cost ledger for a project's Claude Code transcripts, per agent type, model and effort.

.DESCRIPTION
  Reads <ProjectsRoot>\<slug>\*.jsonl (the main sessions) and
  <ProjectsRoot>\<slug>\<session>\subagents\agent-*.jsonl (+ sibling .meta.json with agentType,
  model, effort). Only assistant lines with a "usage" object are parsed. Streaming duplicates
  are removed per requestId (fallback message.id), keeping the record with the most output
  tokens. Cost = tokens x data\prices.json (matched by model-id prefix).

  The `subagent_tokens` figure in notifications is a context size, not spend. This is spend.

.PARAMETER Project       Project folder (default: current folder).
.PARAMETER ProjectsRoot  Where Claude Code keeps transcripts (default: $HOME\.claude\projects).
.PARAMETER Since         Only requests at or after this date/time (any format [datetime] reads).
.PARAMETER Session       Only this session id (the jsonl file name without extension).
.PARAMETER Alias         Rename agent types, "old=new" (for example bug-hunter=reviewer). Several allowed: -Alias a=b,c=d.
.PARAMETER Format        table (default), json or md.
.PARAMETER MainAgent     Name for the main thread. Default: the "agent" value of .claude\settings*.json, else "main".
.PARAMETER Prices        Path to a prices.json (default: ..\data\prices.json next to this script).
#>
[CmdletBinding()]
param(
  [string]$Project = (Get-Location).Path,
  [string]$ProjectsRoot = (Join-Path $HOME '.claude\projects'),
  [string]$Since,
  [string]$Session,
  [string[]]$Alias = @(),
  [ValidateSet('table', 'json', 'md')]
  [string]$Format = 'table',
  [string]$MainAgent,
  [string]$Prices
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------

function Get-ProjectSlug([string]$Path) {
  # Claude Code names the transcript folder after the project path, every non-alphanumeric
  # character replaced by '-' (Z:\GameDev\Sim -> Z--GameDev-Sim).
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  return ($full -replace '[^A-Za-z0-9]', '-')
}

function Find-TranscriptFolder([string]$Root, [string]$ProjectPath) {
  $slug = Get-ProjectSlug $ProjectPath
  $direct = Join-Path $Root $slug
  if (Test-Path -LiteralPath $direct -PathType Container) { return $direct }
  if (Test-Path -LiteralPath $Root -PathType Container) {
    $hit = Get-ChildItem -LiteralPath $Root -Directory | Where-Object { $_.Name -ieq $slug } | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

function Get-MainAgentName([string]$ProjectPath) {
  foreach ($name in 'settings.local.json', 'settings.json') {
    $p = Join-Path $ProjectPath ".claude\$name"
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      try {
        $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
        if ($j.agent) { return [string]$j.agent }
      } catch { }
    }
  }
  return 'main'
}

function Read-Meta([string]$JsonlPath) {
  $metaPath = [System.IO.Path]::ChangeExtension($JsonlPath, '.meta.json')
  if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
    try { return ([System.IO.File]::ReadAllText($metaPath) | ConvertFrom-Json) } catch { }
  }
  return $null
}

function Get-PriceFor([string]$ModelId, $PriceTable) {
  if (-not $ModelId) { return $null }
  $id = $ModelId.ToLowerInvariant()
  foreach ($prop in $PriceTable.families.PSObject.Properties) {
    foreach ($prefix in $prop.Value.prefixes) {
      if ($id.StartsWith($prefix)) { return $prop.Value }
    }
  }
  return $null
}

function Add-Request($Table, $Req) {
  # Keeps, per request id, the record with the most output tokens (streaming writes several).
  if ($Table.ContainsKey($Req.Key)) {
    if ($Req.Out -ge $Table[$Req.Key].Out) { $Table[$Req.Key] = $Req }
  } else {
    $Table[$Req.Key] = $Req
  }
}

function Read-Transcript {
  param([string]$Path, [string]$AgentType, [string]$MetaModel, [string]$MetaEffort,
        [string]$SessionId, [string]$AgentFile, $Table, [string]$SinceIso)
  $reader = New-Object System.IO.StreamReader($Path, (New-Object System.Text.UTF8Encoding($false)), $true, 1048576)
  $bad = 0
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if (-not $line.Contains('"usage"')) { continue }
      if (-not $line.Contains('"assistant"')) { continue }
      try { $o = $line | ConvertFrom-Json } catch { $bad++; continue }
      if ($o.type -ne 'assistant' -or -not $o.message -or -not $o.message.usage) { continue }
      $model = [string]$o.message.model
      if ($model -eq '<synthetic>') { continue }
      if ($SinceIso -and ([string]$o.timestamp) -lt $SinceIso) { continue }
      $u = $o.message.usage
      $key = [string]$o.requestId
      if (-not $key) { $key = [string]$o.message.id }
      if (-not $key) { $key = "$Path#$($o.uuid)" }

      $c5 = 0L; $c1 = 0L
      if ($u.cache_creation) {
        $c5 = [long]$u.cache_creation.ephemeral_5m_input_tokens
        $c1 = [long]$u.cache_creation.ephemeral_1h_input_tokens
      } else {
        $c5 = [long]$u.cache_creation_input_tokens
      }
      $effort = $MetaEffort
      if (-not $effort) { $effort = [string]$o.effort }
      if (-not $effort) { $effort = [string]$o.perTurnEffort }
      if (-not $effort) { $effort = 'default' }
      $groupModel = $MetaModel
      if (-not $groupModel) { $groupModel = $model }

      Add-Request $Table ([pscustomobject]@{
          Key = $key; Agent = $AgentType; Model = $groupModel; PriceModel = $model; Effort = $effort
          Session = $SessionId; AgentFile = $AgentFile
          In = [long]$u.input_tokens; Out = [long]$u.output_tokens
          C5 = $c5; C1 = $c1; CR = [long]$u.cache_read_input_tokens
        })
    }
  } finally {
    $reader.Dispose()
  }
  return $bad
}

function Format-Money([double]$v) { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N2}', $v) }
function Format-Num([long]$v) { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $v) }

function Join-Cells([object[]]$Cells, [int[]]$Widths, [bool[]]$Right) {
  $parts = for ($i = 0; $i -lt $Cells.Count; $i++) {
    $s = [string]$Cells[$i]
    if ($Right[$i]) { $s.PadLeft($Widths[$i]) } else { $s.PadRight($Widths[$i]) }
  }
  return ($parts -join '  ')
}

function Format-TextTable([string[]]$Headers, [object[][]]$Rows, [bool[]]$Right) {
  $w = @(0) * $Headers.Count
  for ($i = 0; $i -lt $Headers.Count; $i++) { $w[$i] = $Headers[$i].Length }
  foreach ($r in $Rows) { for ($i = 0; $i -lt $r.Count; $i++) { $w[$i] = [Math]::Max($w[$i], ([string]$r[$i]).Length) } }
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add((Join-Cells $Headers $w $Right))
  $out.Add((($w | ForEach-Object { '-' * $_ }) -join '  '))
  foreach ($r in $Rows) { $out.Add((Join-Cells $r $w $Right)) }
  return $out
}

function Format-MdTable([string[]]$Headers, [object[][]]$Rows, [bool[]]$Right) {
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add('| ' + ($Headers -join ' | ') + ' |')
  $out.Add('|' + ((0..($Headers.Count - 1) | ForEach-Object { if ($Right[$_]) { '---:' } else { '---' } }) -join '|') + '|')
  foreach ($r in $Rows) { $out.Add('| ' + (($r | ForEach-Object { [string]$_ }) -join ' | ') + ' |') }
  return $out
}

# ---------- locate ----------

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Prices) { $Prices = Join-Path (Split-Path -Parent $scriptRoot) 'data\prices.json' }
$priceTable = [System.IO.File]::ReadAllText($Prices) | ConvertFrom-Json

if (-not $MainAgent) { $MainAgent = Get-MainAgentName $Project }

$aliasMap = @{}
foreach ($a in $Alias) {
  foreach ($pair in ($a -split ',')) {
    if ($pair -match '^\s*([^=]+)=(.+?)\s*$') { $aliasMap[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
}

$sinceIso = $null
if ($Since) { $sinceIso = ([datetime]::Parse($Since)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

$folder = Find-TranscriptFolder $ProjectsRoot $Project
if (-not $folder) {
  [Console]::Error.WriteLine("ledger: no transcript folder for '$Project' under '$ProjectsRoot' (expected '$(Get-ProjectSlug $Project)').")
  exit 1
}

# ---------- read ----------

$requests = @{}
$bad = 0
$spawnFiles = New-Object System.Collections.Generic.HashSet[string]

foreach ($main in (Get-ChildItem -LiteralPath $folder -Filter '*.jsonl' -File)) {
  $sid = [System.IO.Path]::GetFileNameWithoutExtension($main.Name)
  if ($Session -and $sid -ne $Session) { continue }
  $bad += Read-Transcript -Path $main.FullName -AgentType $MainAgent -MetaModel $null -MetaEffort $null `
    -SessionId $sid -AgentFile $main.Name -Table $requests -SinceIso $sinceIso

  $subDir = Join-Path $folder (Join-Path $sid 'subagents')
  if (Test-Path -LiteralPath $subDir -PathType Container) {
    foreach ($sub in (Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -File)) {
      $meta = Read-Meta $sub.FullName
      $type = if ($meta -and $meta.agentType) { [string]$meta.agentType } else { 'unknown' }
      $mm = if ($meta -and $meta.model) { [string]$meta.model } else { $null }
      $me = if ($meta -and $meta.effort) { [string]$meta.effort } else { $null }
      $bad += Read-Transcript -Path $sub.FullName -AgentType $type -MetaModel $mm -MetaEffort $me `
        -SessionId $sid -AgentFile $sub.Name -Table $requests -SinceIso $sinceIso
    }
  }
}

# ---------- aggregate ----------

$unknownModels = New-Object System.Collections.Generic.HashSet[string]
$rows = @{}      # agent|model|effort -> row
$spawns = @{}    # agent -> set of agent files
foreach ($r in $requests.Values) {
  $agent = $r.Agent
  if ($aliasMap.ContainsKey($agent)) { $agent = $aliasMap[$agent] }
  $k = "$agent|$($r.Model)|$($r.Effort)"
  if (-not $rows.ContainsKey($k)) {
    $rows[$k] = [pscustomobject]@{ Agent = $agent; Model = $r.Model; Effort = $r.Effort; Spawns = 0
      Input = 0L; CacheWrite5m = 0L; CacheWrite1h = 0L; CacheRead = 0L; Output = 0L; Cost = 0.0; _files = (New-Object System.Collections.Generic.HashSet[string]) }
  }
  $row = $rows[$k]
  $row.Input += $r.In; $row.CacheWrite5m += $r.C5; $row.CacheWrite1h += $r.C1
  $row.CacheRead += $r.CR; $row.Output += $r.Out
  [void]$row._files.Add("$($r.Session)/$($r.AgentFile)")
  if (-not $spawns.ContainsKey($agent)) { $spawns[$agent] = New-Object System.Collections.Generic.HashSet[string] }
  [void]$spawns[$agent].Add("$($r.Session)/$($r.AgentFile)")

  $p = Get-PriceFor $r.PriceModel $priceTable
  if (-not $p) { $p = Get-PriceFor $r.Model $priceTable }
  if ($p) {
    $row.Cost += ($r.In * $p.input + $r.Out * $p.output + $r.C5 * $p.cache_write_5m + $r.C1 * $p.cache_write_1h + $r.CR * $p.cache_read) / 1e6
  } else {
    [void]$unknownModels.Add([string]$r.PriceModel)
  }
}
foreach ($row in $rows.Values) { $row.Spawns = $row._files.Count }

$detail = @($rows.Values | Sort-Object Cost -Descending | ForEach-Object {
    [pscustomobject]@{ Agent = $_.Agent; Model = $_.Model; Effort = $_.Effort; Spawns = $_.Spawns
      Input = $_.Input; CacheWrite5m = $_.CacheWrite5m; CacheWrite1h = $_.CacheWrite1h; CacheRead = $_.CacheRead
      Output = $_.Output; Cost = [Math]::Round($_.Cost, 6) } })

$byAgent = @($detail | Group-Object Agent | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
      Agent = $_.Name; Spawns = $spawns[$_.Name].Count
      Input = ($g | Measure-Object Input -Sum).Sum
      CacheWrite = ($g | Measure-Object CacheWrite5m -Sum).Sum + ($g | Measure-Object CacheWrite1h -Sum).Sum
      CacheRead = ($g | Measure-Object CacheRead -Sum).Sum
      Output = ($g | Measure-Object Output -Sum).Sum
      Cost = [Math]::Round(($g | Measure-Object Cost -Sum).Sum, 6)
    } } | Sort-Object Cost -Descending)

$total = [Math]::Round((@($detail) | Measure-Object Cost -Sum).Sum, 6)

# ---------- output ----------

if ($Format -eq 'json') {
  [pscustomobject]@{
    project = $Project; transcriptFolder = $folder; requests = $requests.Count
    totalCostUsd = $total; pricesAsOf = $priceTable.as_of; pricesStatus = $priceTable.status
    unknownModels = @($unknownModels); unparsedLines = $bad
    byAgent = $byAgent; rows = $detail
  } | ConvertTo-Json -Depth 6
  exit 0
}

$hAgent = @('Agent', 'Spawns', 'Input', 'CacheWrite', 'CacheRead', 'Output', 'Cost USD')
$rAgent = @($false, $true, $true, $true, $true, $true, $true)
$dataAgent = @($byAgent | ForEach-Object { , @($_.Agent, $_.Spawns, (Format-Num $_.Input), (Format-Num $_.CacheWrite), (Format-Num $_.CacheRead), (Format-Num $_.Output), (Format-Money $_.Cost)) })
$hDetail = @('Agent', 'Model', 'Effort', 'Spawns', 'Input', 'CacheW 5m', 'CacheW 1h', 'CacheRead', 'Output', 'Cost USD')
$rDetail = @($false, $false, $false, $true, $true, $true, $true, $true, $true, $true)
$dataDetail = @($detail | ForEach-Object { , @($_.Agent, $_.Model, $_.Effort, $_.Spawns, (Format-Num $_.Input), (Format-Num $_.CacheWrite5m), (Format-Num $_.CacheWrite1h), (Format-Num $_.CacheRead), (Format-Num $_.Output), (Format-Money $_.Cost)) })

$note = "Prices: data\prices.json, as of $($priceTable.as_of), status: $($priceTable.status)."
$lines = New-Object System.Collections.Generic.List[string]
if ($Format -eq 'md') {
  $lines.Add("**Total: `$$(Format-Money $total)** over $($requests.Count) requests ($note)")
  $lines.Add('')
  $lines.Add('By agent type')
  $lines.Add('')
  $lines.AddRange([string[]](Format-MdTable $hAgent $dataAgent $rAgent))
  $lines.Add('')
  $lines.Add('By agent type, model and effort')
  $lines.Add('')
  $lines.AddRange([string[]](Format-MdTable $hDetail $dataDetail $rDetail))
} else {
  $lines.Add("Project:  $Project")
  $lines.Add("Requests: $($requests.Count)   Total: `$$(Format-Money $total)")
  $lines.Add($note)
  $lines.Add('')
  $lines.Add('By agent type')
  $lines.AddRange([string[]](Format-TextTable $hAgent $dataAgent $rAgent))
  $lines.Add('')
  $lines.Add('By agent type, model and effort')
  $lines.AddRange([string[]](Format-TextTable $hDetail $dataDetail $rDetail))
}
if ($unknownModels.Count -gt 0) { $lines.Add(''); $lines.Add('No price for model(s) (cost counted as 0): ' + (($unknownModels | Sort-Object) -join ', ')) }
if ($bad -gt 0) { $lines.Add(''); $lines.Add("$bad line(s) could not be parsed and were skipped.") }
$lines | ForEach-Object { Write-Output $_ }
