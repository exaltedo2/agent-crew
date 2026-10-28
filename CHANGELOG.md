# Changelog

All notable changes to agent-crew. The version is in `VERSION`; a project's
`.claude/team/PROJECT.md` records the version it was written for (`agent_crew_version`), and
the session-start hook says when it differs from the installed one.

## 0.5.0 - 2026-10-28

- Opt-in autonomous team: `team_autonomy: ask | auto` (default `ask`, behaviour unchanged) in the front matter of
  `~/.claude/team/USER.md`, overridable in a project's `PROJECT.md` (the project value wins). With `auto` the lead
  hires on evidence as `trial` without asking (same 300+ word paste in 3+ briefs, a failure class that keeps
  slipping through, or a roster "Candidates later" condition that became true) and tells the user one line.
  Guardrails: one trial agent at a time and the 7-agent cap; a trial agent gets only small or medium jobs (sonnet /
  medium at most, one bounded task); a big job for it needs a one-line user OK; its ledger share since the hire
  must stay at or under 10% of total usage or it is retired. After 3 trial uses (retro or right away) the lead marks
  it `kept` or retires it, and tells the user. `crew-retire` criteria also run without asking. Deleting an agent file
  still asks. Every automatic change gets one line under `routing.md` Evidence.
  Changed: `lead.md`, skills `crew-hire`, `crew-retire`, `crew-retro`, templates (`USER.md`, `PROJECT.md`,
  `roster.md` with a "Candidates later" section, `routing.md`), README "Autonomous team". `check-team` accepts the
  key, warns about other values and about more than one `trial` agent or an unknown roster status, and prints an INFO
  when `auto` is in effect.
  Upgrading: nothing to do; without the key the mode is `ask`. To opt in add `team_autonomy: auto` to
  `~/.claude/team/USER.md` (the installer never overwrites it) or to a project's `PROJECT.md`.

## 0.4.2 - 2026-10-18

