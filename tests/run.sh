#!/bin/bash
# Offline tests: hook scripts (allow and deny), session.sh on a temp registry with a stub CLI, check.sh with stub gh/aws,
# watchdog. Hook cases only pass text to the checkers: nothing here runs pkill, rm -r, a merge or git in the primary checkout.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); H="$ROOT/hooks/scripts"
TMP=$(mktemp -d /tmp/agent-ops-test.XXXXXX)
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
GH_REPOS="o/app o/web"
DEPLOY_REPO="o/app"
DEPLOY_BRANCH="dev"
BOT_REVIEWERS="codex"
SSO_PROFILE="p"
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

# 1. kills
K=deny_kill.py
deny $K 'pkill -f "make test"'; deny $K 'pkill -fl foo'; deny $K 'pkill --full foo'; deny $K 'killall python'; deny $K 'pkill python'
deny $K 'sleep 1; pkill -f x'; deny $K 'ls && sudo pkill -f x'; deny $K 'bash -c "pkill -f x"'; deny $K 'echo $(killall x)'
deny $K 'timeout 5 pkill -f x'; deny $K 'pkill -P 123 -f x'; deny $K '/usr/bin/killall x'; deny $K 'for p in a; do pkill $p; done'
allow $K 'kill 1234'; allow $K 'pkill -P 1234'; allow $K 'pkill -P "$PID" python'; allow $K 'echo pkill -f foo'; allow $K 'grep "killall" notes.txt'
allow $K 'git commit -m "deny pkill -f in the hook"'; allow $K 'ls'; allow $K "cat it's"

# 2. merge and primary-checkout git
M=deny_merge_git.py
deny $M 'gh pr merge 12 -R o/r --squash'; deny $M 'gh -R o/r pr merge 12'; deny $M 'gh pr --repo o/r merge 12'; deny $M 'while :; do gh pr merge 1; sleep 30; done'
deny $M 'gh api -X PUT repos/o/r/pulls/1/merge'; deny $M "gh api graphql -f query='mutation{mergePullRequest}'"
allow $M 'merge-when-green.sh o/r 12 abc1234'; allow $M '~/.claude/agent-templates/merge-when-green.sh o/r 1 abc1234 --merge'
allow $M 'gh pr view 12'; allow $M 'gh pr list --search merge'; allow $M 'grep "gh pr merge" README.md'; allow $M 'gh api repos/o/r/pulls/1'
deny $M 'git commit -m x' $A; deny $M "git -C $A checkout dev -- ." /tmp; deny $M "cd $A && git reset --hard" /tmp; deny $M "git --git-dir=$A/.git push origin x" /tmp
deny $M 'git stash' $A; deny $M 'git stash list' $A; deny $M 'git worktree remove x' $A; deny $M 'git worktree prune' $A; deny $M 'git branch -D x' $A
deny $M 'git branch newb' $A; deny $M 'git clean -fd' $A; deny $M 'git pull' $A; deny $M 'git update-ref refs/x y' $A; deny $M 'gh pr checkout 12' $A
deny $M 'git status && git add .' "$A/backend"; deny $M "bash -c 'git -C $A merge x'" /tmp; deny $M 'git -c a=b commit' $A; deny $M 'git tag v1' $A
allow $M 'git status' $A; allow $M 'git log --oneline' $A; allow $M 'git diff' "$A/backend"; allow $M 'git fetch origin dev' $A; allow $M 'git branch -a' $A
allow $M "git -C $A worktree add $V/worktrees/s -b b/s origin/dev" /tmp; allow $M "git worktree remove $V/worktrees/s" $A; deny $M "git worktree remove --force $V/worktrees/s" $A; allow $M 'git worktree list' $A; allow $M 'git config --get user.name' $A
allow $M 'git commit -m x' $V/worktrees/s; allow $M "git -C $V/worktrees/s push origin x" $A; allow $M 'git commit -m x' "$A/.worktrees/s"
allow $M 'gh pr checkout 12' $V/worktrees/s; allow $M 'git commit -m "git reset --hard is bad"' /tmp

