#!/bin/bash
# Coordinator session tool: launch, resume and list claude -p worker sessions, with one registry.
#
#   session.sh launch <profile> <name> <prompt-file> --worktree <dir> [--repo <checkout> --base <ref> [--branch <b>]] [--write <dir>]... [--client-data] [--personal-ok]
#   session.sh launch <profile> <name> <prompt-file> --no-sandbox [--client-data] [--personal-ok]   # rare; say why
#   session.sh resume <name> <prompt-file> [--after <pid>] [--worktree <dir>] [--write <dir>]... [--personal-ok]  # queue behind a pid, or run now
#   session.sh recover [--go] [--personal-ok] [<name>...]    # list interrupted rows; --go resumes them
#   session.sh status [--all]                                # registry + live pid + log age + final STATUS
#   session.sh orgcheck                                      # ORG CHANGED lines, for check.sh
#   session.sh log <name> [bytes]                            # tail of the session's log
#
# Registry: ~/.claude/agent-templates/state/sessions.tsv
#   name  profile  sid  pid  prompt  log  started_utc  org  [plugin]  [sandbox dir]  [write paths, :-joined]
# Prompts are copied to $T/prompts/ (internal disk) so a wiped work drive
# cannot make a queued resume fail silently. Logs go to $LOGS_DIR/<name>.log.
# Org: launch and resume refuse a personal org unless --personal-ok. --client-data refuses it always
# (real client data never goes to a personal account).
# Plugin: launch, resume, recover and a queued resume all load this plugin (absolute path) as AGENT_OPS_ROLE=worker,
# unless AGENT_OPS_PLUGIN=0. Column 9 records what the last launch did; it does not decide the next one.
# Sandbox: a launch runs the worker in the Claude Code Bash sandbox (templates/worker-sandbox.json, passed with
# --settings), with cwd = --worktree. A missing --worktree dir is created here (unsandboxed) as a linked worktree of
# --repo on a new branch (--branch, default the dir name) from --base. Bash and every child process may write only
# the worktree, SANDBOX_WRITES (default: the Daytona PG lane logs), the --write dirs and temp; npm and pip caches go
# to temp. A --write or --worktree that holds the home dir, WORK_ROOT or the worktrees dir, or overlaps the primary
# checkout or another registered worktree, is refused; so is an existing --worktree that is not its own git top level,
# or any dir directly under WORK_ROOT (a worktrees root). --write dirs are checked before a worktree is made. Resume keeps the worktree and adds new --write dirs.
# A row from before the sandbox, or from --no-sandbox, resumes without it unless the resume names --worktree.
# AGENT_OPS_HOME (default ~/.claude/agent-templates) holds state, prompts and the config; config.example lists its keys.
set -u
. "$(dirname "$0")/session-lib.sh"

cmd=${1:-status}; shift || true
pos=(); personal_ok=0; client=0; after=""; go=0; all=0; wt=""; writes=(); repo=""; base=""; branch=""; nosb=0
while [ $# -gt 0 ]; do
  case "$1" in
    --personal-ok) personal_ok=1 ;; --client-data) client=1 ;; --go) go=1 ;; --all) all=1 ;;
    --after) after=${2:-}; shift ;;
    --worktree) wt=${2:?--worktree <dir>}; shift ;; --write) writes+=("${2:?--write <dir>}"); shift ;;
    --repo) repo=${2:-}; shift ;; --base) base=${2:-}; shift ;; --branch) branch=${2:-}; shift ;; --no-sandbox) nosb=1 ;;
    *) pos+=("$1") ;;
  esac
  shift
