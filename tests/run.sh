#!/bin/bash
# Offline tests: hook scripts (allow and deny), session.sh on a temp registry with a stub CLI, check.sh with stub gh/aws,
# watchdog. Hook cases only pass text to the checkers: nothing here runs pkill, rm -r, a merge or git in the primary checkout.
set -u
. "$(dirname "$0")/lib.sh"

# Guards: only deny_kill (Yimin, 2026-11-04: text hooks gave false positives; keep the harness light)
expect 'only deny_kill guards Bash' "$(jq -r '.hooks.PreToolUse[].hooks[].command' "$ROOT/hooks/hooks.json" | sed 's|.*/||; s|"$||')" deny_kill.py

# 1. kills
K=deny_kill.py
deny $K 'pkill -f "make test"'; deny $K 'pkill -fl foo'; deny $K 'pkill --full foo'; deny $K 'killall python'; deny $K 'pkill python'
deny $K 'sleep 1; pkill -f x'; deny $K 'ls && sudo pkill -f x'; deny $K 'bash -c "pkill -f x"'; deny $K 'echo $(killall x)'
deny $K 'timeout 5 pkill -f x'; deny $K 'pkill -P 123 -f x'; deny $K '/usr/bin/killall x'; deny $K 'for p in a; do pkill $p; done'
allow $K 'kill 1234'; allow $K 'pkill -P 1234'; allow $K 'pkill -P "$PID" python'; allow $K 'echo pkill -f foo'; allow $K 'grep "killall" notes.txt'
allow $K 'git commit -m "deny pkill -f in the hook"'; allow $K 'ls'; allow $K "cat it's"

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

# Org check on launch and resume
expect 'personal refused' "$("$S" launch me w0 "$P" 2>&1 >/dev/null | grep -c 'personal org')" 1
expect 'no row written' "$(wc -l <"$REG" | tr -d ' ')" 0
expect 'client-data beats personal-ok' "$("$S" launch me w0 "$P" --client-data --personal-ok 2>&1 | grep -c 'personal org')" 1
has 'team launch' "$("$S" launch team w1 "$P")" 'launched w1'; waitfor "$TMP/logs/w1.log" 'STUB'
has 'plugin default on' "$(cat "$TMP/logs/w1.log")" "--plugin-dir $ROOT"; has 'role worker by default' "$(cat "$TMP/logs/w1.log")" 'role=[worker]'
AGENT_OPS_PLUGIN=0 "$S" launch team w0 "$P" >/dev/null; waitfor "$TMP/logs/w0.log" 'STUB'
hasnt 'AGENT_OPS_PLUGIN=0 off' "$(cat "$TMP/logs/w0.log")" '--plugin-dir'; has 'off: no role' "$(cat "$TMP/logs/w0.log")" 'role=[]'
has 'personal-ok launch' "$("$S" launch me w2 "$P" --personal-ok)" 'launched w2'; waitfor "$TMP/logs/w2.log" 'STUB'
expect 'resume personal refused' "$("$S" resume w2 "$P" 2>&1 | grep -c 'personal org')" 1
has 'resume personal-ok' "$("$S" resume w2 "$P" --personal-ok)" 'resumed w2'

# Plugin on every path; only an explicit AGENT_OPS_PLUGIN=0 turns it off
AGENT_OPS_PLUGIN=1 "$S" launch team w3 "$P" >/dev/null; waitfor "$TMP/logs/w3.log" 'STUB'
has 'plugin on' "$(cat "$TMP/logs/w3.log")" "--plugin-dir $ROOT"; has 'role worker' "$(cat "$TMP/logs/w3.log")" 'role=[worker]'
"$S" resume w3 "$P" >/dev/null; waitfor "$TMP/logs/w3.log" '--resume'
has 'resume keeps plugin' "$(grep -e --resume "$TMP/logs/w3.log")" '--plugin-dir'
"$S" resume w1 "$P" >/dev/null; waitfor "$TMP/logs/w1.log" '--resume'; AGENT_OPS_PLUGIN=0 "$S" resume w0 "$P" >/dev/null; waitfor "$TMP/logs/w0.log" '--resume'; hasnt 'explicit off on resume' "$(cat "$TMP/logs/w0.log")" '--plugin-dir'

