#!/bin/bash
# Offline tests for the goal-drift controls: the dispatch gate in session.sh, drift-check.sh, drift-audit.sh and the
# watchdog's audit check. Stub CLI, stub gh, fixed clock (AGENT_OPS_NOW); nothing here reads real state.
set -u
. "$(dirname "$0")/lib.sh"
R="$ROOT/bin/session.sh"; ST="$TMP/home/state"; CM="$ST/commitments.md"
commit() {  # rows "DEF-n|objective|human|done-when|next proof|checkpoint|executor" -> commitments.md, generated at $GEN
  { echo '# Commitments'; [ "${GEN:-}" = - ] || echo "generated ${GEN:-2026-11-03T17:30Z} from Linear label committed; do not edit"; echo 'Ops allowance: heartbeat, PR review, merges, recovery, the daily drift audit.'; echo
    echo '| DEF | objective | accountable | done-when | next proof | checkpoint | executor |'; echo '|---|---|---|---|---|---|---|'
    for r in "$@"; do echo "| ${r//|/ | } |"; done; } >"$CM"
}
: >"$REG"; commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'

# Dispatch gate: launch names --goal DEF-n --expect, or --ops; the goal must be a row in commitments.md
n=$(wc -l <"$REG" | tr -d " ")
has 'launch untagged refused' "$("$R" launch team g0 "$P" --no-sandbox 2>&1)" 'needs --goal DEF-n --expect'
has 'uncommitted goal refused' "$("$R" launch team g0 "$P" --no-sandbox --goal DEF-901 --expect 'a PR' 2>&1)" 'DEF-901 is not a row in'
has 'goal needs expect' "$("$R" launch team g0 "$P" --no-sandbox --goal DEF-900 2>&1)" '--expect'
has 'goal and ops exclusive' "$("$R" launch team g0 "$P" --no-sandbox --goal DEF-900 --expect x --ops y 2>&1)" 'not both'
expect 'no rows for refusals' "$(wc -l <"$REG" | tr -d ' ')" "$n"
has 'goal launch' "$("$R" launch team g1 "$P" --no-sandbox --goal DEF-900 --expect 'PR with drift-check.sh')" 'launched g1'
expect 'goal recorded' "$(tail -1 "$REG" | cut -f12-13)" $'DEF-900\tPR with drift-check.sh'
has 'ops launch' "$("$R" launch team g2 "$P" --no-sandbox --ops 'review PR 12')" 'launched g2'
expect 'ops recorded' "$(tail -1 "$REG" | cut -f12-13)" $'ops\treview PR 12'
mv "$CM" "$CM.away"; has 'no commitments file' "$("$R" launch team g3 "$P" --no-sandbox --goal DEF-900 --expect x 2>&1)" 'no '"$CM"; mv "$CM.away" "$CM"

# Resume: new work names a tag; the same work says --continue and records none; recover continues
waitfor "$TMP/logs/g1.log" 'session.sh end'
has 'resume untagged refused' "$("$R" resume g1 "$P" 2>&1)" '--continue'
has 'resume continue' "$("$R" resume g1 "$P" --continue)" 'resumed g1'; expect 'continue records no tag' "$(tail -1 "$REG" | cut -f12)" ''
waitfor "$TMP/logs/g1.log" '--resume'; sleep 0.3
has 'resume new goal' "$("$R" resume g1 "$P" --goal DEF-900 --expect 'second PR')" 'resumed g1'; expect 'resume tag' "$(tail -1 "$REG" | cut -f12-13)" $'DEF-900\tsecond PR'
has 'resume bad goal refused' "$("$R" resume g1 "$P" --goal DEF-1 --expect x 2>&1)" 'DEF-1 is not a row'
STUB_SLEEP=5 "$R" launch team g4 "$P" --no-sandbox --ops 'long one' >/dev/null; waitfor "$TMP/logs/g4.log" STUB
has 'queued resume' "$("$R" resume g4 "$P" --ops 'next step')" 'queued g4'; expect 'waiter row carries the tag' "$(tail -1 "$REG" | cut -f12-13)" $'ops\tnext step'
for p in $(awk -F'\t' '$1=="g4"{print $4}' "$REG"); do kill "${p#waiting:}" 2>/dev/null; done
printf 'g5\tteam\tsid5\t999999\t%s\t%s\tt\t%s\tplugin\n' "$P" "$TMP/logs/g5.log" "$TEAM" >>"$REG"
has 'recover resumes without a tag' "$("$R" recover --go g5 2>&1)" 'resumed g5'

