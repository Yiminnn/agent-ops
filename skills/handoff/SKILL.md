---
name: handoff
description: Write the coordinator handoff to state/handoff-<date>.md, so a new coordinator can take over without this conversation. Use before a coordinator stops or changes session, or when the user asks for a handoff.
---

# Handoff

Write `~/.claude/agent-templates/state/handoff-<UTC date>.md`. If today's file exists, append `## Added <HH:MM>Z` and do not rewrite it. Check every line against `session.sh status`, `gh` and `state/coordinator.md` before you write it. Newest facts only; history stays in `coordinator.md`.

```markdown
# Coordinator handoff — <date> <HH:MM>Z (from session <sid>, profile <profile>)

Read this, then state/coordinator.md (locks + owners), then worker-rules.md.

## Live and just finished sessions
| name | sid / pid | STATUS | next step |

## Waiting on people
- <person>: <item>, since <date>.

## Decisions waiting on the operator
- <one line each, with the facts needed>

## The operator's standing decisions
- <rule from this period>, <date>.

## Incidents
- <what happened, what is lost, what changed>

## Candidate next work
- <ticket>: <why now>
```

Rules:
- No secrets and no key content. Name client data by its path; never paste it.
- Say what you did not verify.
- Handover: the new coordinator ticks once before the old one stops (`heartbeat` skill). `session.sh status` at that time is the source for the sessions table.