# 3. wide rm
W=deny_wide_rm.py; VU=$(echo "$V" | tr a-z A-Z)
deny $W 'rm -rf /'; deny $W 'rm -rf /*'; deny $W 'rm -r ~'; deny $W 'rm -rf ~/'; deny $W 'rm -rf "$HOME"'; deny $W 'rm -rf ${HOME}/*'; deny $W "rm -r $V"; deny $W "rm -fr $V/"
deny $W "rm -rf $V/*"; deny $W "rm -Rf $V/logs"; deny $W "rm --recursive --force $V/worktrees"; deny $W "cd $V && rm -rf logs" /tmp; deny $W 'rm -rf logs' $V; deny $W 'rm -rf .' $V/logs
deny $W 'rm -rf ..' $V/logs/x/.. ; deny $W "sudo rm -rf $V/logs"; deny $W "bash -c 'rm -rf /'"; deny $W "ls; rm -rf -- $V/x"; deny $W "rm -rf $(dirname "$V")"; deny $W 'rm -rf /Users'; deny $W "rm -rf $VU/logs"
allow $W "rm -rf $V/worktrees/agent-ops-scratch/x"; allow $W 'rm -rf /tmp/foo'; allow $W 'rm -rf build' $V/worktrees/s; allow $W "rm $V/x"; allow $W 'rm -f ~/x'; allow $W "echo rm -rf /"; allow $W 'rm -rf ~/scratch/x'
allow $W "grep 'rm -rf /' notes.md"; allow $W 'git commit -m "rm -rf / is bad"'; allow $W 'python3 -c "import shutil"'

# 4. Stop hook
stop() { MSG=$1 ACTIVE=${2:-false} BG=${3:-[]} python3 -c 'import json,os;print(json.dumps({"last_assistant_message":os.environ["MSG"],"stop_hook_active":os.environ["ACTIVE"]=="true","background_tasks":json.loads(os.environ["BG"])}))' | AGENT_OPS_ROLE=${ROLE-worker} "$H/stop_status.py"; }
GOOD=$'done\nSTATUS: ready\nEVIDENCE: pytest exit 0 at abc123'
has 'stop none' "$(stop 'all finished')" '"decision": "block"'
has 'stop bold' "$(stop '**STATUS: ready**')" '"decision": "block"'
has 'stop bad word' "$(stop $'STATUS: done\nEVIDENCE: x')" '"decision": "block"'
has 'stop no evidence' "$(stop 'STATUS: ready')" 'no EVIDENCE'
has 'stop blocked no q' "$(stop $'STATUS: blocked\nEVIDENCE: x')" 'QUESTION'
has 'stop q not blocked' "$(stop $'STATUS: ready\nQUESTION: ok?\nEVIDENCE: x')" 'only for'
expect 'stop ok' "$(stop "$GOOD")" ""
expect 'stop blocked ok' "$(stop $'STATUS: blocked\nQUESTION: which base?\nEVIDENCE: x')" ""
expect 'stop once' "$(stop 'no report' true)" ""
expect 'stop background' "$(stop 'waiting' false '[{"id":"a"}]')" ""
expect 'stop not worker' "$(ROLE=coordinator stop 'no report')" ""
expect 'stop no role' "$(ROLE= stop 'no report')" ""

