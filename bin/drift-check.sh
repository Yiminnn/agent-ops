#!/bin/bash
# Mechanical goal-drift check, no model. Reads state/commitments.md (the cache the heartbeat renders from Linear with
# commitments-render.py), the session registry, state/pending.md and, for a goal whose checkpoint has passed, the merged
# PRs in GH_REPOS that name its DEF id. Prints one line per exception:
#   DRIFT CHECKPOINT <DEF> <objective>: checkpoint <date> passed, next proof "<proof>"; <merged PRs naming it>
#   DRIFT UNATTENDED <DEF> <objective>: no live executor and no human next action in pending.md (follow-up not passed)
#   DRIFT INCOMPLETE <DEF> <objective>: the Linear description lacks done-when, next proof or checkpoint ("-" in the cache)
#   DRIFT STALLED <DEF> <owner/repo>#<n> <days>d   an open, non-draft PR of the goal not opened, pushed, reviewed or commented
#                                           on for STALLED_DAYS (default 3). Its title, body or head branch names the DEF id (any
#                                           case), or it is stacked on or under such a PR (head = base), never through main, master
#                                           or DEPLOY_BRANCH. When gh fails (or cuts the list at 300), the line from check.sh's last
#                                           snapshot (state/heartbeat.last) is kept with the UNKNOWN: a failed read is not activity
#   DRIFT UNKNOWN: commitments cache stale (generated <UTC>)   its generated header is over 2 h old, or it has none
#   DRIFT DISPATCH ops|uncommitted ...      a dispatch since the last check (state/drift-check.last) with no committed goal
#   DRIFT PENDING overdue <date>|no follow-up: <line>
#   DRIFT UNKNOWN: <input>                  an input is missing or a gh query failed: never read silence as all clear
#   DRIFT NONE committed                    a fresh cache with no rows: no Linear issue carries the label (a valid state);
#                                           the one line then: every dispatch is ops, so no DISPATCH lines
# Exit 0 with no lines or only the NONE line, 1 with exceptions, 2 with an UNKNOWN. A merged PR is listed as evidence; it does not clear a
# passed checkpoint: the accountable human accepts the proof and moves the checkpoint in the Linear issue.
# check.sh prints these lines; it touches state/drift-check.next before this read and renames it to drift-check.last after it keeps a snapshot. AGENT_OPS_NOW (UTC ISO) fixes the clock for tests.
set -u
T="${AGENT_OPS_HOME:-$HOME/.claude/agent-templates}"
[ -f "$T/config" ] || { echo "DRIFT UNKNOWN: config ($T/config)"; exit 2; }
. "$T/config"
GH_REPOS="$GH_REPOS" STALLED_DAYS="${STALLED_DAYS:-3}" DEPLOY_BRANCH="${DEPLOY_BRANCH:-}" exec python3 - "$T/state" <<'EOF'
import datetime as dt, json, os, re, subprocess, sys
st = sys.argv[1]
now = dt.datetime.fromisoformat(os.environ["AGENT_OPS_NOW"].replace("Z", "+00:00")) if os.environ.get("AGENT_OPS_NOW") else dt.datetime.now(dt.timezone.utc)
today = now.date()
out, unknown = [], []

def read(name):
    try: return open(os.path.join(st, name)).read().splitlines()
    except OSError: unknown.append(f"{name} ({os.path.join(st, name)})"); return None

goals = {}  # DEF -> row cells, in file order (the order is the priority)
lines = read("commitments.md")
for l in lines or []:
    c = [x.strip() for x in l.strip().strip("|").split("|")]
    if re.fullmatch(r"DEF-\d+", c[0]):
        if len(c) < 7: unknown.append(f"row of {c[0]} in commitments.md (needs 7 cells)"); continue
        goals[c[0]] = dict(zip(["id", "objective", "human", "done", "proof", "checkpoint", "executor"], c[:7]))
gen = next((m.group(1) for m in map(re.compile(r"generated (\S+) from Linear").match, lines or []) if m), None)
if gen:
    try: age = now - dt.datetime.fromisoformat(gen.replace("Z", "+00:00"))
    except ValueError: age = None
    if age is None or age > dt.timedelta(hours=2): unknown.append(f"commitments cache stale (generated {gen})")
