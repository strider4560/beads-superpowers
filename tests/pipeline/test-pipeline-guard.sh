#!/usr/bin/env bash
# test-pipeline-guard.sh — contract for hooks/pipeline-guard (PreToolUse).
# Exit 2 + a one-line stderr reason blocks the tool call; exit 0 allows it.
# Every case runs the guard inside a mktemp working dir with HOME pointed at a
# mktemp home, so neither the real bundle root nor this repo's own pipeline
# state directory is ever read.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/hooks/pipeline-guard"
fixture="$root/tests/pipeline/fixtures/tier-map.json"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- sandbox builders -------------------------------------------------------

make_home() { # <name> -> path to an empty HOME (no bundle root)
  local home="$TMP/home-$1"; mkdir -p "$home"; printf '%s' "$home"
}
add_bundle() { # <home> <version> — bundle root with a package.json
  mkdir -p "$1/.agents/great_cto"
  printf '{"version":"%s"}\n' "$2" > "$1/.agents/great_cto/package.json"
}
add_tier_map() { # <home> — the fixture tier-map inside that bundle root
  mkdir -p "$1/.agents/great_cto/shared"
  cp -f "$fixture" "$1/.agents/great_cto/shared/tier-map.json"
}
make_cwd() { # <name> [model] -> path to a working dir (session state file when a model is given)
  local cwd="$TMP/cwd-$1"; mkdir -p "$cwd"
  if [ -n "${2:-}" ]; then
    mkdir -p "$cwd/.internal/pipeline"
    printf '{"model_id":"%s","effort":null,"source":"hook","timestamp":"t"}\n' \
      "$2" > "$cwd/.internal/pipeline/session.json"
  fi
  printf '%s' "$cwd"
}

# --- runner + assertion -----------------------------------------------------

