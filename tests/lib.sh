# Sourced by the test files: temp state, a stub CLI, assertions. Nothing here touches real state.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); H="$ROOT/hooks/scripts"
TD=${TMPDIR:-/tmp}; TMP=$(mktemp -d "${TD%/}/agent-ops-test.XXXXXX")  # macOS TMPDIR ends in /; paths are compared as text
export AGENT_OPS_HOME="$TMP/home"; unset AGENT_OPS_PLUGIN AGENT_OPS_ROLE
TEAM=team-org-uuid; STUB="$TMP/stub/claude"; A="$TMP/primary"; V="$TMP/work"
mkdir -p "$TMP/home/state" "$A/backend" "$V/logs" "$V/worktrees/s"
cat >"$TMP/home/config" <<CONF
TEAM_ORG="$TEAM"
PROFILES_DIR="$TMP/profiles"
CLAUDE_CLI="$STUB"
WORKER_MODEL="test-model"
PRIMARY_CHECKOUT="$A"
WORK_ROOT="$V"
LOGS_DIR="$TMP/logs"
SANDBOX_WRITES="$TMP/daytona-logs"
GH_REPOS="o/app o/web"
DEPLOY_REPO="o/app"
DEPLOY_BRANCH="dev"
BOT_REVIEWERS="codex"
SSO_PROFILES="p"
DRIFT_SUMMARY_HOUR_UTC=24  # no daily drift summary in tests that read the real clock; tests/drift.sh tests it
CONF
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
expect() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok ;; esac; }

hook() { CMD=$2 CWD=${3:-/tmp} python3 -c 'import json,os;print(json.dumps({"tool_input":{"command":os.environ["CMD"]},"cwd":os.environ["CWD"]}))' | "$H/$1"; }
deny() { local o; o=$(hook "$1" "$2" "${3:-}"); has "deny $1: $2" "$o" '"permissionDecision": "deny"'; }
allow() { local o; o=$(hook "$1" "$2" "${3:-}"); expect "allow $1: $2" "$o" ""; }

# Stub CLI + temp state
mkdir -p "$TMP/stub" "$TMP/logs"; for p in team me; do mkdir -p "$TMP/profiles/$p"; done
echo "$TEAM" >"$TMP/profiles/team/org"; echo personal-org >"$TMP/profiles/me/org"
cat >"$STUB" <<'EOF'
#!/bin/bash
[ "$1" = auth ] && { printf '{"orgId":"%s"}\n' "$(cat "$CLAUDE_CONFIG_DIR/org")"; exit 0; }
[ "$1" = --version ] && { echo "9.9.9 (Claude Code)"; exit 0; }
args=" $* "; if [[ "$args" == *" --plugin-dir "* ]] && [ -z "${STUB_NOHOOK:-}" ]; then  # what the CLI does with a plugin: SessionStart
  d=${args#* --plugin-dir }; d=${d%% *}; src=startup; [[ "$args" == *" --resume "* ]] && src=resume
  echo "{\"source\":\"$src\"}" | CLAUDE_PLUGIN_ROOT="$d" "$d/hooks/scripts/session_start.sh"
fi
echo "STUB role=[$AGENT_OPS_ROLE] $*"
echo "STUBPID $$"; echo "STUBCWD $PWD"; echo "npm_cache=[${npm_config_cache:-}]"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_RUN:-}" ] && eval "$STUB_RUN"  # what the test's worker does, such as write a report file
[ -n "${STUB_REPORT:-}" ] && echo "STATUS: $STUB_REPORT"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB"; SB="$TMP/session-tagged.sh"; S="$TMP/session-nosb.sh"  # launches without a sandbox, for the tests of other features
# The dispatch gate: tests of other features launch with --ops and resume with --continue unless they name a tag; tests/drift.sh calls the real script
printf '#!/bin/bash\ncase " $* " in *" --goal "*|*" --ops "*|*" --continue "*) ;; *) case "$1" in launch) set -- "$@" --ops test ;; resume) set -- "$@" --continue ;; esac ;; esac\nexec "%s" "$@"\n' "$ROOT/bin/session.sh" >"$SB"; chmod +x "$SB"
printf '#!/bin/bash\n[ "$1" = launch ] && set -- "$@" --no-sandbox\nexec "%s" "$@"\n' "$SB" >"$S"; chmod +x "$S"; REG="$TMP/home/state/sessions.tsv"; P="$TMP/p.md"; echo do-work >"$P"
waitfor() { local i=0; until grep -q -- "$2" "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && { bad "timeout waiting for $2 in $1"; return; }; sleep 0.1; done; ok; }
