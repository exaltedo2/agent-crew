# agent-crew

A reusable, domain-free multi-agent team for [Claude Code](https://claude.com/claude-code).
It gives every project the same small crew with cheap defaults, fixed hand-over rules,
a cost ledger, and hooks that keep the expensive orchestrator disciplined.

Made by an AI under human direction. MIT licensed. No project or domain knowledge is
inside: each project describes itself in `.claude/team/PROJECT.md`.

## The crew

| Agent | Job | Default model / effort |
|---|---|---|
| `lead` | Orchestrator. Talks to you, routes work, never edits project files. | opus / high |
| `thinker` | Critique and ideas. Writes only a report. | sonnet / high |
| `architect` | Options, a recommendation, a numbered task list for the coder. | opus / high |
| `coder` | Implements a plan, runs **all** the project's checks, branch + PR. | sonnet / medium |
| `reviewer` | Adversarial review: tries to disprove the change. | sonnet / medium |
| `scout` | Facts-only search: paths and line numbers. | haiku / low |

Skills: `crew-bootstrap` (set a project up), `crew-retro` (measure, prune, propose),
`crew-hire`, `crew-retire`. More roles to hire from live in `catalog/` (`tester`,
`ui-reviewer`, `security-reviewer`, `docs-writer`, `perf-profiler`). The generic rules
and the evidence behind them are in [docs/RULES.md](docs/RULES.md).

## Install

Requirements: Claude Code, Windows PowerShell 5.1 or PowerShell 7, git.

```powershell
git clone https://github.com/exaltedo2/agent-crew
cd agent-crew
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

It copies:

| From | To |
|---|---|
| `agents/*.md` | `~/.claude/agents/` |
| `skills/*` | `~/.claude/skills/` |
| `hooks/`, `scripts/`, `data/`, `templates/`, `catalog/`, `docs/RULES.md`, `VERSION` | `~/.claude/agent-crew/` (the hooks run from here) |
| `templates/USER.md` | `~/.claude/team/USER.md`, **only if missing** |

and merges five hook entries into `~/.claude/settings.json` (a backup is made first; running
it again never duplicates entries; your other settings are kept). What was installed, with
a hash of each file, is recorded in `~/.claude/agent-crew/installed.json`.

Flags: `-ClaudeHome <path>` (default `$HOME\.claude`; use a temp folder to try it),
`-NoSettings` (do not touch settings.json), `-Update`, `-Uninstall`.

macOS / Linux / Git Bash: `./install.sh` (best effort; flags `--claude-home DIR`
`--no-settings` `--update` `--uninstall`; needs `python3` for the settings merge and
PowerShell 7 `pwsh` to run the hooks). It is much less tested than the PowerShell installer.

Then, in a project: start Claude Code with `claude --agent lead` (the bootstrap also proposes
`"agent": "lead"` for the project's `.claude/settings.local.json`). The lead finds no
`.claude/team/` and runs the `crew-bootstrap` skill: it reads your repo, asks about five
questions, proposes a minimal roster, writes its own team files, and has the coder add `PROJECT.md`,
the settings file and the `.gitignore` lines through a pull request.

### Update

```powershell
cd agent-crew; git pull
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Update
```

`-Update` replaces a file only if it is still exactly what the installer wrote. A file you
edited (or that already existed) is never overwritten: the new version is written next to it as
`<file>.new` for you to merge. Files removed upstream are removed if you did not edit them.
A plain re-run (no `-Update`) only fills in missing files and tells you which updates are
pending. After an update, projects get a one-line notice at session start if their
`PROJECT.md` `agent_crew_version` differs; see [CHANGELOG.md](CHANGELOG.md).

### Uninstall

`install.ps1 -Uninstall` removes the files it installed (the ones you edited are kept), the
`.new` files and the five hook entries (backup first). Project `.claude/team/` folders are not
touched; delete them yourself.

## Precedence and project overrides

Claude Code resolves an agent or skill of the same name in this order:
**project `.claude/agents/` > user `~/.claude/agents/` > plugin**. So:

- To change an agent for one project only, put a file with the same name in the project's
  `.claude/agents/` (it replaces the user-level one completely), or, usually better, add a
  small **role addendum** `.claude/team/roles/<agent>.md`: every crew agent reads its own
  addendum, so you only write what differs.
- Project facts (commands, hazards, branching, who merges) go in `.claude/team/PROJECT.md`.
- Chat language and personal preferences go in `~/.claude/team/USER.md`. On the language of
  the chat USER.md wins; on repository content PROJECT.md wins.

Plugin install is **not supported**: `.claude-plugin/plugin.json` only exists so
`claude plugin validate` can check the folder. The hooks are registered in the user's
settings.json by the installer and run from the installed copy. Use the installers.

## What lives in a project: `.claude/team/`

| File | Purpose | Cap |
|---|---|---|
| `PROJECT.md` | written by the coder, never by the lead. Front matter (`agent_crew_version`, `lead_writable` (default empty), `direct_to_main`, `report_only_agents`) + Context, Commands, Hazards, Conventions, Decision policy, Lead may run | |
| `routing.md` | model and effort per job, Evidence, Learned rules | 150 lines |
| `roster.md` | active agents (why, evidence, trial/kept, uses, retire criterion), retired | 80 lines |
| `state.md` | goal, open tasks, running agents, pending decisions, index. Not a log. | 50 lines |
| `roles/<agent>.md` | optional rule addendum for one agent | |
| `reports/` | long agent output (gitignored); agents return the path | |
| `snapshots/`, `compact_log.md`, `.last-retro` | hook output (gitignored) | |

`scripts/check-team.ps1 -Project .` validates caps, that active roster agents have agent
files, at most 7 active agents, and one-line agent descriptions.

## Hooks

All hooks are PowerShell scripts that do nothing when there is no `.claude/team` folder, and
fail open (a broken hook never blocks work). They read the hook JSON from stdin
(`cwd`, `tool_input.file_path`, `agent_type`, `source`, `trigger`, `compact_summary`).

| Hook | Event | Does |
|---|---|---|
| `guard-paths` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit` | Lead may write only `.claude/team/**` (except `PROJECT.md`) and `~/.claude/team/**`, plus the `lead_writable` globs (never settings, hooks or PROJECT.md). thinker, architect, reviewer (+ `ui-reviewer`, `security-reviewer`, `perf-profiler`, + `report_only_agents`) may write only `.claude/team/reports/**`. Others unrestricted. Blocks with exit 2 and a reason. |
| `check-caps` | PostToolUse, same matcher | Warns (never blocks) when state/routing/roster are over their cap. |
| `pre-compact` | PreCompact | Copies `state.md` to `snapshots/`, keeps the newest 5. |
| `post-compact` | PostCompact | Appends trigger and summary to `compact_log.md`, keeps the newest 20. |
| `session-start` | SessionStart | After a compaction: prints `state.md` and says it is authoritative. On start/resume: asks for the retro when `.last-retro` is missing or over 7 days old or a file is over its cap; notes a version mismatch. |

### Limits

- `guard-paths` sees only the **file-edit tools** (Edit, Write, MultiEdit, NotebookEdit). The lead,
  reviewer, security-reviewer and perf-profiler also have Bash or PowerShell, and a file written
  through those is not seen. For the lead, writing files through Bash/PowerShell is forbidden by its
  prompt, not by the hook: it is a guard rail against mistakes, not a sandbox.
- The lead can never edit `PROJECT.md`, `.claude/settings*.json` or hook scripts with the edit tools,
  even if `lead_writable` lists them (so it cannot widen its own rights or switch the guard off);
  those changes go through the coder. Paths are resolved through junctions and symlinks first.
- The identity check relies on the hook input field `agent_type`; without it the guard allows.
- The guard is registered **once**, in `~/.claude/settings.json` (not in the agent files).
  `install.ps1 -NoSettings` therefore means no guard at all.
- Cost: every hook is a fresh `powershell.exe` start, about 350 ms each even when it does nothing
  (measured on one Windows machine). An Edit or Write call pays for two (guard before, caps after),
  about 0.7 s. The guard reads stdin and exits before loading anything when there is no
  `agent_type`, but the process start itself cannot be avoided.

## Cost ledger

```powershell
powershell -NoProfile -File ~\.claude\agent-crew\scripts\ledger.ps1 -Project . -Alias bug-hunter=reviewer -Since 2026-10-01 -Format md
```

Reads the project's transcripts under `~/.claude/projects/<slug>/` (main sessions and
`<session>/subagents/agent-*.jsonl` with their `.meta.json`), removes streaming duplicates per
request id, and sums input, cache write (5 min / 1 hour), cache read and output tokens per
agent type, model and effort, with spawn counts and an **estimated** cost. `-Format table|json|md`.
The slug is the project path with every non-alphanumeric character replaced by `-`; Claude Code
shortens and hashes very long paths (over about 200 characters), which this does not handle.

Honest limits: a request that appears in both a main and a subagent transcript is counted once and
attributed to the subagent; transcript lines that PowerShell 5.1 cannot parse (for example over 2 MB)
are NOT counted, and the output starts with a warning with their number; long-context and fast-mode
price tiers are not modelled.

**Prices are a guess.** `data/prices.json` holds best-known list prices per model id (the longest
matching prefix wins, so older Opus ids are priced higher than the 4.5 class). A model id without an
exact entry is priced by its family fallback and the ledger prints a warning naming it. The file is
marked `GUESS, verify`; the docs page could not be fetched when it was written. Check
<https://docs.claude.com/en/docs/about-claude/pricing> and fix the file before trusting a dollar
figure. Token counts are exact.

## Settings template

`templates/settings.local.json` (written by the bootstrap into a project's
`.claude/settings.local.json`) contains `"agent": "lead"`, `"autoCompactWindow": 350000` and
`"idleCompaction": true`. JSON has no comments, so here is the explanation: **the two compaction
values are guesses**, chosen to compact the lead's long context earlier than the default so it
is re-read fewer times. Tune them against the ledger. `idleCompaction` compacts while a session
is idle, before the prompt cache expires.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

Plain PowerShell, no Pester. Runs the ledger and `check-team` on fixtures, every hook with sample
stdin, and the installer against a temp folder (install twice, `-Update` with an edited file,
`-Uninstall`).

## Not verified yet

- That the settings.json PreToolUse hook really blocks the lead's edit in a live session (the script
  is tested by feeding it JSON; no live Claude Code session was used).
- That `agent_type` is present in the hook input of the lead when it runs as the main session
  through the `agent` setting. The Claude Code binary documents it for `--agent` sessions and
  subagents; the guard does nothing if it is missing.
- `install.sh` on a real macOS / Linux machine.
- The numbers in `data/prices.json` and `templates/settings.local.json`.
