#!/bin/bash
# Offline tests for the default launch: WORKER_SANDBOX unset (0), so no Bash sandbox, but cwd is still the worktree.
set -u
. "$(dirname "$0")/lib.sh"
S=$SB  # the real session.sh, with no --no-sandbox added
unset npm_config_cache PIP_CACHE_DIR  # a sandboxed caller's own env would pass through to the stub
G="$TMP/repo"; mkdir -p "$G"; git -C "$G" init -q; git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# a --worktree launch: created as before, cwd = the worktree, no settings file and no sandbox env
NW="$V/worktrees/d1"
has 'launch' "$("$S" launch team d1 "$P" --worktree "$NW" --repo "$G" --base HEAD)" 'launched d1'; waitfor "$TMP/logs/d1.log" STUB
NWR=$(cd "$NW" && pwd -P)
hasnt 'no settings' "$(cat "$TMP/logs/d1.log")" '--settings'
has 'cwd is the worktree' "$(cat "$TMP/logs/d1.log")" "STUBCWD $NWR"
has 'no sandbox npm cache' "$(cat "$TMP/logs/d1.log")" 'npm_cache=[]'

# no --worktree and no --no-sandbox: runs in the primary checkout, as before the sandbox
has 'launch without worktree' "$("$S" launch team d2 "$P" 2>&1)" 'launched d2'; waitfor "$TMP/logs/d2.log" STUB
hasnt 'no worktree no settings' "$(cat "$TMP/logs/d2.log")" '--settings'; has 'cwd is the primary checkout' "$(cat "$TMP/logs/d2.log")" "STUBCWD $A"

# --repo, --base or --branch with no --worktree is a forgotten --worktree: refused, not run in the primary checkout
n=$(wc -l <"$REG")
for f in "--repo $G" "--base HEAD" "--branch b/x"; do
  has "refuse $f without worktree" "$("$S" launch team d5 "$P" $f 2>&1)" '--repo/--base/--branch need --worktree'
done
expect 'no rows for those refusals' "$(wc -l <"$REG")" "$n"

# resume --write on a row with no worktree: ignored with the same note, not refused
mkdir -p "$TMP/round2"
has 'resume write on no-worktree row' "$("$S" resume d2 "$P" --write "$TMP/round2" 2>&1)" 'resumed d2'; waitfor "$TMP/logs/d2.log" '--resume'
has 'resume write ignored note' "$(awk '/session.sh run/{s=""} {s=s $0 "\n"} END{printf "%s", s}' "$TMP/logs/d2.log")" '--write ignored: WORKER_SANDBOX=0'

# --write is accepted and ignored, with a note in the log
mkdir -p "$TMP/round"; NW3="$V/worktrees/d3"
has 'launch with write' "$("$S" launch team d3 "$P" --worktree "$NW3" --repo "$G" --base HEAD --write "$TMP/round" 2>&1)" 'launched d3'; waitfor "$TMP/logs/d3.log" STUB
has 'write ignored note' "$(cat "$TMP/logs/d3.log")" '--write ignored: WORKER_SANDBOX=0'; hasnt 'write no settings' "$(cat "$TMP/logs/d3.log")" '--settings'
hasnt 'no note without write' "$(cat "$TMP/logs/d1.log")" '--write ignored'

# the worktrees root is still no --worktree: it would be the worker's cwd
has 'refuse worktrees root' "$("$S" launch team d4 "$P" --worktree "$V/worktrees" 2>&1)" '--write/--worktree'

echo "default pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
