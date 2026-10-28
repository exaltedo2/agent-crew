# Model and effort routing (owned by the lead)

The lead reads this file at the start of every session and follows it. The lead may change
it when the Evidence shows a better choice, and tells the user in one line what changed
and why. Cap: 150 lines (the retro prunes it).

| Job | Model | Effort | Fallback |
|---|---|---|---|
| Finding files, "where is X used" (`scout`) | haiku | low | - |
| A small, clear change in one file (`coder`) | sonnet | low-medium | - |
| Coding across several files with a ready plan (`coder`) | sonnet | medium-high | - |
| Routine critique and ideas (`thinker`) | sonnet | high | - |
| Critique of a hard-to-undo design (`thinker`) | opus | high | - |
| Unclear design, interactions between systems (`architect`) | opus | high | - |
| Review of a small diff (`reviewer`) | sonnet | medium | - |
| Review of a change across systems (`reviewer`) | opus | high | - |
| A bug with an unknown cause, races, state problems | opus | high-xhigh | - |
| A big architecture decision, hard to undo | opus | xhigh-max | - |
| OPTIONAL, untested by the maintainers: the hardest design, hard to undo | fable | xhigh-max | opus |
| OPTIONAL, untested by the maintainers: a bug with an unknown cause that opus failed on | fable | xhigh | opus |

- Model names are free-form aliases (whatever Claude Code accepts). A row whose model is not
  in USER.md "Available models" uses its Fallback (`-` = none: the lead takes the nearest
  available model of the same tier). The two `fable` rows only apply if you have that model;
  delete them otherwise.

- If unsure, go one step up, but never use a high tier for a simple job. Never give a
  small model a high effort.
- If an agent says it is unsure, or the job fails, give the same job again one step up
  (model or effort) without asking the user.
- Call independent jobs in parallel, each with its own model and effort.
- Resume an agent only when its own context is needed; otherwise start a fresh small one.

## Evidence

<!-- One line per measurement: what was tried, what it cost (run scripts/ledger.ps1), what
it found. The retro adds lines here and prunes old ones. With `team_autonomy: auto` every
automatic hire, keep or retire also gets one line (what, why, cost). -->

## Learned rules

<!-- Short project-specific rules the lead follows. Generic ones live in agent-crew
docs/RULES.md; do not copy them here. -->
