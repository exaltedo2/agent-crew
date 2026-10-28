---
name: crew-retire
description: Retires an agent that is unused or redundant: moves it to the roster's Retired list with the reason, and deletes its project file only after the user's OK. With team_autonomy auto the retirement of an automatically hired agent needs no OK. Use during the retro or when an agent keeps being skipped.
---

# crew-retire

Run by the lead. With `team_autonomy: ask` (the default) the lead proposes and the user approves
in one line. With `auto` (only if USER.md says so; see `crew-hire` "Autonomy") the lead retires
**agents it hired automatically** (Evidence cell starting `auto:`, still `trial` or `kept` after such a
trial) by the criteria below without asking, and tells the user one line: which agent and why.
Core agents, agents created by `crew-bootstrap` and agents the user approved still ask, in both modes.
Deleting the agent file asks in both modes (deleting files always needs consent).

## When to retire

- the agent had **0 spawns in the last 5 merged features or pull requests** (check with
  `scripts/ledger.ps1` and `git log`); count only features merged **after its hire date** (`Since`), and at
  least 5 of them; or
- another agent already does the same job (redundant); or
- a `trial` agent was judged after 3 uses, or at the age limit (fewer than 3 uses after 5 merged features
  or 14 days), and did not earn its place; or
- (`auto`) a `trial` agent's weighted share of all usage since its hire date is over 10%.

Core agents (lead, coder, reviewer, scout) are not retired by this rule unless the user says so.

## Steps

1. Propose in at most 4 lines: which agent, the evidence (spawn counts, overlap), where its
   useful knowledge goes. Wait for a one-line OK. (`auto`, automatically hired agents only: send this as
   the one-line notice instead of waiting.)
2. Move its row in `roster.md` from Active to Retired: `name | date | reason | where its
   knowledge went`. In `auto` start the reason with `auto:` (`crew-hire` uses it for its 10-feature
   cooldown). Remove or adjust its rows in `routing.md`. **Retiring means exactly this**: the row
   leaves Active and the lead no longer routes to the agent. The agent file is not renamed, edited or
   deleted by this step (it stays until the user OKs step 4). In `auto`, add one line under
   `routing.md` Evidence (what, why, cost).
3. Keep what was learned: move its rules into a role addendum of the agent that takes over,
   or into `routing.md` "Learned rules".
4. The agent file itself (asks in `auto` too): delete a **project** agent file (`.claude/agents/<name>.md`) only
   after the user said OK to deleting it (it is a repository file: a `coder` job on a branch).
   User-wide agent files in `~/.claude/agents/` belong to the installer: never delete them here.
5. Run `check-team.ps1 -Project .` (it fails if the roster lists an agent whose file is gone).
