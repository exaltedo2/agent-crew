---
name: crew-hire
description: Decides how to add a capability to the agent team (role addendum, skill, or new agent) and adds it after the user's one-line OK, or by itself when team_autonomy is auto. Use when the lead pasted the same long instructions into several briefs, a failure class keeps slipping through, or a roster "Candidates later" condition became true.
---

# crew-hire

Run by the lead. `$CREW` is `~/.claude/agent-crew`. With `team_autonomy: ask` (the default; see
"Autonomy") the lead proposes, the user approves in one line, and only then is anything written.

## When to hire

Hire only on evidence, never on a hunch:
- the lead pasted the same 300+ words of instructions into 3 or more briefs; or
- a class of failure keeps slipping through (the reviewer or CI finds the same kind of bug again); or
- a "Candidates later" condition in `roster.md` became true (for example "ui-reviewer once screens exist").
  When you hire it, remove its Candidates-later entry.

State the evidence in the proposal (which briefs, which failures, which condition). Before hiring,
read the roster's Retired list: a name retired in `auto` mode (reason starting `auto:`) is not hired
again for **10 merged features** after its retirement date, unless there is new evidence that the
retirement reason did not cover (record that evidence under `routing.md` Evidence). In `ask` mode the
user decides anyway.

## The ladder: use the cheapest rung that works

1. **Role addendum**: a file `.claude/team/roles/<agent>.md` with extra rules for an agent that
   already exists (every agent reads its own addendum). Best for project-specific rules.
2. **Skill**: a `SKILL.md` for a procedure that several agents or sessions repeat. Put it in
   `.claude/skills/<name>/SKILL.md` (project) or `~/.claude/skills/` (every project).
3. **New agent**: only if the job needs its own tools, model or isolation that no existing agent
   has. First look in `$CREW/catalog/` (tester, ui-reviewer, security-reviewer, docs-writer,
   perf-profiler); copy it unchanged instead of writing a new one.

## Limits

- At most **7 active agents**. Over the limit: retire one first (`crew-retire`).
- One-line `description`, written as when to use it.
- A new agent starts as `trial` in `roster.md` (with its hire date in `Since`) and is judged after **3 uses**
  (kept or retired). Roles that `crew-bootstrap` creates are user-approved and start as `kept`.

## Autonomy

`team_autonomy` is `auto` only when `~/.claude/team/USER.md` says `auto`. `.claude/team/PROJECT.md` can only
restrict: `ask` there turns it off for the project, `auto` there changes nothing. Missing, empty or any other
value: `ask`.

With `auto`, a trigger above lets the lead hire without asking, as `trial`, and tell the user one
line: what was hired and why. The same ladder and limits apply, plus:
- **One trial at a time.** If an agent is already `trial`, judge it first (below); no second hire.
  The 7-agent cap still holds.
- **Trial guardrails.** A trial agent gets only small or medium jobs: one bounded task, at most
  sonnet / medium, never opus, xhigh or max (its agent file must not set a higher model or effort;
  `check-team` warns). A big job for it (cross-system, opus or high effort, a long run) needs a
  one-line user OK; that is the only question during a trial.
- **Budget.** The `Since` column of its roster row holds the hire date. Its weighted share of ALL usage
  since that date must stay at or under **10%**: run
  `scripts/ledger.ps1 -Since <Since> -Format md` and divide its rows by the total of the whole window.
  Check at each retro and when judging. Over 10%: retire it with `crew-retire`.
- **Judgement after 3 uses**, at the retro or right away: compare the results with the trigger.
  Did it catch the failure class? Did it remove the repeated paste? Is it cheaper than the
  baseline (the same jobs done by the existing agents)? Then set `kept` (and `Since` to `-`) or retire
  it with `crew-retire`, and tell the user one line either way. Do not ask.
- **Age limit.** A trial with fewer than 3 uses after **5 merged features or 14 days** since `Since` is
  judged on what exists: unused (0 uses) means retire; otherwise the same questions as above. Tell the
  user one line. `check-team` warns about a trial older than 14 days.
- Mark the row's Evidence cell with a leading `auto:` (for example `auto: same paste in 3 briefs`). Only
  agents marked so, and agents kept after such a trial, may be retired without asking.
- Add one line under `routing.md` Evidence: what was hired, why, the cost so far.
- Tell the user to restart the session before relying on the new agent.

With `ask` the flow is the one in "Steps" (the user approves every hire).

## Steps

1. Write the proposal to the user in at most 6 lines: what, which rung, the evidence, the model
   and effort, the retire criterion. Wait for a one-line OK. (`auto`: send the one-line notice
   instead of waiting and go on.)
2. Do it:
   - addendum or skill: write the file (addenda are under `.claude/team/`, which the lead may
     write; a project skill is a `coder` job);
   - catalog agent: the `coder` copies `$CREW/catalog/<name>.md` unchanged to
     `.claude/agents/<name>.md` (give it the path); the lead does not write there;
   - new agent: the `coder` writes `.claude/agents/<name>.md` from your brief (frontmatter:
     name, one-line description, tools, model, effort).
3. Add the row to `roster.md` (why, evidence, status `trial`, uses 0, `Since` = today's date, retire
   criterion) and a row to `routing.md` if the agent has its own job type. For an agent file written
   by the `coder`, the roster row (and routing row) go in the **same change** as the file: put the exact
   rows in the brief and have the coder add them in the same commit, so `check-team` never fails because
   the roster lists an agent whose file is missing. Do not write the rows into `roster.md` earlier.
4. Run `check-team.ps1 -Project .`. Update `state.md` Index if useful.
