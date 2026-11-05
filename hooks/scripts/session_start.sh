#!/bin/bash
# SessionStart, on startup and on resume (no matcher). A session.sh launch: one line in its log names the plugin
# revision, so status can tell a loaded plugin from a mere --plugin-dir flag.
# Coordinator: what a new router needs first. Failure: a new coordinator acted before it read the handoff and the locks.
# Its stdout becomes context.
src=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("source",""))' 2>/dev/null)
root=${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/../..}
[ -n "${AGENT_OPS_LOG:-}" ] && echo "--- agent-ops plugin loaded rev=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown) source=$src ---" >>"$AGENT_OPS_LOG"
[ "${AGENT_OPS_ROLE:-}" = coordinator ] || exit 0
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
rev=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)  # the skills this coordinator loaded; check.sh says SKILL STALE when the plugin moves on
if [ -n "$rev" ]; then echo "$rev" >"$T/state/coordinator-plugin-rev"; else rm -f "$T/state/coordinator-plugin-rev"; fi
echo "Newest handoff: $(ls -t "$T"/state/handoff-*.md 2>/dev/null | head -1)"
echo "Locks (state/coordinator.md):"
sed -n '/^## Freeze/,/^## Owners/p' "$T/state/coordinator.md" 2>/dev/null | grep -v '^## Owners'
echo "Sessions:"
"$root/bin/session.sh" status
