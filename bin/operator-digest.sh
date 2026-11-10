#!/bin/bash
# Daily operator digest. check.sh prints it on the daily drift summary tick. It lists the state/pending.md rows that
# wait on the operator: the first field starts with OPERATOR_NAME (config) and the next character is not a letter or
# a digit. So "Ana" and "Ana→Cy" match, and "Anabel" and "Cy→Ana" do not. At most 3 rows, the oldest follow-up date first
# (a row with no follow-up date comes before all of them; equal dates keep file order), then the count of the rest:
#   WAITING ON OPERATOR <n>:
#   <row>                      (at most 3)
#   and <k> more               (only when k > 0)
# Prints nothing with no OPERATOR_NAME or no such row. The coordinator sends it as one PushNotification.
set -u
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
[ -f "$T/config" ] && . "$T/config"
PD="$T/state/pending.md"; [ -n "${OPERATOR_NAME:-}" ] && [ -f "$PD" ] || exit 0  # drift-check.sh says UNKNOWN for a missing pending.md
# LC_ALL=C: macOS awk stops at the first "→" when substr reads it in a UTF-8 locale
LC_ALL=C awk -v op="$OPERATOR_NAME" '
  { f = $0; sub(/^[ \t]*[-*]?[ \t]*/, "", f); sub(/[ \t]*\|.*/, "", f)
    if (index(f, op) != 1 || substr(f, length(op) + 1, 1) ~ /[A-Za-z0-9_]/) next
    d = match($0, /follow-up:? *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) ? substr($0, RSTART + RLENGTH - 10, 10) : "0000-00-00"
    r = $0; sub(/^[ \t]+/, "", r); sub(/[ \t]+$/, "", r); print d "\t" NR "\t" r }' "$PD" |
  sort -t "$(printf '\t')" -k1,1 -k2,2n | cut -f3- |
  awk '{ n++; if (n <= 3) r[n] = $0 }
    END { if (!n) exit; print "WAITING ON OPERATOR " n ":"; for (i = 1; i <= n && i <= 3; i++) print r[i]; if (n > 3) print "and " n - 3 " more" }'
