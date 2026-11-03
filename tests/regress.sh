#!/bin/bash
# Offline regression tests, one block per bug found in review (docs/iterations.md).
set -u
. "$(dirname "$0")/lib.sh"

# Round 1, item 1: client-data rules survive resume, --personal-ok and a queued run
"$S" launch team cd1 "$P" --client-data >/dev/null; waitfor "$TMP/logs/cd1.log" STUB
echo personal-org >"$TMP/profiles/team/org"
expect 'marked refuses personal-ok' "$("$S" resume cd1 "$P" --personal-ok 2>&1 | grep -c 'personal org')" 1
expect 'recover refuses personal-ok' "$("$S" recover --go --personal-ok cd1 2>&1 | grep -c 'personal org')" 1
"$S" _run cd1 "$P"; has 'old _run form refuses marked' "$(cat "$TMP/logs/cd1.log")" 'no longer the team org'
echo "$TEAM" >"$TMP/profiles/team/org"
"$S" launch team cd2 "$P" >/dev/null; waitfor "$TMP/logs/cd2.log" STUB; echo personal-org >"$TMP/profiles/team/org"
expect 'resume can add the mark' "$("$S" resume cd2 "$P" --client-data --personal-ok 2>&1 | grep -c 'personal org')" 1
"$S" launch me nc1 "$P" --personal-ok >/dev/null; waitfor "$TMP/logs/nc1.log" STUB
has 'unmarked personal still works' "$("$S" resume nc1 "$P" --personal-ok)" 'resumed nc1'
echo "$TEAM" >"$TMP/profiles/team/org"

# Round 1, item 3: one queued resume per session; a later one is refused, not lost
STUB_SLEEP=20 "$S" launch team q1 "$P" >/dev/null; waitfor "$TMP/logs/q1.log" STUB
has 'first queued' "$("$S" resume q1 "$P")" 'queued q1'
expect 'second refused' "$("$S" resume q1 "$P" 2>&1 | grep -c 'already has a queued resume')" 1
expect 'no third row' "$(grep -c '^q1	' "$TMP/home/state/sessions.tsv")" 2
for p in $(awk -F'\t' '$1=="q1"{print $4}' "$TMP/home/state/sessions.tsv"); do kill "${p#waiting:}" 2>/dev/null; done

# Round 1, item 4: cd in a child shell or subshell stays there
deny deny_merge_git.py "bash -c 'cd /tmp'; git reset --hard" "$A"
deny deny_merge_git.py "(cd /tmp); git reset --hard" "$A"
deny deny_merge_git.py 'x=$(cd /tmp); git reset --hard' "$A"
deny deny_wide_rm.py "bash -c 'cd /tmp'; rm -rf logs" "$V"
deny deny_wide_rm.py "(cd /tmp); rm -rf logs" "$V"
deny deny_merge_git.py "(cd $A && git reset --hard)" /tmp
allow deny_merge_git.py "(cd /tmp && git status); git log" "$A"
allow deny_wide_rm.py "(cd /tmp && rm -rf logs)" "$V"

# Round 1, item 5: same-second prompts keep their own files
mkdir -p "$TMP/fixed"; printf '#!/bin/bash\necho 20260101T000000Z\n' >"$TMP/fixed/date"; chmod +x "$TMP/fixed/date"
echo first >"$TMP/first.md"; echo second >"$TMP/second.md"; "$S" launch team kp "$P" >/dev/null; waitfor "$TMP/logs/kp.log" STUB
PATH="$TMP/fixed:$PATH" "$S" resume kp "$TMP/first.md" >/dev/null; K1=$(tail -1 "$TMP/home/state/sessions.tsv" | cut -f5); sleep 0.3
PATH="$TMP/fixed:$PATH" "$S" resume kp "$TMP/second.md" >/dev/null; K2=$(tail -1 "$TMP/home/state/sessions.tsv" | cut -f5)
expect 'first prompt kept' "$(cat "$K1")" first; expect 'second prompt kept' "$(cat "$K2")" second

