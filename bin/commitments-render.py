#!/usr/bin/env python3
"""Render state/commitments.md, the read-only cache of committed goals, from Linear issues as JSON on stdin.

The heartbeat pipes in what the Linear MCP returned for team LINEAR_TEAM, label COMMITTED_LABEL, not completed or
canceled: a list of issues, or {"issues": [...]}. Per issue: identifier (DEF-n), title, assignee (a name, or an object
with name or displayName), description. The description holds the block, one field per line, anywhere in it:
    Done when: <the done-when clause>
    Next proof: <one inspectable result>
    Checkpoint: YYYY-MM-DD
A missing field renders as "-"; drift-check.sh flags that row. The executor is the session that last dispatched on the
goal (registry column 12), or "-". The file is replaced atomically; on bad input nothing is written and the exit is 1.
AGENT_OPS_NOW (UTC ISO) fixes the clock for tests.
"""
import datetime as dt, json, os, re, sys

T = os.environ.get("AGENT_OPS_HOME") or os.path.expanduser("~/.claude/agent-templates")
STATE = os.path.join(T, "state")
FIELDS = {"done when": "done", "next proof": "proof", "checkpoint": "checkpoint"}
LINE = re.compile(r"^\s*(?:[-*]\s+)?\**\s*(done when|next proof|checkpoint)\s*:\s*\**\s*(.*?)\s*$", re.I)


def config():
    try: lines = open(os.path.join(T, "config")).read().splitlines()
    except OSError: return {}
    return {m[1]: m[2] for m in (re.match(r'^([A-Z_]+)="(.*)"', l) for l in lines) if m}


def block(desc):
    out = {}
    for l in (desc or "").splitlines():
        m = LINE.match(l)
        if m and m[2] and FIELDS[m[1].lower()] not in out: out[FIELDS[m[1].lower()]] = m[2]
    return out


def name(a):
    if isinstance(a, dict): a = a.get("name") or a.get("displayName")
    return a or "-"


def cell(s):
    return " ".join(str(s).replace("|", "/").split()) or "-"


def main():
    try:
        data = json.load(sys.stdin)
        issues = data["issues"] if isinstance(data, dict) else data
        if not isinstance(issues, list): raise ValueError("want a list of issues")
        bad = [i for i in issues if not isinstance(i, dict) or not i.get("identifier")]
        if bad: raise ValueError(f"issue with no identifier: {json.dumps(bad[0])[:120]}")
    except (ValueError, KeyError) as e:
        sys.exit(f"commitments-render: bad input, {STATE}/commitments.md kept: {e}")
    executor = {}
    try:
        for l in open(os.path.join(STATE, "sessions.tsv")).read().splitlines():
            f = l.split("\t")
            if len(f) > 11 and f[11]: executor[f[11]] = f[0]
    except OSError: pass
    c = config()
    now = dt.datetime.fromisoformat(os.environ["AGENT_OPS_NOW"].replace("Z", "+00:00")) if os.environ.get("AGENT_OPS_NOW") else dt.datetime.now(dt.timezone.utc)
    rows = []
    for i in issues:
        b = block(i.get("description"))
        rows.append([i["identifier"], i.get("title", ""), name(i.get("assignee")), b.get("done", "-"), b.get("proof", "-"),
                     b.get("checkpoint", "-"), executor.get(i["identifier"], "-")])
    text = "\n".join([
        "# Commitments",
        f"generated {now.strftime('%Y-%m-%dT%H:%MZ')} from Linear label {c.get('COMMITTED_LABEL') or 'committed'}; do not edit",
        "",
        f"Ops allowance: {c.get('OPS_ALLOWANCE') or '-'}",
        "",
        "| DEF | objective | accountable | done-when | next proof | checkpoint | executor |",
        "|---|---|---|---|---|---|---|",
        *("| " + " | ".join(map(cell, r)) + " |" for r in rows),
    ]) + "\n"
    tmp = os.path.join(STATE, ".commitments.md.tmp")
    with open(tmp, "w") as f: f.write(text)
    os.replace(tmp, os.path.join(STATE, "commitments.md"))



if __name__ == "__main__": main()
