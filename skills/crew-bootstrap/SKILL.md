---
name: crew-bootstrap
description: Sets up the agent team in a project that has no .claude/team folder yet. Reads the project, asks about five questions, proposes a minimal roster, and writes .claude/team/ from the agent-crew templates. Use when the lead finds .claude/team missing.
---

# crew-bootstrap

Run by the lead, once per project. Crew files live in `~/.claude/agent-crew/` (called
`$CREW` below; on Windows `$HOME\.claude\agent-crew`): `templates/`, `catalog/`, `scripts/`,
`VERSION`. If `$CREW` does not exist, tell the user to run the agent-crew installer and stop.

If `.claude/team/` already exists, do not overwrite anything: say so and stop (the user
may ask for a repair; then work file by file and ask before each change).

## 1. Read the project (no questions yet)

Read what exists: `README*`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, CI workflows
(`.github/workflows`), build files (`package.json`, `Makefile`, `pyproject.toml`,
`*.csproj`, `Cargo.toml`, `go.mod`, `tools/`, `scripts/`...). Find:
- the **verify commands**: tests, lint, format check, build, smoke/e2e. Prefer the ones CI runs;
- hazards: anything the docs warn about (ports, processes, generated files, slow steps);
- branching, commit and pull request rules; the default branch name (`git symbolic-ref
  refs/remotes/origin/HEAD`); the main languages.

Do not run the checks now. Do not edit project files.

## 2. Ask the user (AskUserQuestion, at most 5 questions, offer found answers as options)

1. What is the deliverable (what does "done" look like for a typical task)?
2. How is correctness checked (which of the found commands, anything checked by hand)?
3. Which areas are risky or must never be touched without asking?
4. Which languages: chat with you, repository content (code, comments, commits, docs)?
5. Who approves and merges changes (agents never merge), and may anything go straight to
   the default branch (for example a roadmap file)?

Keep `~/.claude/team/USER.md` in mind: it already answers the chat language and attribution.

## 3. Propose the roster (one message, the user answers in one line)

Minimal core: `lead`, `coder`, `reviewer`, `scout`. Add `thinker` and `architect` only if
the work is design-heavy. Offer catalog roles only with a reason tied to an answer:
`tester` (checks are long and noisy), `ui-reviewer` (there is a visual UI),
`security-reviewer` (auth, secrets, untrusted input), `docs-writer` (docs drift often),
`perf-profiler` (performance matters). At most 7 active agents. Hired catalog agents start
as `trial`.

## 4. Write `.claude/team/`

Create the folder and these files (Write tool; the lead may write `.claude/team/**`):
- `PROJECT.md` from `$CREW/templates/PROJECT.md`: fill Context, Commands (exact commands from
  step 1, with notes), Hazards, Conventions, Decision policy, Lead may run; set
  `agent_crew_version` to the content of `$CREW/VERSION`; set `direct_to_main` only to what the
  user named in question 5; keep `lead_writable`.
- `routing.md` from the template; delete table rows for agents that are not in the roster.
- `roster.md` from the template: only the agents of the roster, status `trial` for catalog roles.
- `state.md` from the template, with the Goal filled and `updated:` set to the current time.
- no `reports/` or `snapshots/` folder: agents and hooks create them when first needed.
- `.last-retro` containing the current ISO timestamp (so the retro is not due at once).

Copy each chosen catalog agent unchanged from `$CREW/catalog/<name>.md` to the project's
`.claude/agents/<name>.md` with a shell copy command (the one exception where the lead
copies a file outside `.claude/team/`; later edits to it go through `coder`).

Write `.claude/settings.local.json` from `$CREW/templates/settings.local.json`: if the file
exists, add only the missing keys. The values are guesses; tell the user they can change
them. Add these lines to `.gitignore` if missing (create the file if needed):

```
.claude/settings.local.json
.claude/team/reports/
.claude/team/snapshots/
.claude/team/state.md
.claude/team/compact_log.md
.claude/team/.last-retro
```

Do not commit anything now: the new files are left as working-tree changes. Tell the user
the `.gitignore` change and `PROJECT.md`, `routing.md`, `roster.md` should be committed
through a normal pull request (the next `coder` job can include them).

## 5. Check and report

Run `powershell -NoProfile -File "$HOME\.claude\agent-crew\scripts\check-team.ps1" -Project .`
(on a machine without PowerShell skip it and say so). Fix what it reports.

Tell the user in at most 8 lines: what was created, the roster, the commands you wrote into
PROJECT.md, what you guessed, and the suggestion to paste
`$CREW/templates/compact-instructions.md` into the project's `CLAUDE.md` (a coder job).
