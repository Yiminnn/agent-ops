#!/bin/bash
# Offline tests for DRIFT STALLED: an open, non-draft PR linked to a committed goal with no push, no review and no
# comment for STALLED_DAYS. drift-check.sh finds the lines; check.sh prints them as news once and in the daily summary.
# Stub gh (open PRs and per-PR activity from files), fixed clock; nothing here reads real state.
set -u
. "$(dirname "$0")/lib.sh"
ST="$TMP/home/state"; CM="$ST/commitments.md"; : >"$REG"
echo '- Ana | pick the ledger reviewer | since 2026-11-01 | DEF-700 | follow-up 2099-01-01' >"$ST/pending.md"  # keeps DEF-700 attended
commit() {  # the cache, generated at $GEN, with one committed goal
  { echo '# Commitments'; echo "generated ${GEN:-2026-11-10T17:30Z} from Linear label committed; do not edit"; echo
    echo '| DEF | objective | accountable | done-when | next proof | checkpoint | executor |'; echo '|---|---|---|---|---|---|---|'
    echo '| DEF-700 | Ledger | Ana | ledger merged | CI of each ledger PR | 2099-01-01 | - |'; } >"$CM"
}
commit
mkdir -p "$TMP/bin" "$TMP/gh"; G="$TMP/gh"
cat >"$TMP/bin/gh" <<'GH'
#!/bin/bash
# open PRs of a repo: $GHD/open-<owner_repo>.json (GH_FAIL_LIST=<repo> fails it); activity of one PR: $GHD/view-<owner_repo>-<n>.json (none: fails)
[ -n "${GH_FAIL:-}" ] && exit 1
a=" $* "; r=${a#* -R }; r=${r%% *}; f=${r//\//_}
case "$a" in
  *" pr list "*headRefName*) [ "$r" = "${GH_FAIL_LIST:-}" ] && exit 1; cat "$GHD/open-$f.json" 2>/dev/null || echo '[]' ;;
  *" pr view "*) n=${a#* pr view }; n=${n%% *}; cat "$GHD/view-$f-$n.json" || exit 1 ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$TMP/bin/gh"; export GHD="$G"
act() {  # repo n commit-time [review-time [comment-time]]: the activity gh pr view returns
  local rv='' cm=''; [ -n "${4:-}" ] && rv="{\"submittedAt\":\"$4\"}"; [ -n "${5:-}" ] && cm="{\"createdAt\":\"$5\"}"
  printf '{"commits":[{"committedDate":"2026-10-01T00:00:00Z"},{"committedDate":"%s"}],"reviews":[%s],"comments":[%s]}\n' "$3" "$rv" "$cm" >"$G/view-${1//\//_}-$2.json"
}
cat >"$G/open-o_app.json" <<'J'
[{"number":1,"title":"ledger: base tables","body":"Part of DEF 700.","headRefName":"ana/ledger-base","baseRefName":"dev","isDraft":false},
 {"number":2,"title":"ledger: api","body":"stacked","headRefName":"ana/ledger-api","baseRefName":"ana/ledger-base","isDraft":false},
 {"number":3,"title":"other work","body":"DEF 7001","headRefName":"bo/other","baseRefName":"dev","isDraft":false},
 {"number":4,"title":"DEF-700 spike","body":"","headRefName":"ana/spike","baseRefName":"dev","isDraft":true},
 {"number":5,"title":"fix rounding","body":null,"headRefName":"ana/def-700-rounding","baseRefName":"dev","isDraft":false},
 {"number":6,"title":"release","body":"carries DEF-700","headRefName":"dev","baseRefName":"main","isDraft":false},
 {"number":7,"title":"ledger: ui","body":"","headRefName":"ana/ledger-ui","baseRefName":"ana/ledger-api","isDraft":false}]
J
echo '[{"number":8,"title":"ledger client","body":"DEF-700","headRefName":"b/z","baseRefName":"main","isDraft":false},
 {"number":9,"title":"ledger export","body":"DEF-700","headRefName":"b/export","baseRefName":"main","isDraft":false}]' >"$G/open-o_web.json"
