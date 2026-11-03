#!/usr/bin/env python3
"""Stop, workers only: ask once for the structured report.

Failures: headless workers stopped mid-task to ask for a confirmation nobody could give, and reports claimed things nobody
had checked. stop_hook_active ends it after one block, so this cannot loop. A turn with background work still running
is a pause, not the end, so it passes. onFailure has no effect on Stop: if this script breaks, the worker stops with no report.
"""
import json
import os
import re
import sys

data = json.load(sys.stdin)
if os.environ.get("AGENT_OPS_ROLE") != "worker" or data.get("stop_hook_active") or data.get("background_tasks"):
    sys.exit(0)
msg = data.get("last_assistant_message") or ""
found = re.findall(r"^STATUS: (ready|waiting|blocked|failed)[ \t]*$", msg, re.M)
question = re.search(r"^QUESTION: ", msg, re.M)
problem = None
if not found:
    problem = "Your last message has no STATUS line."
elif found[-1] == "blocked" and not question:
    problem = "STATUS: blocked needs one QUESTION: line."
elif found[-1] != "blocked" and question:
    problem = "QUESTION: is only for STATUS: blocked. Nobody answers it otherwise."
elif not re.search(r"^EVIDENCE: ", msg, re.M):
    problem = "Your report has no EVIDENCE: line."
if problem:
    reason = (problem + " If work remains that you can do, do it now and do not ask for confirmation. Then end with plain lines:\n"
              "STATUS: ready|waiting|blocked|failed\nQUESTION: <one concrete question, only if blocked>\n"
              "EVIDENCE: <command, exit code, head SHA>  (one line per claim; mark anything unchecked as not verified)")
    print(json.dumps({"decision": "block", "reason": reason}))
