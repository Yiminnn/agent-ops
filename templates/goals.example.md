# Goals
<!-- state/goals.md: the committed goals when LINEAR_TEAM is empty. Humans edit it; the coordinator never does.
One "## DEF-n <objective>" heading per goal, highest priority first. Under it, one field per line (first one wins):
Accountable, Done when, Next proof (one inspectable result, not activity), Checkpoint (UTC date the next proof is due).
A missing line renders as "-" and drift-check.sh prints DRIFT INCOMPLETE. drift-check.sh and the dispatch gate render
state/commitments.md from this file (bin/commitments-render.py --local). Text above the first heading is ignored. -->

## DEF-1006 B6 planner
Accountable: Yimin
Done when: the planner persists a plan and replays it after a restart
Next proof: a test that restarts the planner and reads the plan back
Checkpoint: 2026-11-06

## DEF-1008 B8 reconcile
Accountable: Shubhangi
Done when: reconcile closes drift between plan and ledger end to end
Checkpoint: 2026-11-07
