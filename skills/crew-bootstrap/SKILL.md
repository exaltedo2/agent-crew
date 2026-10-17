---
name: crew-bootstrap
description: Sets up the agent team in a project that has no .claude/team folder yet. Reads the project, asks about five questions, proposes a minimal roster, and writes .claude/team/ from the agent-crew templates. Use when the lead finds .claude/team missing.
---

# crew-bootstrap

Run by the lead, once per project. Crew files live in `~/.claude/agent-crew/` (called
`$CREW` below; on Windows `$HOME\.claude\agent-crew`): `templates/`, `catalog/`, `scripts/`,
`VERSION`. If `$CREW` does not exist, tell the user to run the agent-crew installer and stop.

Bootstrap is **interactive**: Claude Code treats writes under `.claude/` as sensitive, so
the user must approve the first writes to `.claude/team/` (a headless run with `-p` and
`acceptEdits` refuses them). Say this up front.

If `.claude/team/` already exists, do not overwrite anything: say so and stop (the user
may ask for a repair; then work file by file and ask before each change).

## 1. Read the project (no questions yet)

Read what exists: `README*`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, CI workflows
(`.github/workflows`), build files (`package.json`, `Makefile`, `pyproject.toml`,
`*.csproj`, `Cargo.toml`, `go.mod`, `tools/`, `scripts/`...). Find:
- the **verify commands**: tests, lint, format check, build, smoke/e2e. Prefer the ones CI runs;
- hazards: anything the docs warn about (ports, processes, generated files, slow steps);
- branching, commit and pull request rules; the main languages;
- the **default branch**: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the
  `origin/`); with no remote or no such ref use the current branch (`git branch --show-current`).
  Never assume it is called `main`; write the real name into PROJECT.md Conventions and into
  every "straight to the default branch" rule.

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

The lead writes the files that are its own (a hook blocks the file-edit tools elsewhere):
- `routing.md` from `$CREW/templates/routing.md`; delete table rows for agents that are not in the roster.
- `roster.md` from the template: only the agents of the roster, status `trial` for catalog roles.
- `state.md` from the template, with the Goal filled and `updated:` set to the current time.
- `.last-retro` containing the current ISO timestamp (so the retro is not due at once).
- no `reports/` or `snapshots/` folder: agents and hooks create them when first needed.

If a write to `.claude/team/` is refused (not approved, or a headless run), do not retry in a
loop: write every draft to the OS temp folder (or a path the user names) and tell the user the
exact files and their target paths to approve or copy; or hand the placement to the `coder`
with the absolute draft paths, as for the files below.

The lead may NOT write `PROJECT.md`, `.claude/settings.local.json` or `.gitignore`. Instead it
drafts them into `.claude/team/reports/bootstrap-PROJECT.md`, `bootstrap-settings.local.json`
and `bootstrap-gitignore.txt`, then gives one `coder` job (sonnet/low) with the absolute draft
paths to put them in place on a branch with a pull request (`PROJECT.md` is committed; the
`.gitignore` lines too):
- `PROJECT.md` from `$CREW/templates/PROJECT.md`: fill Context, Commands (exact commands from
  step 1, with notes), Hazards, Conventions, Decision policy, Lead may run; set
  `agent_crew_version` to the content of `$CREW/VERSION`; set `direct_to_main` only to what the
  user named in question 5; leave `lead_writable: []` unless the user names a safe extra glob.
- `.claude/settings.local.json` from `$CREW/templates/settings.local.json`: if the file exists,
  add only the missing keys. The values are guesses; tell the user they can change them.
- `.gitignore`: add these lines if missing (create the file if needed):

```
.claude/settings.local.json
.claude/team/reports/
.claude/team/snapshots/
.claude/team/state.md
.claude/team/compact_log.md
.claude/team/.last-retro
```

Copy each chosen catalog agent unchanged from `$CREW/catalog/<name>.md` to the project's
`.claude/agents/<name>.md` as part of that same coder job (give it the catalog path).

## 5. Check and report

After the coder job is done, run `powershell -NoProfile -File "$HOME\.claude\agent-crew\scripts\check-team.ps1" -Project .`
(on a machine without PowerShell skip it and say so). Fix what it reports.

The new agents and skills load only when a session starts: tell the user to restart the
session (a resumed session also reloads) before relying on the team.

Tell the user in at most 8 lines: what was created, the roster, the commands you put into
PROJECT.md, what you guessed, and the suggestion to paste
`$CREW/templates/compact-instructions.md` into the project's `CLAUDE.md` (a coder job).