# drift-check.sh: mechanical exceptions from commitments.md, the registry, pending.md and gh; UNKNOWN on a missing input
mkdir -p "$TMP/bin"; GHLOG="$TMP/gh.log"
cat >"$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >>"$GHLOG"; [ -n "${GH_FAIL:-}" ] && exit 1
case " $* " in *" -R o/app "*DEF-950*) echo '[{"number":12,"title":"planner persistence","body":"DEF 950","mergedAt":"2026-11-01T10:00:00Z","url":"https://github.com/o/app/pull/12"},{"number":13,"title":"x","body":"DEF 9501","mergedAt":"2026-11-02T10:00:00Z","url":"u13"}]' ;; *) echo '[]' ;; esac
GH
chmod +x "$TMP/bin/gh"; export GHLOG
DC() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=${NOW:-2026-11-03T18:00:00Z} "$ROOT/bin/drift-check.sh"; }
rm -f "$CM"; O=$(DC); expect 'missing commitments exits 2' "$?" 2; has 'missing commitments UNKNOWN' "$O" 'DRIFT UNKNOWN: commitments.md'
commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'
O=$(DC); expect 'missing pending exits 2' "$?" 2; has 'missing pending UNKNOWN' "$O" 'DRIFT UNKNOWN: pending.md'
: >"$ST/pending.md"; touch "$ST/drift-check.last"; sleep 1
STUB_SLEEP=30 "$R" launch team t1 "$P" --no-sandbox --goal DEF-900 --expect 'tooling PR' >/dev/null
O=$(DC); expect 'clean exits 0' "$?" 0; expect 'clean is silent' "$O" ''
"$R" launch team o1 "$P" --no-sandbox --ops 'review PR 7' >/dev/null
O=$(DC); expect 'findings exit 1' "$?" 1; has 'ops dispatch listed' "$O" 'DRIFT DISPATCH ops o1'; has 'ops reason' "$O" 'review PR 7'
hasnt 'goal dispatch not listed' "$O" 'DISPATCH DEF-900'
commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|2026-11-02|-'
O=$(DC); has 'goal no longer committed' "$O" 'DRIFT DISPATCH uncommitted DEF-900 t1'
has 'checkpoint passed' "$O" 'DRIFT CHECKPOINT DEF-950 Planner: checkpoint 2026-11-02 passed'; has 'next proof named' "$O" 'persistence test'
has 'merged PR evidence' "$O" 'o/app#12'; hasnt 'DEF 9501 is not DEF 950' "$O" '#13'
has 'unattended' "$O" 'DRIFT UNATTENDED DEF-950 Planner'
commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|2099-01-01|-'
echo '- DEF-950 | Yimin | pick the planner owner | since 2026-11-03 | follow-up 2026-11-05' >"$ST/pending.md"
O=$(DC); hasnt 'human next action attends' "$O" 'UNATTENDED'; hasnt 'future checkpoint' "$O" 'CHECKPOINT'
NOW=2026-11-06T09:00:00Z; O=$(DC); has 'pending overdue' "$O" 'DRIFT PENDING overdue 2026-11-05'; has 'overdue action no longer attends' "$O" 'UNATTENDED DEF-950'; NOW=
echo '- ask Yimin about the budget' >"$ST/pending.md"; has 'pending with no follow-up' "$(DC)" 'DRIFT PENDING no follow-up: - ask Yimin'
: >"$ST/pending.md"; commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|2099-01-01|t1'
hasnt 'named live executor attends' "$(DC)" 'UNATTENDED'
commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|2099-01-01|o1'; has 'named executor not running' "$(DC)" 'executor o1 not running'
commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|2026-11-02|t1'
O=$(GH_FAIL=1 DC); expect 'gh failure exits 2' "$?" 2; has 'gh failure UNKNOWN' "$O" 'DRIFT UNKNOWN: gh pr list o/app DEF-950'
commit 'DEF-950|Planner|Yimin|plan persisted|persistence test|soon|t1'; has 'bad checkpoint UNKNOWN' "$(DC)" 'DRIFT UNKNOWN: checkpoint of DEF-950'
touch "$ST/drift-check.last"; commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'
hasnt 'since the last check only' "$(DC)" 'DISPATCH'
GEN=2026-11-03T15:59Z commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'
O=$(DC); expect 'stale cache exits 2' "$?" 2; has 'stale cache UNKNOWN' "$O" 'DRIFT UNKNOWN: commitments cache stale (generated 2026-11-03T15:59Z)'
GEN=2026-11-03T16:01Z commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'; hasnt 'cache under 2 h is fresh' "$(DC)" 'stale'
GEN=- commit 'DEF-900|Agent tooling|Yimin|harness green|drift PR open|2099-01-01|-'; O=$(DC); expect 'hand-written file exits 2' "$?" 2
has 'hand-written file UNKNOWN' "$O" 'DRIFT UNKNOWN: commitments.md has no generated header'

