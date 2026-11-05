#!/bin/bash
# Daily independent drift audit, run from launchd (scripts/com.agent-ops.drift-audit.plist.template), outside the coordinator.
# On a working day (Mon-Fri, UTC) with no `ok` audit yet today, it launches one fresh read-only worker through session.sh
# (no --worktree, --ops "daily drift audit") with templates/drift-audit-prompt.md, waits for it, and judges the report it
# writes to state/drift-audit.md: at most 3 `DECISION: <DEF-n> <reason>` blocks and a `COVERAGE:` line.
# It writes state/drift-audit.done (`<UTC> ok` or `<UTC> failed: <reason>`; watchdog.sh reads it) and sends the decisions
# and UNKNOWN lines that are new since the last sent report through AGENT_OPS_ALERT_CMD. Dedupe: state/drift-audit.sent
# holds the goal+reason keys last sent; a key that clears and comes back is sent again.
# Config: DRIFT_AUDIT_PROFILE (team profile), DRIFT_AUDIT_MINUTES (default 60), DRIFT_AUDIT_POLL (seconds, default 30).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"; S="$T/state"
[ -f "$T/config" ] || { echo "drift-audit.sh: no $T/config" >&2; exit 1; }
. "$T/config"
NOW=${AGENT_OPS_NOW:-$(date -u +%FT%TZ)}; DAY=${NOW:0:10}; STAMP="${NOW:0:16}Z"; DONE="$S/drift-audit.done"; REP="$S/drift-audit.md"
done_line() { echo "$STAMP $1" >"$DONE"; echo "drift-audit: $1"; [ "$1" = ok ]; exit $?; }
[ "$(python3 -c 'import datetime,sys; print(datetime.date.fromisoformat(sys.argv[1]).weekday())' "$DAY")" -ge 5 ] && exit 0
grep -q "^$DAY[^ ]* ok$" "$DONE" 2>/dev/null && exit 0  # one audit per working day; a failed one may run again
[ -n "${DRIFT_AUDIT_PROFILE:-}" ] || done_line "failed: no DRIFT_AUDIT_PROFILE in $T/config"

prompt=$(mktemp "${TMPDIR:-/tmp}/agent-ops-audit.XXXXXX")
sed -e "s|__STATE__|$S|g" -e "s|__REPORT__|$REP|g" -e "s|__REPOS__|$GH_REPOS|g" -e "s|__DATE__|$DAY|g" \
  -e "s|__LINEAR_TEAM__|${LINEAR_TEAM:-<LINEAR_TEAM not set in the config: write an UNKNOWN line>}|g" -e "s|__COMMITTED_LABEL__|${COMMITTED_LABEL:-committed}|g" "$HERE/../templates/drift-audit-prompt.md" >"$prompt"
rm -f "$REP"
out=$("$HERE/session.sh" launch "$DRIFT_AUDIT_PROFILE" "drift-audit-${STAMP//[-:]/}" "$prompt" --no-sandbox --ops "daily drift audit" 2>&1); rc=$?
rm -f "$prompt"
[ "$rc" = 0 ] || done_line "failed: launch: $(head -1 <<<"$out")"
pid=$(sed -n 's/.* pid=\([0-9]*\).*/\1/p' <<<"$out")
end=$(( $(date +%s) + ${DRIFT_AUDIT_MINUTES:-60} * 60 ))
while kill -0 "$pid" 2>/dev/null; do [ "$(date +%s)" -lt "$end" ] || done_line "failed: worker still running after ${DRIFT_AUDIT_MINUTES:-60} minutes (pid $pid)"; sleep "${DRIFT_AUDIT_POLL:-30}"; done

# Judge the report; print the message of new items (empty: nothing new) and write the keys to drift-audit.sent.new
msg=$(python3 - "$REP" "$S/drift-audit.sent" 2>&1 <<'EOF'
import re, sys
rep, sent = sys.argv[1:]
try: lines = open(rep).read().splitlines()
except OSError: sys.exit("no report at " + rep)
blocks, unknown, cov, cur = [], [], None, None
for l in lines:
    if re.match(r"[^A-Za-z0-9]*(\d+\.\s*)?DECISION:", l):  # at the start of a line after any marks (**, ##, -, `, 1.): such a line fails, not drops out
        m = re.fullmatch(r"DECISION: (DEF-\d+) (checkpoint-missed|unattended|off-goal-work|unverified-claim|scope-change|other)", l.strip())
        if not m: sys.exit(f"bad DECISION line: {l.strip()[:80]}")
        cur = [m.group(1) + " " + m.group(2), [l]]; blocks.append(cur)
    elif l.startswith("UNKNOWN:"): unknown.append(l.strip()); cur = None
    elif l.startswith("COVERAGE:"): cov = l.strip(); cur = None
    elif cur and l.strip(): cur[1].append(l)
if cov is None: sys.exit("no COVERAGE line")
if len(blocks) > 3: sys.exit(f"{len(blocks)} decisions, at most 3")
try: old = set(open(sent).read().splitlines())
except OSError: old = set()
keys = [b[0] for b in blocks] + unknown
open(sent + ".new", "w").write("".join(k + "\n" for k in keys))
new = [b for b in blocks if b[0] not in old]
newu = [u for u in unknown if u not in old]
if new or newu:
    print(f"agent-ops drift audit: {len(new)} new decision(s)" + (f", {len(newu)} UNKNOWN" if newu else ""))
    for b in new: print("\n" + "\n".join(b[1]))
    if newu: print("\n" + "\n".join(newu))
    print("\n" + cov)
EOF
) || done_line "failed: $(tail -1 <<<"$msg")"
if [ -n "$msg" ]; then
  [ -n "${AGENT_OPS_ALERT_CMD:-}" ] || done_line "failed: no AGENT_OPS_ALERT_CMD to send the report (it is in $REP)"
  "$AGENT_OPS_ALERT_CMD" "$msg" || done_line "failed: AGENT_OPS_ALERT_CMD failed (the report is in $REP)"
fi
mv "$S/drift-audit.sent.new" "$S/drift-audit.sent"
done_line ok
