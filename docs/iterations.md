# Iterations

Each suggestion, checked against the code and the official Claude Code docs. Applied only if it prevents a named failure (F1–F9 in the README's failure list) or fixes a reproduced bug, test first, one commit per change. GPT Pro answers are GPT Pro output; they were checked, not trusted.

## Round 1 (GPT Pro output, `gpt-round-1.md`)

| # | Suggestion | Decision | Why |
|---|---|---|---|
| 1 | `--client-data` is lost on resume | **Accepted** `d6c9de9` | Reproduced. F5. Marker file per sid |
| 2 | Standing merge authorization skips the human reviewer; make the helper require an approval at the head | **Rejected** | An explicit operator ruling for one repo, not a bug. Elsewhere the GitHub ruleset requires the approval, and the helper sees it as `mergeStateStatus` |
| 3 | A second queued resume can overlap or get lost | **Accepted, smaller** `2538b9f` | Reproduced. F2, F8. One queued resume per session, refused loudly. The per-session lock is rejected: one coordinator, no failure from a race |
| 4 | `cd` in a child shell moves the guard for the parent | **Accepted, wider** `e1a7e8e` | Reproduced. Plain `(cd x); ...` has the same bug, so subshells are covered too |
| 5 | Two prompts in one second overwrite each other | **Accepted** `f76b76e` | Reproduced. F2 |
| 6 | `status` recreates the logs dir that `check.sh` watches | **Accepted** `7ff4797` | Reproduced. F1, F2. Launch now refuses a missing logs dir |
| 7 | An older STATUS hides a later interrupted turn; move workers to `--output-format json` | **Accepted, other fix** `b324477` | Reproduced with a log fixture. F4. A `--- session.sh end <exit>` line after each run does it in 2 lines, with no change to output and logs |
| 8 | A failed launch returns 0 and writes an empty row | **Accepted** `6dedfe8` | Reproduced. F9 |
| 9 | Bash and Python read `$HOME` in the config differently, which turns a guard off | **Accepted** `4bcb8ae` | Reproduced. Literal absolute paths only; anything else fails the hook, and `onFailure` blocks |
| 10 | `merge-when-green.sh` prints success with no confirmed merge | **Accepted** `e432277` | Reproduced. F9, and F6 when a merge queue is on |
| – | Move helpers to a sourced file to hold the size limit | **Accepted** `59bdbac` | `session.sh` is 129 lines, `session-lib.sh` 47 |
| – | Verify the delete implementation in the app | **Out of scope** | App code; already under review there |

## Other sources

| Source | Finding | Decision |
|---|---|---|
| Dry run of the reviewers on a real merged PR | Two reviewers ran code under review that holds `shutil.rmtree`; one passed a real data root to it. The data did not change | **Accepted** `6674315`: grep for delete code first. A rerun greps first, and still ran the delete in a temp dir: this is a rule, not a guard |
| claude-squad, gastown, pmtui: workers outlive the parent | F4. `nohup` shares the launcher's process group | **Accepted** `6f47d89`: `setsid` per worker. Not tested against a real app restart |
| gastown: cap on re-dispatch | No failure yet from a resume loop; recover runs on the first tick only | **Rejected for now** |
| ameise, BVarvill: narrow tool lists for reviewers | No named failure. Keeping Bash leaves shell writes open | **Rejected** |