# Acceptance replay of 2026-11-03: every dispatch names a valid, committed tooling goal; planner (B6) and reconcile (B8)
# are committed with no executor and a passed checkpoint. The check must flag both, and only them.
sleep 300 & LIVE=$!; FX="$ROOT/tests/fixtures/2026-11-03"
cp "$FX/commitments.md" "$FX/pending.md" "$ST/"; sed "s/__LIVE__/$LIVE/" "$FX/sessions.tsv" >"$REG"; touch -t 202611030000 "$ST/drift-check.last"
O=$(NOW=2026-11-03T18:00:00Z DC); echo "$O" >"$TMP/replay.txt"; [ -n "${REPLAY_OUT:-}" ] && cp "$TMP/replay.txt" "$REPLAY_OUT"
for g in 'DEF-1006 B6 planner' 'DEF-1008 B8 reconcile'; do has "replay checkpoint $g" "$O" "DRIFT CHECKPOINT $g"; has "replay unattended $g" "$O" "DRIFT UNATTENDED $g"; done
hasnt 'replay: tooling is attended' "$O" 'DEF-990'; hasnt 'replay: no dispatch lines' "$O" 'DISPATCH'; expect 'replay: four lines' "$(wc -l <<<"$O" | tr -d ' ')" 4
kill "$LIVE" 2>/dev/null

# check.sh carries the drift lines in its snapshot; a dispatch line going away is not news; a broken drift-check is UNKNOWN
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/aws"; CK() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=2026-11-03T18:00:00Z "$ROOT/bin/check.sh"; }
rm -f "$ST/heartbeat.last"; touch -t 202001010000 "$ST/drift-check.last"; "$R" launch team o2 "$P" --no-sandbox --ops 'merge PR 9' >/dev/null
O=$(CK); has 'check prints drift' "$O" 'DRIFT UNATTENDED DEF-1006'; has 'check prints dispatch' "$O" 'DRIFT DISPATCH ops o2'
expect 'check touches drift-check.last' "$(find "$ST/drift-check.last" -mmin -1)" "$ST/drift-check.last"
O=$(CK); hasnt 'old dispatch is not GONE news' "$O" 'GONE DRIFT DISPATCH'; expect 'then no change' "$(CK)" 'NO CHANGE'
mv "$CM" "$CM.away"; O=$(CK); has 'check shows UNKNOWN' "$O" 'DRIFT UNKNOWN: commitments.md'; mv "$CM.away" "$CM"
cp "$CM" "$CM.ok"; printf '\xff\xfe' >>"$CM"; O=$(CK); mv "$CM.ok" "$CM"; has 'crashed drift-check is UNKNOWN' "$O" 'DRIFT UNKNOWN: drift-check.sh exit 1'

