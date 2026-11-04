# Commitments (replay of 2026-11-03; DEF ids are stand-ins)

Ops allowance: heartbeat ticks, PR reviews, merges, recovery, the daily drift audit. Allowed with --ops; no delivery credit.

| DEF | objective | accountable | done-when | next proof | checkpoint | executor |
|---|---|---|---|---|---|---|
| DEF-1006 | B6 planner | Yimin | the planner persists a plan and replays it after restart | a test that restarts the planner and reads the plan back | 2026-11-02 | - |
| DEF-1008 | B8 reconcile | Yimin | reconcile closes drift between plan and ledger end to end | an end-to-end reconcile test on the synthetic ledger | 2026-11-02 | - |
| DEF-990 | Agent tooling | Yimin | workers run unattended for a week with no lost turn | heartbeat.done judged by the watchdog | 2026-11-10 | - |
