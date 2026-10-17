# Generic rules the crew follows

Each rule has a one-line "why / evidence". Evidence is from real multi-agent work on
software projects with transcripts measured by `scripts/ledger.ps1`; where a number is
given it was observed once, not benchmarked, so treat it as a hint. Project-specific rules
belong in a project's `.claude/team/routing.md` "Learned rules" or `PROJECT.md`, not here.

## Measuring

1. **`subagent_tokens` in a notification is the agent's context size, not what it cost.**
   Why: every turn re-reads the whole context (mostly cheap cache reads, but a lot of them);
   a tiny task resumed on an agent with a ~500k context showed +141 reported tokens but cost
   about 1.5M cache-read tokens. Measure with `ledger.ps1`, never from notifications.
2. **The lead is the largest cost.** Why: its long context is re-read on every turn. In the
   measured project the lead was roughly three quarters of the estimated spend. So:
   compaction settings, short replies, forward file paths instead of pasting content, no
   narration.

## Delegating

3. **Resume an agent (SendMessage) only when the follow-up needs its own context; otherwise
   start a fresh small agent.** Why: see rule 1. Good resumes: fixing its own diff after a
   review, a follow-up review of the fix commit. Bad resumes: a one-line note, a lookup, a
   conflict fix.
4. **When NOT to delegate: if one or two file reads answer it, the lead answers.** Why: a new
   agent starts cold and re-reads what it needs; a trivial lookup costs more delegated than
   done.
5. **Briefs have a fixed shape: goal, relevant decisions, files, constraints, exact output
   expected.** Why: agents do not see the conversation; vague briefs make them scan the whole
   project. Point to files and report paths instead of pasting them.
   ```
   Goal:        <one sentence>
   Decisions:   <what is already decided and must not be reopened>
   Files:       <paths / functions to start from>
   Constraints: <rules, things not to touch, checks to run>
   Output:      <exactly what to return; max 15 lines; long detail to a report file, return the path>
   ```
6. **Subagents reply in at most 15 lines; long detail goes to `.claude/team/reports/` and the
   reply is the path.** Why: the reply lands in the lead's context and is re-read every turn.
   Forward the absolute report path to the next agent (a worktree does not contain gitignored
   folders).
7. **Always pass `model` and `effort` on every Agent call, from the routing table, with a
   one-line announcement.** Why: the defaults in agent files are only a fallback; unannounced
   spend surprises the user.
8. **Escalate one step on failure or uncertainty without asking.** Why: a cheap retry one tier
   up is cheaper than a human round trip. Never give a small model a high effort.

## Which agent for what

9. **A thinker on sonnet/high matched opus/high on routine critique, with fewer tokens.** Why /
   evidence: same findings in a side-by-side run. Keep opus for hard-to-undo design critique.
10. **The reviewer finds real bugs; keep it.** Why / evidence: on each of the three
    pull requests it was tried on, an adversarial review found at least one real bug the tests
    missed (including stuck-state bugs). Opus for changes across systems; sonnet/medium for a
    small diff. Follow-up reviews cover only the fix commit.
11. **A separate tester agent was redundant when the coder runs all the checks and CI repeats
    them.** Why / evidence: it added a spawn and a context without finding anything the coder
    and CI did not. It stays in `catalog/` for projects whose checks are long and noisy.
12. **Never call the thinker after coding started.** Why: a critique of a plan that is already
    being built causes rework. Order: architect, thinker critique, decide, coder, reviewer.

## Working in parallel

13. **Parallel coders use `isolation: worktree`, never kill another agent's processes, and run
    heavy checks one at a time.** Why / evidence: parallel coders collided on fixed ports and
    shared build output and killed each other's test runs, costing hours of reruns.
14. **A worktree branches from the default branch and lacks gitignored folders.** Why: so a
    brief must not rely on a report or generated file that is only in the main checkout, and
    the report path must be absolute.

## Keeping the team files healthy

15. **Rules a subagent needs must live in its own file (agent file or
    `.claude/team/roles/<agent>.md`), not only in the lead's.** Why: subagents do not see the
    lead's instructions; a rule only the lead knows is a rule nobody follows.
16. **State is not a log.** `state.md` holds open tasks, running agents, pending decisions and
    an index, under 50 lines; finished items are deleted and lasting knowledge moves to its
    cold home. Why: it is re-read after every compaction; a growing log defeats it. After a
    compaction `state.md` is authoritative over the summary.
17. **Every capped file has a cap and a hook that warns.** Why: `routing.md` 150, `roster.md` 80
    and `state.md` 50 lines keep them cheap to read at every session start.
18. **Few agents with one-line descriptions: at most 7 active; hire on evidence, retire on
    disuse.** Why: every agent description is loaded into the lead's context, and more roles
    means more routing mistakes. Hire when the same 300+ words were pasted into 3+ briefs or a
    failure class keeps slipping through; prefer a role addendum, then a skill, then a new
    agent.

## Mechanical gotchas

19. **In CI YAML, a step name containing `: ` (colon and space) must be quoted.** Why: an
    unquoted one breaks the whole workflow file and the failure is easy to miss.
20. **Hooks must fail open.** A broken hook script must never block the user's work; only an
    intentional rule violation exits with code 2.
