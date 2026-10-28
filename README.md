# agent-crew

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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

## Models

Models are handled by **family**, never by exact version. `data/prices.json` has one entry per
family (`opus`, `sonnet`, `haiku`, `fable`), each with `match` words and prices. A model id is
priced by an `overrides` entry with the longest matching prefix first (for example older Opus
versions at higher prices), else by the family whose word appears in the id (case-insensitive:
`claude-opus-5-6`, `opus` and `claude-3-5-sonnet-20241022` all work). A **new version of a known
family needs nothing**.

A **whole new family** is data too. If a model's family is unknown, the ledger prices it with the
`default` entry (a rough mid-tier weight), prints ONE warning naming the model, and carries on.
To price it properly, add the family to `~/.claude/team/prices.local.json`, which is merged over
`data/prices.json` and survives updates:

```json
{ "families": { "zephyr": { "match": ["zephyr"], "input": 4.0, "output": 20.0,
                            "cache_write_5m": 5.0, "cache_write_1h": 8.0, "cache_read": 0.4 } } }
```

If two families match one id, the first in file order wins (the base file before the local one,
so a local family cannot take over an id a base family already matches; put the id in an
`overrides` prefix instead). A local file can add or replace entries but cannot delete a base
entry. A malformed local file, or an entry without all five numeric prices (or without `match`),
is skipped with a warning; the ledger never crashes on it.

(`families` entries add or replace by name, `overrides` entries are added, `default` replaces
the default.) Model names in `USER.md` and `routing.md` are free-form aliases, whatever Claude
Code accepts; nothing validates them, and `scripts/check-team.ps1` only warns when a routing row
names a model that is not in USER.md "Available models" and has no Fallback.

**Optional models.** `USER.md` lists "Available models" (default `opus, sonnet, haiku`) and
"Never use". The lead uses only available models; a routing row with an unavailable model uses
its Fallback column. To enable `fable`: add it to Available models and keep the two optional
`fable` rows in `routing.md`. `fable` is an official model alias in Claude Code, but its prices
in `data/prices.json` are a pure guess: set real ones in `prices.local.json`.