# drift-audit.sh: one fresh read-only worker per working day; it writes drift-audit.md, the script judges it, writes
# drift-audit.done and alerts only on a new decision or UNKNOWN (deduped by goal + reason)
AL="$TMP/audit-alerts"; printf '#!/bin/bash\nprintf "%%s\\n===\\n" "$1" >>"%s"\n' "$AL" >"$TMP/bin/alert"; chmod +x "$TMP/bin/alert"
AD="$ST/drift-audit.done"; REP="$ST/drift-audit.md"
rep() {  # decisions as "DEF-n reason" args, then optional UNKNOWN lines via $UNK
  { echo '# Drift audit'; for d in "$@"; do printf 'DECISION: %s\nWRONG: w %s\nNEEDED: n\nEVIDENCE: https://x/%s\n\n' "$d" "$d" "${d%% *}"; done
    [ -n "${UNK:-}" ] && echo "$UNK"; echo 'COVERAGE: 3 committed goals; registry, coordinator.md, Linear, GitHub read at 13:30Z'; } >"$TMP/rep.md"
}
AU() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=$1 DRIFT_AUDIT_PROFILE=${PROF-team} DRIFT_AUDIT_POLL=0.1 AGENT_OPS_ALERT_CMD=${ALERT-$TMP/bin/alert} \
  STUB_RUN=${RUN-"cp '$TMP/rep.md' '$REP'"} "$ROOT/bin/drift-audit.sh"; }
na() { [ -f "$AL" ] && grep -c '^===$' "$AL" || echo 0; }
echo 'LINEAR_TEAM="DEF"' >>"$TMP/home/config"  # COMMITTED_LABEL unset: the default
rm -f "$AD"; AU 2026-11-07T13:30:00Z; expect 'saturday: no audit' "$(cat "$AD" 2>/dev/null)" ''
rep 'DEF-1006 unattended' 'DEF-1008 checkpoint-missed'; AU 2026-11-03T13:30:00Z
expect 'done ok' "$(cat "$AD")" '2026-11-03T13:30Z ok'; expect 'one alert' "$(na)" 1
has 'alert has decision 1' "$(cat "$AL")" 'DECISION: DEF-1006 unattended'; has 'alert has decision 2' "$(cat "$AL")" 'DEF-1008 checkpoint-missed'
has 'alert has evidence' "$(cat "$AL")" 'EVIDENCE: https://x/DEF-1006'; has 'alert has coverage' "$(cat "$AL")" 'COVERAGE: 3 committed'
r=$(grep '^drift-audit-' "$REG" | tail -1); expect 'launched as ops' "$(cut -f12-13 <<<"$r")" $'ops\tdaily drift audit'; expect 'no worktree' "$(cut -f10 <<<"$r")" ''
L=$(cut -f6 <<<"$r"); waitfor "$L" STUB; has 'read-only prompt' "$(cat "$L")" 'You only recommend'; has 'prompt names the report' "$(cat "$L")" "$REP"
has 'prompt names the repos' "$(cat "$L")" 'o/app o/web'; has 'prompt reads Linear by team and label' "$(cat "$L")" 'in team `DEF` with the label `committed`'
has 'runs in the primary checkout' "$(cat "$L")" "STUBCWD $A"
n=$(grep -c '^drift-audit-' "$REG"); AU 2026-11-03T15:00:00Z; expect 'once per working day' "$(grep -c '^drift-audit-' "$REG")" "$n"
AU 2026-11-04T13:30:00Z; expect 'same decisions: no new alert' "$(na)" 1; expect 'next day ok' "$(cat "$AD")" '2026-11-04T13:30Z ok'
rep 'DEF-1006 unattended' 'DEF-990 off-goal-work'; AU 2026-11-05T13:30:00Z; expect 'new decision alerts' "$(na)" 2
has 'only the new one' "$(sed -n '/^===$/,$p' "$AL" | sed 1d)" 'DEF-990 off-goal-work'; hasnt 'not the old one' "$(sed -n '/^===$/,$p' "$AL" | sed 1d)" 'DEF-1006'
rep; AU 2026-11-06T13:30:00Z; expect 'no decision: no alert' "$(na)" 2
rep 'DEF-1006 unattended'; AU 2026-11-09T13:30:00Z; expect 'a cleared decision that comes back alerts again' "$(na)" 3
UNK='UNKNOWN: Linear status of DEF-1008 (MCP not connected)' rep; AU 2026-11-10T13:30:00Z; expect 'UNKNOWN alerts' "$(na)" 4; has 'UNKNOWN text' "$(tail -5 "$AL")" 'MCP not connected'
RUN=true AU 2026-11-11T13:30:00Z; has 'no report: failed' "$(cat "$AD")" 'failed: no report'
rep 'DEF-1 other' 'DEF-2 other' 'DEF-3 other' 'DEF-4 other'; AU 2026-11-12T13:30:00Z; has 'over 3 decisions: failed' "$(cat "$AD")" 'failed: 4 decisions'
rep 'DEF-1006 bogus-reason'; AU 2026-11-13T13:30:00Z; has 'unknown reason code: failed' "$(cat "$AD")" 'failed: bad DECISION line'
{ echo '# x'; } >"$TMP/rep.md"; AU 2026-11-16T13:30:00Z; has 'no coverage: failed' "$(cat "$AD")" 'failed: no COVERAGE line'
rep 'DEF-1008 unattended'; ALERT= AU 2026-11-17T13:30:00Z; has 'no alert command: failed' "$(cat "$AD")" 'failed: no AGENT_OPS_ALERT_CMD'
AU 2026-11-17T15:00:00Z; expect 'a failed day retries and sends' "$(cat "$AD")" '2026-11-17T15:00Z ok'; has 'sent after retry' "$(tail -8 "$AL")" 'DEF-1008 unattended'
rep; PROF=nope AU 2026-11-18T13:30:00Z; has 'launch refused: failed' "$(cat "$AD")" 'failed: launch: session.sh: unknown profile nope'

