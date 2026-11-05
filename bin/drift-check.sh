#!/bin/bash
# Mechanical goal-drift check, no model. Reads state/commitments.md (the cache the heartbeat renders from Linear with
# commitments-render.py), the session registry, state/pending.md and, for a goal whose checkpoint has passed, the merged
# PRs in GH_REPOS that name its DEF id. Prints one line per exception:
#   DRIFT CHECKPOINT <DEF> <objective>: checkpoint <date> passed, next proof "<proof>"; <merged PRs naming it>
#   DRIFT UNATTENDED <DEF> <objective>: no live executor and no human next action in pending.md (follow-up not passed)
#   DRIFT INCOMPLETE <DEF> <objective>: the Linear description lacks done-when, next proof or checkpoint ("-" in the cache)
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
GH_REPOS="$GH_REPOS" exec python3 - "$T/state" <<'EOF'
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

for g, c in goals.items():
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