**Settings that override routing.** `CLAUDE_CODE_EFFORT_LEVEL` beats every agent's and every call's effort;
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` beats every model (`CLAUDE_CODE_SUBAGENT_MODEL` alone only fills in
where nothing else sets a model). **Agent teams:** with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, named
subagent calls may launch as teammates (different cost, no resume, plans approved automatically). agent-crew
expects that flag off. `check-team` warns when any of these is set, in the environment or in the `env` block
of the user or project `settings.json`.

**Agent frontmatter guards.** `scout` has `omitClaudeMd: true` (it only looks things up, so it skips
CLAUDE.md) and `scout` / `reviewer` have `maxTurns` (40 / 80) as a runaway guard. The two `maxTurns` values
are guesses: raise them if an agent is cut off on a legitimate task.

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

and merges the hook entries (12 with the defaults) into `~/.claude/settings.json` (a backup is made first; running
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
`.new` files and the hook entries (backup first). Project `.claude/team/` folders are not
touched; delete them yourself.

## Autonomous team (opt-in)

By default (`team_autonomy: ask`) the lead only proposes hiring or retiring an agent and waits for
your one-line OK. Set `team_autonomy: auto` in the front matter of `~/.claude/team/USER.md` (every
project) or of a project's `.claude/team/PROJECT.md` (the project value wins; a missing or unknown
value means `ask`) and the lead changes the team itself and tells you one line per change:

- **Hire** when a trigger fires: the same 300+ word paste in 3+ briefs, a failure class that keeps
  slipping through, or a roster "Candidates later" condition that became true (for example
  "ui-reviewer once screens exist"). The agent starts as `trial`. At most one trial agent at a
  time, and the 7-agent cap holds.
- **Trial guardrails.** A trial agent gets only small or medium jobs: one bounded task, sonnet / medium
  at most, never opus, xhigh or max. A big job for it (cross-system, opus or high effort, a long run)
  needs your one-line OK, the only question during a trial. Its ledger share since the hire must stay at
  or under 10% of total usage, or the lead retires it.
- **Judgement after 3 trial uses** (at the retro or right away): did it catch the failure class, remove
  the repeated paste, and cost less than the baseline? The lead marks it `kept` or retires it, and tells you.
- **Retire** by the `crew-retire` criteria (0 spawns in 5 merged features, or redundant) without asking:
  the agent moves to the roster's Retired list with its reason and where its knowledge went. **Deleting an
  agent file still asks you.**
- Each automatic change gets one line under `routing.md` Evidence (what, why, cost). Restart the session
  to load a new or retired agent.

`check-team` accepts the key, warns about other values, prints an INFO when `auto` is in effect, and warns
when more than one agent is `trial`. With `ask` nothing changes.

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
- `team_autonomy` (`ask` | `auto`, see "Autonomous team") is set in USER.md and may be overridden in
  PROJECT.md; there the project value wins.

Plugin install is **not supported**: `.claude-plugin/plugin.json` only exists so
`claude plugin validate` can check the folder. The hooks are registered in the user's
settings.json by the installer and run from the installed copy. Use the installers.

## What lives in a project: `.claude/team/`

| File | Purpose | Cap |
|---|---|---|
| `PROJECT.md` | written by the coder, never by the lead. Front matter (`agent_crew_version`, `lead_writable` (default empty), `direct_to_main`, `report_only_agents`, optional `team_autonomy`) + Context, Commands, Hazards, Conventions, Decision policy, Lead may run | |
| `routing.md` | model and effort per job, Evidence, Learned rules | 150 lines |
| `roster.md` | active agents (why, evidence, trial/kept, uses, retire criterion), retired | 80 lines |
| `state.md` | goal, open tasks, running agents, pending decisions, index. Not a log. | 50 lines |
| `roles/<agent>.md` | optional rule addendum for one agent | |
| `reports/` | long agent output (gitignored); agents return the path | |
| `snapshots/`, `compact_log.md`, `.last-retro` | hook output (gitignored) | |

`scripts/check-team.ps1 -Project .` validates caps, that active roster agents have agent
files, at most 7 active agents, and one-line agent descriptions; it warns when more than one agent is
`trial` and about an unknown `team_autonomy` value.

## Hooks

All hooks are PowerShell scripts that do nothing when there is no `.claude/team` folder, and
fail open (a broken hook never blocks work). They read the hook JSON from stdin
(`cwd`, `tool_input.file_path`, `agent_type`, `source`, `trigger`, `compact_summary`).

| Hook | Event | Does |
|---|---|---|
| `guard-paths` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit` | Lead may write only `.claude/team/**` (except `PROJECT.md`) and `~/.claude/team/reports/**` (never USER.md or ram-guard.json there), plus the `lead_writable` globs (never settings, hooks or PROJECT.md) and, outside the project, the optional `lead_writable` list in `~/.claude/team/USER.md` (absolute or `~`-relative globs, e.g. `~/.claude/notes/**`; never settings*.json, hooks, agent files, PROJECT.md, anything inside a git repository (work tree or bare), anything in `~/.claude` except `notes/**`, shell profiles, `.ssh`, Startup folders, `.gitconfig` or credential spots (`.npmrc`, `.aws`, `.config/gh`, `.docker/config.json`, `.netrc`, `.git-credentials`); relative globs and globs starting at a drive root or the home folder are ignored; 8.3 short names are expanded first; an error while checking any lead write denies it, and the message lists what the lead may write; other agents fail open). thinker, architect, reviewer (+ `ui-reviewer`, `security-reviewer`, `perf-profiler`, + `report_only_agents`) may write only `.claude/team/reports/**`. Others unrestricted. Blocks with exit 2 and a reason. |
| `ram-guard` | PreToolUse `Agent\|Task`, and `Bash` / `PowerShell` with an `if` filter such as `Bash(claude *)` | Blocks starting new heavy work (a subagent, or a command matching a configured pattern) while free memory is below that job kind's threshold. Exit 2 and a reason; never kills anything. See [RAM guard](#ram-guard). |
| `no-session-links` | PreToolUse `Bash` / `PowerShell`, with `if` filters `*git *` and `*gh *` (the script then finds `git commit` / `commit-tree` / `notes` / `tag` and `gh pr`/`issue` `create`/`edit`/`comment` anywhere in the line: `git -C x commit`, `cd x && git commit`, `gh -R o/r pr create`) | Denies (exit 2, with a reason) a command whose text, or whose `-F` / `--file` / `--body-file` file, contains a session link (a `Claude-Session:` trailer or a `claude.ai/code/session` URL) that Claude Code's own attribution text can add. Allowed when `allow_session_links: true` is in the front matter of `~/.claude/team/USER.md`. Fails open; does not see stdin (`-F -`). Time for a command it ignores: about 290 ms on one Windows machine (10 runs, average; almost all of it is the `powershell.exe` start, the script exits right after parsing the command), and it is only started for commands the `*git *` or `*gh *` filter selects. |
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
  those changes go through the coder. The same holds for the USER.md list, which also never reaches into a git
  repository (code changes stay on the PR path); `check-team` warns about such entries. Paths are resolved through junctions and symlinks first.
