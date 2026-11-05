---
name: heartbeat
description: Coordinator heartbeat, the router's loop. Check GitHub, deploys, worker sessions, AWS SSO and Slack for changes since the last tick, act on each change, report in one short Chinese message. Use when a cron or the user sends /heartbeat or 心跳.
---

# Heartbeat

The coordinator is the router. It evaluates events, creates work, replies, reviews through agents, merges and watches deploys. It never writes code: code work goes to one worker session per ticket, each in its own directory. It takes as little human attention as possible: a person hears from it only when they must act or can use a result.

State is in `~/.claude/agent-templates` (or `$AGENT_OPS_HOME`), outside this plugin. Read `state/coordinator.md` (locks, owners, rules) before any merge or deploy. Read the newest `state/handoff-*.md` once per session. Read `heartbeat-local.md` once per session: who is who, which asks go where, the SSO command, the health URL, and hard rules for this team. Where it and this file differ, it wins.

## Handover

Only one coordinator acts at a time. The old one stops first: it deletes its cron, lets a running tick finish, and logs `<UTC> handover release by <sid>` in `state/coordinator.md`. Until that line exists, the new one only reads: it may run Probe and read Slack, but it does no step 4 or 5 action. After the line, it logs `<UTC> handover take by <sid>` and ticks in full. If the old session is dead and cannot write the line, the new one confirms that no `release` or `tick` line from the old sid is newer than 30 minutes, logs `<UTC> handover take by <sid> (old <sid> unresponsive)`, and goes on. On its first tick after a start or a recovery, the coordinator reads the whole of `state/heartbeat.last` and reconciles PRs and finished sessions against `state/coordinator.md` and live GitHub, even if the probe says `NO CHANGE`: the old coordinator may have stopped between Probe and Act. It checks whether each outside action already happened before it does one. It also runs `session.sh recover` and reads the list. It runs `session.sh recover --go` when the rows were cut off by a restart; `legacy` rows resume only by name. To stop with no successor, `touch state/heartbeat.stopped`, so the watchdog stays quiet; remove the file when you start again.

## Steps

1. **Probe.** Run `check.sh` (on the PATH while this plugin is loaded). It prints `NO CHANGE` or `CHANGED:` with `NEW`/`GONE` lines for PRs (every repo in `GH_REPOS`), the last deploy run, worker sessions with their final `STATUS:`, the `DELIVER` lines of finished worker reports, `SKILL STALE`, `ORG CHANGED`, SSO, disk, the external drive, and the `DRIFT` lines of `drift-check.sh` (goal drift, below). If it exits 1 (`probe failed; last snapshot kept`), that is not `NO CHANGE`: nothing was observed. Retry next tick; report it if it repeats.
2. **Sync commitments.** Linear is the one source of committed goals; `state/commitments.md` is a cache that this step rewrites every tick, and nobody edits it. With the Linear MCP tools, list the issues in team `LINEAR_TEAM` with label `COMMITTED_LABEL` (both from the config; the label defaults to `committed`). Follow `cursor` until `hasNextPage` is false. Drop issues whose status type is completed or canceled. If a listed issue has no full description, read it with `get_issue`. Write the issues, in Linear priority order (Urgent first, no priority last), as a JSON list of `{"identifier", "title", "assignee", "description"}` to a temp file with the Write tool, then run `commitments-render.py < <file>` (on the PATH with this plugin). It writes the cache with the header `generated <UTC> from Linear label <label>; do not edit` and the ops allowance from `OPS_ALLOWANCE`. Never add or remove the committed label, and never write the cache by hand: humans decide what is committed. If Linear cannot be read, or the render exits non-zero, keep the old file and put `DRIFT UNKNOWN: linear sync failed (<reason>)` in this tick's report; do not write a file that looks fresh. The `DRIFT` lines of this tick's Probe come from the cache of the last sync; `drift-check.sh` says `commitments cache stale` once that is over 2 hours old.

   The parsing contract for an issue (the code is `bin/commitments-render.py`; its tests are `tests/commitments.sh`):
   - identifier = `DEF-n` only (`LINEAR_TEAM` must be the DEF team); another id makes the render fail and keeps the old file. An empty list is valid: the cache has no rows and `drift-check.sh` prints `DRIFT NONE committed`.
   - objective = the title, or `-`; accountable = the assignee's name, or `-`; executor = the session whose current dispatch (its last non-empty registry column 12) is `--goal <id>`, or `-`. A session that moved to another goal or to `--ops` no longer counts.
   - The description holds three lines, anywhere in it, one field per line; the first of each wins; a `- ` or `* ` bullet and bold (`**Done when:** x`, `**Done when**: x`, `**Done when: x**`) are allowed; keys are not case-sensitive:
     `Done when: <the done-when clause>`, `Next proof: <one inspectable result>`, `Checkpoint: YYYY-MM-DD` (UTC).
   - A missing line renders as `-`, and `drift-check.sh` prints `DRIFT INCOMPLETE <DEF> …` for that row: ask the accountable human once to fill in the issue. `|` in a value becomes `/`.