# Waiters: the queued form and the old two-argument _run form; a recheck refuses a changed org
has 'queued' "$("$S" resume w1 "$P" --after 999999)" 'queued w1'; sleep 0.5
expect 'waiter ran' "$(grep -c -e '--resume' "$TMP/logs/w1.log")" 2
"$S" _run w1 "$P"; expect 'old _run form' "$(grep -c -e '--resume' "$TMP/logs/w1.log")" 3
echo other >"$TMP/profiles/team/org"; "$S" _run w1 "$P" check; has 'recheck refused' "$(cat "$TMP/logs/w1.log")" 'no longer the team org'
has 'ORG CHANGED' "$("$S" orgcheck)" 'ORG CHANGED team registry=team-org now=other'
echo "$TEAM" >"$TMP/profiles/team/org"; expect 'org stable' "$("$S" orgcheck)" ""

# recover: contract rows only unless named; a final STATUS or a live pid is left alone; a dead waiter is resumed
AGENT_OPS_PLUGIN=0 "$S" launch team old "$P" >/dev/null; waitfor "$TMP/logs/old.log" STUB
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

# DELIVER: each line of a finished report prints on every tick until handled.txt has "deliver <session> <n>"
HD="$TMP/home/state/handled.txt"; C >/dev/null
printf -- 'DELIVER: Liz | reply on the budget | /tmp/r.md\nEVIDENCE: x\nDELIVER: Shubhangi | eval table | -\n' >>"$TMP/logs/w3.log"
O=$(C); has 'deliver 1' "$O" 'NEW DELIVER w3 1 Liz | reply on the budget | /tmp/r.md'; has 'deliver 2' "$O" 'NEW DELIVER w3 2 Shubhangi | eval table | -'
O=$(C); has 'deliver re-emitted' "$O" 'NEW DELIVER w3 1 Liz'; has 'deliver 2 re-emitted' "$O" 'NEW DELIVER w3 2'
hasnt 'deliver not in the snapshot' "$(cat "$TMP/home/state/heartbeat.last")" 'DELIVER'
echo 'deliver w3 1' >>"$HD"; O=$(C); hasnt 'handled deliver cleared' "$O" 'DELIVER w3 1'; has 'other still open' "$O" 'NEW DELIVER w3 2'
echo 'deliver w3 2' >>"$HD"; expect 'all delivered: no change' "$(C)" 'NO CHANGE'
sleep 300 & DLIVE=$!; printf 'DELIVER: Liz | draft | -\n' >"$TMP/logs/dl.log"; printf 'dl\tteam\tsidd\t%s\t%s\t%s\tt\t%s\tplugin\n' "$DLIVE" "$P" "$TMP/logs/dl.log" "$TEAM" >>"$REG"
hasnt 'running session: no deliver yet' "$(C)" 'DELIVER dl'; kill "$DLIVE"; wait "$DLIVE" 2>/dev/null; has 'deliver once it ends' "$(C)" 'NEW DELIVER dl 1 Liz | draft'; echo 'deliver dl 1' >>"$HD"

# SKILL STALE: the coordinator's SessionStart records the plugin rev; check.sh says so every tick while the plugin differs
REV=$(git -C "$ROOT" rev-parse --short HEAD); RF="$TMP/home/state/coordinator-plugin-rev"
echo '{"source":"startup"}' | AGENT_OPS_ROLE=coordinator CLAUDE_PLUGIN_ROOT="$ROOT" "$H/session_start.sh" >/dev/null
expect 'start records rev' "$(cat "$RF")" "$REV"; expect 'same rev: no change' "$(C)" 'NO CHANGE'
echo 0000000 >"$RF"; has 'stale skill' "$(C)" "NEW SKILL STALE 0000000→$REV"; has 'stale re-emitted' "$(C)" 'NEW SKILL STALE'
echo "$REV" >"$RF"; expect 'rev written back: no change' "$(C)" 'NO CHANGE'
mkdir -p "$TMP/nogit"; echo 0000000 >"$RF"; echo '{"source":"startup"}' | AGENT_OPS_ROLE=coordinator CLAUDE_PLUGIN_ROOT="$TMP/nogit" "$H/session_start.sh" >/dev/null 2>&1
expect 'no git rev: no record' "$(cat "$RF" 2>/dev/null)" ''

