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

# NEXT

echo "regress pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
