#!/bin/bash
# Offline tests for the per-worker Bash sandbox settings that session.sh passes with --settings when WORKER_SANDBOX=1.
set -u
. "$(dirname "$0")/lib.sh"
settings() { sed -n 's/.*--settings \([^ ]*\).*/\1/p' "$1" | tail -1; }  # the settings file of the last run in a log
sb() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["sandbox"]; print(s["enabled"], s["failIfUnavailable"], s["allowUnsandboxedCommands"], s["enableWeakerNetworkIsolation"]); print("\n".join(s["filesystem"]["allowWrite"]))' "$1"; }
S=$SB  # the real session.sh: lib.sh's $S adds --no-sandbox for the tests of other features
echo 'WORKER_SANDBOX="1"' >>"$AGENT_OPS_HOME/config"  # the sandbox is opt-in
G="$TMP/repo"; mkdir -p "$G"; git -C "$G" init -q; git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
tree() { git -C "$G" worktree add -q "$1" -b "t/$(basename "$1")" HEAD && (cd "$1" && pwd -P); }  # a linked worktree, as the launcher makes them
W=$(tree "$V/worktrees/s"); mkdir -p "$V/venvs/s"; X=$(cd "$V/venvs/s" && pwd -P)

# empty registry: the worktrees root, or any dir that is not a git top level of its own, is no --worktree
has 'refuse worktrees root, empty registry' "$("$S" launch team r0 "$P" --worktree "$V/worktrees" 2>&1)" '--write/--worktree'
"$S" launch team r1 "$P" --no-sandbox >/dev/null; waitfor "$TMP/logs/r1.log" STUB
has 'refuse worktrees root on resume' "$("$S" resume r1 "$P" --worktree "$V/worktrees" 2>&1)" '--write/--worktree'
mkdir -p "$V/worktrees/plain"; has 'refuse a plain dir' "$("$S" launch team r0 "$P" --worktree "$V/worktrees/plain" 2>&1)" 'git top level'
tree "$V/wtroot" >/dev/null; has 'refuse a git top level directly under WORK_ROOT' "$("$S" launch team r0 "$P" --worktree "$V/wtroot" 2>&1)" 'directly under WORK_ROOT'
mkdir -p "$W/sub"; has 'refuse a subdir of a worktree' "$("$S" launch team r0 "$P" --worktree "$W/sub" 2>&1)" 'git top level'
expect 'no rows for root refusals' "$(cut -f1 "$REG" | sort -u | tr '\n' ' ')" 'r1 '

# launch: cwd is the worktree; the settings turn the sandbox on and list the worktree and each --write path
has 'launch' "$("$S" launch team sb1 "$P" --worktree "$W" --write "$X")" 'launched sb1'; waitfor "$TMP/logs/sb1.log" STUB
D=$(cd "$TMP/daytona-logs" && pwd -P)  # the launcher makes the default write dirs
F=$(settings "$TMP/logs/sb1.log"); expect 'settings file' "$([ -f "$F" ] && echo yes)" yes
expect 'sandbox on, no unsandboxed retry' "$(sb "$F" | head -1)" 'True True False True'
expect 'allowWrite' "$(sb "$F" | tail -n +2)" "$W"$'\n'"$D"$'\n'"$X"
has 'npm cache in sandbox temp' "$(cat "$TMP/logs/sb1.log")" "npm_cache=[/tmp/claude-$(id -u)/npm-cache]"
has 'cwd is the worktree' "$(cat "$TMP/logs/sb1.log")" "STUBCWD $W"
expect 'registry columns' "$(tail -1 "$REG" | cut -f10-11)" "$W"$'\t'"$X"

# resume keeps the sandbox and adds a new --write path once
mkdir -p "$TMP/round"; R=$(cd "$TMP/round" && pwd -P)
"$S" resume sb1 "$P" --write "$R" --write "$X" >/dev/null; waitfor "$TMP/logs/sb1.log" "--resume"
F=$(settings "$TMP/logs/sb1.log"); expect 'resume allowWrite' "$(sb "$F" | tail -n +2)" "$W"$'\n'"$D"$'\n'"$X"$'\n'"$R"
has 'resume cwd' "$(sed -n '/--resume/,$p' "$TMP/logs/sb1.log")" "STUBCWD $W"

# a queued resume (the waiter's _run) keeps it too
"$S" resume sb1 "$P" --after 999999 >/dev/null; sleep 0.5
expect 'waiter keeps sandbox' "$(grep -c -e "--resume.*--settings" "$TMP/logs/sb1.log")" 2