# watchdog.sh: alerts once per episode when drift-audit.done is missing, says failed, or is over 30 h old on a weekday
# (the weekend does not count against Monday)
WAL="$TMP/wd-alerts"; printf '#!/bin/bash\necho "$1" >>"%s"\n' "$WAL" >"$TMP/bin/walert"; chmod +x "$TMP/bin/walert"
WD() { AGENT_OPS_NOW=$1 AGENT_OPS_ALERT_CMD="$TMP/bin/walert" "$ROOT/scripts/watchdog.sh"; }; nw() { cat "$WAL" 2>/dev/null | wc -l | tr -d ' '; }
echo "$(date -u +%FT%H:%MZ) ok" >"$ST/heartbeat.done"; rm -f "$ST/watchdog."*; rm -f "$AD"
WD 2026-11-03T14:00:00Z; expect 'no audit yet alerts' "$(nw)" 1; has 'names the missing file' "$(cat "$WAL")" 'no drift-audit.done yet'; WD 2026-11-03T14:00:00Z; expect 'missing once' "$(nw)" 1
echo '2026-11-03T13:30Z ok' >"$AD"; WD 2026-11-03T14:00:00Z; expect 'fresh audit: quiet' "$(nw)" 1
WD 2026-11-04T19:00:00Z; expect '29.5 h: quiet' "$(nw)" 1; WD 2026-11-04T20:00:00Z; expect '30.5 h on a weekday alerts' "$(nw)" 2; has 'stale text' "$(tail -1 "$WAL")" 'no drift audit since 2026-11-03T13:30Z'
WD 2026-11-04T21:00:00Z; expect 'stale once' "$(nw)" 2
echo '2026-11-06T13:30Z ok' >"$AD"; WD 2026-11-07T20:00:00Z; WD 2026-11-08T20:00:00Z; expect 'weekend quiet' "$(nw)" 2
WD 2026-11-09T10:00:00Z; expect 'monday morning, friday audit: quiet' "$(nw)" 2; WD 2026-11-09T20:00:00Z; expect 'monday evening, no monday audit: alerts' "$(nw)" 3
echo '2026-11-10T13:30Z failed: no COVERAGE line' >"$AD"; WD 2026-11-10T14:00:00Z; expect 'failed alerts' "$(nw)" 4; has 'failed text' "$(tail -1 "$WAL")" 'drift audit failed: no COVERAGE line'
WD 2026-11-10T14:30:00Z; expect 'failed once' "$(nw)" 4
echo '2026-11-11T13:30Z ok' >"$AD"; WD 2026-11-11T14:00:00Z; echo '2026-11-12T13:30Z failed: launch: x' >"$AD"; WD 2026-11-12T14:00:00Z; expect 'second failure episode' "$(nw)" 5
touch "$ST/heartbeat.stopped"; echo '2026-11-13T13:30Z ok' >"$AD"; WD 2026-11-13T14:00:00Z; echo '2026-11-13T15:00Z failed: y' >"$AD"; WD 2026-11-13T16:00:00Z
expect 'audit check runs with the heartbeat stopped' "$(nw)" 6; rm -f "$ST/heartbeat.stopped"

echo "drift pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