# Round 1, item 6: a vanished logs dir stays vanished until setup; launch refuses
mv "$TMP/logs" "$TMP/logs.away"; mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/gh" "$TMP/bin/aws"
"$S" status >/dev/null; "$S" orgcheck >/dev/null
expect 'status keeps it gone' "$([ -d "$TMP/logs" ] && echo there || echo gone)" gone
has 'probe warns' "$(PATH="$TMP/bin:$PATH" "$ROOT/bin/check.sh")" 'DRIVE'
expect 'launch refuses' "$("$S" launch team nolog "$P" 2>&1 | grep -c 'work drive')" 1
expect 'dir still gone' "$([ -d "$TMP/logs" ] && echo there || echo gone)" gone
mv "$TMP/logs.away" "$TMP/logs"; rm -f "$TMP/home/state/heartbeat.last"

# Round 1, item 8: a launch that cannot start says so
mv "$A" "$A.away"; O=$("$S" launch team badcwd "$P" 2>&1); RC=$?; mv "$A.away" "$A"
expect 'launch fails' "$RC" 1; hasnt 'no launched line' "$O" 'launched'; expect 'no row' "$(grep -c '^badcwd	' "$TMP/home/state/sessions.tsv")" 0
"$S" launch team bres "$P" >/dev/null; waitfor "$TMP/logs/bres.log" STUB
mv "$A" "$A.away"; O=$("$S" resume bres "$P" 2>&1); RC=$?; mv "$A.away" "$A"
expect 'resume fails' "$RC" 1; hasnt 'no resumed line' "$O" 'resumed'
echo personal-org >"$TMP/profiles/team/org"; "$S" recover --go bres >/dev/null 2>&1; expect 'recover passes the failure on' "$?" 1; echo "$TEAM" >"$TMP/profiles/team/org"

# Round 1, item 7, by a smaller route: a run with no clean end has no final STATUS
fake() { printf 'fk\tteam\tsid\t999999\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/fk.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"; }
printf -- '--- session.sh run x ---\nSTATUS: waiting\nEVIDENCE: y\n' >"$TMP/logs/fk.log"; fake
has 'killed after STATUS is interrupted' "$("$S" recover)" 'interrupted fk'; hasnt 'killed shows no word' "$("$S" status | grep '^fk ')" 'waiting'
printf -- '--- session.sh end 1\n' >>"$TMP/logs/fk.log"; has 'failed exit is interrupted' "$("$S" recover)" 'interrupted fk'
printf -- '--- session.sh run x ---\nSTATUS: ready\nEVIDENCE: y\n--- session.sh end 0\n' >>"$TMP/logs/fk.log"; hasnt 'clean end is final' "$("$S" recover)" 'interrupted fk'; has 'clean end shows word' "$("$S" status | grep '^fk ')" 'ready'
printf 'STATUS: ready\n' >"$TMP/logs/lg.log"; printf 'lg\tteam\tsid\t999999\t%s\t%s\tt\t%s\t\n' "$P" "$TMP/logs/lg.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"; has 'legacy log with no markers still reads' "$("$S" status | grep '^lg ')" 'ready'
"$S" launch team em "$P" >/dev/null; waitfor "$TMP/logs/em.log" 'session.sh end 0'

# Failure 4: the worker leaves the launcher's process group
STUB_SLEEP=8 "$S" launch team det "$P" >/dev/null; waitfor "$TMP/logs/det.log" STUB
DP=$(tail -1 "$TMP/home/state/sessions.tsv" | cut -f4); DG=$(ps -o pgid= -p "$DP" | tr -d ' ')
expect 'worker leads its own group' "$DG" "$DP"
kill -- "-$DP" 2>/dev/null

# Round 1, item 9: $HOME in a guard path fails loudly instead of disabling the guard
G=$(mktemp -d "$TMP/cfg.XXXXXX"); mkdir -p "$G/state"
for v in '$HOME/x' '~/x' "'/x'" 'rel/x' '`pwd`/x'; do
  sed "s|^PRIMARY_CHECKOUT=.*|PRIMARY_CHECKOUT=\"$v\"|" "$TMP/home/config" >"$G/config"
  echo '{"tool_input":{"command":"ls"},"cwd":"/tmp"}' | AGENT_OPS_HOME="$G" "$H/deny_merge_git.py" >/dev/null 2>&1; expect "bad config value $v" "$?" 1
done
sed 's|^PRIMARY_CHECKOUT=.*|PRIMARY_CHECKOUT="/a path/with spaces"|' "$TMP/home/config" >"$G/config"
echo '{"tool_input":{"command":"ls"},"cwd":"/tmp"}' | AGENT_OPS_HOME="$G" "$H/deny_merge_git.py" >/dev/null 2>&1; expect 'spaces are fine' "$?" 0

# Round 1, item 10: no success without a confirmed merge
GHS="$TMP/ghs"; mkdir -p "$GHS"
cat >"$GHS/gh" <<'GH'
#!/bin/bash
case " $* " in
  *" merge "*) exit 0 ;;
  *headRefOid*) echo '{"headRefOid":"abc1234f","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}' ;;
  *mergeCommit*) [ "$VIEW" = fail ] && exit 1; cat "$VIEWJSON" ;;
