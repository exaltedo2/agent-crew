---
name: crew-retire
description: Retires an agent that is unused or redundant: moves it to the roster's Retired list with the reason, and deletes its project file only after the user's OK. With team_autonomy auto the retirement itself needs no OK. Use during the retro or when an agent keeps being skipped.
---

# crew-retire

Run by the lead. With `team_autonomy: ask` (the default) the lead proposes and the user approves
in one line. With `auto` (PROJECT.md value, else USER.md value; see `crew-hire` "Autonomy") the
lead retires by the criteria below without asking and tells the user one line: which agent and why.
Deleting the agent file asks in both modes (deleting files always needs consent).

## When to retire

- the agent had **0 spawns in the last 5 merged features or pull requests** (check with
  `scripts/ledger.ps1` and `git log`); or
- another agent already does the same job (redundant); or
- a `trial` agent was judged after 3 uses and did not earn its place; or
- (`auto`) a `trial` agent's ledger share since its hire is over 10% of total usage.

Core agents (lead, coder, reviewer, scout) are not retired by this rule unless the user says so.

## Steps

1. Propose in at most 4 lines: which agent, the evidence (spawn counts, overlap), where its
   useful knowledge goes. Wait for a one-line OK. (`auto`: send this as the one-line notice
   instead of waiting.)
2. Move its row in `roster.md` from Active to Retired: `name | date | reason | where its
   knowledge went`. Remove or adjust its rows in `routing.md`. Retiring means this move plus
   disabling the agent (no more routing to it); its file stays until step 4. In `auto`, add one
   line under `routing.md` Evidence (what, why, cost).
3. Keep what was learned: move its rules into a role addendum of the agent that takes over,
   or into `routing.md` "Learned rules".
4. The agent file itself (asks in `auto` too): delete a **project** agent file (`.claude/agents/<name>.md`) only
   after the user said OK to deleting it (it is a repository file: a `coder` job on a branch).
   User-wide agent files in `~/.claude/agents/` belong to the installer: never delete them here.
5. Run `check-team.ps1 -Project .` (it fails if the roster lists an agent whose file is gone).
