# Changelog

All notable changes to agent-crew. The version is in `VERSION`; a project's
`.claude/team/PROJECT.md` records the version it was written for (`agent_crew_version`), and
the session-start hook says when it differs from the installed one.

## 0.2.2 - 2026-10-17

- `tests/e2e-bootstrap.ps1`: opt-in end-to-end test of `crew-bootstrap` with a real headless
  Claude Code run (not part of `tests/run.ps1`, spends real usage).
- `crew-bootstrap`: a non-interactive path (answers given in the request, or no AskUserQuestion):
  use the given answers, default the rest and say which. Interactive stays the default.

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
