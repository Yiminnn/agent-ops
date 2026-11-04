# agent-ops

One operator's coordinator/worker workflow for Claude Code, as a local plugin: a router session, one headless worker per ticket, a structured worker report, one guard hook (`deny_kill`), a health check from outside the router, and a recovery note after a restart. Scripts, hooks, skills and subagents only. No SQLite, domain model, web panel, MCP server or marketplace. Workers run without the Claude Code Bash sandbox by default; `WORKER_SANDBOX=1` in the config turns it on, passed per launch with `--settings` (a plugin cannot turn it on).

## Division of labour

Taken from [`deepseek-ai/dsh-superagent-prototype`](https://github.com/deepseek-ai/dsh-superagent-prototype) (MIT). The idea only: no code is copied.

| Role | Here | Does |
|---|---|---|
| Router | a coordinator session with `skills/heartbeat` | Evaluates events, creates work, replies, reviews through agents, merges. Never writes code. Takes as little human attention as possible |
| Executor | one `claude -p` per ticket, from `bin/session.sh`, with `skills/worker` | Does the work in its own directory. Ends with `STATUS: ready\|waiting\|blocked\|failed` |
| Reviewers | `agents/pr-reviewer`, `delta-reviewer`, `experiment-reviewer` | Round 1 full; round 2 on: delta and must-fix only; experiments: recompute from raw |
| Health check | `scripts/watchdog.sh` under launchd, no Claude | Alerts when the last finished tick (`state/heartbeat.done`) is over 90 minutes old, or failed |
| Recovery | `session.sh recover` | Lists runs with no clean end; `--go` resumes them with a note to check the worktree, git log and PR before it repeats an outside action |
| Handover | `skills/handoff`, heartbeat rule | A new coordinator ticks once, in full, before the old one stops |
| Dispatch gate | `session.sh launch`/`resume` | Every dispatch names `--goal DEF-n --expect "<result>"` (a row in `state/commitments.md`) or `--ops "<reason>"`; a resume of the same work says `--continue`. Registry columns 12-13 |
| Drift check | `bin/drift-check.sh`, no model, inside `check.sh` | Passed checkpoints, unattended commitments, ops or uncommitted dispatches, overdue pending items; `UNKNOWN` on a missing input, never an all clear |
| Drift audit | `bin/drift-audit.sh` under launchd, one fresh read-only worker per working day | At most 3 decisions with evidence and a coverage line, sent only when new; recommends, never acts. The watchdog alerts when it is late or failed |

`bin/check.sh` is the read-only probe. `bin/merge-when-green.sh` merges only the reviewed head, and says `merged` only after GitHub does.

## Install

State stays outside the plugin, in `~/.claude/agent-templates` (or `$AGENT_OPS_HOME`): `state/`, `prompts/`, `worker-rules.md`, `heartbeat-local.md` (people and routes), and `config` (machine values).

1. Copy `config.example` to `$AGENT_OPS_HOME/config` and fill it in. Paths must be double-quoted literal absolute paths, each key once.
2. Create `LOGS_DIR`. A launch refuses if it is missing, so a wiped drive stays visible.
3. Worker: `bin/session.sh launch <team profile> <name> <prompt-file> [--worktree <dir> --repo <checkout> --base origin/<base>]`; with no `--worktree` it runs in the primary checkout, for read-only work only (reviews, research). Launch, resume, recover and a queued resume all pass `--plugin-dir <this dir>` and `AGENT_OPS_ROLE=worker`; only `AGENT_OPS_PLUGIN=0` turns that off. Registry column 9 records what the last launch did. The run header in the log names the plugin revision and CLI version, and the SessionStart hook adds a `plugin loaded` line (hooks run outside the Bash sandbox, so the log dir needs no `--write` even with `WORKER_SANDBOX=1`); `status` and `check.sh` flag a plugin run without that line (`PLUGIN NOT LOADED`). The first plugin resume of an older row tells the worker to load `agent-ops:worker`. Tell a new worker to load it too.
4. Coordinator: `AGENT_OPS_ROLE=coordinator claude --plugin-dir <this dir>`, then `/agent-ops:heartbeat`.
5. Watchdog: fill in `scripts/*.plist.template`, copy it to `~/Library/LaunchAgents/`, `launchctl load`. It needs `AGENT_OPS_ALERT_CMD <message>`, a command that works with no Claude session. With none it only writes `state/watchdog.alert`, and nobody is told. It judges `state/heartbeat.done`, which the heartbeat skill writes at the end of every tick (`<UTC> ok` or `<UTC> failed: <reason>`), not `heartbeat.last`, which `check.sh` touches at Probe, before the tick has done its work. It alerts once per episode when that file is older than `AGENT_OPS_WATCHDOG_MINUTES` (default 90) or its last line says `failed:`. Until the first `heartbeat.done` exists, after an upgrade, it judges `heartbeat.last` and says so in the alert. `state/heartbeat.stopped` silences it.

6. Goals: copy `templates/commitments.example.md` to `state/commitments.md` and fill it with the committed goals only; create `state/pending.md` (empty is fine). Until both exist, `drift-check.sh` prints `DRIFT UNKNOWN` and `--goal` launches are refused (`--ops` works).
7. Drift audit: set `DRIFT_AUDIT_PROFILE` in the config, fill in `scripts/com.agent-ops.drift-audit.plist.template` (weekdays, 13:30 UTC in local hours), copy and load it like the watchdog. It writes `state/drift-audit.md` and `state/drift-audit.done`; the watchdog alerts once per episode when that is missing, failed, or over 30 working hours old.

Needs Claude Code 2.1.295 or later (`onFailure`), `python3`, `jq`, `gh`, macOS.

`session.sh` refuses a personal org on every launch and resume unless `--personal-ok`. `--client-data` marks the session, and a marked session never leaves the team org, with or without that flag. One queued resume per session; a second is refused. Each worker and waiter has its own process group.

## What each hook stops, and what it does not

Only one guard remains: `deny_kill`. The text guards for merges, primary-checkout git and wide `rm` were removed (Yimin, 2026-11-04): they read command text, gave false positives on harmless commands and text, and the harness is meant to stay light. Their rules stay written rules: only the coordinator merges, and only through `merge-when-green.sh`; no git writes in `PRIMARY_CHECKOUT`; delete only what you created (`worker-rules.md`, "Delete paths").

| Hook | Failure behind it | Does not stop |
|---|---|---|
| `deny_kill` (PreToolUse Bash): `pkill -f`, `killall`, `pkill` with no `-P` | `pkill -f "make test"` killed another session's tests, twice | `pgrep -f x \| xargs kill`; kills inside a script |
| `stop_status` (Stop, role worker): asks once for `STATUS:`, `QUESTION:` if blocked, `EVIDENCE:` | Workers stopped to ask for confirmation in headless sessions; reports claimed unchecked things | A false report. It checks form, not truth |
| `session_start` (SessionStart, startup and resume): a `plugin loaded` line in a session.sh log; for role coordinator, prints newest handoff, locks, `session.sh status` | A new coordinator acted before it read them; a worker ran with no hooks and nobody saw | A coordinator launched without the role |

`deny_kill` reads command text, so a deny is a guard against a slip, not a security boundary. It does not parse heredocs or quotes: text that holds a pattern kill is denied too, and the deny message says to write such text with the Write tool and pass the file. A worker can still write a script that kills by pattern. It uses `onFailure: "block"`: a broken hook or a missing `python3` blocks every Bash call, loudly. `onFailure` has no effect on Stop (Claude Code docs), and SessionStart uses `continue`, so a broken one leaves only a hook error event and the session goes on. In a worker's log, the symptom of a broken Stop hook is `done` with no STATUS. Hooks run by shebang, not `python3 <file>`, because Python exits 2 on a missing file, and exit 2 means "block" to a hook.

## Test

`tests/run.sh` is offline: hook tables, `session.sh` on a temp registry with a stub CLI, `check.sh` and `merge-when-green.sh` with a stub `gh`, watchdog, and `tests/regress.sh`, one block per bug found in review.

`SMOKE_SCRATCH=<dir> [SMOKE_CLAUDE=<cli>] tests/smoke.sh` runs one throwaway `claude -p --plugin-dir` per hook under `--permission-mode bypassPermissions`, in that directory, with a fake state dir. It needs a login. Each smoke command is guarded with `false &&` or a target that does not exist.

## Prior art and history

[`docs/prior-art.md`](docs/prior-art.md): the public projects read from their code, what was taken as an idea and from whom (the process group and the run-outcome states from gastown, pmtui and claude-squad), what was not. No code is copied. [`docs/iterations.md`](docs/iterations.md): every review suggestion, accepted or rejected, and why.

No licence file yet: all rights reserved until the owner adds one.
