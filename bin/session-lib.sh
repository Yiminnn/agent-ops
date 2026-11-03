# Sourced by session.sh: config, registry, org check, status parser, launcher.
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
[ -f "$T/config" ] || { echo "session.sh: no $T/config; copy config.example" >&2; exit 1; }
. "$T/config"
REG="$T/state/sessions.tsv"
PROMPTS="$T/prompts"
LOGS="$LOGS_DIR"
PROFILES="$PROFILES_DIR"
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
RECOVERY="Your previous turn was cut off by a restart. Before you repeat anything, check the worktree (git status, uncommitted work), git log on your branch, and the PR with its comments. Do not repeat an outside action (push, comment, merge, Linear, Slack) that already happened. Then continue the task and end with your STATUS report."
mkdir -p "$PROMPTS" "$(dirname "$REG")"
touch "$REG"

SETSID='import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])'  # own session and group: a kill of the parent group misses it
die() { echo "session.sh: $*" >&2; exit 1; }
cli() { [ -n "${CLAUDE_CLI:-}" ] && { echo "$CLAUDE_CLI"; return; }; ls "$CLAUDE_CLI_ROOT/"*/*/claude.app/Contents/MacOS/claude 2>/dev/null | sort -V | tail -1; }
org_of() { CLAUDE_CONFIG_DIR="$PROFILES/$1" "$(cli)" auth status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("orgId",""))'; }
need_org() {  # profile personal_ok; sets org
  org=$(org_of "$1"); [ -n "$org" ] || die "cannot read the org of profile $1 (logged out?)"
  [ "$org" = "$TEAM_ORG" ] || [ "$2" = 1 ] || die "profile $1 is personal org $org; use a team profile, or pass --personal-ok if this work holds no client data"
}
client_mark() { echo "$T/state/client-$1"; }  # holds no data: says this sid may not leave the team org
row() { awk -F'\t' -v n="$1" '$1==n' "$REG" | tail -1; }
field() { cut -f"$2" <<<"$1"; }
add_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(date -u +%FT%TZ)" "$7" "${8:-}" >>"$REG"; }
latest() { awk -F'\t' '{last[$1]=$0; order[$1]=NR} END {for (n in last) print order[n] "\t" last[n]}' "$REG" | sort -n | cut -f2-; }
alive() { local p=${1#waiting:}; [[ "$p" =~ ^[1-9][0-9]*$ ]] && kill -0 "$p" 2>/dev/null; }
final_status() {  # the last STATUS word of the last run, if that run ended with exit 0; a log with no markers predates them
  [ -f "$1" ] || return 0
  awk '/^--- session.sh run /{s=""; m=1; e=""} /^--- session.sh end /{e=$4} $1=="STATUS:" && $2 ~ /^(ready|waiting|blocked|failed)$/{s=$2} END{if (m && e!="0") s=""; print s}' "$1"
}
keep_prompt() {  # copy the prompt next to the registry; print the kept path
  [ -s "$1" ] || die "prompt file missing or empty: $1"
  local dst; dst=$(mktemp "$PROMPTS/$2-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || die "cannot create a prompt file"
  cp "$1" "$dst" && echo "$dst"
}
run_claude() {  # profile sid mode(new|resume) prompt log [plugin]
  [ -d "$LOGS" ] || die "no $LOGS: is the work drive mounted? Create it only after you check the drive"
  local B; B=$(cli); [ -x "$B" ] || die "no bundled claude CLI found"
  local flag=(--session-id "$2") role=""; [ "$3" = resume ] && flag=(--resume "$2")
  [ "${6:-}" = plugin ] && { flag+=(--plugin-dir "$PLUGIN_DIR"); role=worker; }
  cd "$PRIMARY_CHECKOUT" || die "no $PRIMARY_CHECKOUT"
  echo "--- session.sh run $(date -u +%FT%TZ) ---" >>"$5" || die "cannot write $5"
  AGENT_OPS_ROLE="$role" CLAUDE_CONFIG_DIR="$PROFILES/$1" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    nohup python3 -c "$SETSID" bash -c 'trap "trap - TERM; kill -TERM -- -$$" TERM; "$@" & c=$!; wait "$c"; echo "--- session.sh end $?"' _ "$B" -p "${flag[@]}" --permission-mode bypassPermissions --model "$WORKER_MODEL" "$(cat "$4")" \
    </dev/null >>"$5" 2>&1 &
  echo $!
}
