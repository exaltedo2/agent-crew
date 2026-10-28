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

State the evidence in the proposal (which briefs, which failures, which condition).

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
- A new agent starts as `trial` in `roster.md` and is judged after **3 uses** (kept or retired).

## Autonomy

`team_autonomy` is `auto` when `.claude/team/PROJECT.md` says so, or, if it does not have the key,
when `~/.claude/team/USER.md` does (the project value wins). Missing or any other value: `ask`.

With `auto`, a trigger above lets the lead hire without asking, as `trial`, and tell the user one
line: what was hired and why. The same ladder and limits apply, plus:
- **One trial at a time.** If an agent is already `trial`, judge it first (below); no second hire.
  The 7-agent cap still holds.
- **Trial guardrails.** A trial agent gets only small or medium jobs: one bounded task, at most
  sonnet / medium, never opus, xhigh or max. A big job for it (cross-system, opus or high effort,
  a long run) needs a one-line user OK; that is the only question during a trial.
- **Budget.** Its ledger share since the hire must stay at or under **10%** of total usage
  (`scripts/ledger.ps1`; check at each retro and when judging). Over 10%: retire it with `crew-retire`.
- **Judgement after 3 uses**, at the retro or right away: compare the results with the trigger.
  Did it catch the failure class? Did it remove the repeated paste? Is it cheaper than the
  baseline (the same jobs done by the existing agents)? Then set `kept` or retire it with
  `crew-retire`, and tell the user one line either way. Do not ask.
- Add one line under `routing.md` Evidence: what was hired, why, the cost so far.
- Tell the user to restart the session before relying on the new agent.

With `ask` nothing changes.

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
3. Add the row to `roster.md` (why, evidence, status `trial`, uses 0, retire criterion) and a
   row to `routing.md` if the agent has its own job type.
4. Run `check-team.ps1 -Project .`. Update `state.md` Index if useful.
