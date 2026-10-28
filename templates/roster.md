# Team roster (owned by the lead)

Cap: 80 lines. At most 7 active agents. Every active agent has a one-line description in
its file. Hire with the `crew-hire` skill, retire with `crew-retire`.

last_retro: never

## Active

| Name | Why it exists | Evidence | Status | Uses | Since | Retire when |
|---|---|---|---|---|---|---|
| lead | talks to the user, routes the work | core | kept | - | - | never |
| coder | implements plans, runs all checks, opens PRs | core | kept | 0 | - | never |
| reviewer | tries to disprove a change | core | kept | 0 | - | never |
| scout | cheap fact search | core | kept | 0 | - | 0 spawns in 5 merged PRs |

Status is `trial` (a new agent, judged after 3 uses) or `kept`. At most one agent is `trial` at a time.
"Uses" counts spawns since the last retro (the retro takes them from `scripts/ledger.ps1`). "Since" is the
hire date (`YYYY-MM-DD`) of a `trial` agent, `-` for the others: the 10% usage cap and the age limit of a
trial count from it. Evidence `user-approved` marks agents the user chose (core, bootstrap); a leading
`auto:` marks agents the lead hired itself under `team_autonomy: auto`.

## Candidates later

<!-- agent | condition that makes it worth hiring, for example: ui-reviewer | once screens exist.
With `team_autonomy: auto` the lead hires it as `trial` when the condition becomes true. -->

## Retired

<!-- name | date | reason | where its knowledge went -->