elif lines is not None: unknown.append("commitments.md has no generated header (the heartbeat writes it from Linear)")

def alive(pid):
    pid = pid.removeprefix("waiting:")
    if not pid.isdigit() or pid == "0": return False
    try: os.kill(int(pid), 0); return True
    except PermissionError: return True
    except OSError: return False

latest, tagged, dispatches = {}, {}, []  # name -> last row; name -> last dispatch goal; dispatch rows
reg = read("sessions.tsv")
try: since = dt.datetime.fromtimestamp(int(os.path.getmtime(os.path.join(st, "drift-check.last"))), dt.timezone.utc)  # registry times are whole seconds
except OSError: since = now - dt.timedelta(hours=24)
for l in reg or []:
    f = l.split("\t") + [""] * 13
    latest[f[0]] = f
    if f[11]:
        tagged[f[0]] = f[11]
        try: t = dt.datetime.fromisoformat(f[6].replace("Z", "+00:00"))
        except ValueError: continue
        if t >= since: dispatches.append(f)  # a dispatch in the boundary second shows on both ticks; check.sh prints it once
live = {n for n, f in latest.items() if alive(f[3])}

pend = read("pending.md")
acted = set()  # DEF ids with a human next action whose follow-up has not passed
for l in pend or []:
    if not l.strip() or l.lstrip().startswith("#"): continue
    m = re.search(r"follow-up:?\s*(\d{4}-\d{2}-\d{2})", l)
    if not m: out.append(f"DRIFT PENDING no follow-up: {l.strip()}"); continue
    if dt.date.fromisoformat(m.group(1)) < today: out.append(f"DRIFT PENDING overdue {m.group(1)}: {l.strip()}"); continue
    acted |= {"DEF-" + n for n in re.findall(r"\bDEF[- ](\d+)\b", l)}

def merged_prs(g):
    n, found, failed = g.removeprefix("DEF-"), [], False
    for repo in os.environ["GH_REPOS"].split():
        r = subprocess.run(["gh", "pr", "list", "-R", repo, "--state", "merged", "-L", "30", "--search", f'"DEF {n}" OR {g}',
                            "--json", "number,title,body,mergedAt,url"], capture_output=True, text=True)
        try: prs = json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError: prs = None
        if prs is None: unknown.append(f"gh pr list {repo} {g}"); failed = True; continue
        found += [(p["mergedAt"], f"{repo}#{p['number']}") for p in prs if re.search(rf"\bDEF[- ]{n}\b", p["title"] + " " + (p["body"] or ""))]
    if failed: return "merged PRs unknown (gh failed)"  # not "none" on a gh flake; check.sh leaves this evidence out of its comparison
    found.sort(reverse=True)
    return f"{len(found)} merged PRs name it, latest {found[0][1]} at {found[0][0][:10]}" if found else "no merged PR names it"

def open_prs():  # repo -> its open PRs, one gh call per repo; None when gh failed
    prs = {}
    for repo in os.environ["GH_REPOS"].split():
        r = subprocess.run(["gh", "pr", "list", "-R", repo, "--state", "open", "-L", "300",
                            "--json", "number,title,body,headRefName,baseRefName,isDraft"], capture_output=True, text=True)
        try: prs[repo] = json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError: prs[repo] = None
        if prs[repo] is None: unknown.append(f"gh pr list {repo} open")
        elif len(prs[repo]) >= 300: unknown.append(f"gh pr list {repo} open (300 PRs: the list may be cut off)")
    return prs

try: earlier = [l for l in open(os.path.join(st, "heartbeat.last")).read().splitlines() if l.startswith("DRIFT STALLED ")]  # check.sh's snapshot
except OSError: earlier = []

