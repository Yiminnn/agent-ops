# Prior art

Read 2026-11-03. Stats and the last commit come from `gh api`; the notes come from a shallow clone of the code, not from the README alone. Nothing was run. No code was copied into this plugin: every item below is an idea, and each licence is listed in case that changes.

| Project | ★ | Last commit | Licence | What it is |
|---|---|---|---|---|
| [deepseek-ai/dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype) | 14088 | 2026-10-31 `6337fc82` | MIT | The source of the division of labour. Research prototype on DeepSeek Harness, not Claude Code |
| [pakgin/cc-superagent](https://github.com/pakgin/cc-superagent) | 0 | main 2026-10-31 `6337fc82`, branches newer | MIT | Port to the Claude Agent SDK, in progress: main is the upstream commit, the work is in branches and open issues |
| [vicfei/dsh-super-agent](https://github.com/vicfei/dsh-super-agent) | 3 | 2026-11-03 `9b316107` | MIT | Independent TypeScript version for any CLI agent: admission gate, tickets, SQLite, panel |
| [gastownhall/gastown](https://github.com/gastownhall/gastown) | 18672 | 2026-10-28 `466aa41c` | MIT | Large Go workspace manager: mayor, witness, deacon, polecats, on tmux |
| [hung-phan/pmtui](https://github.com/hung-phan/pmtui) | 5 | 2026-11-03 `b5b8c408` | MIT | Rust supervisor with one tmux terminal per project |
| [OrchestratorInc/agent-orchestrator](https://github.com/OrchestratorInc/agent-orchestrator) | 14033 | 2026-11-03 `630debf6` | Apache-2.0 | Daemon and desktop app, task to merged PR |
| [CalvinDittkrist/ameise](https://github.com/CalvinDittkrist/ameise) | 1 | 2026-10-05 `d211c12f` | MIT | Local controller, dashboard and Claude Code plugins for GitHub issues |
| [askrzypczak/claude-workflow](https://github.com/askrzypczak/claude-workflow) | 0 | 2026-11-02 `311c08d9` | MIT | Plugin plus launchd poller and a container for sessions; "personal experiment" |
| [BVarvill/orchestrator-agent-plugin](https://github.com/BVarvill/orchestrator-agent-plugin) | 0 | 2026-10-13 `582dc1f4` | MIT | Small plugin: one session merges, workers report by PR. Closest in size to this one |
| [madic-creates/td-orchestrator](https://github.com/madic-creates/td-orchestrator) | 0 | 2026-10-16 `38daf586` | MIT | Plugin with a fresh agent per issue and role; needs Herdr |
| [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | 8722 | 2026-08-20 `ce1ffb43` | **AGPL-3.0** | TUI over tmux and worktrees. Idea only; never copy its code |
| [parcadei/Continuous-Claude-v3](https://github.com/parcadei/Continuous-Claude-v3) | 3947 | 2026-01-26 `d07ff4b0` | MIT | 30 hooks, ledgers, handoffs. Stale since January |
| [Dicklesworthstone/claude_code_agent_farm](https://github.com/Dicklesworthstone/claude_code_agent_farm) | 923 | 2026-09-21 `d88ba78e` | MIT with a rider against OpenAI and Anthropic | 20+ agents in tmux. **Do not copy: the rider is not a plain MIT grant** |

Not found: an official Claude Code version of DeepSeek's prototype, or any finished third-party port. Not verified: the p95 figures for the prototype that blogs and vicfei's README quote.

## What is worth taking

**Workers survive the parent (failure 4).** gastown, pmtui and claude-squad all keep workers in tmux sessions, so a dead parent app does not end them. `session/tmux/tmux.go` in claude-squad and `internal/tmux/tmux.go` in gastown show it. Here the idea is smaller: put each worker in its own session and process group.

**A bound on recovery.** `internal/deacon/redispatch.go` in gastown caps re-dispatch at 3 with a cooldown, then escalates, because a bead can keep killing its workers. `session.sh recover --go` has no such cap yet.

**The outcome of a process that left no result is its own state.** pmtui `docs/SPEC.md`: `done`, `needs_human`, `failed`, `ended_without_result`, and the row "does nothing until a person clears it". Same idea as `done` with no STATUS in `check.sh`. pmtui's `src/job.rs` says it well: "Worker proposes, harness disposes."

**Three exit types are enough.** gastown `gt done --status COMPLETED|ESCALATED|DEFERRED` confirms that a short fixed set works. pmtui's heartbeat comment confirms the rule behind it: the worker reports its state, and the supervisor infers only one thing, "is the heartbeat fresh?".

**An approval must cover the head.** vicfei `src/merge.ts`: every merge condition is "a checkable fact about the PR, never model judgment", any miss is a recorded reason, a stale approval does not count, and the merge is pinned to the SHA. `merge-when-green.sh` already pins the SHA.

**Fail closed when the guard's tool is missing.** claude-workflow `hooks/guard-comments.sh` exits 2 when `jq` is absent, and says "it is a guardrail, not a security boundary". It also shows that a launchd job gets a minimal PATH and must set its own (`dispatch/launchd/job.sh`), which matters for the watchdog.

**Review agents cannot edit.** ameise `docs/security.md`: reviewers run with `disallowedTools: Edit, Write, NotebookEdit, Agent`. Comments, logs and file contents are labeled as data, not instructions. A reviewer here reads untrusted PR text and has more tools than it needs.

**A plugin agent's tool list is a real limit, cheap to add.** BVarvill `agents/reviewer.md` and ameise both state a narrow tool list in frontmatter.

## What is not worth taking

| Idea | Where | Why not |
|---|---|---|
| SQLite store, effect queue, panel, admission tables, observe mode | vicfei, dsh-superagent | One operator asks for all work; no failure here comes from admission. The operator's limits rule them out |
| Agent SDK service with a stream to each session | cc-superagent | A long-lived service for one Mac. Its spike is useful as evidence only: the sandbox rules held on macOS |
| Mayor, witness, deacon, polecats; beads; mail | gastown | A whole system of roles. The coordinator plus `check.sh` covers the need |
| Detecting stuck sessions by pinging and force-killing | gastown `deacon/stuck.go` | Workers are `-p` processes with a pid, and force-kills caused failure 8 |
| Text-match guard for `rm -rf /` only | gastown `tap_guard_dangerous.go` | Weaker than ours: it splits on spaces, needs both `r` and `f`, and matches only `/` and `/*` |
| Text-match guards for `sudo`, package installs, SQL | gastown | No failure here justifies them |
| Reading context percentage to force a handoff at 85 % | Continuous-Claude `auto-handoff-stop.py` | Depends on a status line file. Failure 8 is met by the handoff skill and a fresh coordinator |
| 30 hooks, ledgers, artifact index | Continuous-Claude | The opposite of a little harness |
| Container per session, firewall | claude-workflow | The operator ruled out a heavy sandbox |
| Auto mode, permission classifier as the guard | ameise | Workers run in bypass mode; changing that is a separate decision |
| Reviewer panel per PR, auto self-merge | ameise | One review agent and a human reviewer is the rule here |
