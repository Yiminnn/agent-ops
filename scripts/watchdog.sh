#!/bin/bash
# Run from launchd, outside any Claude session. Alerts once per episode when state/heartbeat.last is older than 90 minutes.
# Failure: 4 hours with no heartbeat, unseen. check.sh touches that file on every tick, including NO CHANGE.
# state/heartbeat.stopped marks an intentional stop with no successor.
# Alert path: AGENT_OPS_ALERT_CMD, a command that takes the message as $1 and does not depend on a Claude session.
# Unset: write state/watchdog.alert and exit 3, so launchd's log shows it, and nobody is told. Choose one before relying on this.
set -u
S="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}/state"; LAST="$S/heartbeat.last"; MAX=${AGENT_OPS_WATCHDOG_MINUTES:-90}
[ -f "$S/heartbeat.stopped" ] && exit 0
if [ -n "$(find "$LAST" -mmin -"$MAX" 2>/dev/null)" ]; then rm -f "$S/watchdog.alerted"; exit 0; fi
[ -f "$S/watchdog.alerted" ] && exit 0
msg="agent-ops: no heartbeat for over $MAX minutes (last tick: $(stat -f %Sm "$LAST" 2>/dev/null || echo never))."
if [ -n "${AGENT_OPS_ALERT_CMD:-}" ]; then
  "$AGENT_OPS_ALERT_CMD" "$msg" && touch "$S/watchdog.alerted"
else
  echo "$msg" >>"$S/watchdog.alert"; echo "$msg" >&2; exit 3
fi
