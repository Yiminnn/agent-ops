"""Split Bash command text into simple commands for the deny hooks.

It reads text only. What a script or a Python child does after it starts is invisible here.
Quotes are not kept, so `echo 'pkill -f x'` under `bash -c` or in a heredoc can match: a false deny costs
a retry through the Write tool, a miss costs another session's work.
"""
import json
import os
import re
import shlex
import sys

PUNCT = set(";&|()\n")
KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "time"}
WRAPPERS = {"sudo", "env", "nohup", "command", "exec", "nice", "caffeinate", "xargs", "timeout", "gtimeout", "builtin"}
SHELLS = {"sh", "bash", "zsh", "dash"}
HOME = os.path.expanduser("~")


def config(key):
    """A value from $AGENT_OPS_HOME/config. A missing one exits 1: onFailure blocks the call, loudly."""
    path = os.path.join(os.environ.get("AGENT_OPS_HOME") or os.path.join(HOME, ".claude/agent-templates"), "config")
    value = None
    try:
        for line in open(path):
            k, _, v = line.strip().partition("=")
            if k != key:
                continue
            if value is not None or not re.fullmatch(r'"/[^"$`\'\\]*"', v):
                sys.exit(f"agent-ops: {key} in {path} must appear once, as a quoted literal absolute path: bash and Python read anything else differently")
            value = v[1:-1]
    except OSError:
        pass
    if value is not None:
        return value
    sys.exit(f"agent-ops: {key} is not set in {path}; copy config.example")


def _tokens(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace, lex.whitespace_split, lex.commenters = " \t\r", True, ""
    return list(lex)


def _simple(text):
    try:
        toks = _tokens(text)
    except ValueError:  # a heredoc apostrophe, an unclosed quote: read the words anyway
        toks = _tokens(re.sub(r"[\\'\"]", " ", text))
    cur = []
    for t in toks + [";"]:
        if t and set(t) <= PUNCT:
            if cur:
                yield cur
            cur = []
            for c in t:
                if c in "()":
                    yield [c]
        else:
            cur.append(t)


def _strip(argv):
    argv = list(argv)
    while argv and (argv[0] in KEYWORDS or re.fullmatch(r"\w+=.*", argv[0])):
        argv.pop(0)
    if argv and os.path.basename(argv[0]) in WRAPPERS:
        argv.pop(0)
        while argv and (argv[0].startswith("-") or re.fullmatch(r"\w+=.*|[\d.]+[smhd]?", argv[0])):
            argv.pop(0)
        return _strip(argv)
    return argv


def path_of(word, cwd):
    """Absolute normal form of a path word: ~ and $HOME expanded, a trailing /* or / dropped."""
    word = re.sub(r"^(~|\$HOME|\$\{HOME\})(?=/|$)", HOME, word)
    word = re.sub(r"(/\.?\*)+$", "/", word)
    return os.path.normpath(os.path.join(cwd, word))


def walk(text, cwd):
    """Yield (argv, cwd) per simple command. Follows `cd`, `bash -c`, `eval`, $(...) and backticks."""
    state = [cwd]

    def visit(chunk, depth):
        subshells = []
        for raw in _simple(chunk):
            if raw == ["("]:
                subshells.append(state[0])
                continue
            if raw == [")"]:
                state[0] = subshells.pop() if subshells else state[0]
                continue
            argv = _strip(raw)
            outer = state[0]
            if depth < 5:
                for word in raw:
                    for inner in re.findall(r"\$\(([^()]*)\)|`([^`]*)`", word):
                        yield from visit(inner[0] or inner[1], depth + 1)
                        state[0] = outer
            if not argv:
                continue
            base, args = os.path.basename(argv[0]), argv[1:]
            if base == "cd" and args[:1] == ["--"]:
                args = args[1:] or [HOME]
            if base in {"cd", "pushd"} and args:
                state[0] = path_of(args[0], state[0])
            elif base == "eval" and depth < 5:
                yield from visit(" ".join(args), depth + 1)
            elif base in SHELLS and depth < 5:
                flags = [i for i, a in enumerate(args) if re.fullmatch(r"-[a-z]*c", a)]
                if flags and flags[0] + 1 < len(args):
                    yield from visit(args[flags[0] + 1], depth + 1)
                    state[0] = outer
            yield [base] + args, state[0]

    return visit(text, 0)


def run(rule):
    """Hook main: rule(command, cwd) returns a reason to deny, or None."""
    data = json.load(sys.stdin)
    command = (data.get("tool_input") or {}).get("command") or ""
    reason = rule(command, data.get("cwd") or os.getcwd())
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