- The identity check relies on the hook input field `agent_type`; without it the guard allows.
- The guard is registered **once**, in `~/.claude/settings.json` (not in the agent files).
  `install.ps1 -NoSettings` therefore means no guard at all.
- `ram-guard` is registered for every Agent / Task call and, through an `if` filter, only for the Bash and
  PowerShell commands that can match its patterns (cost and consequences under [RAM guard](#ram-guard)).
- Cost: every hook is a fresh `powershell.exe` start, about 350 ms each even when it does nothing
  (measured on one Windows machine). An Edit or Write call pays for two (guard before, caps after),
  about 0.7 s. The guard reads stdin and exits before loading anything when there is no
  `agent_type`, but the process start itself cannot be avoided.

## RAM guard

Agents run heavy things (subagents, test suites, game engines, headless `claude`) while you work on
the same PC. The `ram-guard` hook stops **new** work when free physical memory is low, so the machine
does not freeze at 100% RAM. It blocks with exit 2 and tells the model: `free RAM 900 MB < needed
1500 MB for 'agent-spawn'`, wait for running work to finish, do not retry in a loop, tell the user.
It **never kills** anything and never touches work that is already running. `lead.md` carries the
matching one-line instruction.

**Kinds of jobs.** A kind has a name, `min_free_mb`, and what it matches:

- `tools: ["Agent", "Task"]` matches **every** subagent spawn (patterns do not apply to spawns, so a
  `patterns`-only override of such a kind does not turn it off).
- `patterns` (regular expressions, case-insensitive, **200 ms match timeout**: a pattern that times out or
  does not compile is skipped with a warning) are matched against the Bash/PowerShell command. With
  patterns and no `tools`, the tools default to Bash and PowerShell. A kind for shell commands with no
  valid pattern is skipped with a warning; it never matches every command.
- When several kinds match one call, the highest `min_free_mb` decides.

Shipped defaults (`data/ram-guard.json`, **all numbers are guesses**, tune them):

| Kind | Matches | Needs free |
|---|---|---|
| `agent-spawn` | every Agent / Task call | 1500 MB |
| `claude-headless` | `claude -p` / `claude --print` **at the start of a command** (also after `;` `&&` `\|\|` `\|` `$(` or a newline, after `VAR=x`, with a path or `.exe`); not inside quotes (`git commit -m "document claude -p"`) and not as an argument (`echo claude -p`, `grep 'claude -p'`) | 2500 MB |

A heavy job started inside a quoted string (`bash -c "claude -p ..."`) or by a script that starts it is not
seen: the guard looks only at the tool name and the command text. No project-specific commands are shipped.

**Override files**, merged in this order: shipped `data/ram-guard.json` < `~/.claude/team/ram-guard.json`
(the user, or `$CLAUDE_CONFIG_DIR/team/`) < `<project>/.claude/team/ram-guard.json` (commit it with the
project).

**Trust boundary.** The user file may change anything: replace a kind of the same name field by field,
lower a threshold, `"enabled": false` for the whole guard or one kind, `"project_max_mb"` (below),
`"scan_all_commands"` (below). The **project** file is in the repository, where an agent can edit it, so it
may only make things **stricter**: add kinds, add patterns and tools to a kind (never remove the inherited
ones), raise `min_free_mb`, but never above the user's `project_max_mb` (default **8000**, a guess; a higher
request is lowered to it). It cannot lower a threshold, switch the guard or a kind off, or set
`project_max_mb`: such entries are ignored with a warning. Example project file for a heavy engine:

```json
{
  "kinds": {
    "my-engine": {
      "description": "headless run of my-engine",
      "patterns": ["(^|[;&|\\n(])\\s*my-engine\\s+--headless", "\\bmy-tests\\b"],
      "hook_if": ["my-engine *"],
      "min_free_mb": 4000
    },
    "agent-spawn": { "min_free_mb": 2000 }
  }
}
```

JSON has no comments, so: the backslash is written twice inside the strings, and `my-engine` and the numbers
are placeholders.

**Fails open.** An unparseable file, a non-object, a wrong type, a bad regular expression or an incomplete
kind is skipped with a warning (the lower files still apply; `scripts/check-team.ps1` reports them: a bad
project file is a problem, a bad user file a warning). If free memory cannot be read, the call is allowed
with a warning. Warnings reach the model once per 12 hours per text (marker files in the temp folder).

**Free memory** is the OS's "available" memory (free plus cache that can be dropped): Windows via
`Microsoft.VisualBasic.Devices.ComputerInfo` (fallback CIM), Linux `MemAvailable` in `/proc/meminfo`,
macOS `vm_stat` (free + inactive + speculative pages). Only the Windows reader has been run.

**Cost, and why the shell entries have an `if`.** Every hook run is a fresh `powershell.exe`. Measured by
hand on one Windows machine (Windows PowerShell 5.1): the ram-guard process takes about 510-540 ms in total,
of which about 275 ms is the bare process start (the `guard-paths` no-op takes that long); so the
script's own work is about 240-260 ms, mostly cold PowerShell and loading the JSON reader. That is too slow
to pay on every Bash call, so the installer registers `Agent|Task` unconditionally, but the Bash and
PowerShell entries with Claude Code's hook `if` filter
([permission rule syntax](https://code.claude.com/docs/en/hooks)), e.g. `Bash(claude *)`, built from the
`hook_if` command globs of the kinds in the shipped file and **your user file**. An ordinary command then
does not start the hook at all (documented behaviour; not observed in a live session). Consequences:

- After you change `hook_if` or add a shell kind to your own `ram-guard.json`, **re-run `install.ps1`** so
  the filters are rebuilt (`-Update` is not needed for this, the hook entries are always refreshed).
- A user kind with `patterns` but no `hook_if`, or `"scan_all_commands": true` in the user file, makes the
  installer register one unfiltered `Bash|PowerShell` entry instead: every shell command pays about half a
  second.
- A **project** kind's patterns are only reached if its commands also pass a `hook_if` filter that is
  installed, which the user-wide installer cannot know. Either add the project's commands to your user file
  (`hook_if`), set `scan_all_commands`, or add a hook entry to the project's `.claude/settings.json`
  that runs the installed `~/.claude/agent-crew/hooks/ram-guard.ps1` with an `if` rule for that command.
  The `hook_if` in a project file is documentation for this; the installer does not read it.
- A Claude Code version without the `if` field would run the entries unfiltered (slow, still correct).

Tests fake the free memory with the environment variable `AGENT_CREW_FREE_MB` (a number, or
`unreadable`) and the user folder with `AGENT_CREW_USER_DIR`; they are not meant for normal use.

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

**Share of usage.** By default (`-Mode usage`) every table has a `Share %` column (the row's cost
weighted by model price, over the total) and no dollar figures, which fits subscription limits.
`-Mode cost` adds the estimated dollars and total; use it only if you pay per token. The JSON
format always carries both.

Honest limits: a request that appears in both a main and a subagent transcript is counted once and
attributed to the subagent; transcript lines that PowerShell 5.1 cannot parse (for example over 2 MB)
are NOT counted, and the output starts with a warning with their number; long-context and fast-mode
price tiers are not modelled.

**Prices are a guess.** `data/prices.json` holds best-known list prices per model family (see
[Models](#models)). The file is
marked `GUESS, verify`; the docs page could not be fetched when it was written. Check
<https://docs.claude.com/en/docs/about-claude/pricing> and fix the file before trusting a dollar
figure. Token counts are exact.

## Sessions load agents at start

New agents, agent tool allowlists and skills load only when a session starts. After installing
agent-crew, or after hiring or retiring, restart the session (a resumed session also reloads).

## Bootstrap is interactive

`crew-bootstrap` writes under `.claude/team/`, which Claude Code treats as sensitive: you approve
the first writes. A headless run (`-p` with `acceptEdits`) refuses them; the skill then writes its
drafts to a temp path and tells you which files to approve or copy (or hands them to the `coder`).
It detects the repo's default branch (`origin/HEAD`, else the current branch) instead of
assuming `main`.

## Settings template

`templates/settings.local.json` (written by the bootstrap into a project's
`.claude/settings.local.json`) contains `"agent": "lead"` and `"idleCompaction": true`
(a documented setting; compacts an idle session before the prompt cache expires). The compact
window is not in it: see "Long sessions".

## Long sessions

The lead's context is re-read on every turn, so a session that never compacts gets expensive. The
lead's compaction point comes from settings, not from the agent file: the `autoCompactWindow`
in an agent's front matter does not apply when the agent is the main session (`claude --agent lead`).

- **The lead owns the window.** It lives in `.claude/team/session.json`
  (`{"lead_compact_window": 200000, "reason": "...", "updated": "..."}`, gitignored, written by the
  lead; the lead may edit it, hooks and settings stay off limits). `crew-bootstrap` writes the first
  value, a **guess**: small repo and short tasks 150000, typical 200000, large repo with long design
  discussions 250000. `crew-retro` compares it with the lead's real context per turn and compactions
  and the lead adjusts it, telling you in one line; no pull request. Range 100000-400000 (clamped).
- **How it reaches Claude Code.** The `session-start` hook copies the value into `autoCompactWindow`
  of the project's `.claude/settings.local.json` and touches no other key or file (atomic write,
  skipped when unchanged, a missing or invalid `session.json` leaves settings alone and warns). It
  takes effect from the next session start; whether a running session picks up a settings change is
  not verified.
- **What wins.** Documented order, highest first: managed (policy) settings, env
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (process environment or the `env` block of a settings file), the
  `--autocompact` flag, `modelSettings.<model>.autoCompactWindow` (written by `/autocompact`), then top-level
  `autoCompactWindow` (local beats project beats user). So the hook writes to `settings.local.json` and a
  user top-level key does not win; but if it finds an env var (also in an `env` block), a `modelSettings`
  entry or a managed value it does not fight it: it leaves settings alone and warns that the other value wins.
  The `--autocompact` flag cannot be seen by scripts. Managed settings paths are the documented per-OS
  ones, written from memory (unverified): `C:\Program Files\ClaudeCode\managed-settings.json`,
  `/Library/Application Support/ClaudeCode/managed-settings.json`, `/etc/claude-code/managed-settings.json`.
  `check-team` validates `session.json`, prints the effective value and the winning source, says when
  there is no `session.json` (the lead should create it), and warns about overrides and `idleCompaction: false`.
- **Your file stays yours.** The hook edits `settings.local.json` as text: it replaces only the number (or
  inserts the key after the opening brace), never reformats or re-escapes, and leaves a file with comments
  untouched with a warning. Writes go through a unique temp file and an atomic replace (retried a few
  times; a short-lived `*.bak` made by the replace is deleted, so a stray `*.bak` means a crash). It also
  adds `.claude/team/session.json` to the project `.gitignore` once (git work trees only).
- **Idle compaction.** `idleCompaction` (default true) compacts a session that has been idle about
  54 minutes (the 1h cache lifetime) instead of re-reading the whole context cold.
- **After a compaction** the lead re-reads `.claude/team/state.md`, which is authoritative for open
  tasks and running agents (the session-start hook prints it).

Existing projects may still have an old local `autoCompactWindow` (earlier templates carried 350000): the
hook replaces it with the `session.json` value.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

Plain PowerShell, no Pester. Runs the ledger and `check-team` on fixtures, every hook with sample
stdin (the RAM guard with a faked free-memory value), and the installer against a temp folder (install twice, `-Update` with an edited file,
`-Uninstall`).

Opt-in end-to-end test of `crew-bootstrap` (NOT part of `run.ps1`, it spends real usage, capped
by `-MaxBudgetUsd`, default 3):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e-bootstrap.ps1 [-Keep] [-Model sonnet]
```

It makes a temp git project on a branch called `trunk`, runs `claude -p --agent lead` in it with
the bootstrap answers given up front (the skill's non-interactive path), and checks the four team
files, the default branch and `agent_crew_version` in `PROJECT.md`, and `check-team`. It uses
your real installed `~/.claude` (agent-crew must be installed) and does not modify it; the skill
under test is the one in this checkout.

## Not verified yet

- That the settings.json PreToolUse hook really blocks the lead's edit in a live session (the script
  is tested by feeding it JSON; no live Claude Code session was used).
- That `agent_type` is present in the hook input of the lead when it runs as the main session
  through the `agent` setting. The Claude Code binary documents it for `--agent` sessions and
  subagents; the guard does nothing if it is missing.
- `install.sh` on a real macOS / Linux machine, and the Linux / macOS free-memory readers of the RAM guard.
- That the RAM guard hook really blocks an Agent / Bash call in a live Claude Code session (the script is
  tested by feeding it JSON), and whether the Agent tool is called `Agent` or `Task` in the hook input
  (both are matched).
- The RAM guard thresholds (1500 / 2500 MB): guesses.
- That Claude Code really skips the Bash / PowerShell ram-guard entries for commands that do not match their
  `if` filter (documented at code.claude.com/docs/en/hooks, not observed in a live session).
- The numbers in `data/prices.json` and `templates/settings.local.json`.
