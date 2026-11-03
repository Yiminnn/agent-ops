#!/usr/bin/env python3
"""PreToolUse Bash: deny a hand-made merge, and any git write in the primary checkout.

Failure 1: a hand-written wait-and-merge loop could merge a head nobody reviewed. merge-when-green.sh merges only the
reviewed head. Its inner `gh pr merge` is not a tool call, so this hook never sees it; the script's own command line passes.
Failure 2: `git checkout ref -- .` overwrote files in a checkout other sessions rely on. Allowed in the primary checkout:
reads, `fetch`, `worktree add` (worker-rules create worktrees that way) and `worktree remove` of an outside path with no
--force (git refuses a dirty one). `worktree prune` stays denied. Everything else is denied, unknown verbs too.
Not stopped: a merge through curl, and git inside a script.
"""
import os
import re

from cmdtext import config, path_of, run, walk

PRIMARY = config("PRIMARY_CHECKOUT")
READ = {"status", "log", "show", "diff", "rev-parse", "rev-list", "ls-files", "ls-tree", "cat-file", "merge-base", "describe",
        "blame", "grep", "shortlog", "for-each-ref", "name-rev", "check-ignore", "fetch", "help", "version", "reflog"}
LIST_FLAGS = {"branch": {"--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--show-current"}, "tag": {"--list", "-l"}}
MERGE = "agent-ops deny-merge: merge only through merge-when-green.sh <owner/repo> <pr> <reviewed-sha>; it merges the reviewed head or nothing."
WRITE = f"agent-ops deny-git: no git write in {PRIMARY} ({{}}). Work in a worktree: git -C {PRIMARY} worktree add <dir on the work drive> -b <branch> origin/<base>."


def in_primary(path):
    real = os.path.realpath(path).casefold()
    root = os.path.realpath(PRIMARY).casefold()
    if real != root and not real.startswith(root + "/"):
        return False
    return not re.match(r"/(\.worktrees|\.claude/worktrees)(/|$)", real[len(root):])


def git_write(args, cwd):
    """The subcommand when this git call writes to the primary checkout, else None."""
    i, target = 0, cwd
    while i < len(args) and args[i].startswith("-"):
        flag = args[i]
        if flag in {"-C", "--git-dir", "--work-tree"} and i + 1 < len(args):
            target = path_of(args[i + 1], target)
            i += 1
        elif flag.startswith(("--git-dir=", "--work-tree=")):
            target = path_of(flag.split("=", 1)[1], target)
        elif flag in {"-c", "--namespace"}:
            i += 1
        i += 1
    if i >= len(args) or not in_primary(target):
        return None
    sub, rest = args[i], args[i + 1:]
    if sub in READ:
        return None
    if sub in LIST_FLAGS and set(rest) <= LIST_FLAGS[sub]:
        return None
    if sub == "config" and rest and rest[0] in {"--get", "--get-all", "--list", "-l"}:
        return None
    if sub == "remote" and (not rest or rest[0] in {"-v", "get-url", "show"}):
        return None
    if sub == "worktree" and rest and rest[0] in {"add", "list"}:
        return None
    if sub == "worktree" and rest[:1] == ["remove"] and not {"-f", "--force"} & set(rest):
        if not any(in_primary(path_of(a, target)) for a in rest[1:]):
            return None
    return sub


def gh_merge(args):
    words, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in {"-R", "--repo"}:
            skip = True
        elif not a.startswith("-"):
            words.append(a)
    if words[:2] == ["pr", "merge"]:
        return True
    return words[:1] == ["api"] and any(re.search(r"/merges?\b|mergePullRequest|AutoMerge", a) for a in args)


def rule(command, cwd):
    for argv, where in walk(command, cwd):
        args = argv[1:]
        if argv[0] == "gh" and gh_merge(args):
            return MERGE
        if argv[0] == "gh" and args[:2] == ["pr", "checkout"] and in_primary(where):
            return WRITE.format("gh pr checkout")
        if argv[0] == "git":
            sub = git_write(args, where)
            if sub:
                return WRITE.format("git " + sub)
    return None


run(rule)
