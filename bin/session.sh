#!/bin/bash
# Coordinator session tool: launch, resume and list claude -p worker sessions, with one registry.
#
#   session.sh launch <profile> <name> <prompt-file> [--client-data] [--personal-ok]
#   session.sh resume <name> <prompt-file> [--after <pid>] [--personal-ok]  # queue behind a pid, or run now
#   session.sh recover [--go] [--personal-ok] [<name>...]    # list interrupted rows; --go resumes them
#   session.sh status [--all]                                # registry + live pid + log age + final STATUS
#   session.sh orgcheck                                      # ORG CHANGED lines, for check.sh
#   session.sh log <name> [bytes]                            # tail of the session's log
#
# Registry: ~/.claude/agent-templates/state/sessions.tsv
#   name  profile  sid  pid  prompt  log  started_utc  org  [plugin]
# Prompts are copied to $T/prompts/ (internal disk) so a wiped work drive
# cannot make a queued resume fail silently. Logs go to $LOGS_DIR/<name>.log.
# Org: launch and resume refuse a personal org unless --personal-ok. --client-data refuses it always
# (real client data never goes to a personal account).
# AGENT_OPS_PLUGIN=1: new launches load this plugin as AGENT_OPS_ROLE=worker, column 9 says so, and
# resumes of that row keep it. Default off: older rows and unflagged launches run with no plugin.
# AGENT_OPS_HOME (default ~/.claude/agent-templates) holds state, prompts and the config; config.example lists its keys.
set -u
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
[ -f "$T/config" ] || { echo "session.sh: no $T/config; copy config.example" >&2; exit 1; }
. "$T/config"
REG="$T/state/sessions.tsv"
PROMPTS="$T/prompts"
LOGS="$LOGS_DIR"
PROFILES="$PROFILES_DIR"
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
RECOVERY="Your previous turn was cut off by a restart. Before you repeat anything, check the worktree (git status, uncommitted work), git log on your branch, and the PR with its comments. Do not repeat an outside action (push, comment, merge, Linear, Slack) that already happened. Then continue the task and end with your STATUS report."
mkdir -p "$PROMPTS" "$LOGS" "$(dirname "$REG")"
touch "$REG"