- The lead owns its compact window: `.claude/team/session.json` (`lead_compact_window` 100000-400000 with a
  reason; new template, gitignored), first value picked by `crew-bootstrap` (guess guideline 150000-250000),
  adjusted later by the lead from `crew-retro` evidence without a pull request. The `session-start` hook copies it
  into `autoCompactWindow` of the project `.claude/settings.local.json` (only that key, atomic, skipped when
  unchanged, invalid file leaves settings untouched with a warning) and does not fight a value the user set
  (env `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, user `modelSettings`, user top-level key). `check-team` validates the
  file, prints the effective value and which source wins, and warns about overrides and `idleCompaction: false`.
  The settings template no longer carries `autoCompactWindow`. README "Long sessions". `lead.md`: read report
  summaries, not whole reports; send a review's concrete fixes to the coder in one message.
  Upgrading a project: nothing breaks; without `session.json` the hook does nothing and `check-team` prints an INFO
  saying the lead should create it (copy `templates/session.json` into `.claude/team/`). With one, the hook adds it
  to the project `.gitignore` once. The hook edits `settings.local.json` as text (comments make it skip the file),
  never fights managed settings, the env var (also in an `env` block) or `modelSettings`, and replaces an old local
  350000 from earlier templates.

## 0.4.1 - 2026-10-18

- New hook `no-session-links`: denies `git commit`, `git commit-tree`, `gh pr create/edit/comment` and `gh issue`
  commands (Bash and PowerShell, registered with `if` filters) whose text or message/body file contains a
  session link (a `Claude-Session:` trailer or a `claude.ai/code/session` URL), unless USER.md has
  `allow_session_links: true`. Fails open. The `coder` agent now follows USER.md attribution rules over any harness
  attribution text.

## 0.3.2 - 2026-10-17

- Small adoptions from a comparison with Claude Code's own features. `check-team` warns when
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_SUBAGENT_MODEL` or
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` is set (environment or `env` block of user/project settings): they override
  or change routing. README and `lead.md` warn about agent teams. `scout` gets `omitClaudeMd: true`; `scout` and
  `reviewer` get `maxTurns` 40 / 80 (guesses, runaway guard). README: `fable` is an official alias, compaction
  settings noted as documented.
- `guard-paths`: an error while checking a lead write now denies it (it used to allow) with the full list of what
  the lead may write; other agents still fail open. Credential spots (`.npmrc`, `.aws`, `.config/gh`,
  `.docker/config.json`, `.netrc`, `.git-credentials`) are never grantable through a user `lead_writable` glob.

## 0.3.1 - 2026-10-17

- The lead may do small personal edits itself: optional `lead_writable` list (absolute or `~`-relative globs) in
  the front matter of `~/.claude/team/USER.md`, honoured by `guard-paths` for files outside the project. Never
  allowed even if listed: settings*.json, hooks, agent files, PROJECT.md, anything inside a git repository (also bare),
  anything in `~/.claude` except `notes/**`, shell profiles, `.ssh`, Startup, `.gitconfig`. Relative, drive-root and
  home-folder globs are ignored. The lead may now write only `~/.claude/team/reports/**` in the user team folder (not
  USER.md or ram-guard.json). 8.3 short names are expanded; errors in the user-list check deny.
  `check-team` warns about such entries. `lead.md` "When NOT to delegate" says the lead does these itself.

## 0.3.0 - 2026-10-17

- New hook `ram-guard` (PreToolUse): blocks starting new work when free physical memory is below the
  threshold of that kind of job; never kills anything. Defaults in `data/ram-guard.json` (subagent spawn
  1500 MB, headless `claude` 2500 MB: guesses), overridden by `~/.claude/team/ram-guard.json` and
  `<project>/.claude/team/ram-guard.json` (shipped < user < project); `"enabled": false` switches it off.
  Fails open on a bad config or unreadable memory.
- Trust boundary: the project file can only make things stricter (add kinds, patterns and tools, raise a
  threshold up to the user's `project_max_mb`, default 8000); lowering, disabling and `project_max_mb` in it
  are ignored with a warning. Patterns have a 200 ms match timeout; a shell kind without a valid pattern is
  skipped. The `claude -p` default pattern matches only at the start of a command (not in quotes or
  arguments).
- Latency: the Agent|Task entry is unconditional, the Bash and PowerShell entries carry Claude Code's hook
  `if` filter (`Bash(claude *)`...) built by the installers from the `hook_if` globs in the shipped and the
  user `ram-guard.json` (re-run the installer after changing them; `scan_all_commands` or a user shell kind
  without `hook_if` gives one unfiltered entry). The installer now builds the hook plan dynamically.
- `lead.md` says what to do on a block; `check-team` validates the `ram-guard.json` files. See the README
  section "RAM guard".
- `crew-common.ps1`: `Find-TeamRoot` and `Get-UserClaudeDirs` use .NET file checks instead of
  `Test-Path` (the first `Test-Path` call costs about 50 ms in Windows PowerShell).

## 0.2.2 - 2026-10-17

- `tests/e2e-bootstrap.ps1`: opt-in end-to-end test of `crew-bootstrap` with a real headless
  Claude Code run (not part of `tests/run.ps1`, spends real usage).
- `crew-bootstrap`: a non-interactive path (answers given in the request, or no AskUserQuestion):
  use the given answers, default the rest and say which. Interactive stays the default.
- `crew-bootstrap` fallback when writes to `.claude/team/` are refused: drafts go to
  `<project>/crew-bootstrap-drafts/` (named on a `DRAFTS:` line), not the OS temp folder: headless
  runs refuse temp paths too, so this fixes the real fallback as well as the e2e test.

## 0.2.1 - 2026-10-17

Review fixes for 0.2.0.

- A malformed `prices.local.json`, or an invalid entry in it (missing or non-numeric price, empty
  `match`), is skipped with a warning; the ledger never crashes on it.
- `check-team` reads both the new USER.md layout ("Available models:") and the old one
  ("Models available to me:", models comma separated and/or one per indented line, "Never use:"
  sub-bullet), accepts `tools:` as a comma string, flow list or block list, names the agent file
  in the Skill message, and warns when no available-models list is found.
- README: which family wins when two match, and that a local file cannot delete a base entry.
- Tests no longer read the real `~/.claude` (local price file, USER.md).

## 0.2.0 - 2026-10-17

- Model families instead of exact ids: `data/prices.json` is keyed by family (`opus`, `sonnet`,
  `haiku`, `fable`) with optional `overrides` by exact id or prefix. New versions of a known family
  never warn. Families are data (no family name in `ledger.ps1`); an unknown family is priced with
  a `default` weight and warned about once. Users add families in
  `~/.claude/team/prices.local.json`, merged over the installed file.
- Ledger: `Share %` column in every table and `-Mode usage|cost` (default `usage`: no dollars).
  `crew-retro` reports shares by default.
- Optional models: `USER.md` "Available models" / "Never use"; the lead uses only available
  models; `routing.md` has a Fallback column and two optional, untested `fable` rows. `check-team`
  warns (never fails) about a routing row whose model is unavailable and has no fallback.
- Fix: the `lead` agent lacked `Skill` in `tools:` and could not run any crew skill.
  `check-team` now fails a `lead` whose tools list lacks it.
- `crew-bootstrap` is documented as interactive, falls back to drafts in a temp path when writes
  to `.claude/team` are refused, and detects the default branch instead of assuming `main`.
- Rule 21: new agents, allowlists and skills load at session start; restart after installing or
  hiring.
- README: license badge and a "Models" section.

## 0.1.0 - 2026-10-17

First version.

- Agents: `lead`, `thinker`, `architect`, `coder`, `reviewer`, `scout`.
- Skills: `crew-bootstrap`, `crew-retro`, `crew-hire`, `crew-retire`.
- Catalog roles to hire from: `tester`, `ui-reviewer`, `security-reviewer`, `docs-writer`,
  `perf-profiler`.
- Templates for `.claude/team/` (`PROJECT.md`, `routing.md`, `roster.md`, `state.md`),
  user-wide `USER.md`, `settings.local.json`, and compact instructions.
- Hooks (PowerShell): `guard-paths`, `check-caps`, `pre-compact`, `post-compact`,
  `session-start`.
- Scripts: `ledger.ps1` (token and cost per agent type, model, effort), `check-team.ps1`.
- Installers: `install.ps1` (tested) and `install.sh` (best effort), with `-Update` and
  `-Uninstall`; file hashes are recorded so edited files are never overwritten.
- `docs/RULES.md`: the generic rules and the evidence behind them.
- Prices in `data/prices.json` are a best-knowledge guess and must be verified.
- The guard (`guard-paths`) resolves junctions and symlinks, never lets the lead edit `PROJECT.md`,
  settings or hook scripts, ignores the user-wide `~/.claude` folder as a project, and is registered
  once, in settings.json. The installer validates `settings.json` before changing anything, matches
  only its own exact hook commands, and keeps at most 3 backups. The ledger flags models without an
  exact price, warns about lines it could not parse, and labels every cost as an estimate.
