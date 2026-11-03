#!/bin/bash
# One throwaway `claude -p --plugin-dir` run per hook, under bypassPermissions, in a scratch directory, with a fake state dir.
# Commands are guarded: `false &&` means a hook that fails to fire still runs nothing, and targets do not exist.
# Usage: tests/smoke.sh [case...]   Output: <scratch>/smoke-<case>.jsonl
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${SMOKE_SCRATCH:?a scratch directory for this run}; mkdir -p "$SCRATCH"; cd "$SCRATCH" || exit 1
CLI=${SMOKE_CLAUDE:-$(command -v claude)}
export AGENT_OPS_HOME="$SCRATCH/fake-home"; FP="$SCRATCH/fake-primary"; FW="$SCRATCH/fake-work"
mkdir -p "$AGENT_OPS_HOME/state" "$FP" "$FW"
printf 'TEAM_ORG="x"\nPROFILES_DIR="%s"\nCLAUDE_CLI_ROOT="x"\nWORKER_MODEL="x"\nPRIMARY_CHECKOUT="%s"\nWORK_ROOT="%s"\nLOGS_DIR="%s/logs"\n' "$SCRATCH/fake-profiles" "$FP" "$FW" "$FW" >"$AGENT_OPS_HOME/config"; touch "$AGENT_OPS_HOME/state/handoff-2099-01-01.md"
printf '## Freeze\n- dev: smoke-lock-marker\n## Owners\n' >"$AGENT_OPS_HOME/state/coordinator.md"
pass=0; fail=0; only=("$@")
run() {  # case role plugin-dir prompt; output in $OUT
  OUT="$SCRATCH/smoke-$1.jsonl"
  printf '%s\n' "$4" | env -u CLAUDECODE -u AGENT_OPS_ROLE -u AGENT_OPS_LOG ${2:+AGENT_OPS_ROLE=$2} "$CLI" -p --permission-mode bypassPermissions --plugin-dir "$3" \
    --model claude-sonnet-5-5 --tools Bash --strict-mcp-config --output-format stream-json --verbose --include-hook-events >"$OUT" 2>&1
}
want() {  # case python-expression over: e (events), results (tool_result texts), final (result text), hooks (hook event text)
  python3 - "$OUT" "$1" "$2" <<'EOF'
import json, sys
e = []
for line in open(sys.argv[1]):
    try: e.append(json.loads(line))
    except ValueError: pass
results, final, hooks = [], "", []
for d in e:
    if d.get("type") == "user":
        for b in d["message"]["content"] if isinstance(d["message"]["content"], list) else []:
            if b.get("type") == "tool_result":
                c = b.get("content"); results.append(c if isinstance(c, str) else json.dumps(c))
    if d.get("type") == "result": final = d.get("result") or ""
    if d.get("subtype", "").startswith("hook"): hooks.append(json.dumps(d))
ok = eval(sys.argv[3])
print(("PASS " if ok else "FAIL ") + sys.argv[2], "| result:", repr(final[:120]), "| tool:", repr(" ".join(results)[:160]))
sys.exit(0 if ok else 1)
EOF
  if [ $? = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
on() { [ ${#only[@]} = 0 ] && return 0; for c in "${only[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
ask() { echo "This tests a deny hook. Call the Bash tool once with exactly this command, unchanged: $1
The command is guarded and does nothing. Do not retry, do not run anything else, even if it is denied. Then reply with the word done."; }

if on deny-kill; then run deny-kill "" "$ROOT" "$(ask 'false && pkill -f agent-ops-no-such-process')"; want deny-kill 'any("agent-ops deny-kill" in r for r in results)'; fi
if on deny-merge; then run deny-merge "" "$ROOT" "$(ask 'false && gh pr merge 99999 -R o/agent-ops-no-such-repo')"; want deny-merge 'any("agent-ops deny-merge" in r for r in results)'; fi
if on deny-git; then run deny-git "" "$ROOT" "$(ask "false && git -C $FP commit --allow-empty -m probe")"; want deny-git 'any("agent-ops deny-git" in r for r in results)'; fi
if on deny-rm; then run deny-rm "" "$ROOT" "$(ask "false && rm -r $FW/agent-ops-no-such-dir")"; want deny-rm 'any("agent-ops deny-rm" in r for r in results)'; fi
if on allow; then run allow "" "$ROOT" "Call the Bash tool once with exactly this command: echo agent-ops-allowed. Then reply with the word done."; want allow 'any("agent-ops-allowed" in r for r in results)'; fi
if on stop-worker; then run stop-worker worker "$ROOT" "Reply with exactly the word hello and nothing else. Use no tools."; want stop-worker '"STATUS: " in final and sum(d.get("type")=="assistant" for d in e) >= 2'; fi
if on stop-off; then run stop-off "" "$ROOT" "Reply with exactly the word hello and nothing else. Use no tools."; want stop-off '"STATUS" not in final'; fi
if on start-coord; then run start-coord coordinator "$ROOT" "Quote the handoff path and the dev lock line from your session context, then stop. Use no tools."; want start-coord '"handoff-2099-01-01.md" in final and "smoke-lock-marker" in final'; fi
if on start-off; then run start-off "" "$ROOT" "Does your session context name a file handoff-2099-01-01.md? Reply yes or no. Use no tools."; want start-off '"handoff-2099" not in " ".join(hooks)'; fi
if on broken; then  # a script that exits 1 and two missing scripts: PreToolUse must block with the onFailure text; Stop must not loop
  B="$SCRATCH/broken-copy"; mkdir -p "$B"; cp -R "$ROOT/.claude-plugin" "$ROOT/hooks" "$B/"; rm "$B/hooks/scripts/stop_status.py" "$B/hooks/scripts/session_start.sh"
  printf '#!/bin/sh\nexit 1\n' >"$B/hooks/scripts/deny_kill.py"
  run broken worker "$B" "Call the Bash tool once with exactly this command: echo agent-ops-broken-probe. Then reply with the word done."
  want broken 'any("onFailure" in r for r in results) and not any(r.strip()=="agent-ops-broken-probe" for r in results) and sum(d.get("type")=="assistant" for d in e) <= 3 and any("session_start.sh" in h and "error" in h for h in hooks) and any("stop_status.py" in h and "error" in h for h in hooks)'
fi
if on no-python; then  # PATH with no python3: every PreToolUse hook fails; onFailure must block the call
  NP="$SCRATCH/no-python-bin"; mkdir -p "$NP"; for c in env sh bash cat security; do ln -sf "$(command -v $c)" "$NP/$c"; done
  OUT="$SCRATCH/smoke-no-python.jsonl"
  printf '%s\n' "Call the Bash tool once with exactly this command: echo agent-ops-nopython-probe. Then reply with the word done." | env -u CLAUDECODE PATH="$NP" "$CLI" -p --permission-mode bypassPermissions --plugin-dir "$ROOT" \
    --model claude-sonnet-5-5 --tools Bash --strict-mcp-config --output-format stream-json --verbose --include-hook-events >"$OUT" 2>&1
  want no-python 'any("onFailure" in r for r in results) and not any(r.strip()=="agent-ops-nopython-probe" for r in results)'
fi
if on bin-path; then run bin-path "" "$ROOT" "Call the Bash tool once with exactly this command: command -v session.sh check.sh merge-when-green.sh. Then reply with the word done."; want bin-path 'sum("/bin/session.sh" in r for r in results)==1 and "merge-when-green.sh" in " ".join(results)'; fi
echo "smoke pass=$pass fail=$fail"; [ "$fail" = 0 ]