die() { echo "session.sh: $*" >&2; exit 1; }
cli() { [ -n "${CLAUDE_CLI:-}" ] && { echo "$CLAUDE_CLI"; return; }; ls "$CLAUDE_CLI_ROOT/"*/*/claude.app/Contents/MacOS/claude 2>/dev/null | sort -V | tail -1; }
org_of() { CLAUDE_CONFIG_DIR="$PROFILES/$1" "$(cli)" auth status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("orgId",""))'; }
need_org() {  # profile personal_ok; sets org
  org=$(org_of "$1"); [ -n "$org" ] || die "cannot read the org of profile $1 (logged out?)"
  [ "$org" = "$TEAM_ORG" ] || [ "$2" = 1 ] || die "profile $1 is personal org $org; use a team profile, or pass --personal-ok if this work holds no client data"
}
row() { awk -F'\t' -v n="$1" '$1==n' "$REG" | tail -1; }
field() { cut -f"$2" <<<"$1"; }
add_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(date -u +%FT%TZ)" "$7" "${8:-}" >>"$REG"; }
latest() { awk -F'\t' '{last[$1]=$0; order[$1]=NR} END {for (n in last) print order[n] "\t" last[n]}' "$REG" | sort -n | cut -f2-; }
alive() { local p=${1#waiting:}; [[ "$p" =~ ^[1-9][0-9]*$ ]] && kill -0 "$p" 2>/dev/null; }
final_status() {  # the last STATUS word since the last run marker, or nothing
  [ -f "$1" ] || return 0
  tail -c 65536 "$1" | awk '/^--- session.sh run /{s=""} $1=="STATUS:" && $2 ~ /^(ready|waiting|blocked|failed)$/{s=$2} END{print s}'
}
keep_prompt() {  # copy the prompt next to the registry; print the kept path
  [ -s "$1" ] || die "prompt file missing or empty: $1"
  local dst="$PROMPTS/$2-$(date -u +%Y%m%dT%H%M%SZ).md"
  cp "$1" "$dst" && echo "$dst"
}
run_claude() {  # profile sid mode(new|resume) prompt log [plugin]
  local B; B=$(cli); [ -x "$B" ] || die "no bundled claude CLI found"
  local flag=(--session-id "$2") role=""; [ "$3" = resume ] && flag=(--resume "$2")
  [ "${6:-}" = plugin ] && { flag+=(--plugin-dir "$PLUGIN_DIR"); role=worker; }
  cd "$PRIMARY_CHECKOUT" || die "no $PRIMARY_CHECKOUT"
  echo "--- session.sh run $(date -u +%FT%TZ) ---" >>"$5"
  AGENT_OPS_ROLE="$role" CLAUDE_CONFIG_DIR="$PROFILES/$1" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    nohup "$B" -p "${flag[@]}" --permission-mode bypassPermissions --model "$WORKER_MODEL" "$(cat "$4")" \
    </dev/null >>"$5" 2>&1 &
  echo $!
}

cmd=${1:-status}; shift || true
pos=(); personal_ok=0; client=0; after=""; go=0; all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --personal-ok) personal_ok=1 ;; --client-data) client=1 ;; --go) go=1 ;; --all) all=1 ;;
    --after) after=${2:-}; shift ;;
    *) pos+=("$1") ;;
  esac
  shift
done
set -- ${pos[@]+"${pos[@]}"}
case "$cmd" in
launch)
  [ $# -ge 3 ] || die "usage: launch <profile> <name> <prompt-file> [--client-data] [--personal-ok]"
  profile=$1 name=$2 prompt=$3
  [ -d "$PROFILES/$profile" ] || die "unknown profile $profile"
  [ -z "$(row "$name")" ] || die "name $name already in registry; pick another or use resume"
  [ "$client" = 1 ] && personal_ok=0
  need_org "$profile" "$personal_ok"
  kept=$(keep_prompt "$prompt" "$name") || exit 1
  plug=""; [ "${AGENT_OPS_PLUGIN:-0}" = 1 ] && plug=plugin
  sid=$(uuidgen | tr 'A-Z' 'a-z'); log="$LOGS/$name.log"
  pid=$(run_claude "$profile" "$sid" new "$kept" "$log" "$plug")
  add_row "$name" "$profile" "$sid" "$pid" "$kept" "$log" "$org" "$plug"
  echo "launched $name pid=$pid sid=$sid profile=$profile log=$log"
  ;;
resume)
  [ $# -ge 2 ] || die "usage: resume <name> <prompt-file> [--after <pid>] [--personal-ok]"
  name=$1 prompt=$2
  r=$(row "$name"); [ -n "$r" ] || die "no session $name in registry"
  profile=$(field "$r" 2) sid=$(field "$r" 3) log=$(field "$r" 6) plug=$(field "$r" 9)
  need_org "$profile" "$personal_ok"
  kept=$(keep_prompt "$prompt" "$name") || exit 1
  live=$(field "$r" 4)
  if [ -z "$after" ] && alive "$live"; then after=${live#waiting:}; fi  # never run two turns at once
  if [ -n "$after" ]; then
    # Detached waiter; the prompt is already on the internal disk, so a wiped external drive cannot drop it.
    recheck=check; [ "$personal_ok" = 1 ] && recheck=""
    nohup bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 30; done; exec "$2" _run "$3" "$4" "$5"' _ \
      "$after" "$0" "$name" "$kept" "$recheck" </dev/null >>"$log" 2>&1 &
    add_row "$name" "$profile" "$sid" "waiting:$!" "$kept" "$log" "$org" "$plug"
    echo "queued $name after pid $after (waiter $!)"
  else
    pid=$(run_claude "$profile" "$sid" resume "$kept" "$log" "$plug")
    add_row "$name" "$profile" "$sid" "$pid" "$kept" "$log" "$org" "$plug"
    echo "resumed $name pid=$pid"
  fi
  ;;
_run)  # internal: the waiter's hand-off once the blocking pid exits. No third arg: a waiter queued before the org check.
  name=$1 kept=$2; r=$(row "$name"); log=$(field "$r" 6)
  [ -s "$kept" ] || { echo "session.sh: queued prompt vanished: $kept" >>"$log"; exit 1; }
  if [ "${3:-}" = check ] && [ "$(org_of "$(field "$r" 2)")" != "$TEAM_ORG" ]; then
    echo "session.sh: queued resume refused: profile $(field "$r" 2) is no longer the team org" >>"$log"; exit 1
  fi
  pid=$(run_claude "$(field "$r" 2)" "$(field "$r" 3)" resume "$kept" "$log" "$(field "$r" 9)")
  add_row "$name" "$(field "$r" 2)" "$(field "$r" 3)" "$pid" "$kept" "$log" "$(field "$r" 8)" "$(field "$r" 9)"
  # Stay alive for the whole turn: a later resume may be queued behind this waiter's pid, and must not start early.
  while kill -0 "$pid" 2>/dev/null; do sleep 30; done
  ;;
recover)
  # Rows from before the report contract (no plugin column) never print STATUS, so "no STATUS" means nothing
  # for them: they resume only when named. A dead waiter's prompt never ran, whatever the log says.
  latest | while IFS=$'\t' read -r name profile sid pid prompt log started org plug; do
    alive "$pid" && continue
    note=$RECOVERY
    if [[ "$pid" == waiting:* ]]; then note="$RECOVERY A queued instruction never ran; read and do it after these checks: $prompt"
    elif [ -n "$(final_status "$log")" ]; then continue; fi
    named=0; for n in "$@"; do [ "$n" = "$name" ] && named=1; done
    [ $# = 0 ] || [ "$named" = 1 ] || continue
    if [ -z "$plug" ] && [ "$named" = 0 ]; then
      [ -f "$log" ] && [ -z "$(find "$log" -mmin +1440)" ] && echo "legacy $name (no report contract; name it to resume)"
      continue
    fi
    echo "interrupted $name profile=$profile sid=${sid:0:8}"
    if [ "$go" = 1 ]; then
      tmp=$(mktemp); printf '%s\n' "$note" >"$tmp"
      ok=(); [ "$personal_ok" = 1 ] && ok=(--personal-ok)
      "$0" resume "$name" "$tmp" ${ok[@]+"${ok[@]}"}; rm -f "$tmp"
    fi
  done
  ;;
status)
  latest | while IFS=$'\t' read -r name profile sid pid prompt log started org plug; do
    p=${pid#waiting:}; state=done
    alive "$pid" && state=$([ "$pid" = "$p" ] && echo running || echo queued)
    [ "$state" = done ] && [ "$all" != 1 ] && [ -n "$(find "$log" -mmin +1440 2>/dev/null)" ] && continue
    age=$( [ -f "$log" ] && echo "$(( ($(date +%s) - $(stat -f %m "$log")) / 60 ))m" || echo "nolog")
    team=$([ "$org" = "$TEAM_ORG" ] && echo team || echo PERSONAL)
    st=""; [ "$state" = done ] && st=$(final_status "$log")
    printf '%-28s %-8s %-5s %-8s %-8s log %-6s %s %s\n' "$name" "$state" "$profile" "$team" "$p" "$age" "${sid:0:8}" "$st"
  done
  ;;
orgcheck)  # stable text: check.sh diffs these lines between ticks
  awk -F'\t' '{o[$2]=$8} END {for (p in o) print p "\t" o[p]}' "$REG" | sort | while IFS=$'\t' read -r p old; do
    now=$(org_of "$p"); [ "$now" = "$old" ] || echo "ORG CHANGED $p registry=${old:0:8} now=${now:0:8}"
  done
  ;;
log)
  r=$(row "${1:?name}"); [ -n "$r" ] || die "no session $1"; tail -c "${2:-1500}" "$(field "$r" 6)"; echo
  ;;
*) die "unknown command $cmd" ;;
esac
