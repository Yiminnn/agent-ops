#!/bin/bash
# Merge a PR only at the exact head that was reviewed, only when every required check passed.
#   merge-when-green.sh <owner/repo> <pr> <reviewed-sha> [--squash|--merge] [--timeout-min N]
# Waits for checks on <reviewed-sha>. Exits 2 without merging if the head moves, a check fails,
# the PR is not mergeable, or the timeout passes. Never merges any other sha.
set -u
repo=$1 pr=$2 sha=$3; method=${4:---squash}; tmo=${6:-60}
[ ${#sha} -ge 7 ] || { echo "reviewed sha too short"; exit 2; }
deadline=$(( $(date +%s) + tmo*60 ))
while :; do
  j=$(gh pr view "$pr" -R "$repo" --json headRefOid,state,mergeable,mergeStateStatus,statusCheckRollup) || { echo "cannot read PR"; exit 2; }
  head=$(jq -r .headRefOid <<<"$j"); state=$(jq -r .state <<<"$j")
  [ "$state" = OPEN ] || { echo "PR is $state"; exit 2; }
  [[ "$head" == "$sha"* ]] || { echo "head moved: $head is not the reviewed $sha; not merging"; exit 2; }
  fail=$(jq -r '[.statusCheckRollup[]|select((.conclusion//"")|test("FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED"))|.name]|join(", ")' <<<"$j")
  [ -z "$fail" ] || { echo "checks failed: $fail"; exit 2; }
  pending=$(jq -r '[.statusCheckRollup[]|select((.status//"COMPLETED")!="COMPLETED")|.name]|length' <<<"$j")
  mstate=$(jq -r .mergeStateStatus <<<"$j")
  if [ "$pending" = 0 ] && [ "$mstate" = CLEAN ]; then
    gh pr merge "$pr" -R "$repo" "$method" --match-head-commit "$head" || { echo "merge refused by GitHub"; exit 2; }
    for try in 1 2; do  # a merge queue, or a failed read, leaves the merge unconfirmed
      r=$(gh pr view "$pr" -R "$repo" --json state,mergeCommit) && jq -e '.state == "MERGED" and .mergeCommit.oid != null' <<<"$r" >/dev/null &&
        { jq -r '"merged \(.mergeCommit.oid[0:9])"' <<<"$r"; exit 0; }
      sleep 2
    done
    echo "merge sent, not confirmed: check PR $pr"; exit 2
  fi
  [ "$pending" = 0 ] && [ "$mstate" != UNKNOWN ] && [ "$mstate" != UNSTABLE ] && { echo "not mergeable: $mstate"; exit 2; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo "timeout after ${tmo}m (pending=$pending state=$mstate)"; exit 2; }
  sleep 30
done
