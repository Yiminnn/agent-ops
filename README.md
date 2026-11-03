# agent-ops

The coordinator/worker workflow as a local Claude Code plugin. Division of labour from `deepseek-ai/dsh-superagent-prototype`: a router that evaluates, routes and replies; one executor per ticket; a structured worker report; a health check from outside the router; a recovery note after a restart. No SQLite, domain model, web panel, MCP server, marketplace or sandbox. State stays outside the plugin, in `~/.claude/agent-templates` (`$AGENT_OPS_HOME`): `state/`, `prompts/`, `config` (machine values, see `config.example`), `heartbeat-local.md` (people and routes), `worker-rules.md`.

## What runs where

| Piece | Runs in | Does |
|---|---|---|
| `skills/heartbeat` | coordinator session | The router's loop and the handover rule |
| `skills/worker` | worker session | worker-rules plus the report contract |
| `skills/handoff` | coordinator session | Writes `state/handoff-<date>.md` |
| `agents/pr-reviewer`, `delta-reviewer`, `experiment-reviewer` | subagents of the coordinator | Round 1; round 2 on; experiment PRs |
| `bin/session.sh`, `merge-when-green.sh`, `check.sh` | any shell | On the Bash PATH while loaded. The old paths are thin wrappers to these |
| `hooks/` | every session that loaded the plugin | See below |
| `scripts/watchdog.sh` | launchd, no Claude | Alerts when `state/heartbeat.last` is over 90 minutes old |

## Turn it on

- Worker: `AGENT_OPS_PLUGIN=1 session.sh launch <team profile> <name> <prompt>`. That passes `--plugin-dir` and `AGENT_OPS_ROLE=worker`, and registry column 9 keeps it for resumes. Unset, nothing changes. Tell the worker to load the `agent-ops:worker` skill.
- Coordinator: `AGENT_OPS_ROLE=coordinator claude --plugin-dir ~/.claude/agent-templates/plugin`, then `/agent-ops:heartbeat`. Remove `~/.claude/skills/heartbeat` once no session uses it.
- Watchdog: fill in `scripts/*.plist.template`, copy it to `~/Library/LaunchAgents/`, `launchctl load`. It needs an alert command, `AGENT_OPS_ALERT_CMD <message>`, that works with no Claude session: for example a Slack webhook read from the Keychain. macOS notifications hit permission prompts. With none it only writes `state/watchdog.alert`.
- `session.sh recover` lists; `--go` resumes. Rows from before the report contract resume only by name, since they never print STATUS.

## What each hook stopped, and what it does not stop

| Hook | Failure behind it | Does not stop |
|---|---|---|
| `deny_kill` (PreToolUse Bash): `pkill -f`, `killall`, `pkill` with no `-P` | `pkill -f "make test"` killed another session's tests, twice | `pgrep -f x \| xargs kill`; kills inside a script |
| `deny_merge_git`: `gh pr merge`, `gh api .../merge`; git writes in `PRIMARY_CHECKOUT` | A hand-written loop could merge an unreviewed head; `git checkout ref -- .` overwrote files. `merge-when-green.sh` passes because the hook sees only its command line, not its inner `gh` | A merge through curl; git inside a script. Reads, `fetch`, `worktree add` and `worktree remove` of an outside path with no `--force` stay allowed |
| `deny_wide_rm`: `rm -r` on `/`, `~`, `WORK_ROOT`, a direct child, or a parent of those | The 2026-11-02 work drive loss | **A delete inside Python: that wipe was `shutil.rmtree` under unittest, with no `rm` in the text.** The "Delete paths" rule and Daytona remain for that. Also an unset variable (`rm -rf "$X"/`) and `find -delete` |
| `stop_status` (Stop, role worker): asks once for `STATUS:`, `QUESTION:` if blocked, `EVIDENCE:` | Workers stopped to ask for confirmation in headless sessions; reports claimed unchecked things | A false report. It checks form, not truth |
| `session_start` (SessionStart, role coordinator): prints newest handoff, locks, `session.sh status` | A new coordinator acted before it read them | A coordinator launched without the role |

Hooks read command text, so a deny is a guard against a slip, not a security boundary. A worker can still write a script that does any of this. PreToolUse hooks use `onFailure: "block"`: a broken hook blocks every Bash call, loudly. `onFailure` has no effect on Stop (Claude Code docs), and SessionStart uses `continue`, so a broken one leaves only a hook error event and the session goes on. In a worker's text log the symptom of a broken Stop hook is `done` with no STATUS. Hooks run by shebang, not `python3 <file>`, because Python exits 2 on a missing file, and exit 2 means "block" to a hook.

## Test

`tests/run.sh` is offline: hook tables, `session.sh` on a temp registry with a stub CLI, `check.sh` with stub `gh`/`aws`, watchdog. `SMOKE_SCRATCH=<dir> tests/smoke.sh` runs one throwaway `claude -p --plugin-dir` per hook, under `--permission-mode bypassPermissions`, in that scratch directory, with a fake state dir. Each smoke command is guarded with `false &&` or a target that does not exist.
