#!/bin/bash
# Offline tests for bin/commitments-render.py: Linear issues as JSON on stdin -> state/commitments.md, read back by
# drift-check.sh. No Linear, stub gh, fixed clock (AGENT_OPS_NOW).
set -u
. "$(dirname "$0")/lib.sh"
ST="$TMP/home/state"; CM="$ST/commitments.md"; : >"$REG"; : >"$ST/pending.md"
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
RENDER() { AGENT_OPS_NOW=${NOW:-2026-11-03T18:00:00Z} python3 "$ROOT/bin/commitments-render.py"; }
DC() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=${NOW:-2026-11-03T18:00:00Z} "$ROOT/bin/drift-check.sh"; }

# A description with no block fields renders "-", and drift-check flags the row
echo '[{"identifier":"DEF-960","title":"Planner","assignee":"Shubhangi","description":"Done when: plan persisted\nNo other fields."}]' | RENDER
expect 'render exits 0' "$?" 0
has 'missing fields render as -' "$(cat "$CM")" '| DEF-960 | Planner | Shubhangi | plan persisted | - | - | - |'
O=$(DC); expect 'incomplete row exits 1' "$?" 1
has 'incomplete row flagged' "$O" 'DRIFT INCOMPLETE DEF-960 Planner: no next proof, checkpoint in the Linear description (accountable: Shubhangi)'
hasnt 'a missing checkpoint is not an input failure' "$O" 'UNKNOWN'

# The full block, in the forms Linear's editor writes; header from config; executor from the registry; order kept
printf 'COMMITTED_LABEL="goal"\nOPS_ALLOWANCE="heartbeat, PR review, merges"\n' >>"$TMP/home/config"
printf 'p1\tteam\ts\t0\tp\tl\t2026-11-03T10:00:00Z\to\tplugin\t\t\tDEF-961\ta test\np2\tteam\ts\t0\tp\tl\t2026-11-03T11:00:00Z\to\tplugin\t\t\tDEF-961\tsecond\n' >"$REG"
cat >"$TMP/issues.json" <<'J'
{"issues":[
 {"identifier":"DEF-961","title":"Reconcile | ledger","assignee":{"name":"Liz"},"description":"Context first.\n\n- **Done when:** reconcile closes drift end to end\n* Next proof: an end-to-end test\n**Checkpoint:** 2099-01-07\nDone when: a later line is ignored"},
 {"identifier":"DEF-962","title":"Planner","assignee":null,"description":"done when: plan persisted\nnext proof: restart test\ncheckpoint: 2099-01-08"}]}
J
RENDER <"$TMP/issues.json"; F=$(cat "$CM")
has 'header names the label' "$F" 'generated 2026-11-03T18:00Z from Linear label goal; do not edit'
has 'ops allowance from config' "$F" 'Ops allowance: heartbeat, PR review, merges'
has 'bullet and bold forms parsed' "$F" '| DEF-961 | Reconcile / ledger | Liz | reconcile closes drift end to end | an end-to-end test | 2099-01-07 | p2 |'
has 'no assignee, lower case keys' "$F" '| DEF-962 | Planner | - | plan persisted | restart test | 2099-01-08 | - |'
expect 'Linear order is the priority' "$(grep -o '^| DEF-96[0-9]' "$CM" | tr '\n' ' ')" '| DEF-961 | DEF-962 '
has 'drift-check judges the rendered executor' "$(DC)" 'DRIFT UNATTENDED DEF-961 Reconcile / ledger: executor p2 not running'

# Bad input keeps the old file; a cache rendered over 2 h ago is stale
cp "$CM" "$TMP/before"; O=$(echo 'not json' | RENDER 2>&1); expect 'bad input exits 1' "$?" 1; has 'bad input says kept' "$O" 'commitments.md kept'
expect 'bad input keeps the old file' "$(cat "$CM")" "$(cat "$TMP/before")"
O=$(echo '[{"title":"no identifier"}]' | RENDER 2>&1); expect 'issue with no identifier exits 1' "$?" 1; has 'names the issue' "$O" 'no identifier: {"title"'; expect 'and keeps the file' "$(cat "$CM")" "$(cat "$TMP/before")"
NOW=2026-11-03T15:30:00Z RENDER <"$TMP/issues.json"; O=$(DC); expect 'stale render exits 2' "$?" 2
has 'stale render UNKNOWN' "$O" 'DRIFT UNKNOWN: commitments cache stale (generated 2026-11-03T15:30Z)'

echo "commitments pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
