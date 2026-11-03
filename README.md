# agent-ops

One operator's coordinator/worker workflow for Claude Code, as a local plugin: a router session, one headless worker per ticket, a structured worker report, guard hooks, a health check from outside the router, and a recovery note after a restart. Scripts, hooks, skills and subagents only. No SQLite, domain model, web panel, MCP server or marketplace. Workers run in the Claude Code Bash sandbox, passed per launch with `--settings` (a plugin cannot turn it on).

## Division of labour

Taken from [`deepseek-ai/dsh-superagent-prototype`](https://github.com/deepseek-ai/dsh-superagent-prototype) (MIT). The idea only: no code is copied.

| Role | Here | Does |
|---|---|---|
| Router | a coordinator session with `skills/heartbeat` | Evaluates events, creates work, replies, reviews through agents, merges. Never writes code. Takes as little human attention as possible |
| Executor | one `claude -p` per ticket, from `bin/session.sh`, with `skills/worker` | Does the work in its own directory. Ends with `STATUS: ready\|waiting\|blocked\|failed` |
| Reviewers | `agents/pr-reviewer`, `delta-reviewer`, `experiment-reviewer` | Round 1 full; round 2 on: delta and must-fix only; experiments: recompute from raw |
| Health check | `scripts/watchdog.sh` under launchd, no Claude | Alerts when the heartbeat is over 90 minutes old |
| Recovery | `session.sh recover` | Lists runs with no clean end; `--go` resumes them with a note to check the worktree, git log and PR before it repeats an outside action |
| Handover | `skills/handoff`, heartbeat rule | A new coordinator ticks once, in full, before the old one stops |

`bin/check.sh` is the read-only probe. `bin/merge-when-green.sh` merges only the reviewed head, and says `merged` only after GitHub does.

## Install

State stays outside the plugin, in `~/.claude/agent-templates` (or `$AGENT_OPS_HOME`): `state/`, `prompts/`, `worker-rules.md`, `heartbeat-local.md` (people and routes), and `config` (machine values).

1. Copy `config.example` to `$AGENT_OPS_HOME/config` and fill it in. Guard paths must be double-quoted literal absolute paths, each key once; anything else fails the hook on purpose.
2. Create `LOGS_DIR`. A launch refuses if it is missing, so a wiped drive stays visible.
3. Worker: `bin/session.sh launch <team profile> <name> <prompt-file> --worktree <dir> --repo <checkout> --base origin/<base>`. Launch, resume, recover and a queued resume all pass `--plugin-dir <this dir>` and `AGENT_OPS_ROLE=worker`; only `AGENT_OPS_PLUGIN=0` turns that off. Registry column 9 records what the last launch did. The run header in the log names the plugin revision and CLI version, and the SessionStart hook adds a `plugin loaded` line (hooks run outside the Bash sandbox, so the log dir needs no `--write`); `status` and `check.sh` flag a plugin run without that line (`PLUGIN NOT LOADED`). The first plugin resume of an older row tells the worker to load `agent-ops:worker`. Tell a new worker to load it too.
4. Coordinator: `AGENT_OPS_ROLE=coordinator claude --plugin-dir <this dir>`, then `/agent-ops:heartbeat`.
5. Watchdog: fill in `scripts/*.plist.template`, copy it to `~/Library/LaunchAgents/`, `launchctl load`. It needs `AGENT_OPS_ALERT_CMD <message>`, a command that works with no Claude session. With none it only writes `state/watchdog.alert`, and nobody is told.

Needs Claude Code 2.1.295 or later (`onFailure`), `python3`, `jq`, `gh`, macOS.

`session.sh` refuses a personal org on every launch and resume unless `--personal-ok`. `--client-data` marks the session, and a marked session never leaves the team org, with or without that flag. One queued resume per session; a second is refused. Each worker and waiter has its own process group.

## What each hook stops, and what it does not

| Hook | Failure behind it | Does not stop |
|---|---|---|
| `deny_kill` (PreToolUse Bash): `pkill -f`, `killall`, `pkill` with no `-P` | `pkill -f "make test"` killed another session's tests, twice | `pgrep -f x \| xargs kill`; kills inside a script |
| `deny_merge_git`: `gh pr merge`, `gh api .../merge`; git writes in `PRIMARY_CHECKOUT` | A hand-written loop could merge an unreviewed head; `git checkout ref -- .` overwrote files. `merge-when-green.sh` passes because a hook sees only its command line, not its inner `gh` | A merge through curl; git inside a script. Reads, `fetch`, `worktree add` and `worktree remove` of an outside path with no `--force` stay allowed |
| `deny_wide_rm`: `rm -r` on `/`, `~`, `WORK_ROOT`, a direct child, or a parent of those | A recursive delete lost most of a work drive | **A delete inside Python: that loss was `shutil.rmtree` under unittest, with no `rm` in the text.** Rules and a sandbox lane remain for that. Also an unset variable (`rm -rf "$X"/`) and `find -delete` |
| `stop_status` (Stop, role worker): asks once for `STATUS:`, `QUESTION:` if blocked, `EVIDENCE:` | Workers stopped to ask for confirmation in headless sessions; reports claimed unchecked things | A false report. It checks form, not truth |
| `session_start` (SessionStart, startup and resume): a `plugin loaded` line in a session.sh log; for role coordinator, prints newest handoff, locks, `session.sh status` | A new coordinator acted before it read them; a worker ran with no hooks and nobody saw | A coordinator launched without the role |

Hooks read command text, so a deny is a guard against a slip, not a security boundary. They do not parse heredocs or quotes: text that holds a guarded command is denied too, and every deny message says to write such text with the Write tool and pass the file. A worker can still write a script that does any of this. PreToolUse hooks use `onFailure: "block"`: a broken hook, a bad config or a missing `python3` blocks every Bash call, loudly. `onFailure` has no effect on Stop (Claude Code docs), and SessionStart uses `continue`, so a broken one leaves only a hook error event and the session goes on. In a worker's log, the symptom of a broken Stop hook is `done` with no STATUS. Hooks run by shebang, not `python3 <file>`, because Python exits 2 on a missing file, and exit 2 means "block" to a hook.

## Test

`tests/run.sh` is offline: hook tables, `session.sh` on a temp registry with a stub CLI, `check.sh` and `merge-when-green.sh` with a stub `gh`, watchdog, and `tests/regress.sh`, one block per bug found in review.

`SMOKE_SCRATCH=<dir> [SMOKE_CLAUDE=<cli>] tests/smoke.sh` runs one throwaway `claude -p --plugin-dir` per hook under `--permission-mode bypassPermissions`, in that directory, with a fake state dir. It needs a login. Each smoke command is guarded with `false &&` or a target that does not exist.

## Prior art and history

[`docs/prior-art.md`](docs/prior-art.md): the public projects read from their code, what was taken as an idea and from whom (the process group and the run-outcome states from gastown, pmtui and claude-squad), what was not. No code is copied. [`docs/iterations.md`](docs/iterations.md): every review suggestion, accepted or rejected, and why.

No licence file yet: all rights reserved until the owner adds one.
