#!/usr/bin/env python3
"""Render state/commitments.md, the read-only cache of committed goals, from Linear issues as JSON on stdin, or with
--local from state/goals.md, the human-maintained list used when LINEAR_TEAM is empty (drift-check.sh and the dispatch
gate run that form themselves). goals.md: one heading per goal, in priority order, the block lines under it:
    ## DEF-12 <objective>
    Accountable: <name>
    Done when: ... / Next proof: ... / Checkpoint: YYYY-MM-DD

The heartbeat pipes in what the Linear MCP returned for team LINEAR_TEAM, label COMMITTED_LABEL, not completed or
canceled: a list of issues, or {"issues": [...]}. Per issue: identifier (DEF-n), title, assignee (a name, or an object
with name or displayName), description. The description holds the block, one field per line, anywhere in it:
    Done when: <the done-when clause>
    Next proof: <one inspectable result>
    Checkpoint: YYYY-MM-DD
A missing field renders as "-"; drift-check.sh flags that row. The executor is the session whose current dispatch is the
goal (its last non-empty registry column 12), or "-". The file is replaced atomically; on bad input nothing is written and the exit is 1.
AGENT_OPS_NOW (UTC ISO) fixes the clock for tests.
"""
import datetime as dt, json, os, re, subprocess, sys, tempfile

T = os.environ.get("AGENT_OPS_HOME") or os.path.expanduser("~/.claude/agent-templates")
STATE = os.path.join(T, "state")
FIELDS = {"done when": "done", "next proof": "proof", "checkpoint": "checkpoint", "accountable": "human"}
LINE = re.compile(r"^\s*(?:[-*]\s+)?\**\s*(done when|next proof|checkpoint|accountable)\s*\**\s*:\s*\**\s*(.*?)\s*\**\s*$", re.I)


def config():  # sourced by bash, as drift-check.sh and drift-audit.sh read it, so quoting means the same thing
    cfg = os.path.join(T, "config")
    if not os.path.isfile(cfg): return {}
    r = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; printf "%s\\0%s" "${COMMITTED_LABEL-}" "${OPS_ALLOWANCE-}"', "_", cfg],
                       capture_output=True, text=True)
    return dict(zip(["COMMITTED_LABEL", "OPS_ALLOWANCE"], r.stdout.split("\0")))


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


def local():  # goals.md -> issues in the shape Linear gives; a heading "# <ID-n> <title>" starts a goal
    path = os.path.join(STATE, "goals.md")
    try: lines = open(path).read().splitlines()
    except OSError: raise ValueError(f"no {path} (LINEAR_TEAM is empty, so the goals live there)")
    issues = []
    for l in lines:
        m = re.match(r"^#+\s+([A-Za-z]+-\d+)\b[\s:.-]*(.*)$", l)
        if m: issues.append({"identifier": m[1], "title": m[2].strip(), "description": ""})
        elif issues: issues[-1]["description"] += l + "\n"
    for i in issues: i["assignee"] = block(i["description"]).get("human")
    dup = [i["identifier"] for n, i in enumerate(issues) if i["identifier"] in [j["identifier"] for j in issues[:n]]]
    if dup: raise ValueError(f"{dup[0]} appears twice in {path}")
    return issues


def main():
    loc = "--local" in sys.argv[1:]
    try:
        data = local() if loc else json.load(sys.stdin)
        issues = data["issues"] if isinstance(data, dict) else data
        if not isinstance(issues, list): raise ValueError("want a list of issues")
        bad = [i for i in issues if not isinstance(i, dict) or not i.get("identifier")]
        if bad: raise ValueError(f"issue with no identifier: {json.dumps(bad[0])[:120]}")
        bad = [i["identifier"] for i in issues if not re.fullmatch(r"DEF-\d+", str(i["identifier"]))]
        if bad: raise ValueError(f"{bad[0]} is not DEF-n: goals are DEF-n: LINEAR_TEAM must be the DEF team, goals.md headings DEF-n (drift-check.sh reads DEF rows only)")
    except (ValueError, KeyError) as e:
        sys.exit(f"commitments-render: bad input, {STATE}/commitments.md kept: {e}")
    current = {}  # session name -> its current dispatch (last non-empty column 12), as drift-check.sh's tagged
    try:
        for l in open(os.path.join(STATE, "sessions.tsv")).read().splitlines():
            f = l.split("\t")
            if len(f) > 11 and f[11]: current[f[0]] = f[11]
    except OSError: pass
    executor = {g: n for n, g in current.items()}
    c = config()
    now = dt.datetime.fromisoformat(os.environ["AGENT_OPS_NOW"].replace("Z", "+00:00")) if os.environ.get("AGENT_OPS_NOW") else dt.datetime.now(dt.timezone.utc)
    rows = []
    for i in issues:
        b = block(i.get("description"))
        rows.append([i["identifier"], i.get("title") or "-", name(i.get("assignee")), b.get("done", "-"), b.get("proof", "-"),
                     b.get("checkpoint", "-"), executor.get(i["identifier"], "-")])
    text = "\n".join([
        "# Commitments",
        f"generated {now.strftime('%Y-%m-%dT%H:%MZ')} from " + ("goals.md" if loc else f"Linear label {c.get('COMMITTED_LABEL') or 'committed'}") + "; do not edit",
        "",
        f"Ops allowance: {c.get('OPS_ALLOWANCE') or '-'}",
        "",
        "| DEF | objective | accountable | done-when | next proof | checkpoint | executor |",
        "|---|---|---|---|---|---|---|",
        *("| " + " | ".join(map(cell, r)) + " |" for r in rows),
    ]) + "\n"
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".commitments.")  # own name: the gate and drift-check may render at once
    with os.fdopen(fd, "w") as f: f.write(text)
    os.replace(tmp, os.path.join(STATE, "commitments.md"))



if __name__ == "__main__": main()
