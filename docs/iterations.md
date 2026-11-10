# Iterations

Each suggestion, checked against the code and the official Claude Code docs. Applied only if it prevents a named failure or fixes a reproduced bug, test first, one commit per change. GPT Pro answers are GPT Pro output; they were checked, not trusted.

The named failures:

- **F1** A test deleted most of a work drive, through Python, in a bypass-mode worker.
- **F2** Queued resumes lived on that drive and failed silently.
- **F3** A heartbeat was stopped for a handover nobody took: 4 hours with none.
- **F4** An app restart killed all workers; recovery was manual.
- **F5** A profile silently became a personal account.
- **F6** A hand-written merge loop could merge an unreviewed head.
- **F7** Review loops: fresh reviewers kept finding new things.
- **F8** Coordinator context grew huge; workers stopped to ask with nobody there; `pkill -f` hit another session's tests.
- **F9** Reports claimed things nobody had verified.

## Round 1 (GPT Pro output, `gpt-round-1.md`)

| # | Suggestion | Decision | Why |
|---|---|---|---|
| 1 | `--client-data` is lost on resume | **Accepted** `0c5fd43` | Reproduced. F5. Marker file per sid |
| 2 | Standing merge authorization skips the human reviewer; make the helper require an approval at the head | **Rejected** | An explicit operator ruling for one repo, not a bug. Elsewhere the GitHub ruleset requires the approval, and the helper sees it as `mergeStateStatus` |
| 3 | A second queued resume can overlap or get lost | **Accepted, smaller** `7875945` | Reproduced. F2, F8. One queued resume per session, refused loudly. The per-session lock is rejected: one coordinator, no failure from a race |
| 4 | `cd` in a child shell moves the guard for the parent | **Accepted, wider** `964d58a` | Reproduced. Plain `(cd x); ...` has the same bug, so subshells are covered too |
| 5 | Two prompts in one second overwrite each other | **Accepted** `e005654` | Reproduced. F2 |
| 6 | `status` recreates the logs dir that `check.sh` watches | **Accepted** `6e92051` | Reproduced. F1, F2. Launch now refuses a missing logs dir |
| 7 | An older STATUS hides a later interrupted turn; move workers to `--output-format json` | **Accepted, other fix** `1fe1f77` | Reproduced with a log fixture. F4. A `--- session.sh end <exit>` line after each run does it in 2 lines, with no change to output and logs |
| 8 | A failed launch returns 0 and writes an empty row | **Accepted** `db1ffea` | Reproduced. F9 |
| 9 | Bash and Python read `$HOME` in the config differently, which turns a guard off | **Accepted** `f6afe0f` | Reproduced. Literal absolute paths only; anything else fails the hook, and `onFailure` blocks |
| 10 | `merge-when-green.sh` prints success with no confirmed merge | **Accepted** `b7a9be3` | Reproduced. F9, and F6 when a merge queue is on |
| – | Move helpers to a sourced file to hold the size limit | **Accepted** `e033b60` | `session.sh` is 129 lines, `session-lib.sh` 47 |
| – | Verify the delete implementation in the app | **Out of scope** | App code; already under review there |

## Other sources

| Source | Finding | Decision |
|---|---|---|
| Dry run of the reviewers on a real merged PR | Two reviewers ran code under review that holds `shutil.rmtree`; one passed a real data root to it. The data did not change | **Accepted** `7efbad9`: grep for delete code first. A rerun greps first, and still ran the delete in a temp dir: this is a rule, not a guard |
| claude-squad, gastown, pmtui: workers outlive the parent | F4. `nohup` shares the launcher's process group | **Accepted** `09cef6c`: `setsid` per worker. Not tested against a real app restart |
| gastown: cap on re-dispatch | No failure yet from a resume loop; recover runs on the first tick only | **Rejected for now** |
| ameise, BVarvill: narrow tool lists for reviewers | No named failure. Keeping Bash leaves shell writes open | **Rejected** |

## Round 2 (GPT Pro output, `gpt-round-2.md`)

| # | Suggestion | Decision | Why |
|---|---|---|---|
| 1 | The registered pid became a wrapper; `kill <pid>` leaves the CLI alive and a resume starts a second one | **Accepted** `3232645` | Reproduced, a bug in round 1's end marker. F8. The wrapper forwards TERM to its own group. Checked with the real CLI: the group is gone after TERM, and `recover` lists the row |
| 2 | The waiter can publish its running row before the launcher publishes `waiting` | **Accepted** `1c85e7a` | Reproduced with a slow `date` stub. F2. New evidence against round 1's "one coordinator, no race". Still no lock |
| 3 | A dead queued resume shows the old STATUS, and an old log hides it | **Accepted** `67b0bcb` | Reproduced. F2, F4, F9 |
| 4 | The 64 KiB tail hides the run marker, so the end-marker rule stops working | **Accepted** `77ef1f5` | Reproduced. F4, F9 |
| 5 | A resume that ends with the same STATUS is `NO CHANGE` | **Accepted, smaller** `d5f621a` | Reproduced. F8, F9. Adds the pid only to rows with a STATUS, so older rows keep their baseline line |
| 6 | An explicit `--after` bypasses the live worker | **Accepted** `81cc8e1` | Reproduced. F2, F8 |
| 7 | Duplicate keys or a comment in the config: bash and Python read different paths | **Accepted** `80ffbd9` | Reproduced. Guards went to the wrong path |
| 8 | A trailing slash on `WORK_ROOT` removes direct-child protection | **Accepted** `d02bfd3` | Reproduced. F1 |
| 9 | `cd -- PATH` moves the guard to a wrong directory | **Accepted** `a6c2d01` | Reproduced |
| 10 | A failed `gh` reads as "all PRs gone", then `NO CHANGE`, and the watchdog stays quiet | **Accepted** `905e256` | Reproduced. F3. Exits 1 and keeps the last snapshot |

