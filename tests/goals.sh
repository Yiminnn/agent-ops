#!/bin/bash
# Offline tests for local goals (LINEAR_TEAM empty): state/goals.md -> commitments.md via commitments-render.py --local,
# rendered by drift-check.sh and the dispatch gate themselves. Stub gh, fixed clock (AGENT_OPS_NOW).
set -u
. "$(dirname "$0")/lib.sh"
sed -i.bak 's/^LINEAR_TEAM=.*/LINEAR_TEAM=""/' "$TMP/home/config"
R="$ROOT/bin/session.sh"; ST="$TMP/home/state"; CM="$ST/commitments.md"; G="$ST/goals.md"; : >"$REG"; : >"$ST/pending.md"
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
DC() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=${NOW:-2026-11-03T18:00:00Z} "$ROOT/bin/drift-check.sh"; }

# No goals.md: drift-check says UNKNOWN, the gate refuses a --goal, --ops still runs
O=$(DC); expect 'no goals.md exits 2' "$?" 2; has 'no goals.md UNKNOWN' "$O" 'DRIFT UNKNOWN: goals.md: no '"$G"
has 'gate refuses with no goals.md' "$("$R" launch team l0 "$P" --no-sandbox --goal DEF-1 --expect x 2>&1)" "no $G"
has 'ops needs no goals.md' "$("$R" launch team l1 "$P" --no-sandbox --ops 'review')" 'launched l1'

# Headings start goals, file order is the priority; bullets, bold and Accountable parsed; text before the first goal ignored
cat >"$G" <<'M'
# Goals
Notes before the first goal: Done when: ignored

## DEF-10 Agent | tooling
Accountable: Yimin
- **Done when:** harness green on Linux
Next proof: tests/run.sh passes
Checkpoint: 2099-01-01

## DEF-11: Planner
Done when: plan persisted
M
O=$(DC); expect 'incomplete goal exits 1' "$?" 1
F=$(cat "$CM"); has 'header names goals.md' "$F" 'generated 2026-11-03T18:00Z from goals.md; do not edit'
has 'full goal row' "$F" '| DEF-10 | Agent / tooling | Yimin | harness green on Linux | tests/run.sh passes | 2099-01-01 | - |'
has 'colon after id, no accountable' "$F" '| DEF-11 | Planner | - | plan persisted | - | - | - |'
expect 'file order kept' "$(grep -o '^| DEF-1[0-9]' "$CM" | tr '\n' ' ')" '| DEF-10 | DEF-11 '
has 'incomplete names goals.md' "$O" 'DRIFT INCOMPLETE DEF-11 Planner: no next proof, checkpoint in goals.md (accountable: -)'
has 'unattended' "$O" 'DRIFT UNATTENDED DEF-10 Agent / tooling: no live executor'; hasnt 'never stale' "$O" 'stale'

# Gate reads goals.md as it is now: a goal added after the last render is dispatchable, a removed one is not
printf '\n## DEF-12 Reconcile\nAccountable: Liz\nDone when: a\nNext proof: b\nCheckpoint: 2099-02-01\n' >>"$G"
has 'new goal dispatchable' "$("$R" launch team l2 "$P" --no-sandbox --goal DEF-12 --expect 'a PR')" 'launched l2'
expect 'goal recorded' "$(tail -1 "$REG" | cut -f12-13)" $'DEF-12\ta PR'
has 'uncommitted refused' "$("$R" launch team l3 "$P" --no-sandbox --goal DEF-99 --expect x 2>&1)" 'DEF-99 is not a row in'
sed -i.bak '/^## DEF-12/,$d' "$G"; touch -t 202001010000 "$ST/drift-check.last"
O=$(DC); has 'removed goal: dispatch uncommitted' "$O" 'DRIFT DISPATCH uncommitted DEF-12 l2'
has 'removed goal: ops dispatch listed' "$O" 'DRIFT DISPATCH ops l1'

# Bad goals.md keeps the old cache: a non-DEF heading, a duplicate id
cp "$CM" "$TMP/before"; echo '## ENG-5 other team' >>"$G"
O=$(DC); expect 'non-DEF heading exits 2' "$?" 2; has 'names the id' "$O" 'ENG-5 is not DEF-n'; expect 'cache kept' "$(cat "$CM")" "$(cat "$TMP/before")"
sed -i.bak '$d' "$G"; echo '## DEF-10 again' >>"$G"; has 'duplicate id' "$(DC)" 'DEF-10 appears twice'
sed -i.bak '$d' "$G"

# An empty goals.md is a valid state; a passed checkpoint is flagged like a Linear one
touch "$ST/drift-check.last"; echo '# Goals' >"$G"; O=$(DC); expect 'no goals exits 0' "$?" 0; expect 'no goals says so' "$O" 'DRIFT NONE committed'
printf '## DEF-13 Late\nAccountable: Yimin\nDone when: a\nNext proof: b\nCheckpoint: 2026-11-01\n' >"$G"
has 'passed checkpoint' "$(DC)" 'DRIFT CHECKPOINT DEF-13 Late: checkpoint 2026-11-01 passed'

# The daily audit prompt reads goals.md, not Linear
printf 'DRIFT_AUDIT_PROFILE="team"\n' >>"$TMP/home/config"; rm -f "$ST/drift-audit.done"
PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=2026-11-03T13:30:00Z DRIFT_AUDIT_POLL=0.1 AGENT_OPS_ALERT_CMD=true STUB_RUN="echo 'COVERAGE: x' >'$ST/drift-audit.md'" "$ROOT/bin/drift-audit.sh" >/dev/null
L=$(cut -f6 <<<"$(grep '^drift-audit-' "$REG" | tail -1)"); waitfor "$L" STUB
has 'audit reads goals.md' "$(cat "$L")" "\`$G\`, directly"; hasnt 'audit not Linear' "$(cat "$L")" 'in team `'

echo "goals pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
