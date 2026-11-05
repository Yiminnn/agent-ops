#!/bin/bash
# Run from launchd, outside any Claude session. Alerts once per episode when the last finished tick is older than 90 minutes,
# or when it failed. The heartbeat skill writes state/heartbeat.done (`<UTC> ok` or `<UTC> failed: <reason>`) at the end
# of every tick. check.sh touches state/heartbeat.last at Probe, at the start of a tick, so a tick that dies after Probe
# would still look fresh there. Until the first heartbeat.done exists (first run after an upgrade), heartbeat.last decides,
# and the alert says so.
# Failure: 4 hours with no heartbeat, unseen.
# state/heartbeat.stopped marks an intentional stop with no successor.
# Alert path: AGENT_OPS_ALERT_CMD, a command that takes the message as $1 and does not depend on a Claude session.
# The daily drift audit (bin/drift-audit.sh) writes state/drift-audit.done; an alert, once per episode, when it is missing,
# says failed, or is over 30 hours old on a weekday (weekend days do not count). A different message (stale, then a
# failed run) is a new episode. heartbeat.stopped does not silence this.
# Unset: write state/watchdog.alert and exit 3, so launchd's log shows it, and nobody is told. Choose one before relying on this.
set -u
S="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}/state"; DONE="$S/heartbeat.done"; MAX=${AGENT_OPS_WATCHDOG_MINUTES:-90}; rc=0
alert() {  # message marker; the marker holds the message sent
  if [ -n "${AGENT_OPS_ALERT_CMD:-}" ]; then "$AGENT_OPS_ALERT_CMD" "$1" && echo "$1" >"$2"
  else echo "$1" >>"$S/watchdog.alert"; echo "$1" >&2; rc=3; fi
}
audit=$(python3 - "$S/drift-audit.done" <<'EOF'
import datetime as dt, os, sys
now = dt.datetime.fromisoformat(os.environ["AGENT_OPS_NOW"].replace("Z", "+00:00")) if os.environ.get("AGENT_OPS_NOW") else dt.datetime.now(dt.timezone.utc)
try: line = open(sys.argv[1]).read().splitlines()[-1]
except (OSError, IndexError): line = ""
ts, _, rest = line.partition(" ")
if rest.startswith("failed:"): sys.exit(print(f"agent-ops: drift audit failed: {rest[7:].strip()} ({ts})."))
if now.weekday() >= 5: sys.exit()
if not line: sys.exit(print("agent-ops: no drift-audit.done yet: the daily drift audit has not run (scripts/com.agent-ops.drift-audit.plist.template)."))
try: t = dt.datetime.strptime(ts, "%Y-%m-%dT%H:%MZ").replace(tzinfo=dt.timezone.utc)
except ValueError: sys.exit(print(f"agent-ops: unreadable drift-audit.done: {line[:80]}"))
weekend = sum((t.date() + dt.timedelta(days=d)).weekday() >= 5 for d in range(1, (now.date() - t.date()).days))
if now - t - dt.timedelta(days=weekend) > dt.timedelta(hours=30): print(f"agent-ops: no drift audit since {ts} (over 30 working hours).")
EOF
)
arc=$?; [ "$arc" = 0 ] || [ -n "$audit" ] || audit="agent-ops: watchdog audit check failed (python3 exit $arc); the drift audit is not judged."  # a crash is not all clear
if [ -z "$audit" ]; then rm -f "$S/watchdog.audit-alerted"; elif [ "$(cat "$S/watchdog.audit-alerted" 2>/dev/null)" != "$audit" ]; then alert "$audit" "$S/watchdog.audit-alerted"; fi
[ -f "$S/heartbeat.stopped" ] && exit "$rc"
if [ -f "$DONE" ]; then REF=$DONE; note=""; else REF="$S/heartbeat.last"; note=" (no heartbeat.done yet, judged by heartbeat.last)"; fi
failed=""; [ -f "$DONE" ] && failed=$(tail -n 1 "$DONE" | sed -n 's/^[^ ]* failed: //p')
if [ -z "$failed" ] && [ -n "$(find "$REF" -mmin -"$MAX" 2>/dev/null)" ]; then rm -f "$S/watchdog.alerted"; exit "$rc"; fi
[ -f "$S/watchdog.alerted" ] && exit "$rc"
if [ -n "$failed" ]; then msg="agent-ops: last tick failed: $failed ($(tail -n 1 "$DONE" | cut -d' ' -f1))."
else msg="agent-ops: no finished heartbeat for over $MAX minutes (last: $(stat -f %Sm "$REF" 2>/dev/null || echo never))$note."; fi
alert "$msg" "$S/watchdog.alerted"
exit "$rc"