# SessionStart
SS() { echo "{\"source\":\"${2:-startup}\"}" | AGENT_OPS_ROLE=$1 CLAUDE_PLUGIN_ROOT="$ROOT" "$H/session_start.sh"; }
touch "$TMP/home/state/handoff-2026-01-01.md"; printf '## Freeze\n- dev: open\n## Deploy lock\n- prod: none\n## Owners\n- x\n' >"$TMP/home/state/coordinator.md"
expect 'start worker silent' "$(SS worker)" ""; O=$(SS coordinator); has 'start handoff' "$O" 'handoff-2026-01-01.md'; has 'start locks' "$O" '- prod: none'; has 'start status' "$O" 'w3'; hasnt 'start owners' "$O" 'Owners'
has 'start on resume too' "$(SS coordinator resume)" 'handoff-2026-01-01.md'

# Watchdog: judges heartbeat.done (end of a tick); heartbeat.last (Probe, start of a tick) only until the first done exists
D="$ROOT/scripts/watchdog.sh"; LAST="$TMP/home/state/heartbeat.last"; DONE="$TMP/home/state/heartbeat.done"; AL="$TMP/alerts"; rm -f "$TMP/home/state/watchdog."* "$DONE"; echo "$(date -u +%FT%H:%MZ) ok" >"$TMP/home/state/drift-audit.done"  # a fresh audit: these tests judge the heartbeat
WD() { AGENT_OPS_ALERT_CMD="$TMP/bin/alert" "$D"; }; printf '#!/bin/bash\necho "$1" >>"%s"\n' "$AL" >"$TMP/bin/alert"; chmod +x "$TMP/bin/alert"
N() { cat "$AL" 2>/dev/null | wc -l | tr -d ' '; }; OLD() { touch -t 202001010000 "$1"; }
touch "$LAST"; WD; expect 'no done, fresh last: no alert' "$(N)" 0
OLD "$LAST"; WD; has 'no done, stale last alerts' "$(cat "$AL")" 'heartbeat'; has 'fallback named' "$(cat "$AL")" 'no heartbeat.done yet'; WD; expect 'alert once' "$(N)" 1
touch "$LAST"; WD; OLD "$LAST"; WD; expect 'second episode' "$(N)" 2
touch "$LAST"; echo '2026-11-03T10:00Z ok' >"$DONE"; WD; expect 'fresh done: no alert' "$(N)" 2
OLD "$DONE"; touch "$LAST"; WD; expect 'stale done alerts, fresh last' "$(N)" 3; hasnt 'no fallback note' "$(tail -1 "$AL")" 'no heartbeat.done yet'; WD; expect 'stale done once' "$(N)" 3
echo '2026-11-03T11:00Z ok' >"$DONE"; WD; echo '2026-11-03T12:00Z failed: slack 500' >"$DONE"; WD; has 'failed alerts' "$(tail -1 "$AL")" 'last tick failed: slack 500'
WD; expect 'failed once' "$(N)" 4; echo '2026-11-03T13:00Z ok' >"$DONE"; WD; echo '2026-11-03T14:00Z failed: x' >"$DONE"; WD; expect 'failed second episode' "$(N)" 5
rm -f "$TMP/home/state/watchdog.alerted"; touch "$TMP/home/state/heartbeat.stopped"; WD; expect 'stopped: failed silent' "$(N)" 5
OLD "$DONE"; WD; expect 'stopped: stale silent' "$(N)" 5; rm "$TMP/home/state/heartbeat.stopped"
echo '2026-11-03T15:00Z ok' >"$DONE"; OLD "$DONE"; "$D" 2>/dev/null; expect 'no alert cmd exits 3' "$?" 3; has 'alert file' "$(cat "$TMP/home/state/watchdog.alert")" 'heartbeat'

bash "$(dirname "$0")/regress.sh" || fail=$((fail+1))
bash "$(dirname "$0")/sandbox.sh" || fail=$((fail+1))
bash "$(dirname "$0")/default.sh" || fail=$((fail+1))
bash "$(dirname "$0")/drift.sh" || fail=$((fail+1))
bash "$(dirname "$0")/commitments.sh" || fail=$((fail+1))
echo "pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