def stalled(g, prs):  # the goal's open PRs: title, body or head branch names it, plus the PRs stacked on or under one of them
    n, keep, days = g.removeprefix("DEF-"), {"main", "master", os.environ["DEPLOY_BRANCH"]}, int(os.environ["STALLED_DAYS"])
    for repo, ps in prs.items():
        blind, failed = ps is None or len(ps) >= 300, set()  # gh failed or cut off the repo's list; PRs whose activity gh failed to return
        ps = ps or []
        listed = {str(p["number"]) for p in ps}
        name = re.compile(rf"(?i)(?<![a-z0-9])def[-_ ]?{n}(?![0-9])")  # DEF 700, DEF-700, def-700 in any case; _ is a separator, not a word letter
        link = [p for p in ps if name.search(f"{p['title']} {p['body'] or ''} {p['headRefName']}")]
        while True:  # a stack link is a branch that is one PR's head and another's base; never a long-lived branch
            heads, bases = {p["headRefName"] for p in link} - keep, {p["baseRefName"] for p in link} - keep
            more = [p for p in ps if p not in link and (p["baseRefName"] in heads or p["headRefName"] in bases)]
            if not more: break
            link += more
        for p in sorted(link, key=lambda p: p["number"]):
            if p["isDraft"]: continue
            r = subprocess.run(["gh", "pr", "view", str(p["number"]), "-R", repo, "--json", "createdAt,commits,reviews,comments"], capture_output=True, text=True)
            try: v = json.loads(r.stdout) if r.returncode == 0 else None
            except ValueError: v = None
            if v is None: unknown.append(f"gh pr view {repo}#{p['number']}"); failed.add(str(p["number"])); continue
            ts = [x for x in [v.get("createdAt")] if x] + [c["committedDate"] for c in v.get("commits") or []] + [x["submittedAt"] for x in v.get("reviews") or [] if x.get("submittedAt")] + \
                 [x["createdAt"] for x in v.get("comments") or []]
            if not ts: continue
            quiet = (now - max(dt.datetime.fromisoformat(t.replace("Z", "+00:00")) for t in ts)).days
            if quiet >= days: out.append(f"DRIFT STALLED {g} {repo}#{p['number']} {quiet}d")
        for l in earlier:  # a gh failure is not activity: keep the earlier line of a PR gh could not read, so check.sh sees no GONE
            m = re.match(rf"DRIFT STALLED {g} {re.escape(repo)}#(\d+) ", l)
            if m and (m[1] in failed or (blind and m[1] not in listed)): out.append(l)

prs = open_prs() if goals else {}
for g, c in goals.items():
    stalled(g, prs)
    miss = [k for k, f in (("done-when", "done"), ("next proof", "proof"), ("checkpoint", "checkpoint")) if c[f] in ("", "-")]
    if miss: out.append(f"DRIFT INCOMPLETE {g} {c['objective']}: no {', '.join(miss)} in the Linear description (accountable: {c['human']})")
    try: cp = None if "checkpoint" in miss else dt.date.fromisoformat(c["checkpoint"])
    except ValueError: unknown.append(f"checkpoint of {g} in commitments.md ({c['checkpoint']!r}, want YYYY-MM-DD)"); continue
    if cp and cp < today:
        out.append(f'DRIFT CHECKPOINT {g} {c["objective"]}: checkpoint {cp} passed, next proof "{c["proof"]}"; {merged_prs(g)}')
    ex = c["executor"] if c["executor"] not in ("", "-") else ""
    if (ex and ex in live) or any(tagged.get(n) == g for n in live) or g in acted: continue
    out.append(f"DRIFT UNATTENDED {g} {c['objective']}: " + (f"executor {ex} not running" if ex else "no live executor") +
               f"; no human next action in pending.md (accountable: {c['human']})")

for f in dispatches if goals or not gen else []:
    if f[11] == "ops": out.append(f"DRIFT DISPATCH ops {f[0]} {f[6]}: {f[12]}")
    elif gen and f[11] not in goals: out.append(f"DRIFT DISPATCH uncommitted {f[11]} {f[0]} {f[6]}: {f[12]}")

if gen and not goals: print("DRIFT NONE committed")  # a valid state: no Linear issue carries the label
for u in unknown: print(f"DRIFT UNKNOWN: {u}")
for l in out: print(l)
sys.exit(2 if unknown else 1 if out else 0)
EOF
