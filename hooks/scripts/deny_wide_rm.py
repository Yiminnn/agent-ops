#!/usr/bin/env python3
"""PreToolUse Bash: deny `rm -r` on a wide path: /, ~, WORK_ROOT, a direct child of it, or a parent of those.

Failure: 2026-11-02, most of the work drive was lost to a recursive delete.
This hook CANNOT see a delete inside Python. That wipe was shutil.rmtree under `python -m unittest`, and its command text
held no `rm` at all. The "Delete paths" rule in worker-rules.md and the Daytona lane remain the guards for that case.
Not stopped either: an unset variable (`rm -rf "$X"/`), `find -delete`, and rm inside a script.
"""
import os

from cmdtext import HOME, config, path_of, run, walk

WORK = config("WORK_ROOT")
REASON = "agent-ops deny-rm: {} is a wide path. Delete only what you created in this task, by its full path."


def wide(path):
    for p in {path.casefold(), os.path.realpath(path).casefold()}:
        roots = (HOME.casefold(), WORK.casefold())
        if p in roots or os.path.dirname(p) == roots[1] or any(r.startswith(p.rstrip("/") + "/") for r in roots):
            return True
    return False


def rule(command, cwd):
    for argv, where in walk(command, cwd):
        if argv[0] != "rm":
            continue
        args, recursive, targets = argv[1:], False, []
        for i, a in enumerate(args):
            if a == "--":
                targets += args[i + 1:]
                break
            if a == "--recursive" or (a[:1] == "-" and a[1:2] != "-" and set(a[1:]) & {"r", "R"}):
                recursive = True
            elif a[:1] != "-":
                targets.append(a)
        if recursive:
            for t in targets:
                if wide(path_of(t, where)):
                    return REASON.format(t)
    return None


run(rule)
