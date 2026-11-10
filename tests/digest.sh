#!/bin/bash
# Offline tests for the daily operator digest: on the daily summary tick, check.sh lists the state/pending.md rows that
# wait on the operator (first field starts with OPERATOR_NAME), oldest follow-up first, at most 3, with the count of the rest.
# Stub gh and aws, fixed clock; invented rows; nothing here reads real state.
set -u
. "$(dirname "$0")/lib.sh"
ST="$TMP/home/state"; : >"$REG"
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/gh" "$TMP/bin/aws"
sed -i '' 's/^DRIFT_SUMMARY_HOUR_UTC=24.*/DRIFT_SUMMARY_HOUR_UTC=13/' "$TMP/home/config"; echo 'OPERATOR_NAME="Ana"' >>"$TMP/home/config"
{ echo '# Open items waiting on a person (who | question | since | link | follow-up YYYY-MM-DD)'
  echo '- Bo | review #12 | since 2026-11-01 | link | follow-up 2026-11-02'
  echo '- Ana | pick the ledger owner | since 2026-11-01 | link | follow-up 2026-11-20'
  echo '- Ana→Cy | send the design | since 2026-11-02 | link | follow-up 2026-11-12'
  echo '- Cy→Ana | read the proposal | since 2026-11-03 | link | follow-up 2026-11-01'
  echo '- Ana | approve the budget | since 2026-11-04 | link | follow-up 2026-11-09'
  echo ''
  echo '- Ana | reply to the auditor | since 2026-11-05 | link | follow-up 2026-11-12'
  echo '- Anabel | not the operator | since 2026-11-05 | link | follow-up 2026-11-01'
  echo '- Ana | 2FA by Tuesday | since 2026-11-06 | link'; } >"$ST/pending.md"
CK() { { echo '# Commitments'; echo "generated ${CNOW:0:13}:00Z from Linear label committed; do not edit"; } >"$ST/commitments.md"
  PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=$CNOW "$ROOT/bin/check.sh"; }

CNOW=2026-11-10T12:00:00Z; O=$(CK); hasnt 'no digest before the summary hour' "$O" 'WAITING ON OPERATOR'
CNOW=2026-11-10T13:05:00Z; O=$(CK); D=$(sed -n '/^WAITING ON OPERATOR/,/more$/p' <<<"$O")
expect 'count, the oldest three, the rest' "$D" "WAITING ON OPERATOR 5:
- Ana | 2FA by Tuesday | since 2026-11-06 | link
- Ana | approve the budget | since 2026-11-04 | link | follow-up 2026-11-09
- Ana→Cy | send the design | since 2026-11-02 | link | follow-up 2026-11-12
and 2 more"
has 'after the drift summary' "$(head -1 <<<"$O")" 'DRIFT SUMMARY 2026-11-10:'
CNOW=2026-11-10T17:00:00Z; hasnt 'once a day' "$(CK)" 'WAITING ON OPERATOR'
grep -v -e '^- Ana ' -e '^- Ana→' "$ST/pending.md" >"$TMP/p" && cp "$TMP/p" "$ST/pending.md"; echo '- Ana | one thing | since 2026-11-09 | link | follow-up 2026-11-11' >>"$ST/pending.md"
CNOW=2026-11-11T13:00:00Z; O=$(CK); has 'one row' "$O" $'WAITING ON OPERATOR 1:\n- Ana | one thing'; hasnt 'no rest line' "$O" 'more'
grep -v '^- Ana ' "$ST/pending.md" >"$TMP/p" && cp "$TMP/p" "$ST/pending.md"
CNOW=2026-11-12T13:00:00Z; hasnt 'no rows, no digest' "$(CK)" 'WAITING ON OPERATOR'
echo '- Ana | x | since 2026-11-09 | link | follow-up 2026-11-11' >>"$ST/pending.md"; sed -i '' '/^OPERATOR_NAME=/d' "$TMP/home/config"
CNOW=2026-11-13T13:00:00Z; hasnt 'no operator in the config, no digest' "$(CK)" 'WAITING ON OPERATOR'

echo "digest pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
