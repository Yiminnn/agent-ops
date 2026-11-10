#!/bin/bash
# Read-only heartbeat probe. Prints "NO CHANGE" or the lines that changed since the last run.
# State: ~/.claude/agent-templates/state/heartbeat.last. Its mtime is the last Probe, at the start of a tick, whatever
# changed. It does not mean the tick finished: scripts/watchdog.sh reads state/heartbeat.done, written at the end of a
# tick, and falls back to this file only until the first heartbeat.done exists.
# The snapshot holds drift-check.sh's DRIFT lines, compared by item (kind + DEF id, the pending line, the UNKNOWN input):
# NEW DRIFT when an item is new or its text changed (a CHECKPOINT's merged-PR evidence aside), GONE DRIFT when it clears. Once a UTC day, on the first tick at or after
# DRIFT_SUMMARY_HOUR_UTC (config, default 13; 24 turns it off), DRIFT SUMMARY <date>: <n> open heads the output with every open item,
# then operator-digest.sh (WAITING ON OPERATOR <n>:); state/drift-summary.last holds the day of the last one. A STALLED item
# is its goal and PR: its day count growing is not news. AGENT_OPS_NOW (UTC ISO) fixes the clock for tests.
# Two kinds of line stay out of the snapshot and print on every tick until handled: NEW DELIVER <session> <hash8> <to> |
# <what> | <path> (a DELIVER line of a worker report from the last 7 days; handled by "deliver <session> <hash8>" in
# state/handled.txt; a line with no | prints as NEW DELIVER MALFORMED <session> <hash8>: <line>), and NEW SKILL STALE
# <old>→<new> (the plugin moved past state/coordinator-plugin-rev, which SessionStart writes, and this script too when it
# is missing). An unhandled DELIVER line whose log is 7-30 days old prints once as NEW DELIVER EXPIRED <session> <to> |
# <what> (state/deliver-expired.txt remembers it).
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
  touch "$T/state/drift-check.next"  # the next watermark, taken before the read: a launch during the probe is not lost
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
drift_news() {  # NEW DRIFT for an item that is new or whose text changed, GONE DRIFT for a cleared one (a dispatch clears silently)
  awk 'function key(l, k) { k = l  # the item: kind + DEF, the pending line without its dates, the UNKNOWN input without its detail
      if (match(l, /^DRIFT (CHECKPOINT|UNATTENDED|INCOMPLETE) DEF-[0-9]+/)) return substr(l, 1, RLENGTH)
      if (match(l, /^DRIFT STALLED DEF-[0-9]+ [^ ]+/)) return substr(l, 1, RLENGTH)  # + the PR
      if (sub(/^DRIFT PENDING (overdue [0-9-]+|no follow-up): /, "", k)) { gsub(/follow-up:? *[0-9-]+/, "", k); return "DRIFT PENDING " k }
      if (l ~ /^DRIFT UNKNOWN: /) sub(/ \(.*/, "", k)
      return k }
    !/^DRIFT / { next }
    { k = key($0); k = k SUBSEP (++n[FILENAME, k]) }  # items that share a key (same row twice, dates apart) pair up in order
    { c = $0; if (c ~ /^DRIFT CHECKPOINT /) sub(/"; [^"]*$/, "\"", c); if (c ~ /^DRIFT STALLED /) sub(/ [0-9]+d$/, "", c) }  # its merged-PR evidence, or one more quiet day, is not news
    FILENAME == ARGV[1] { old[k] = c; line[k] = $0; next }
    { now[k] = 1; if (!(k in old) || old[k] != c) print "NEW " $0 }
    END { for (k in old) if (!(k in now) && line[k] !~ /^DRIFT DISPATCH /) print "GONE " line[k] }' "$1" "$2" | sort
}
if [ -f "$LAST" ]; then
  ch=$(diff <(grep -v '^DRIFT ' "$LAST") <(grep -v '^DRIFT ' "$NEW") | grep '^[<>]' | sed 's/^< /GONE /;s/^> /NEW /')
  dn=$(drift_news "$LAST" "$NEW"); [ -n "$dn" ] && ch=${ch:+$ch$'\n'}$dn
else ch=$(cat "$NEW"); fi
# Open work, outside the snapshot: printed every tick until handled
while IFS=$'\t' read -r k s h d; do  # a DELIVER line until state/handled.txt has "deliver <session> <hash8>"
  [ -n "$s" ] && ! grep -qxF "deliver $s $h" "$T/state/handled.txt" 2>/dev/null || continue
  case $k in
    open) ch=${ch:+$ch$'\n'}"NEW DELIVER $s $h $d" ;;
    malformed) ch=${ch:+$ch$'\n'}"NEW DELIVER MALFORMED $s $h: $d" ;;
    expired) grep -qxF "$s $h" "$T/state/deliver-expired.txt" 2>/dev/null && continue  # once, then it is dropped
      echo "$s $h" >>"$T/state/deliver-expired.txt"; ch=${ch:+$ch$'\n'}"NEW DELIVER EXPIRED $s ${d% | *}" ;;
  esac
done <<<"$dl"
old=$(cat "$T/state/coordinator-plugin-rev" 2>/dev/null); rev=$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null)
[ -z "$old" ] && [ -n "$rev" ] && echo "$rev" >"$T/state/coordinator-plugin-rev"  # a coordinator from before the record starts tracking here
[ -n "$old" ] && [ -n "$rev" ] && [ "$old" != "$rev" ] && ch=${ch:+$ch$'\n'}"NEW SKILL STALE ${old}→${rev}"  # until the coordinator re-invokes its skills and writes $rev there
now=${AGENT_OPS_NOW:-$(date -u +%FT%TZ)}; day=${now:0:10}; SUM="$T/state/drift-summary.last"  # the UTC day of the last summary
if [ "$((10#${now:11:2}))" -ge "${DRIFT_SUMMARY_HOUR_UTC:-13}" ] && [ "$(cat "$SUM" 2>/dev/null)" != "$day" ]; then
  open=$(grep '^DRIFT ' "$NEW" | grep -v -e '^DRIFT DISPATCH ' -e '^DRIFT NONE committed$')  # a dispatch is an event; no committed goals is said once, as news
  echo "DRIFT SUMMARY $day: $(grep -c . <<<"$open") open"; [ -n "$open" ] && echo "$open"
  "$HERE/operator-digest.sh"; echo "$day" >"$SUM"  # WAITING ON OPERATOR <n>: the oldest rows that wait on the operator
elif [ -z "$ch" ]; then echo "NO CHANGE"; fi
[ -n "$ch" ] && { echo "CHANGED:"; echo "$ch"; }  # a dispatch line that only went away is no change
cp "$NEW" "$LAST"
mv -f "$T/state/drift-check.next" "$T/state/drift-check.last"  # the next DRIFT DISPATCH lines start at this probe's read
rm -f "$NEW"
