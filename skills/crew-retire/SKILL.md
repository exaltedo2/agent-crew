---
name: crew-retire
description: Retires an agent that is unused or redundant: moves it to the roster's Retired list with the reason, and deletes its project file only after the user's OK. Use during the retro or when an agent keeps being skipped.
---

# crew-retire

Run by the lead. The lead proposes; the user approves in one line.

## When to retire

- the agent had **0 spawns in the last 5 merged features or pull requests** (check with
  `scripts/ledger.ps1` and `git log`); or
- another agent already does the same job (redundant); or
- a `trial` agent was judged after 3 uses and did not earn its place.

Core agents (lead, coder, reviewer, scout) are not retired by this rule unless the user says so.

## Steps

1. Propose in at most 4 lines: which agent, the evidence (spawn counts, overlap), where its
   useful knowledge goes. Wait for a one-line OK.
2. Move its row in `roster.md` from Active to Retired: `name | date | reason | where its
   knowledge went`. Remove or adjust its rows in `routing.md`.
3. Keep what was learned: move its rules into a role addendum of the agent that takes over,
   or into `routing.md` "Learned rules".
4. The agent file itself: delete a **project** agent file (`.claude/agents/<name>.md`) only
   after the user said OK to deleting it (it is a repository file: a `coder` job on a branch).
   User-wide agent files in `~/.claude/agents/` belong to the installer: never delete them here.
5. Run `check-team.ps1 -Project .` (it fails if the roster lists an agent whose file is gone).