esac
GH
chmod +x "$GHS/gh"; MG() { PATH="$GHS:$PATH" VIEW=$1 VIEWJSON="$TMP/view.json" "$ROOT/bin/merge-when-green.sh" o/r 1 abc1234f; }
echo '{"state":"OPEN","mergeCommit":null}' >"$TMP/view.json"; O=$(MG ok); expect 'queued is not merged' "$?" 2; hasnt 'no merged line' "$O" 'merged '
O=$(MG fail); expect 'failed view is not merged' "$?" 2; hasnt 'no merged line 2' "$O" 'merged '
echo '{"state":"MERGED","mergeCommit":{"oid":"deadbeef1234"}}' >"$TMP/view.json"; O=$(MG ok); expect 'merged exits 0' "$?" 0; has 'merged line' "$O" 'merged deadbeef1'

# Round 2, item 1: the registered pid stands for the whole worker
STUB_SLEEP=30 "$S" launch team tm "$P" >/dev/null; waitfor "$TMP/logs/tm.log" STUBPID
TP=$(tail -1 "$TMP/home/state/sessions.tsv" | cut -f4); CP=$(awk '/^STUBPID/{print $2}' "$TMP/logs/tm.log"); kill -TERM "$TP"; sleep 1
expect 'worker gone with its wrapper' "$(kill -0 "$CP" 2>/dev/null && echo alive || echo gone)" gone; hasnt 'no clean end' "$(cat "$TMP/logs/tm.log")" 'session.sh end 0'
STUB_EXIT=7 "$S" launch team ex7 "$P" >/dev/null; waitfor "$TMP/logs/ex7.log" 'session.sh end 7'

