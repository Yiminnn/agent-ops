#!/bin/bash
# Read-only heartbeat probe. Prints "NO CHANGE" or the lines that changed since the last run.
# State: ~/.claude/agent-templates/state/heartbeat.last. Its mtime is the last Probe, at the start of a tick, whatever
# changed. It does not mean the tick finished: scripts/watchdog.sh reads state/heartbeat.done, written at the end of a
# tick, and falls back to this file only until the first heartbeat.done exists.
# The snapshot holds drift-check.sh's DRIFT lines: a goal-drift exception shows once as NEW, and as GONE when it clears.
# Two kinds of line stay out of the snapshot and print on every tick until handled: NEW DELIVER <session> <hash8> <to> |
# <what> | <path> (a DELIVER line of a worker report from the last 7 days; handled by "deliver <session> <hash8>" in
# state/handled.txt), and NEW SKILL STALE <old>→<new> (the plugin moved past state/coordinator-plugin-rev, which
# SessionStart writes, and this script too when it is missing).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"; LAST="$T/state/heartbeat.last"; NEW=$(mktemp "${TMPDIR:-/tmp}/agent-ops-check.XXXXXX")  # bare mktemp ignores TMPDIR on macOS
[ -f "$T/config" ] || { echo "check.sh: no $T/config; copy config.example" >&2; exit 1; }
. "$T/config"
{
  for r in $GH_REPOS; do
    gh pr list -R "$r" --state open -L 300 \
      --json number,title,headRefOid,reviewDecision,latestReviews,statusCheckRollup,isDraft 2>/dev/null |
    R=${r#*/} BOTS=$BOT_REVIEWERS jq -r '.[] | select(.isDraft|not) |
      "PR \(env.R)#\(.number) head=\(.headRefOid[0:9]) decision=\(.reviewDecision // "-") reviews=[\([.latestReviews[]|select(.author.login|test(env.BOTS)|not)|.author.login+":"+.state]|join(","))] checks=[\([.statusCheckRollup[]|select(.name!="Claude Code Review")|(.conclusion // .status // .state)]|group_by(.)|map("\(.[0])x\(length)")|join(","))] \(.title[0:60])"' || exit 1
  done
  gh run list -R "$DEPLOY_REPO" -b "$DEPLOY_BRANCH" -L 1 --json workflowName,status,conclusion,headSha --jq '.[]|"DEPLOY \(.workflowName) \(.status) \(.conclusion) \(.headSha[0:9])"' 2>/dev/null || exit 1
  "$HERE/session.sh" status 2>/dev/null | awk '{s="SESSION " $1 " " $2; st=$9; if (st=="plugin-not-loaded") st=""; if (st!="") s=s " STATUS:" st " pid=" $5; if ($NF=="plugin-not-loaded") s=s " PLUGIN NOT LOADED"; print s}' || exit 1
  "$HERE/session.sh" orgcheck 2>/dev/null || exit 1
  d=$("$HERE/drift-check.sh" 2>/dev/null); rc=$?  # 0 clear, 1 exceptions, 2 UNKNOWN; anything else, or no line with a nonzero exit, is a broken check
  d=$(grep '^DRIFT ' <<<"$d"); { [ "$rc" -le 2 ] && { [ "$rc" = 0 ] || [ -n "$d" ]; }; } || d="DRIFT UNKNOWN: drift-check.sh exit $rc"
  [ -z "$d" ] || echo "$d"
  sso="SSO ok"  # every profile: one profile's cached role credentials can outlive the SSO token
  for p in $SSO_PROFILES; do aws sts get-caller-identity --profile "$p" >/dev/null 2>&1 || sso="SSO EXPIRED"; done
  echo "$sso"
  free=$(df -g / | awk 'NR==2{print $4}'); [ "$free" -lt 20 ] && echo "DISK internal ${free}GiB free (<20)"
  [ -d "$LOGS_DIR" ] || echo "DRIVE $WORK_ROOT missing or wiped"
} | sort > "$NEW" || { echo "check.sh: probe failed; last snapshot kept" >&2; rm -f "$NEW"; exit 1; }
dl=$("$HERE/session.sh" delivers 2>/dev/null) || { echo "check.sh: probe failed; last snapshot kept" >&2; rm -f "$NEW"; exit 1; }
if [ -f "$LAST" ]; then ch=$(diff "$LAST" "$NEW" | grep '^[<>]' | sed 's/^</GONE/;s/^>/NEW /' | grep -v '^GONE DRIFT DISPATCH '); else ch=$(cat "$NEW"); fi
# Open work, outside the snapshot: printed every tick until handled
while IFS=$'\t' read -r s h d; do  # a DELIVER line until state/handled.txt has "deliver <session> <hash8>"
  [ -n "$s" ] && ! grep -qxF "deliver $s $h" "$T/state/handled.txt" 2>/dev/null && ch=${ch:+$ch$'\n'}"NEW DELIVER $s $h $d"
done <<<"$dl"
old=$(cat "$T/state/coordinator-plugin-rev" 2>/dev/null); rev=$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null)
[ -z "$old" ] && [ -n "$rev" ] && echo "$rev" >"$T/state/coordinator-plugin-rev"  # a coordinator from before the record starts tracking here
[ -n "$old" ] && [ -n "$rev" ] && [ "$old" != "$rev" ] && ch=${ch:+$ch$'\n'}"NEW SKILL STALE ${old}→${rev}"  # until the coordinator re-invokes its skills and writes $rev there
if [ -z "$ch" ]; then echo "NO CHANGE"; else echo "CHANGED:"; echo "$ch"; fi  # a dispatch line that only went away is no change
cp "$NEW" "$LAST"
touch "$T/state/drift-check.last"  # the next DRIFT DISPATCH lines start here
rm -f "$NEW"