act o/app 1 2026-11-05T18:00:00Z                             # named in the body, 5 days quiet
act o/app 2 2026-11-07T18:00:00Z                             # stacked on #1, quiet exactly 3 days
act o/app 3 2026-10-01T00:00:00Z                             # DEF 7001 is not DEF 700, and dev is not a stack link
act o/app 5 2026-11-01T00:00:00Z 2026-11-02T00:00:00Z 2026-11-07T18:01:00Z  # branch names def-700; a comment 2d 23h ago
act o/app 6 2026-11-10T09:00:00Z                             # the release PR names it: recent, so quiet
act o/app 7 2026-11-01T00:00:00Z 2026-11-10T08:00:00Z        # stacked two up: a review today
act o/web 8 2026-11-01T12:00:00Z                             # another repo, 9 days
echo '{"createdAt":"2026-11-10T17:59:00Z","commits":[{"committedDate":"2026-11-01T00:00:00Z"}],"reviews":[],"comments":[]}' >"$G/view-o_web-9.json"  # opened a minute ago, old commits
DC() { PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=${NOW:-2026-11-10T18:00:00Z} "$ROOT/bin/drift-check.sh"; }

# drift-check.sh: one line per linked, open, non-draft PR quiet for STALLED_DAYS (default 3)
O=$(DC); expect 'stalled exits 1' "$?" 1
has 'named in the body' "$O" 'DRIFT STALLED DEF-700 o/app#1 5d'
has 'stacked on a named PR, at the 3-day line' "$O" 'DRIFT STALLED DEF-700 o/app#2 3d'
has 'another repo' "$O" 'DRIFT STALLED DEF-700 o/web#8 9d'
hasnt 'a longer id is not a link' "$O" 'o/app#3'; hasnt 'a draft is skipped' "$O" 'o/app#4'
hasnt 'a PR opened a minute ago is not stalled by its old commits' "$O" 'o/web#9'
hasnt 'a comment is activity' "$O" 'o/app#5'; hasnt 'recent push' "$O" 'o/app#6'; hasnt 'a review is activity' "$O" 'o/app#7'
expect 'only those three' "$(grep -c '^DRIFT STALLED' <<<"$O")" 3
act o/app 5 2026-11-01T00:00:00Z; has 'the branch name links it' "$(DC)" 'DRIFT STALLED DEF-700 o/app#5 9d'
cp "$G/open-o_web.json" "$TMP/web.ok"; for n in 10 11 12 13 14; do act o/web $n 2026-11-01T00:00:00Z; done
cat >"$G/open-o_web.json" <<'J'
[{"number":10,"title":"x","body":"","headRefName":"ana/def-700_fix","baseRefName":"main","isDraft":false},
 {"number":11,"title":"x","body":"","headRefName":"feat_def-700","baseRefName":"main","isDraft":false},
 {"number":12,"title":"def-700 cleanup","body":"","headRefName":"ana/c","baseRefName":"main","isDraft":false},
 {"number":13,"title":"x","body":"","headRefName":"feat_def-7001","baseRefName":"main","isDraft":false},
 {"number":14,"title":"undef-700 guard","body":"","headRefName":"ana/u","baseRefName":"main","isDraft":false}]
J
O=$(DC); has 'branch id before an underscore' "$O" 'o/web#10 9d'; has 'branch id after an underscore' "$O" 'o/web#11 9d'
has 'a lower-case title' "$O" 'o/web#12 9d'; hasnt 'a longer id in a branch' "$O" 'o/web#13'; hasnt 'a word that ends in def' "$O" 'o/web#14'
mv "$TMP/web.ok" "$G/open-o_web.json"
act o/app 5 2026-11-01T00:00:00Z 2026-11-02T00:00:00Z 2026-11-07T18:01:00Z
echo 'STALLED_DAYS=5' >>"$TMP/home/config"; O=$(DC)
has 'days from the config' "$O" 'o/app#1 5d'; hasnt 'under the configured days' "$O" 'o/app#2'
sed -i '' '/^STALLED_DAYS=/d' "$TMP/home/config"
O=$(GH_FAIL=1 DC); expect 'gh failure exits 2' "$?" 2; has 'gh failure is UNKNOWN' "$O" 'DRIFT UNKNOWN: gh pr list o/app open'
rm "$G/view-o_web-8.json"; O=$(DC); expect 'a failed activity read exits 2' "$?" 2; has 'and is UNKNOWN' "$O" 'DRIFT UNKNOWN: gh pr view o/web#8'
act o/web 8 2026-11-01T12:00:00Z

