#!/bin/bash
# Read-only heartbeat probe. Prints "NO CHANGE" or the lines that changed since the last run.
# State: ~/.claude/agent-templates/state/heartbeat.last. Its mtime is the last successful tick, whatever changed:
# scripts/watchdog.sh reads that age from outside the coordinator.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"; LAST="$T/state/heartbeat.last"; NEW=$(mktemp)
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
  "$HERE/session.sh" status 2>/dev/null | awk '{s="SESSION " $1 " " $2; if ($9!="") s=s " STATUS:" $9 " pid=" $5; print s}' || exit 1
  "$HERE/session.sh" orgcheck 2>/dev/null || exit 1
  aws sts get-caller-identity --profile "$SSO_PROFILE" >/dev/null 2>&1 && echo "SSO ok" || echo "SSO EXPIRED"
  free=$(df -g / | awk 'NR==2{print $4}'); [ "$free" -lt 20 ] && echo "DISK internal ${free}GiB free (<20)"
  [ -d "$LOGS_DIR" ] || echo "DRIVE $WORK_ROOT missing or wiped"
} | sort > "$NEW" || { echo "check.sh: probe failed; last snapshot kept" >&2; rm -f "$NEW"; exit 1; }
if [ -f "$LAST" ] && cmp -s "$LAST" "$NEW"; then echo "NO CHANGE"; touch "$LAST"; else
  echo "CHANGED:"; if [ -f "$LAST" ]; then diff "$LAST" "$NEW" | grep '^[<>]' | sed 's/^</GONE/;s/^>/NEW /'; else cat "$NEW"; fi
  cp "$NEW" "$LAST"
fi
rm -f "$NEW"
