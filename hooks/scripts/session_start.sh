#!/bin/bash
# SessionStart, coordinator only: what a new router needs first. Failure: a new coordinator acted before it read
# the handoff and the locks. Its stdout becomes context.
[ "${AGENT_OPS_ROLE:-}" = coordinator ] || exit 0
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
echo "Newest handoff: $(ls -t "$T"/state/handoff-*.md 2>/dev/null | head -1)"
echo "Locks (state/coordinator.md):"
sed -n '/^## Freeze/,/^## Owners/p' "$T/state/coordinator.md" 2>/dev/null | grep -v '^## Owners'
echo "Sessions:"
"${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/../..}/bin/session.sh" status
