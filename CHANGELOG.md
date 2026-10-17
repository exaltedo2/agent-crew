# Changelog

All notable changes to agent-crew. The version is in `VERSION`; a project's
`.claude/team/PROJECT.md` records the version it was written for (`agent_crew_version`), and
the session-start hook says when it differs from the installed one.

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