# Stub CLI + temp state
mkdir -p "$TMP/stub" "$TMP/logs"; for p in team me; do mkdir -p "$TMP/profiles/$p"; done
echo "$TEAM" >"$TMP/profiles/team/org"; echo personal-org >"$TMP/profiles/me/org"
cat >"$STUB" <<'EOF'
#!/bin/bash
[ "$1" = auth ] && { printf '{"orgId":"%s"}\n' "$(cat "$CLAUDE_CONFIG_DIR/org")"; exit 0; }
echo "STUB role=[$AGENT_OPS_ROLE] $*"
[ -n "${STUB_REPORT:-}" ] && echo "STATUS: $STUB_REPORT"
exit 0
EOF
chmod +x "$STUB"; S="$ROOT/bin/session.sh"; REG="$TMP/home/state/sessions.tsv"; P="$TMP/p.md"; echo do-work >"$P"
waitfor() { local i=0; until grep -q -- "$2" "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && { bad "timeout waiting for $2 in $1"; return; }; sleep 0.1; done; ok; }

# Org check on launch and resume
expect 'personal refused' "$("$S" launch me w0 "$P" 2>&1 >/dev/null | grep -c 'personal org')" 1
expect 'no row written' "$(wc -l <"$REG" | tr -d ' ')" 0
expect 'client-data beats personal-ok' "$("$S" launch me w0 "$P" --client-data --personal-ok 2>&1 | grep -c 'personal org')" 1
has 'team launch' "$("$S" launch team w1 "$P")" 'launched w1'; waitfor "$TMP/logs/w1.log" 'STUB'
hasnt 'plugin default off' "$(cat "$TMP/logs/w1.log")" '--plugin-dir'; has 'no role' "$(cat "$TMP/logs/w1.log")" 'role=[]'
has 'personal-ok launch' "$("$S" launch me w2 "$P" --personal-ok)" 'launched w2'; waitfor "$TMP/logs/w2.log" 'STUB'
expect 'resume personal refused' "$("$S" resume w2 "$P" 2>&1 | grep -c 'personal org')" 1
has 'resume personal-ok' "$("$S" resume w2 "$P" --personal-ok)" 'resumed w2'

# Plugin behind the variable; resume keeps it
AGENT_OPS_PLUGIN=1 "$S" launch team w3 "$P" >/dev/null; waitfor "$TMP/logs/w3.log" 'STUB'
has 'plugin on' "$(cat "$TMP/logs/w3.log")" "--plugin-dir $ROOT"; has 'role worker' "$(cat "$TMP/logs/w3.log")" 'role=[worker]'
"$S" resume w3 "$P" >/dev/null; waitfor "$TMP/logs/w3.log" '--resume'
has 'resume keeps plugin' "$(grep -e --resume "$TMP/logs/w3.log")" '--plugin-dir'
"$S" resume w1 "$P" >/dev/null; waitfor "$TMP/logs/w1.log" '--resume'; hasnt 'legacy resume stays off' "$(AGENT_OPS_PLUGIN=1 cat "$TMP/logs/w1.log")" '--plugin-dir'

# Waiters: the queued form and the old two-argument _run form; a recheck refuses a changed org
has 'queued' "$("$S" resume w1 "$P" --after 999999)" 'queued w1'; sleep 0.5
expect 'waiter ran' "$(grep -c -e '--resume' "$TMP/logs/w1.log")" 2
"$S" _run w1 "$P"; expect 'old _run form' "$(grep -c -e '--resume' "$TMP/logs/w1.log")" 3
echo other >"$TMP/profiles/team/org"; "$S" _run w1 "$P" check; has 'recheck refused' "$(cat "$TMP/logs/w1.log")" 'no longer the team org'
has 'ORG CHANGED' "$("$S" orgcheck)" 'ORG CHANGED team registry=team-org now=other'
echo "$TEAM" >"$TMP/profiles/team/org"; expect 'org stable' "$("$S" orgcheck)" ""

# recover: contract rows only unless named; a final STATUS or a live pid is left alone; a dead waiter is resumed
"$S" launch team old "$P" >/dev/null; waitfor "$TMP/logs/old.log" STUB
AGENT_OPS_PLUGIN=1 "$S" launch team cut "$P" >/dev/null; waitfor "$TMP/logs/cut.log" STUB
AGENT_OPS_PLUGIN=1 STUB_REPORT=ready "$S" launch team fin "$P" >/dev/null; waitfor "$TMP/logs/fin.log" 'STATUS'
sleep 300 & LIVE=$!; AGENT_OPS_PLUGIN=1 "$S" launch team live "$P" >/dev/null; printf 'live\tteam\tsid\t%s\t%s\t%s\tt\to\tplugin\n' "$LIVE" "$P" "$TMP/logs/live.log" >>"$REG"
printf 'q\tteam\tsidq\twaiting:999999\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/q.log" "$TEAM" >>"$REG"; echo $'STATUS: ready' >"$TMP/logs/q.log"
L=$("$S" recover); has 'lists cut' "$L" 'interrupted cut'; has 'lists dead waiter' "$L" 'interrupted q'; has 'lists legacy' "$L" 'legacy old'
hasnt 'skips final' "$L" 'interrupted fin'; hasnt 'skips live' "$L" 'interrupted live'; hasnt 'no resume when listing' "$(cat "$TMP/logs/cut.log")" '--resume'
"$S" recover --go >/dev/null; waitfor "$TMP/logs/cut.log" '--resume'; waitfor "$TMP/logs/cut.log" 'check the worktree'; waitfor "$TMP/logs/q.log" 'never ran'
hasnt 'legacy not resumed' "$(cat "$TMP/logs/old.log")" '--resume'
"$S" recover --go old >/dev/null; waitfor "$TMP/logs/old.log" 'check the worktree'
kill "$LIVE" 2>/dev/null

# status shows the final STATUS of the last run only
sleep 0.3; has 'status word' "$("$S" status | grep '^fin ')" ' ready'
hasnt 'status none' "$("$S" status | grep '^w3 ')" ' ready'
printf -- '--- session.sh run x ---\nno report\n' >>"$TMP/logs/fin.log"; hasnt 'old STATUS ignored' "$("$S" status | grep '^fin ')" ' ready'

# check.sh with stub gh/aws; ticks update heartbeat.last's mtime
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/"*
C() { PATH="$TMP/bin:$PATH" "$ROOT/bin/check.sh"; }
has 'check first' "$(C)" 'SSO ok'; has 'check session' "$(sed -n '/SESSION w3/p' "$TMP/home/state/heartbeat.last")" 'SESSION w3 done'
expect 'check no change' "$(C)" 'NO CHANGE'; touch -t 202001010000 "$TMP/home/state/heartbeat.last"; C >/dev/null
expect 'NO CHANGE touches mtime' "$(find "$TMP/home/state/heartbeat.last" -mmin +5)" ""
echo other >"$TMP/profiles/team/org"; has 'check org' "$(C)" 'ORG CHANGED team'; expect 'check org stable' "$(C)" 'NO CHANGE'
echo "$TEAM" >"$TMP/profiles/team/org"
printf -- 'STATUS: blocked\n' >>"$TMP/logs/w3.log"; has 'check status' "$(C)" 'SESSION w3 done STATUS:blocked'

# SessionStart
SS() { AGENT_OPS_ROLE=$1 CLAUDE_PLUGIN_ROOT="$ROOT" "$H/session_start.sh"; }
touch "$TMP/home/state/handoff-2026-01-01.md"; printf '## Freeze\n- dev: open\n## Deploy lock\n- prod: none\n## Owners\n- x\n' >"$TMP/home/state/coordinator.md"
expect 'start worker silent' "$(SS worker)" ""; O=$(SS coordinator); has 'start handoff' "$O" 'handoff-2026-01-01.md'; has 'start locks' "$O" '- prod: none'; has 'start status' "$O" 'w3'; hasnt 'start owners' "$O" 'Owners'

# Watchdog
D="$ROOT/scripts/watchdog.sh"; LAST="$TMP/home/state/heartbeat.last"; AL="$TMP/alerts"; rm -f "$TMP/home/state/watchdog."*
WD() { AGENT_OPS_ALERT_CMD="$TMP/bin/alert" "$D"; }; printf '#!/bin/bash\necho "$1" >>"%s"\n' "$AL" >"$TMP/bin/alert"; chmod +x "$TMP/bin/alert"
touch "$LAST"; WD; expect 'fresh no alert' "$(cat "$AL" 2>/dev/null)" ""
touch -t 202001010000 "$LAST"; WD; has 'stale alerts' "$(cat "$AL")" 'heartbeat'; WD; expect 'alert once' "$(wc -l <"$AL" | tr -d ' ')" 1
touch "$LAST"; WD; touch -t 202001010000 "$LAST"; WD; expect 'second episode' "$(wc -l <"$AL" | tr -d ' ')" 2
rm -f "$TMP/home/state/watchdog.alerted"; touch "$TMP/home/state/heartbeat.stopped"; WD; expect 'intentional stop' "$(wc -l <"$AL" | tr -d ' ')" 2; rm "$TMP/home/state/heartbeat.stopped"
"$D" 2>/dev/null; expect 'no alert cmd exits 3' "$?" 3; has 'alert file' "$(cat "$TMP/home/state/watchdog.alert")" 'heartbeat'

echo "pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
