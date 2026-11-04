---
name: worker
description: Rules for a worker session, the executor of one ticket in its own directory, and the report it must end with. Load at the start of every coordinator-run worker session, and again before you write the report.
---

# Worker

You own one ticket, in your own worktree. The coordinator routes; you do the technical work and verify it.

1. Read `~/.claude/agent-templates/worker-rules.md` in full, including "Delete paths". Read the round's copy if your prompt names one. It is the one source for workspace, tests, data and output rules.
2. Your cwd is your worktree, already created on your branch: stay in it. If your cwd is the primary checkout, you have no worktree: make no git writes; if the task needs commits, end `blocked` and ask for a `--worktree` launch. Your Bash runs with no sandbox by default. Only when the coordinator set `WORKER_SANDBOX=1` (your prompt says so, or a write fails with `Operation not permitted`) does it run in a sandbox: then it can write only your worktree, temp, the Daytona lane logs and the dirs the coordinator added with `--write`. Make venvs as `.venv` in the worktree. An `Operation not permitted` outside those is the sandbox: do not retry it another way; finish what you can and end `blocked`, naming the directory you need.
3. Never stop mid-task to ask for a confirmation: no person reads this session. Decide routine things yourself and state the decision. Finish what you can, then end with `blocked` and one question.
4. Write prompt, PR body and comment text with the Write tool, then pass the file (`gh pr create --body-file`, `git commit -F`). The one guard hook left, `deny_kill`, reads text, not shell: a heredoc in Bash that holds a kill by pattern is denied. The other text hooks are off (Yimin, 2026-11-04: they gave false positives, and the harness stays light), so these are rules, not hooks: never merge (only the coordinator merges, through `merge-when-green.sh`), no git writes in the primary checkout, and delete only what you created.
5. End your last message with the report below. The last lines are plain text with no bold and no code fence: `check.sh` and a Stop hook read them.

## Report contract

```
STATUS: ready|waiting|blocked|failed
QUESTION: <one concrete question>
EVIDENCE: <what you claim>: <command>, exit <code>, <head SHA or file:line>
```

| STATUS | Meaning |
|---|---|
| `ready` | The work is done and verified, and a result is ready to use. |
| `waiting` | You did all you can until a named outside event happens: CI, a review, a date. Say which. |
| `blocked` | Only a decision from a person can move this. Write `QUESTION:`. |
| `failed` | It did not work. Say what you tried and what you saw. A draft is not `ready`. |

- `QUESTION:` only with `blocked`, and only one.
- One `EVIDENCE:` line per claim. Run the command before you claim the result. Write `not verified` beside anything you did not check.

The Stop hook asks once for a missing report. It cannot make the report true.
