# Commitments

Copy to `~/.claude/agent-templates/state/commitments.md` (or `$AGENT_OPS_HOME/state/commitments.md`). The operator and lead own this file; the coordinator and the drift audit read it and never edit it.

Ops allowance: heartbeat ticks, PR reviews, merges, deploy watching, recovery of cut-off sessions, the daily drift audit. These run with `session.sh ... --ops "<reason>"`; they are allowed without a goal and earn no delivery credit.

Rules:
- One row per committed goal, highest priority first. A goal that is only proposed is not a row: a dispatch to it is refused.
- `next proof` is one concrete, inspectable result (a test, a decision, a resolved question), not activity. `checkpoint` is the date it is due (YYYY-MM-DD, UTC).
- `drift-check.sh` flags the row once the checkpoint has passed, until the accountable human accepts the proof and writes the next proof and checkpoint. A merged PR is evidence, not proof.
- `executor` is the session name that works on the next proof, or `-`. A row with no live executor needs a human next action in `state/pending.md`: a line that names the DEF id and `follow-up YYYY-MM-DD`.
- Change done-when, scope or dates in the open: the old row stays in git history or the coordinator log, not silently rewritten.

| DEF | objective | accountable | done-when | next proof | checkpoint | executor |
|---|---|---|---|---|---|---|
| DEF-1006 | B6 planner | Yimin | the planner persists a plan and replays it after a restart | a test that restarts the planner and reads the plan back | 2026-11-06 | planner-b6 |
| DEF-1008 | B8 reconcile | Yimin | reconcile closes drift between plan and ledger end to end | an end-to-end reconcile test on the synthetic ledger | 2026-11-07 | - |
