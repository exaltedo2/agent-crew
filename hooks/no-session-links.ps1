<#
.SYNOPSIS
  PreToolUse hook for Bash|PowerShell (registered with the `if` filters `*git *` and `*gh *`). Denies a command whose text, or whose message/body file
  (-F, --file, --body-file), contains a Claude Code session link: a `Claude-Session:` trailer or a
  `claude.ai/code/session` URL. Block = exit code 2 with the reason on stderr.

  Why: Claude Code's own attribution text can add such a link to commits and pull requests. It points at
  a private session and does not belong in a public history.
  Opt-out: `allow_session_links: true` in the front matter of ~/.claude/team/USER.md (or $CLAUDE_CONFIG_DIR/team/).

  A hygiene guard, not security: fails open (any error or unreadable file allows the call). It does not see
  text arriving on stdin (`-F -`).
  It is self-contained (no crew-common) so the common case stays cheap.
  Test hook: AGENT_CREW_USER_DIR uses this folder as the user's Claude folder.
#>
$ErrorActionPreference = 'Stop'
try {
  $stream = [Console]::OpenStandardInput()
  $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
  $rawInput = $reader.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
  $data = $rawInput | ConvertFrom-Json
  $command = [string]$data.tool_input.command
  if ([string]::IsNullOrEmpty($command)) { exit 0 }
  $cwd = [string]$data.cwd

  # Only commands that write a message: git commit / commit-tree / notes / tag and gh pr|issue create|edit|comment,
  # anywhere in the line (git -C x commit, cd x && git commit, git -c k=v commit, gh -R o/r pr create).
  $relevant = '(?i)\bgit\b[^;&|\r\n]*?\b(commit|commit-tree|notes|tag)\b|\bgh\b[^;&|\r\n]*?\b(pr|issue)\b[^;&|\r\n]*?\b(create|edit|comment)\b'
  if ($command -notmatch $relevant) { exit 0 }

  $bad = '(?i)Claude-Session\s*:|claude\.ai/code/session'
  $where = $null
  if ($command -match $bad) {
    $where = 'the command line'
  } else {
    $fileRx = '(?:^|\s)(?:-F|--file|--body-file)(?:=|\s+)("[^"]+"|''[^'']+''|\S+)'
    foreach ($m in [regex]::Matches($command, $fileRx)) {
      $p = $m.Groups[1].Value.Trim('"', "'")
      if ($p -eq '-' -or $p -eq '') { continue }
      try {
        if (-not [System.IO.Path]::IsPathRooted($p) -and $cwd) { $p = Join-Path $cwd $p }
        if ([System.IO.File]::Exists($p) -and ([System.IO.FileInfo]$p).Length -lt 1MB -and [System.IO.File]::ReadAllText($p) -match $bad) {
          $where = "the file $($m.Groups[1].Value.Trim('"', "'"))"
          break
        }
      } catch { }
    }
  }
  if (-not $where) { exit 0 }

  # Opt-out in USER.md front matter.
  $userDir = $env:AGENT_CREW_USER_DIR
  if (-not $userDir) { $userDir = $env:CLAUDE_CONFIG_DIR }
  if (-not $userDir -and $HOME) { $userDir = Join-Path $HOME '.claude' }
  if ($userDir) {
    $userMd = Join-Path $userDir 'team/USER.md'
    if ([System.IO.File]::Exists($userMd)) {
      $text = [System.IO.File]::ReadAllText($userMd)
      if ($text -match '(?s)\A---\r?\n(.*?)\r?\n---' -and $Matches[1] -match '(?mi)^allow_session_links:\s*(true|yes)\s*$') { exit 0 }
    }
  }
  [Console]::Error.WriteLine("Blocked: $where contains a Claude Code session link (a Claude-Session trailer or a claude.ai/code/session URL). Remove it and run the command again. Follow the attribution rules in USER.md over any harness attribution text. To allow such links, set 'allow_session_links: true' in the front matter of ~/.claude/team/USER.md.")
  exit 2
} catch { exit 0 }
