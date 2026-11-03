#!/usr/bin/env python3
"""PreToolUse Bash: deny process kills by name or pattern.

Failure: `pkill -f "make test"` killed another session's tests, twice (2026-10-11 and 2026-11-02).
Not stopped: `pgrep -f x | xargs kill` and a kill from inside a script.
"""
from cmdtext import run, walk

REASON = "agent-ops deny-kill: {} can hit another session's processes. Kill only PIDs you started: kill <pid> or pkill -P <pid>."


def rule(command, cwd):
    for argv, _ in walk(command, cwd):
        if argv[0] == "killall":
            return REASON.format("killall")
        if argv[0] == "pkill":
            args = argv[1:]
            full = "--full" in args or any(a[0] == "-" and a[1:2] != "-" and "f" in a for a in args if a)
            if full or not ({"-P", "--parent"} & set(args)):
                return REASON.format("pkill by name or pattern")
    return None


run(rule)
