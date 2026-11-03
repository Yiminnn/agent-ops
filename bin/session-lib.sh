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
LOAD_WORKER="This session now runs with the current agent-ops plugin: load the agent-ops:worker skill first, follow the rules it names, and end with its report contract."
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
policy() { [ "${AGENT_OPS_PLUGIN:-1}" = 0 ] || echo plugin; }  # every launch path: the plugin, unless turned off explicitly
row() { awk -F'\t' -v n="$1" '$1==n' "$REG" | tail -1; }
field() { cut -f"$2" <<<"$1"; }
add_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(date -u +%FT%TZ)" "$7" "${8:-}" "${9:-}" "${10:-}" >>"$REG"; }
path_ok() {  # name kind(worktree|write) path [own worktree]: print its real path, or die if it reaches past this worker's own tree
  python3 - "$1" "$2" "$3" "${4:-}" "$REG" "$HOME" "$WORK_ROOT" "$PRIMARY_CHECKOUT" <<'EOF' || exit 1
import os, subprocess, sys
name, kind, path, own_arg, reg, *roots = sys.argv[1:]
rp = os.path.realpath
r = rp(path)
def die(m): sys.exit(f"session.sh: --write/--worktree {r}: {m}")
if ":" in r or "\t" in r: die("no ':' or tab")
if kind == "write" and not os.path.isdir(r): die("no such directory")
def holds(a, b): return a == "/" or b == a or b.startswith(a + "/")
rows = [l.rstrip("\n").split("\t") for l in open(reg)]
trees = {f[0]: rp(f[9]) for f in rows if len(f) > 9 and f[9]}  # name -> worktree; the last row wins
own = rp(own_arg) if own_arg else trees.pop(name, "")
trees.pop(name, None)
others = [t for t in trees.values() if t != own]
if kind == "worktree":
    own = r
    if os.path.dirname(r) == rp(roots[1]): die("is a dir directly under WORK_ROOT, such as the worktrees root: name one worktree")
    if os.path.exists(r):  # a missing one is created next, as a linked worktree
        top = subprocess.run(["git", "-C", r, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
        if not top or rp(top) != r: die("is not a git top level of its own: name one worktree")
for h in [rp(x) for x in roots[:2]] + ([rp(os.path.dirname(rp(own)))] if own else []):
    if holds(r, h): die(f"holds {h}: name the one directory the task needs")
for o in [rp(roots[2])] + others:
    if holds(r, o) or holds(o, r): die(f"overlaps {o}, which is not this worker's tree")
print(r)
EOF
}
latest() { awk -F'\t' '{last[$1]=$0; order[$1]=NR} END {for (n in last) print order[n] "\t" last[n]}' "$REG" | sort -n | cut -f2-; }
alive() { local p=${1#waiting:}; [[ "$p" =~ ^[1-9][0-9]*$ ]] && kill -0 "$p" 2>/dev/null; }
final_status() {  # the last STATUS word of the last run, if that run ended with exit 0; a log with no markers predates them
  [ -f "$1" ] || return 0
  awk '/^--- session.sh run /{s=""; m=1; e=""} /^--- session.sh end /{e=$4} $1=="STATUS:" && $2 ~ /^(ready|waiting|blocked|failed)$/{s=$2} END{if (m && e!="0") s=""; print s}' "$1"
}
plugin_unseen() {  # the last run asked for the plugin, and no SessionStart line came before it ended or within 2 minutes
  [ -f "$1" ] || return 0
  local old; old=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')  # BSD and GNU date differ
  awk -v old="$old" '/^--- session.sh run /{p=/ plugin=/ && !/ plugin=off /; t=$4; seen=0; e=0}
    /^--- agent-ops plugin loaded /{seen=1} /^--- session.sh end /{e=1} END{if (p && !seen && (e || t<old)) print "plugin-not-loaded"}' "$1"
}
keep_prompt() {  # copy the prompt next to the registry; print the kept path
  [ -s "$1" ] || die "prompt file missing or empty: $1"
  local dst; dst=$(mktemp "$PROMPTS/$2-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || die "cannot create a prompt file"
  cp "$1" "$dst" && echo "$dst"
}
SANDBOX_WRITES=${SANDBOX_WRITES:-$HOME/.claude/agent-templates/daytona-pg-lane-logs}  # every sandboxed worker: the Daytona PG lane's logs
SANDBOX_TMP=/tmp/claude-$(id -u)  # the TMPDIR the CLI gives sandboxed commands (2.1.309); npm and pip caches go there
sandbox_settings() {  # sid dir writes(:-joined): fill templates/worker-sandbox.json, print the file's path
  mkdir -p "$T/state/sandbox" || return 1
  local IFS=:; for w in $SANDBOX_WRITES; do mkdir -p "$w" || return 1; done; unset IFS
  python3 - "$PLUGIN_DIR/templates/worker-sandbox.json" "$T/state/sandbox/$1.json" "$2" "$3" "$SANDBOX_WRITES" <<'EOF'
import json, os, sys
s = json.load(open(sys.argv[1]))
s["sandbox"]["filesystem"]["allowWrite"] = [os.path.realpath(p) for p in [sys.argv[3]] + sys.argv[5].split(":") + sys.argv[4].split(":") if p]
json.dump(s, open(sys.argv[2], "w"), indent=2)
print(sys.argv[2])
EOF
}
run_claude() {  # profile sid mode(new|resume) prompt log [plugin] [sandbox dir] [extra write paths, :-joined]
  [ -d "$LOGS" ] || die "no $LOGS: is the work drive mounted? Create it only after you check the drive"
  local B; B=$(cli); [ -x "$B" ] || die "no bundled claude CLI found"
  local flag=(--session-id "$2") role="" dir=${7:-} set env=(); [ "$3" = resume ] && flag=(--resume "$2")
  local rev=off; [ "${6:-}" = plugin ] && { flag+=(--plugin-dir "$PLUGIN_DIR"); role=worker; rev=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown); }
  if [ -n "$dir" ]; then  # Bash and its children may write only here, the --write paths and temp
    set=$(sandbox_settings "$2" "$dir" "${8:-}") || die "cannot write the sandbox settings"; flag+=(--settings "$set")
    env=(npm_config_cache="$SANDBOX_TMP/npm-cache" PIP_CACHE_DIR="$SANDBOX_TMP/pip-cache")
  else dir=$PRIMARY_CHECKOUT; fi  # --no-sandbox, or a row from before the sandbox
  cd "$dir" || die "no $dir"
  echo "--- session.sh run $(date -u +%FT%TZ) plugin=$rev cli=$("$B" --version 2>/dev/null | cut -d' ' -f1) ---" >>"$5" || die "cannot write $5"
  env ${env[@]+"${env[@]}"} AGENT_OPS_LOG="$5" AGENT_OPS_ROLE="$role" CLAUDE_CONFIG_DIR="$PROFILES/$1" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    nohup python3 -c "$SETSID" bash -c 'trap "trap - TERM; kill -TERM -- -$$" TERM; "$@" & c=$!; wait "$c"; echo "--- session.sh end $?"' _ "$B" -p "${flag[@]}" --permission-mode bypassPermissions --model "$WORKER_MODEL" "$(cat "$4")" \
    </dev/null >>"$5" 2>&1 &
  echo $!
}