## Round 3 (GPT Pro output, `gpt-round-3.md`), the last

| # | Suggestion | Decision | Why |
|---|---|---|---|
| 1 | A dead waiter hides a live worker; a resume starts a second CLI on the same session. Keep the predecessor pid in a sidecar file | **Accepted, smaller** `5d84a1e` | Reproduced. F2, F4, F8. The registry already holds the worker row, so no sidecar. An explicit `--after` on another session's pid is not kept after its waiter dies |
| – | From the same finding: a restart kills the waiter, since only workers had their own group | **Accepted** `312bca7` | F4 |
| 2 | A `StatusContext` has `context` and `state`, so `check.sh` shows `nullx1` and the merge helper quits on `BLOCKED` while CI is pending | **Accepted** `e48b2e4` | Reproduced with a stub. F6, F8. The repos looked at use check runs today, so this is a latent bug |
| 3 | A coordinator that dies between Probe and Act loses the change, because the snapshot has moved | **Accepted** `044d342` | Reproduced at shell level. F3, F4. One rule in the heartbeat skill. Not tested in a real coordinator |

GPT Pro's own closing line: stop after these three. Stopped at the limit of 3 rounds.

## Goal drift (GPT Pro adversarial review of the first drift design, `gpt-drift-answer.md`)

Failure behind it: on 2026-11-03 the coordinator stayed busy and healthy while most worker time went to agent tooling, and the planner (B6) and reconcile (B8) had no owner and slipped. Only the CEO noticed.

| # | Suggestion | Decision | Why |
|---|---|---|---|
| 1 | Name the commitments the checker must cover | **Elsewhere** | Drafted by another session. Here: the file it fills, `state/commitments.md` |
| 2 | "Create a goal first" is no authorization: dispatch only to committed goals, with a bounded expected result; ops allowance with no credit | **Accepted** | `session.sh` gate; `--continue` for a resume of the same work, so new work cannot pass silently |
| 3 | Observe beyond the coordinator's account; UNKNOWN on a missing input | **Accepted** | The launcher records the tag; `drift-check.sh` reads the registry and gh; the audit reads GitHub and Linear directly |
| 4 | Progress is new evidence for a next proof, not activity | **Accepted, smaller** | A passed checkpoint stays flagged until the human moves it; a merged PR is listed as evidence only. No automatic evidence comparison |
| 5 | Unattended commitments, not empty owner fields; waiting does not suppress forever | **Accepted** | Live executor or a pending.md line with a follow-up that has not passed |
| 6 | One mechanical check every tick, one independent audit per working day, monitored | **Accepted** | `drift-check.sh` in `check.sh`; `drift-audit.sh` under launchd; watchdog checks `drift-audit.done` |
| 7 | Cut worker-time accounting | **Accepted (not built)** | Dispatch lines only |

Acceptance replay: `tests/fixtures/2026-11-03`, every dispatch tagged to a committed tooling goal. `drift-check.sh` flags B6 and B8 (checkpoint and unattended) and nothing else.

## Retro 2026-11-10: three drift additions

Failures behind them, all on 2026-11-10:
- The drift check printed nothing while the PR stack of a committed goal had no update and no review for five days.
- The goal's `Done when` was loosened from "merged to dev" to "waits only on review", and nothing showed it.
- 33 pending rows, most of them waiting on the operator, were each pushed once and then lost.

| # | Change | Decision | Why |
|---|---|---|---|
| 1 | `DRIFT STALLED <DEF> <repo>#<n> <days>d` | **Built** `drift-check.sh` | The PR is linked by name: its title, body or head branch names the DEF id, plus the PRs stacked on or under it (head = base), never through `main`, `master` or `DEPLOY_BRANCH`. **Not linked:** comments (reviews name follow-up ids), and the `#n` in an executor's `--expect` (it names no repo, and a worker reads PRs it does not own). **Clock:** the PR's opening, last commit, review or comment, not `updatedAt`, so label and title edits do not count. A force-push that keeps old committer dates is missed. **gh failure** (or a list cut at 300): the line of the last snapshot is kept beside the UNKNOWN, so a flake is no GONE and no second ask (review round 1) |
| 2 | `DRIFT GOALPOST <DEF> <field>: "<old>" -> "<new>"` | **Built** `commitments-render.py` | Compared as rendered against the cache that the render replaces, so the line prints once. `state/goalpost.log` keeps the trace. A row that left the cache and came back counts as new |
| 3 | `WAITING ON OPERATOR <n>:` digest | **Built** `operator-digest.sh`, called on the `DRIFT SUMMARY` tick | Matched by the first field (`OPERATOR_NAME`, then a non-letter), so `<person>→<operator>` rows, owed to the operator, are not in it. Rows with no follow-up come first |

No new guard, deny or hook.

## Size

Scripts other than tests: 529 lines before these rounds, 587 after (+11 %), and no script over 150. All lines of script: 735 to 1022 (+39 %), which is over the limit of about a third. The excess is `tests/regress.sh`, one block per reproduced bug. Keeping it: it is the proof that each fix holds, and none of it runs in a session.