# Round 2, item 2: the waiter cannot publish before the launcher does
mkdir -p "$TMP/slow"; rm -f "$TMP/slow/n"; cat >"$TMP/slow/date" <<SLOW
#!/bin/bash
n=\$(cat "$TMP/slow/n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n >"$TMP/slow/n"
[ "\$n" = 2 ] && /bin/sleep 1.5
exec /bin/date "\$@"
SLOW
chmod +x "$TMP/slow/date"; "$S" launch team ord "$P" >/dev/null; waitfor "$TMP/logs/ord.log" STUB; sleep 0.3
PATH="$TMP/slow:$PATH" "$S" resume ord "$P" --after 999999 >/dev/null; sleep 2.5
hasnt 'latest row is not the waiter' "$(tail -1 <(grep '^ord	' "$TMP/home/state/sessions.tsv") | cut -f4)" waiting

# Round 2, item 3: a dead waiter has no final status, and an old log does not hide it
printf -- '--- session.sh run x ---\nSTATUS: ready\nEVIDENCE: y\n--- session.sh end 0\n' >"$TMP/logs/dq.log"; printf 'dq\tteam\tsid\twaiting:999999\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/dq.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"
hasnt 'dead waiter shows no old word' "$("$S" status | grep '^dq ')" 'ready'
touch -t 202001010000 "$TMP/logs/dq.log"; has 'old log does not hide it' "$("$S" status)" 'dq '

# Round 2, item 4: a long run keeps its run marker in view
lg() { { echo '--- session.sh run x ---'; python3 -c 'print("x"*70000)'; printf 'STATUS: ready\nEVIDENCE: y\n'; printf -- "$1"; } >"$TMP/logs/ln.log"; }
printf 'ln\tteam\tsid\t999999\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/ln.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"
lg ''; has 'long, no end: interrupted' "$("$S" recover)" 'interrupted ln'
lg '--- session.sh end 1\n'; has 'long, end 1: interrupted' "$("$S" recover)" 'interrupted ln'
lg '--- session.sh end 0\n'; has 'long, end 0: final' "$("$S" status | grep '^ln ')" 'ready'

# Round 2, item 5: same STATUS, new run, still a change; rows with no STATUS keep their line
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "[]"\n' >"$TMP/bin/gh"; printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/gh" "$TMP/bin/aws"
printf -- 'STATUS: ready\n' >"$TMP/logs/sm.log"; printf 'sm\tteam\tsid\t1111\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/sm.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"
CK() { PATH="$TMP/bin:$PATH" "$ROOT/bin/check.sh"; }; CK >/dev/null; expect 'same again is no change' "$(CK)" 'NO CHANGE'
printf 'sm\tteam\tsid\t2222\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/sm.log" "$TEAM" >>"$TMP/home/state/sessions.tsv"
has 'new run shows' "$(CK)" 'SESSION sm done STATUS:ready'
hasnt 'no STATUS, no pid' "$(grep 'SESSION w ' "$TMP/home/state/heartbeat.last" 2>/dev/null; grep 'SESSION kp' "$TMP/home/state/heartbeat.last")" 'pid='

# Round 2, item 6: an explicit --after must not bypass the running worker
STUB_SLEEP=20 "$S" launch team af "$P" >/dev/null; waitfor "$TMP/logs/af.log" STUB; AP=$(tail -1 "$TMP/home/state/sessions.tsv" | cut -f4)
expect 'dead --after refused while live' "$("$S" resume af "$P" --after 999999 2>&1 | grep -c 'still running')" 1
expect 'no new row' "$(grep -c '^af	' "$TMP/home/state/sessions.tsv")" 1
has 'current pid is fine' "$("$S" resume af "$P" --after "$AP")" 'queued af'
for p in $(awk -F'\t' '$1=="af"{print $4}' "$TMP/home/state/sessions.tsv"); do kill "${p#waiting:}" 2>/dev/null; done

# Round 2, item 7: one quoted literal path per key, the only form bash and Python read alike
G2=$(mktemp -d "$TMP/cfg2.XXXXXX"); mkdir -p "$G2/state"; cfgtest() {
  echo '{"tool_input":{"command":"ls"},"cwd":"/tmp"}' | AGENT_OPS_HOME="$G2" "$H/deny_merge_git.py" >/dev/null 2>&1; expect "$1" "$?" "$2"; }
{ cat "$TMP/home/config"; echo "PRIMARY_CHECKOUT=\"/other\""; } >"$G2/config"; cfgtest 'duplicate key fails' 1
sed 's|^PRIMARY_CHECKOUT=\(.*\)|PRIMARY_CHECKOUT=\1 # main|' "$TMP/home/config" >"$G2/config"; cfgtest 'trailing comment fails' 1
cp "$TMP/home/config" "$G2/config"; cfgtest 'plain config passes' 0

# Round 2, item 8: WORK_ROOT with a trailing slash
sed "s|^WORK_ROOT=.*|WORK_ROOT=\"$V/\"|" "$TMP/home/config" >"$G2/config"
rmcheck() { CMD=$1 python3 -c 'import json,os;print(json.dumps({"tool_input":{"command":os.environ["CMD"]},"cwd":"/tmp"}))' | AGENT_OPS_HOME="$G2" "$H/deny_wide_rm.py"; }
has 'slash root, child denied' "$(rmcheck "rm -rf $V/logs")" 'deny'; expect 'slash root, deep allowed' "$(rmcheck "rm -rf $V/worktrees/s/build")" ""

# Round 2, item 9: cd --
deny deny_merge_git.py "cd -- $A && git reset --hard" /tmp
deny deny_wide_rm.py "cd -- $V && rm -rf logs" /tmp

# Round 2, item 10: a GitHub failure is not "everything went away"
mkdir -p "$TMP/bad"; printf '#!/bin/bash\necho "HTTP 401" >&2; exit 1\n' >"$TMP/bad/gh"; chmod +x "$TMP/bad/gh"
CK >/dev/null; BEFORE=$(cat "$TMP/home/state/heartbeat.last"); touch -t 202001010000 "$TMP/home/state/heartbeat.last"
O=$(PATH="$TMP/bad:$TMP/bin:$PATH" "$ROOT/bin/check.sh" 2>&1); expect 'failed probe exits 1' "$?" 1; has 'failed probe says so' "$O" 'probe failed'; hasnt 'no NO CHANGE' "$O" 'NO CHANGE'
expect 'snapshot kept' "$(cat "$TMP/home/state/heartbeat.last")" "$BEFORE"; expect 'mtime kept' "$(find "$TMP/home/state/heartbeat.last" -mmin +5 | wc -l | tr -d ' ')" 1

# NEXT

echo "regress pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
