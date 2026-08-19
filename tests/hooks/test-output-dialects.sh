#!/usr/bin/env bash
# Asserts hooks/session-start emits the correct JSON dialect per harness env var.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start"
fail=0
# Sampled before ANY hook invocation: the guard at the bottom of this file must cover
# every check() call, not just its own armed run.
REPO_STATE="$ROOT/.internal/pipeline/session.json"
repo_state_id() { if [ -e "$REPO_STATE" ]; then cksum < "$REPO_STATE"; else echo absent; fi; }
repo_state_before=$(repo_state_id)
# Isolated runtime dir + distinct session_id per check(): Task 3's event-scoped dedup
# marker suppresses a second same-(session_id,source) event within 60s. These 5 calls
# are ambient (no stdin, unisolated XDG_RUNTIME_DIR) and would otherwise collide on the
# same "nosid/unknown" marker key -- both with each other and with other test files that
# use the same real-/tmp fallback key (see tests/hooks/test-dedup-marker.sh).
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUNDIR="$T/run"; mkdir -p "$RUNDIR"
# Sandboxed HOME + CWD for every invocation below. Two independent reasons, and the
# sandbox is the fix for both:
#   HOME — the hook maintains $HOME/.agents/beads-superpowers and writes
#   $HOME/.local/state/beads-superpowers/record.json, and on a developer machine
#   $HOME/.agents is commonly a symlink into a synced dotfiles tree.
#   CWD — on a pipeline-armed machine ($HOME/.agents/great_cto/ AND
#   <root>/shared/tier-map.json both present) the hook writes its session state file
#   RELATIVE TO ITS CWD; run with the real $HOME and no cd, each check() overwrote
#   this repo's own live session state, once per call. That write is correct and
#   deliberate in the hook -- it is symmetric with the CWD-relative read in
#   scripts/pipeline/tier-gate.sh.
# No assertion here reads HOME or CWD: they inspect the JSON envelope shape and the
# bootstrap text, which the hook resolves from its own $0.
SBHOME="$T/home"; SBWS="$T/ws"; mkdir -p "$SBHOME" "$SBWS"
n=0
check() { # desc | env-assignment | jq-filter that must be non-empty
  local desc="$1" envset="$2" filter="$3"
  local out
  n=$((n + 1))
  # shellcheck disable=SC2086  # $envset is intentionally word-split (space-separated KEY=VALUE pairs)
  out=$(printf '{"session_id":"dialect-%s","source":"startup"}' "$n" \
    | ( cd "$SBWS" && env -i HOME="$SBHOME" PATH="$PATH" XDG_RUNTIME_DIR="$RUNDIR" \
        $envset bash "$HOOK" 2>/dev/null ))
  if echo "$out" | jq -e "$filter" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"; echo "  got: $out"; fail=1
  fi
}
check "Cursor → top-level additional_context"        "CURSOR_PLUGIN_ROOT=/x" '.additional_context'
check "Claude → nested additionalContext"            "CLAUDE_PLUGIN_ROOT=/x" '.hookSpecificOutput.additionalContext'
check "Claude settings-channel (PROJECT_DIR only) → nested" "CLAUDE_PROJECT_DIR=/x" '.hookSpecificOutput.additionalContext'
check "Codex → nested additionalContext"             "CODEX_PLUGIN_ROOT=/x" '.hookSpecificOutput.additionalContext'
check "Copilot (with CLAUDE root) → top-level"       "CLAUDE_PLUGIN_ROOT=/x COPILOT_CLI=1" '.additionalContext'
check "Copilot (with PROJECT_DIR) → top-level"       "CLAUDE_PROJECT_DIR=/x COPILOT_CLI=1" '.additionalContext'
check "Generic fallback → top-level additionalContext" "" '.additionalContext'
check "Rule section present in injected context"       "" '.additionalContext | contains("Skill Name Resolution")'
# --- regression guard: an armed hook run must not touch THIS repo's state file -----
# Asserting "repo file unchanged" alone would pass vacuously on an unarmed machine
# (the write never fires), so this arms a sandbox HOME and requires the write to land
# in the sandbox workspace. Both halves must hold: the write happened, and it landed
# somewhere other than the repo.
ARMED="$T/armed-home"; ARMEDWS="$T/armed-ws"
mkdir -p "$ARMED/.agents/great_cto/shared" "$ARMEDWS"
printf '{"tiers":{}}\n' > "$ARMED/.agents/great_cto/shared/tier-map.json"
printf '{"session_id":"dialect-armed","source":"startup"}' \
  | ( cd "$ARMEDWS" && env -i HOME="$ARMED" PATH="$PATH" XDG_RUNTIME_DIR="$RUNDIR" \
      bash "$HOOK" ) >/dev/null 2>&1
repo_state_after=$(repo_state_id)
if [ -f "$ARMEDWS/.internal/pipeline/session.json" ]; then
  echo "PASS: armed sandbox HOME does write session.json — the guard below is live"
else
  echo "FAIL: armed sandbox wrote no session.json — arming changed; the guard is vacuous"
  fail=1
fi
if [ "$repo_state_before" = "$repo_state_after" ]; then
  echo "PASS: repo's own .internal/pipeline/session.json untouched by this whole run"
else
  echo "FAIL: this run clobbered $REPO_STATE"
  echo "  before: $repo_state_before"
  echo "  after:  $repo_state_after"
  fail=1
fi

exit $fail
