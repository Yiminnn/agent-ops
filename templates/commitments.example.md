# Commitments
generated 2026-11-04T09:00Z from Linear label committed; do not edit

Ops allowance: heartbeat ticks, PR reviews, merges, deploy watching, recovery of cut-off sessions, the daily drift audit

| DEF | objective | accountable | done-when | next proof | checkpoint | executor |
|---|---|---|---|---|---|---|
| DEF-1006 | B6 planner | Yimin | the planner persists a plan and replays it after a restart | a test that restarts the planner and reads the plan back | 2026-11-06 | planner-b6 |
| DEF-1008 | B8 reconcile | Shubhangi | reconcile closes drift between plan and ledger end to end | - | 2026-11-07 | - |

<!-- Everything below is a note in this example only; bin/commitments-render.py writes the part above.

This is the shape of state/commitments.md, a read-only cache. Do not copy or edit it: each heartbeat rewrites it from
Linear (team LINEAR_TEAM, label COMMITTED_LABEL, not completed or canceled), in Linear priority order (Urgent first, no priority last).
To change a goal, change its Linear issue. To commit or uncommit one, a human adds or removes the label.

- objective = issue title; accountable = assignee; executor = the session whose current dispatch is this goal (registry), or -.
- Ids are DEF-n only: LINEAR_TEAM must be the DEF team. No labelled issue gives a file with no rows: DRIFT NONE committed.
- done-when, next proof, checkpoint = these lines in the issue description, anywhere in it, first one wins:
    Done when: <the done-when clause>
    Next proof: <one inspectable result: a test, a decision, a resolved question; not activity>
    Checkpoint: YYYY-MM-DD   (UTC date the next proof is due)
  A missing line renders as "-" (DEF-1008 above), and drift-check.sh prints DRIFT INCOMPLETE for that row.
- Ops allowance = OPS_ALLOWANCE in the config. Those runs use session.sh ... --ops "<reason>" and earn no delivery credit.
- drift-check.sh flags a passed checkpoint until the accountable human accepts the proof and moves the checkpoint in
  Linear; a merged PR is evidence, not proof. A row with no live executor needs a human next action in state/pending.md.
- A generated line over 2 h old makes drift-check.sh print DRIFT UNKNOWN: commitments cache stale.
-->
