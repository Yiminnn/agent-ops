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

# NEXT

echo "regress pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