run() { # <cwd> <home> <stdin-payload> — sets rc, err (stderr)
  # PATH_OVERRIDE, when set, replaces PATH for the guard only (jq-absence cases).
  local cwd="$1" home="$2" payload="$3"
  ( cd "$cwd" && HOME="$home" PATH="${PATH_OVERRIDE:-$PATH}" "$BASH" "$guard" ) \
    <<<"$payload" >/dev/null 2>"$TMP/stderr"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

check() { # <name> <want-exit> [<ere-pattern on stderr>] — one PASS/FAIL line
  local name="$1" want="$2" pattern="${3:-}" detail=""
  if [ "$rc" -ne "$want" ]; then
    detail="exit $rc want $want (stderr: $err)"
  elif [ -n "$pattern" ]; then
    printf '%s' "$err" | grep -qE -- "$pattern" || detail="no /$pattern/ on stderr: $err"
  fi
  if [ -z "$detail" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: $detail"
    fails=$((fails+1))
  fi
}

# --- payloads ---------------------------------------------------------------

p_epic='{"tool_name":"Bash","tool_input":{"command":"bd create -t epic \"X\""}}'
p_import='{"tool_name":"Bash","tool_input":{"command":"bd import issues.jsonl"}}'
p_task='{"tool_name":"Bash","tool_input":{"command":"bd create -t task \"X\""}}'
p_src='{"tool_name":"Write","tool_input":{"file_path":"src/x.js","content":"x"}}'
p_src_edit='{"tool_name":"Edit","tool_input":{"file_path":"src/x.js","old_string":"a","new_string":"b"}}'
p_internal='{"tool_name":"Write","tool_input":{"file_path":".internal/specs/a.md","content":"x"}}'
p_mex='{"tool_name":"Write","tool_input":{"file_path":".mex/lessons.md","content":"x"}}'
p_docs='{"tool_name":"Write","tool_input":{"file_path":"docs/en/x.md","content":"x"}}'
p_assert='{"tool_name":"Bash","tool_input":{"command":"bash scripts/pipeline/tier-gate.sh --assert planning"}}'
p_assert_pty='{"tool_name":"Bash","tool_input":{"command":"script -qec '"'"'bash scripts/pipeline/tier-gate.sh --assert planning'"'"' /dev/null"}}'
p_state_assert='{"tool_name":"Write","tool_input":{"file_path":".internal/pipeline/tier-assert","content":"review"}}'
p_state_session='{"tool_name":"Write","tool_input":{"file_path":".internal/pipeline/session.json","content":"{}"}}'
p_state_bash='{"tool_name":"Bash","tool_input":{"command":"printf '"'"'review\\n'"'"' > .internal/pipeline/tier-assert"}}'
p_malformed='{"tool_name":"Bash","tool_input":'

# --- fixtures ---------------------------------------------------------------

h_full="$(make_home full)";         add_bundle "$h_full" "3.0.0"; add_tier_map "$h_full"
h_nobundle="$(make_home nobundle)"
h_nomap="$(make_home nomap)";       add_bundle "$h_nomap" "3.0.0"

c_plan="$(make_cwd plan model-plan-1)"          # planning tier
c_orch="$(make_cwd orch model-orch-only)"       # implementation-orchestration tier
c_unarmed="$(make_cwd unarmed)"                 # no pipeline state at all
c_assertfile="$(make_cwd assertfile)"           # armed by the tier assert file alone
mkdir -p "$c_assertfile/.internal/pipeline"
printf 'planning\n' > "$c_assertfile/.internal/pipeline/tier-assert"

# A PATH with no jq on it, for the missing-jq case.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sort head cat mkdir; do ln -sf "$(command -v "$b")" "$nojq/$b"; done

# --- Rule A: only a planning-tier session mutates the plan graph -------------

run "$c_orch" "$h_full" "$p_epic"
check "ruleA-epic-denied" 2
check "ruleA-epic-names-rule-A" 2 'Rule A'
check "ruleA-epic-reason-is-one-line" 2 '^pipeline-guard: only a planning-tier session mutates the plan graph \(Rule A\)$'

run "$c_orch" "$h_full" "$p_import"
check "ruleA-import-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_task"
check "ruleA-task-allowed" 0

# Rule A is scoped to non-planning tiers: the planning session is the one that
# is supposed to be creating epics.
run "$c_plan" "$h_full" "$p_epic"
check "ruleA-does-not-fire-on-the-planning-tier" 0

# --- Rule B: a planning-tier session cannot write source files --------------

run "$c_plan" "$h_full" "$p_src"
check "ruleB-src-write-denied" 2
check "ruleB-src-write-reason-is-one-line" 2 '^pipeline-guard: planning-tier session cannot write source files \(Rule B\)$'

run "$c_plan" "$h_full" "$p_src_edit"
check "ruleB-src-edit-denied" 2 'Rule B'

run "$c_plan" "$h_full" "$p_internal"
check "ruleB-internal-allowed" 0

run "$c_plan" "$h_full" "$p_mex"
check "ruleB-mex-allowed" 0

run "$c_plan" "$h_full" "$p_docs"
check "ruleB-docs-allowed" 0

# Rule B is scoped to the planning tier: an implementation session writes source.
run "$c_orch" "$h_full" "$p_src"
check "ruleB-does-not-fire-off-the-planning-tier" 0

# The tier assert file is the other arming channel, and resolves a tier too.
run "$c_assertfile" "$h_full" "$p_src"
check "ruleB-fires-when-the-tier-came-from-the-tier-assert-file" 2 'Rule B'

# --- Rule C: --assert is human-only (D13a) ----------------------------------

run "$c_plan" "$h_full" "$p_assert"
check "ruleC-bare-assert-denied" 2
check "ruleC-bare-assert-reason-is-one-line" 2 '^pipeline-guard: --assert is human-only; ask the user to run it \(Rule C\)$'

# A model can defeat tier-gate's tty check by wrapping the call in `script`.
# The guard must match the pattern anywhere in the command string.
run "$c_plan" "$h_full" "$p_assert_pty"
check "ruleC-script-wrapped-assert-denied" 2 'Rule C'

# Rule C applies at every tier, not only planning.
run "$c_orch" "$h_full" "$p_assert"
check "ruleC-denied-at-a-non-planning-tier-too" 2 'Rule C'

# --- Rule D: the pipeline state directory is not model-writable (D13b) ------

run "$c_plan" "$h_full" "$p_state_assert"
check "ruleD-write-to-tier-assert-denied" 2
check "ruleD-write-to-tier-assert-reason-is-one-line" 2 '^pipeline-guard: the pipeline state directory is not model-writable \(Rule D\)$'

run "$c_plan" "$h_full" "$p_state_session"
check "ruleD-write-to-session-json-denied" 2 'Rule D'

run "$c_plan" "$h_full" "$p_state_bash"
check "ruleD-bash-redirect-into-the-state-dir-denied" 2 'Rule D'

# Rule D is evaluated before Rule B's .internal/ allowance, and at every tier.
run "$c_orch" "$h_full" "$p_state_assert"
check "ruleD-denied-at-a-non-planning-tier-too" 2 'Rule D'

run "$c_plan" "$h_full" "$p_internal"
check "ruleD-leaves-rule-Bs-internal-allowance-intact" 0

# --- unarmed: no pipeline state -> allow everything, cost nothing -----------
# No bundle root, no tier-map and no jq on PATH, because phase 1 must not touch
# any of them. Every payload above, plus malformed stdin, must exit 0.

PATH_OVERRIDE="$nojq"
unarmed_bad=0
for p in "$p_epic" "$p_import" "$p_task" "$p_src" "$p_src_edit" "$p_internal" \
         "$p_mex" "$p_docs" "$p_assert" "$p_assert_pty" "$p_state_assert" \
         "$p_state_session" "$p_state_bash" "$p_malformed"; do
  run "$c_unarmed" "$h_nobundle" "$p"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL unarmed-allows-all: exit $rc on payload: $p"
    unarmed_bad=$((unarmed_bad+1)); fails=$((fails+1))
  fi
done
unset PATH_OVERRIDE
[ "$unarmed_bad" -eq 0 ] && echo "PASS unarmed-allows-all"

# --- armed error paths: strict fail-closed ----------------------------------

run "$c_plan" "$h_full" "$p_malformed"
check "armed-malformed-stdin-denies" 2
check "armed-malformed-stdin-says-pipeline-guard" 2 '^pipeline-guard: '

PATH_OVERRIDE="$nojq"
run "$c_plan" "$h_full" "$p_task"
check "armed-missing-jq-denies" 2 'jq'
unset PATH_OVERRIDE

run "$c_plan" "$h_nobundle" "$p_task"
check "armed-missing-bundle-root-denies" 2

run "$c_plan" "$h_nomap" "$p_task"
check "armed-missing-tier-map-denies" 2

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: pipeline-guard ($fails failing)"; exit 1; fi
echo "PASS: pipeline-guard"
