---
name: heartbeat
description: Coordinator heartbeat, the router's loop. Check GitHub, deploys, worker sessions, AWS SSO and Slack for changes since the last tick, act on each change, report in one short Chinese message. Use when a cron or the user sends /heartbeat or 心跳.
---

# Heartbeat

The coordinator is the router. It evaluates events, creates work, replies, reviews through agents, merges and watches deploys. It never writes code: code work goes to one worker session per ticket, each in its own directory. It takes as little human attention as possible: a person hears from it only when they must act or can use a result.

State is in `~/.claude/agent-templates` (or `$AGENT_OPS_HOME`), outside this plugin. Read `state/coordinator.md` (locks, owners, rules) before any merge or deploy. Read the newest `state/handoff-*.md` once per session. Read `heartbeat-local.md` once per session: who is who, which asks go where, the SSO command, the health URL, and hard rules for this team. Where it and this file differ, it wins.

## Handover

A new coordinator ticks once, in full, before the old one stops. After that tick it logs `<UTC> handover tick by <sid>` in `state/coordinator.md`; the old one stops its cron only after it sees that line. On its first tick the new coordinator runs `session.sh recover` and reads the list. It runs `session.sh recover --go` when the rows were cut off by a restart; `legacy` rows resume only by name. To stop with no successor, `touch state/heartbeat.stopped`, so the watchdog stays quiet; remove the file when you start again.

## Steps

1. **Probe.** Run `check.sh` (on the PATH while this plugin is loaded). It prints `NO CHANGE` or `CHANGED:` with `NEW`/`GONE` lines for PRs (every repo in `GH_REPOS`), the last deploy run, worker sessions with their final `STATUS:`, `ORG CHANGED`, SSO, disk and the external drive.
2. **Slack.** Read `state/heartbeat-slack.ts` (a Unix ts; create it with now−1800 if missing). Search all channels and DMs with `after:` that ts, bots included. Then write the newest message ts back. Done when every message from the people `heartbeat-local.md` names, and every mention of the operator, is handled by the table below.
3. **Act** on every change, using the table. Done when each `NEW` line and each Slack ask has an action or a stated reason for none.
4. **Report** in Chinese, ASD-STE100 style, results first. With no change and no Slack ask: one line, `心跳：无变化。` Never repeat a decision request already sent with no new facts.

## What to do per change

| Change | Action |
|---|---|
| New or updated PR (head changed), not draft, no review yet | One `pr-reviewer` agent at the head. An experiment PR: `experiment-reviewer`. |
| PR head changed after our review | One `delta-reviewer` agent: delta only, must-fix only. File what it lists under Follow-up as one follow-up issue. |
| PR approved by the required reviewer + checks green | `merge-when-green.sh <repo> <pr> <reviewed-sha>`, respecting coordinator.md order and locks; then watch the deploy (`gh run watch`), check the health URL, log one line in coordinator.md. Never main or prod without the operator's explicit yes. |
| PR in a repo with a standing authorization in `heartbeat-local.md`, agent review has no must-fix, CI green | Merge, same script. |
| PR with CHANGES_REQUESTED whose owner session is done | Resume the owner session with the review (`session.sh resume <name> <prompt>`), or launch one if none. |
| SESSION `done STATUS:ready` | `session.sh log <name>`; re-run a sample of its `EVIDENCE:` lines; relay, queue the next step, or close the item. |
| SESSION `done STATUS:blocked` | Read its `QUESTION:`. Answer it if the facts settle it and resume the session; else ask the operator once. |
| SESSION `done STATUS:waiting` | Note what it waits for; resume when that arrives. |
| SESSION `done STATUS:failed` | Read the log. Resume with a fix, or report to the operator. |
| SESSION `done` with no STATUS | `session.sh log <name>`. It may be cut off: `session.sh recover <name>` lists it. |
| `ORG CHANGED` | Stop launching on that profile; PushNotification to the operator. |
| Ask from a named teammate | Add 👀, start it (launch a worker session for code), reply in the thread when done, add ✅. |
| Anyone else asks the operator | Answer facts directly; scope or product calls go to the operator as a decision. |
| `SSO EXPIRED` | Follow the SSO command in `heartbeat-local.md`. |
| `DRIVE ... missing or wiped`, or `DISK` low | Stop launching work; PushNotification to the operator. |
| Decision only the operator can make | PushNotification, one Chinese line, ≤200 characters. |

## Launching and resuming workers

`session.sh launch <profile> <name> <prompt-file> [--client-data] [--personal-ok]`, `resume <name> <prompt-file> [--personal-ok]`, `recover [--go] [<name>...]`, `status`, `log <name>`. Use a team profile; a personal org is refused unless `--personal-ok`, and never allowed with `--client-data`. Every worker prompt starts with a mattpocock skill and tells the worker to load the `worker` skill of this plugin. `AGENT_OPS_PLUGIN=1` makes a new launch load the plugin.

## Hard rules

- Never type a password or an MFA code. Never print, copy or commit a secret.
- Slack replies: send directly, short.
- Real client data stays in the places `heartbeat-local.md` names; never in repos, PRs, trackers or artifacts.