3. **Slack.** Read `state/heartbeat-slack.ts` (a Unix ts; create it with now−1800 if missing). Read each channel id on the `Read channels` line of `heartbeat-local.md` (one line listing the people's DMs and group DMs, each as `<name> <channel id>`) with `slack_read_channel` from `oldest=<ts>`: search misses file-only messages, which have no text. Search only the other channels and DMs, with `after:` that ts, a `limit` and `response_format: concise`, bots included. Done when every message from the people `heartbeat-local.md` names, and every mention of the operator, is handled by the table below. Move the ts forward only past messages that are handled, or that have a line in `state/pending.md`; a crash before that point reads them again next tick.
4. **Open work.** The probe diff says what changed; it does not say what is still undone. A tick that died after Probe leaves no diff, so derive the work from live state every tick, even on `NO CHANGE`:
   - each open, non-draft PR whose current head has no line `review <owner/repo>#<n> <head>` in `state/handled.txt`. Do not use GitHub reviews by the operator's login for this: workers post under the same login;
   - each PR approved by the required reviewer with checks green and not merged;
   - each session row `done STATUS:<x> pid=<p>` with no line `session <name> <p>` in `state/handled.txt`;
   - each line in `state/pending.md`;
   - each `DRIFT` line in `state/heartbeat.last`. Print them in the report as they are.
5. **Act** on every item of steps 1–4, using the table. Done when each item has an action or a stated reason for none. After you act on a session, append `session <name> <pid>` to `state/handled.txt`; when you start a reviewer, append `review <owner/repo>#<n> <head>` (full SHA). Every promise you make to a person ("I will send / do X") gets a `state/pending.md` row `- <operator>→<person> | <what> | since <date> | <link> | follow-up <YYYY-MM-DD>` in the same step; remove the row when it is kept. An open PR older than the ledger with no line: check whether a workflow review exists at that head (its body names the reviewed SHA) before you start one. Before an outside action that must not run twice (merge, deploy, Slack reply, file upload), check live state that it has not happened.
6. **Done.** Write `<UTC> ok` (or `<UTC> failed: <reason>`) to `state/heartbeat.done`. The watchdog reads this file: `heartbeat.last` changes at Probe, before the tick has done its work.
7. **Report** in Chinese, ASD-STE100 style, results first. With no change, no open work and no Slack ask: one line, `心跳：无变化。` Never repeat a decision request already sent with no new facts.

## What to do per change

| Change | Action |
|---|---|
| New or updated PR (head changed), not draft, no review yet | One `pr-reviewer` agent at the head. An experiment PR: `experiment-reviewer`. |
| PR head changed after our review | One `delta-reviewer` agent: delta only, must-fix only. File what it lists under Follow-up as one follow-up issue. |
| PR approved by the required reviewer + checks green | `merge-when-green.sh <repo> <pr> <reviewed-sha>`, respecting coordinator.md order and locks; then watch the deploy (`gh run watch`), check the health URL, log one line in coordinator.md. Never main or prod without the operator's explicit yes. |
| PR in a repo with a standing authorization in `heartbeat-local.md`, agent review has no must-fix, CI green | Merge, same script. |
| PR with CHANGES_REQUESTED whose owner session is done | Resume the owner session with the review (`session.sh resume <name> <prompt> --continue`), or launch one if none. |
| SESSION `done STATUS:ready` | `session.sh log <name>`; re-run a sample of its `EVIDENCE:` lines; relay, queue the next step, or close the item. |
| SESSION `done STATUS:blocked` | Read its `QUESTION:`. Answer it if the facts settle it and resume the session; else ask the operator once. |
| SESSION `done STATUS:waiting` | Note what it waits for; resume when that arrives. |
| SESSION `done STATUS:failed` | Read the log. Resume with a fix, or report to the operator. |
| SESSION `done` with no STATUS | `session.sh log <name>`. It may be cut off: `session.sh recover <name>` lists it. |
| `DELIVER <session> <hash8> <to> \| <what> \| <path>` | Send `<what>` (the file at `<path>`) to `<to>`, or state in the report why not. Then append `deliver <session> <hash8>` to `state/handled.txt`; `check.sh` prints the line every tick until then. |
| `DELIVER MALFORMED <session> <hash8>: <line>` | The worker wrote a DELIVER line with no `\|`. Read the session log, deliver what it meant or say why not, then append `deliver <session> <hash8>`. |
| `DELIVER EXPIRED <session> <to> \| <what>` | An unhandled DELIVER from a log 7–30 days old; it prints once. Say in the report that it was never sent, and ask the operator once whether it still goes. |
| `SKILL STALE <old>→<new>` | The plugin moved on since this session loaded its skills. Re-invoke `agent-ops:heartbeat` (and any other agent-ops skill in use), then write `<new>` to `state/coordinator-plugin-rev`. |
| `ORG CHANGED` | Stop launching on that profile; PushNotification to the operator. |
| Ask from a named teammate | Add 👀, start it (launch a worker session for code), reply in the thread when done, add ✅. |
| Anyone else asks the operator | Answer facts directly; scope or product calls go to the operator as a decision. |
| `SSO EXPIRED` | Follow the SSO command in `heartbeat-local.md`. |
| `DRIVE ... missing or wiped`, or `DISK` low | Stop launching work; PushNotification to the operator. |
| Decision only the operator can make | PushNotification, one Chinese line, ≤200 characters. Add it to `state/pending.md` (who, question, since, link); remove the line when answered. |
| Line in `state/pending.md` | Act if its answer or trigger has arrived; else leave it. Do not resend it. Every line carries `follow-up YYYY-MM-DD`. |
| `DRIFT CHECKPOINT` or `DRIFT UNATTENDED <DEF>` | Act on the line; do not re-plan. Dispatch the next proof to a worker if the row's done-when and next proof make the task clear; else ask the accountable human once for an owner or a deferral, and add a pending.md line that names the DEF id and a `follow-up` date. Never edit commitments.md or the Linear issue, move a checkpoint, or make a goal to cover work already done. The accountable human moves the checkpoint in Linear. |
| `DRIFT NONE committed` | No Linear issue carries the committed label. Say so once in the report; dispatch only `--ops` work until a human labels a goal. Do not label one yourself. |
| `DRIFT INCOMPLETE <DEF>` | The Linear issue lacks a `Done when:`, `Next proof:` or `Checkpoint:` line. Ask the accountable human once to fill it in, with a pending.md line and a `follow-up` date. Do not fill it in yourself. |
| `DRIFT DISPATCH ops` or `uncommitted` | Ops: nothing, unless ops dispatches crowd out a flagged commitment; then say so in the report. Uncommitted: no more dispatches to that goal; ask the operator whether it gets the committed label in Linear. |
| `DRIFT PENDING overdue` or `no follow-up` | Follow up once with the person named, then set a new `follow-up` date; a line with none gets one. |
| `DRIFT UNKNOWN: <input>` | Not an all clear. Restore the input (a missing file, gh auth); report it if it repeats. `commitments cache stale` or `linear sync failed`: the Sync step is failing; fix the Linear connection, never the file. |
| SESSION `drift-audit-*` | `drift-audit.sh` judges and sends that report. Append the handled line; do nothing else. |

## Launching and resuming workers

Every dispatch names `--goal` or `--ops`. `session.sh launch` and a `resume` that gives new work take `--goal DEF-n --expect "<concrete artifact or result>"`, where DEF-n is a row in `state/commitments.md` (the cache of the committed Linear issues), or `--ops "<reason>"` for routine work in the ops allowance (no delivery credit). A resume of the same work says `--continue`. A goal that is not a row is refused: do not invent or widen a goal to pass the gate; ask the operator. `--expect` names an inspectable result ("a test that restarts the planner and reads the plan back"), not an activity ("improve the planner").

`session.sh launch <profile> <name> <prompt-file> (--goal DEF-n --expect "<result>" | --ops "<reason>") [--worktree <WORK_ROOT>/worktrees/<slug> --repo <checkout> --base origin/<base> [--branch <branch>]] [--write <dir>]... [--client-data] [--personal-ok]`, `resume <name> <prompt-file> (--continue | --goal ... --expect ... | --ops ...) [--write <dir>]... [--personal-ok]`, `recover [--go] [<name>...]`, `status`, `log <name>`. Use a team profile; a personal org is refused unless `--personal-ok`, and never allowed with `--client-data`. Every worker prompt starts with a mattpocock skill and tells the worker to load the `worker` skill of this plugin. Every launch and resume loads the plugin unless `AGENT_OPS_PLUGIN=0`; a `PLUGIN NOT LOADED` line means a worker runs without hooks: stop and look before it does more. The worker runs with cwd = its worktree (the primary checkout when no `--worktree` is given). Leave out `--worktree` only for read-only work (reviews, research); any work that commits gets `--worktree --repo --base`; session.sh creates a missing worktree from `--repo` and `--base`, so never ask a worker to create one. No Bash sandbox by default. Only with `WORKER_SANDBOX=1` in the config does the worker run in the Bash sandbox, and then `--worktree` is required: its Bash can write only that worktree, the Daytona lane logs, temp, and each `--write` dir. Give `--write` for a report dir (`/tmp/<ROUND>`), a venv outside the worktree, or any data dir the task writes; with the sandbox off it is ignored, with a note in the log. `--no-sandbox` only with a reason in the prompt.

## Goal drift

`check.sh` carries the lines of `drift-check.sh` (no model): committed goals past their checkpoint, committed goals with no live executor and no human next action, committed goals whose Linear issue lacks a block line, ops or uncommitted dispatches since the last check, overdue pending items, and `UNKNOWN` inputs. Print them, act on them by the table, do not re-plan. A separate fresh session audits the day once per working day (`drift-audit.sh`, from launchd) and sends at most 3 decisions to the operator; it recommends only. The coordinator does not write its own daily narrative.

## Hard rules

- Never type a password or an MFA code. Never print, copy or commit a secret.
- Slack replies: send directly, short.
- Real client data stays in the places `heartbeat-local.md` names; never in repos, PRs, trackers or artifacts.