done
set -- ${pos[@]+"${pos[@]}"}
add_writes() {  # name; sets wr: $wr plus each checked --write dir, no repeats
  local w; for w in ${writes[@]+"${writes[@]}"}; do w=$(path_ok "$1" write "$w" "$dir") || exit 1; [[ ":$wr:" == *":$w:"* ]] || wr=${wr:+$wr:}$w; done
}
case "$cmd" in
launch)
  [ $# -ge 3 ] || die "usage: launch <profile> <name> <prompt-file> [--client-data] [--personal-ok]"
  profile=$1 name=$2 prompt=$3
  [ -d "$PROFILES/$profile" ] || die "unknown profile $profile"
  [ -z "$(row "$name")" ] || die "name $name already in registry; pick another or use resume"
  [ "$client" = 1 ] && personal_ok=0
  need_org "$profile" "$personal_ok"
  [ -d "$LOGS" ] || die "no $LOGS: is the work drive mounted? Create it only after you check the drive"
  dir=""; wr=""
  if [ "$nosb" = 1 ]; then [ -z "$wt$repo${writes[*]-}" ] || die "--no-sandbox takes no --worktree, --repo or --write"
  else
    [ -n "$wt" ] || die "launch needs --worktree <dir> (with --repo <checkout> --base <ref> to create it), or --no-sandbox with a reason"
    dir=$(path_ok "$name" worktree "$wt") || exit 1
    add_writes "$name"  # before the worktree exists: a refused --write leaves no tree or branch behind
    if [ ! -e "$dir" ]; then
      [ -n "$repo" ] && [ -n "$base" ] || die "--worktree $dir does not exist: pass --repo <checkout> --base <ref> to create it"
      git -C "$repo" worktree add -q "$dir" -b "${branch:-$(basename "$dir")}" "$base" >&2 || die "cannot create worktree $dir"
    fi
    [ -d "$dir" ] || die "--worktree $dir is not a directory"
  fi
  kept=$(keep_prompt "$prompt" "$name") || exit 1
  plug=$(policy)
  sid=$(uuidgen | tr 'A-Z' 'a-z'); log="$LOGS/$name.log"
  [ "$client" = 1 ] && { : >"$(client_mark "$sid")" || die "cannot write the client-data marker"; }
  pid=$(run_claude "$profile" "$sid" new "$kept" "$log" "$plug" "$dir" "$wr") || exit 1
  add_row "$name" "$profile" "$sid" "$pid" "$kept" "$log" "$org" "$plug" "$dir" "$wr"
  echo "launched $name pid=$pid sid=$sid profile=$profile log=$log"
  ;;
resume)
  [ $# -ge 2 ] || die "usage: resume <name> <prompt-file> [--after <pid>] [--personal-ok]"
  name=$1 prompt=$2
  r=$(row "$name"); [ -n "$r" ] || die "no session $name in registry"
  profile=$(field "$r" 2) sid=$(field "$r" 3) log=$(field "$r" 6) plug=$(policy) dir=$(field "$r" 10) wr=$(field "$r" 11)
  if [ -n "$wt" ]; then dir=$(path_ok "$name" worktree "$wt") || exit 1; [ -d "$dir" ] || die "--worktree $dir is not a directory"; fi
  [ -z "$dir" ] && [ ${#writes[@]} -gt 0 ] && die "--write needs a sandboxed row; add --worktree"
  add_writes "$name"
  [ "$client" = 1 ] && { : >"$(client_mark "$sid")" || die "cannot write the client-data marker"; }
  [ -e "$(client_mark "$sid")" ] && personal_ok=0
  need_org "$profile" "$personal_ok"
  kept=$(keep_prompt "$prompt" "$name") || exit 1
  if [ -z "$(field "$r" 9)" ] && [ -n "$plug" ]; then  # first run with the plugin: an old conversation follows old rules
    { printf '%s\n\n' "$LOAD_WORKER"; cat "$prompt"; } >"$kept" || die "cannot write $kept"
  fi
  live=$(field "$r" 4)
  if [[ "$live" == waiting:* ]] && ! alive "$live"; then  # the waiter died; its worker may not have
    live=$(awk -F'\t' -v n="$name" '$1==n && $4 !~ /^waiting:/ {p=$4} END {print p}' "$REG")
  fi
  [[ "$live" == waiting:* ]] && alive "$live" && die "$name already has a queued resume (waiter ${live#waiting:}); wait for it to start, or add this to its prompt"
  [ -n "$after" ] && alive "$live" && [ "$after" != "${live#waiting:}" ] && die "$name is still running; --after must name its current worker pid"
  if [ -z "$after" ] && alive "$live"; then after=${live#waiting:}; fi  # never run two turns at once
  if [ -n "$after" ]; then
    # Detached waiter; the prompt is already on the internal disk, so a wiped external drive cannot drop it.
    recheck=check; [ "$personal_ok" = 1 ] && recheck=""
    nohup python3 -c "$SETSID" bash -c 'while kill -0 "$6" 2>/dev/null; do sleep 0.05; done; while kill -0 "$1" 2>/dev/null; do sleep 30; done; exec "$2" _run "$3" "$4" "$5"' _ \
      "$after" "$0" "$name" "$kept" "$recheck" "$$" </dev/null >>"$log" 2>&1 &
    add_row "$name" "$profile" "$sid" "waiting:$!" "$kept" "$log" "$org" "$plug" "$dir" "$wr"
    echo "queued $name after pid $after (waiter $!)"
  else
    pid=$(run_claude "$profile" "$sid" resume "$kept" "$log" "$plug" "$dir" "$wr") || exit 1
    add_row "$name" "$profile" "$sid" "$pid" "$kept" "$log" "$org" "$plug" "$dir" "$wr"
    echo "resumed $name pid=$pid"
  fi
  ;;
_run)  # internal: the waiter's hand-off once the blocking pid exits. No third arg: a waiter queued before the org check.
  name=$1 kept=$2; r=$(row "$name"); log=$(field "$r" 6)
  [ -s "$kept" ] || { echo "session.sh: queued prompt vanished: $kept" >>"$log"; exit 1; }
  if { [ "${3:-}" = check ] || [ -e "$(client_mark "$(field "$r" 3)")" ]; } && [ "$(org_of "$(field "$r" 2)")" != "$TEAM_ORG" ]; then
    echo "session.sh: queued resume refused: profile $(field "$r" 2) is no longer the team org" >>"$log"; exit 1
  fi
  plug=$(policy)
  pid=$(run_claude "$(field "$r" 2)" "$(field "$r" 3)" resume "$kept" "$log" "$plug" "$(field "$r" 10)" "$(field "$r" 11)") || exit 1
  add_row "$name" "$(field "$r" 2)" "$(field "$r" 3)" "$pid" "$kept" "$log" "$(field "$r" 8)" "$plug" "$(field "$r" 10)" "$(field "$r" 11)"
  # Stay alive for the whole turn: a later resume may be queued behind this waiter's pid, and must not start early.
  while kill -0 "$pid" 2>/dev/null; do sleep 30; done
  ;;
recover)
  # Rows from before the report contract (no plugin column) never print STATUS, so "no STATUS" means nothing
  # for them: they resume only when named. A dead waiter's prompt never ran, whatever the log says.
  latest | tr '\t' '\037' | { rc=0; while IFS=$'\037' read -r name profile sid pid prompt log started org plug _; do  # \037: an empty column stays empty
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
      tmp=$(mktemp "${TMPDIR:-/tmp}/agent-ops-recover.XXXXXX"); printf '%s\n' "$note" >"$tmp"
      ok=(); [ "$personal_ok" = 1 ] && ok=(--personal-ok)
      "$0" resume "$name" "$tmp" ${ok[@]+"${ok[@]}"} || rc=1; rm -f "$tmp"
    fi
  done; exit "$rc"; }
  ;;
status)
  latest | tr '\t' '\037' | while IFS=$'\037' read -r name profile sid pid prompt log started org plug _; do
    p=${pid#waiting:}; state=done
    alive "$pid" && state=$([ "$pid" = "$p" ] && echo running || echo queued)
    [ "$state" = done ] && [[ "$pid" != waiting:* ]] && [ "$all" != 1 ] && [ -n "$(find "$log" -mmin +1440 2>/dev/null)" ] && continue
    age=$( [ -f "$log" ] && echo "$(( ($(date +%s) - $(stat -f %m "$log")) / 60 ))m" || echo "nolog")
    team=$([ "$org" = "$TEAM_ORG" ] && echo team || echo PERSONAL)
    st=""; [ "$state" = done ] && [[ "$pid" != waiting:* ]] && st=$(final_status "$log")
    printf '%-28s %-8s %-5s %-8s %-8s log %-6s %s %s %s\n' "$name" "$state" "$profile" "$team" "$p" "$age" "${sid:0:8}" "$st" "$(plugin_unseen "$log")"
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
