#!/bin/bash
# Run from launchd, outside any Claude session. Alerts once per episode when the last finished tick is older than 90 minutes,
# or when it failed. The heartbeat skill writes state/heartbeat.done (`<UTC> ok` or `<UTC> failed: <reason>`) at the end
# of every tick. check.sh touches state/heartbeat.last at Probe, at the start of a tick, so a tick that dies after Probe
# would still look fresh there. Until the first heartbeat.done exists (first run after an upgrade), heartbeat.last decides,
# and the alert says so.
# Failure: 4 hours with no heartbeat, unseen.
# state/heartbeat.stopped marks an intentional stop with no successor.
# Alert path: AGENT_OPS_ALERT_CMD, a command that takes the message as $1 and does not depend on a Claude session.
# Unset: write state/watchdog.alert and exit 3, so launchd's log shows it, and nobody is told. Choose one before relying on this.
set -u
S="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}/state"; DONE="$S/heartbeat.done"; MAX=${AGENT_OPS_WATCHDOG_MINUTES:-90}
[ -f "$S/heartbeat.stopped" ] && exit 0
if [ -f "$DONE" ]; then REF=$DONE; note=""; else REF="$S/heartbeat.last"; note=" (no heartbeat.done yet, judged by heartbeat.last)"; fi
failed=""; [ -f "$DONE" ] && failed=$(tail -n 1 "$DONE" | sed -n 's/^[^ ]* failed: //p')
if [ -z "$failed" ] && [ -n "$(find "$REF" -mmin -"$MAX" 2>/dev/null)" ]; then rm -f "$S/watchdog.alerted"; exit 0; fi
[ -f "$S/watchdog.alerted" ] && exit 0
if [ -n "$failed" ]; then msg="agent-ops: last tick failed: $failed ($(tail -n 1 "$DONE" | cut -d' ' -f1))."
else msg="agent-ops: no finished heartbeat for over $MAX minutes (last: $(stat -f %Sm "$REF" 2>/dev/null || echo never))$note."; fi
if [ -n "${AGENT_OPS_ALERT_CMD:-}" ]; then
  "$AGENT_OPS_ALERT_CMD" "$msg" && touch "$S/watchdog.alerted"
else
  echo "$msg" >>"$S/watchdog.alert"; echo "$msg" >&2; exit 3
fi