# check.sh: a stalled PR is news once; its day count growing is not; activity clears it; the daily summary lists it
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/aws"; chmod +x "$TMP/bin/aws"
CK() { GEN=${CNOW:0:13}:00Z commit; PATH="$TMP/bin:$PATH" AGENT_OPS_NOW=$CNOW "$ROOT/bin/check.sh"; }
act o/app 5 2026-11-01T00:00:00Z "" 2026-11-10T12:00:00Z  # a comment today: not stalled in this block
rm -f "$ST/heartbeat.last"; CNOW=2026-11-10T18:00:00Z CK >/dev/null
CNOW=2026-11-10T18:30:00Z; act o/app 7 2026-11-01T00:00:00Z; O=$(CK)  # #7's review was its last activity: now 9 days quiet
expect 'a new stalled PR is news' "$(grep STALLED <<<"$O")" 'NEW DRIFT STALLED DEF-700 o/app#7 9d'
CNOW=2026-11-11T18:30:00Z; expect 'one more quiet day is no news' "$(CK)" 'NO CHANGE'
act o/app 1 2026-11-05T18:00:00Z '' 2026-11-11T19:00:00Z; CNOW=2026-11-11T19:30:00Z; O=$(CK)
has 'a comment clears it' "$O" 'GONE DRIFT STALLED DEF-700 o/app#1 6d'; hasnt 'and nothing else is news' "$O" 'NEW DRIFT'
sed -i '' 's/^DRIFT_SUMMARY_HOUR_UTC=24.*/DRIFT_SUMMARY_HOUR_UTC=13/' "$TMP/home/config"; CNOW=2026-11-12T13:00:00Z; O=$(CK)
has 'the daily summary lists it' "$O" $'\nDRIFT STALLED DEF-700 o/web#8 11d'

# A gh failure is not a cleared stall: the earlier line stays (no GONE now, no second NEW later), with the UNKNOWN
rm "$G/view-o_web-8.json"; CNOW=2026-11-12T14:00:00Z; O=$(CK)
hasnt 'a failed activity read is not GONE' "$O" 'GONE DRIFT STALLED'; has 'it is UNKNOWN' "$O" 'NEW DRIFT UNKNOWN: gh pr view o/web#8'
act o/web 8 2026-11-01T12:00:00Z; CNOW=2026-11-12T14:30:00Z; O=$(CK)
hasnt 'recovery is not NEW again' "$O" 'NEW DRIFT STALLED'; has 'recovery clears the UNKNOWN' "$O" 'GONE DRIFT UNKNOWN: gh pr view o/web#8'
CNOW=2026-11-12T15:00:00Z; O=$(GH_FAIL_LIST=o/web CK)
hasnt 'a failed PR list is not GONE' "$O" 'GONE DRIFT STALLED'; has 'it is UNKNOWN too' "$O" 'NEW DRIFT UNKNOWN: gh pr list o/web open'
CNOW=2026-11-12T15:30:00Z; O=$(CK); hasnt 'and its recovery is not NEW again' "$O" 'NEW DRIFT STALLED'
cp "$G/open-o_web.json" "$TMP/web.ok"; python3 -c 'import json; print(json.dumps([{"number": 1000 + i, "title": "x", "body": "", "headRefName": f"f/{i}", "baseRefName": "main", "isDraft": False} for i in range(300)]))' >"$G/open-o_web.json"
CNOW=2026-11-12T15:45:00Z; O=$(CK); has 'a full page of 300 is UNKNOWN' "$O" 'NEW DRIFT UNKNOWN: gh pr list o/web open'; hasnt 'and keeps the PR it may have cut off' "$O" 'GONE DRIFT STALLED'
mv "$TMP/web.ok" "$G/open-o_web.json"; CK >/dev/null
cp "$G/open-o_web.json" "$TMP/web.ok"; sed -i '' 's/"b\/z","baseRefName":"main","isDraft":false/"b\/z","baseRefName":"main","isDraft":true/' "$G/open-o_web.json"
CNOW=2026-11-12T16:00:00Z; has 'a PR back to draft is GONE, not kept' "$(CK)" 'GONE DRIFT STALLED DEF-700 o/web#8'; mv "$TMP/web.ok" "$G/open-o_web.json"

echo "stalled pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