# no worktree: refused, unless --no-sandbox (then no settings, cwd the primary checkout)
has 'no worktree refused' "$("$S" launch team sb2 "$P" 2>&1)" '--no-sandbox'
"$S" launch team sb2 "$P" --no-sandbox >/dev/null; waitfor "$TMP/logs/sb2.log" STUB
hasnt 'no-sandbox no settings' "$(cat "$TMP/logs/sb2.log")" '--settings'; has 'no-sandbox cwd' "$(cat "$TMP/logs/sb2.log")" "STUBCWD $A"

# a missing worktree is created by the launcher: a linked worktree of --repo on a new branch from --base
NW="$V/worktrees/new1"
has 'new worktree needs repo' "$("$S" launch team sb4 "$P" --worktree "$NW" 2>&1)" '--repo'
has 'launch creates' "$("$S" launch team sb4 "$P" --worktree "$NW" --repo "$G" --base HEAD --branch b/new1)" 'launched sb4'; waitfor "$TMP/logs/sb4.log" STUB
NWR=$(cd "$NW" && pwd -P); has 'cwd is the new worktree' "$(cat "$TMP/logs/sb4.log")" "STUBCWD $NWR"
expect 'on the new branch' "$(git -C "$NW" branch --show-current)" b/new1
expect 'linked to the repo' "$(cd "$(git -C "$NW" rev-parse --git-common-dir)" && pwd -P)" "$(cd "$G/.git" && pwd -P)"
"$S" launch team sb5 "$P" --worktree "$V/worktrees/new2" --repo "$G" --base HEAD >/dev/null; waitfor "$TMP/logs/sb5.log" STUB
expect 'branch defaults to the dir name' "$(git -C "$V/worktrees/new2" branch --show-current)" new2

# a row from before the sandbox resumes without it, unless the resume names a worktree
printf 'old\tteam\tsido\t1\t%s\t%s\tt\t%s\n' "$P" "$TMP/logs/old.log" "$TEAM" >>"$REG"
"$S" resume old "$P" >/dev/null; waitfor "$TMP/logs/old.log" STUB; hasnt 'legacy no settings' "$(cat "$TMP/logs/old.log")" '--settings'
OW=$(tree "$V/worktrees/old")
has 'legacy cannot take a sibling tree' "$("$S" resume old "$P" --worktree "$W" 2>&1)" "overlaps $W"
"$S" resume old "$P" --worktree "$OW" >/dev/null; waitfor "$TMP/logs/old.log" "STUBCWD $OW"; has 'legacy opts in' "$(cat "$TMP/logs/old.log")" '--settings'

# wide or missing paths are refused before anything runs
n=$(wc -l <"$REG"); tree "$V/worktrees/s3" >/dev/null
for bad in / "$V" "$TMP" "$HOME" "$TMP/no-such-dir" "$V/worktrees" "$NW" "$NW/sub" "$A"; do
  has "refuse $bad" "$("$S" launch team sb3 "$P" --worktree "$V/worktrees/s3" --write "$bad" 2>&1)" '--write/--worktree'
done
mkdir -p "$NW/sub"; tree "$V/lone/a" >/dev/null
has 'refuse a dir inside another tree' "$("$S" launch team sb3 "$P" --worktree "$V/worktrees/s3" --write "$NW/sub" 2>&1)" 'overlaps'
has 'refuse the dir that holds my tree' "$("$S" launch team sb3 "$P" --worktree "$V/lone/a" --write "$V/lone" 2>&1)" 'holds'
has 'refuse wide worktree' "$("$S" launch team sb3 "$P" --worktree "$V" 2>&1)" '--write/--worktree'
has 'refuse parent of own worktree on resume' "$("$S" resume sb4 "$P" --write "$V/worktrees" 2>&1)" '--write/--worktree'
has 'refuse other worktree on resume' "$("$S" resume sb4 "$P" --write "$W" 2>&1)" '--write/--worktree'
has 'refuse wide on resume' "$("$S" resume sb1 "$P" --write "$V" 2>&1)" '--write/--worktree'
expect 'no rows for refusals' "$(wc -l <"$REG")" "$n"

# a launch refused for a --write leaves no worktree and no branch behind
has 'bad write refused first' "$("$S" launch team sb6 "$P" --worktree "$V/worktrees/new3" --repo "$G" --base HEAD --write "$V" 2>&1)" '--write/--worktree'
expect 'no worktree left' "$([ -e "$V/worktrees/new3" ] && echo left)" ""
expect 'no branch left' "$(git -C "$G" branch --list new3)" ""

echo "sandbox pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
