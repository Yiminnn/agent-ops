---
name: worker
description: Rules for a worker session, the executor of one ticket in its own directory, and the report it must end with. Load at the start of every coordinator-run worker session, and again before you write the report.
---

# Worker

You own one ticket, in your own worktree. The coordinator routes; you do the technical work and verify it.

1. Read `~/.claude/agent-templates/worker-rules.md` in full, including "Delete paths". Read the round's copy if your prompt names one. It is the one source for workspace, tests, data and output rules.
2. Never stop mid-task to ask for a confirmation: no person reads this session. Decide routine things yourself and state the decision. Finish what you can, then end with `blocked` and one question.
3. End your last message with the report below. The last lines are plain text with no bold and no code fence: `check.sh` and a Stop hook read them.

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
