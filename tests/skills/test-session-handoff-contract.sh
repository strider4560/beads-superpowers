#!/usr/bin/env bash
# Contract test for session-handoff (ADR-0049 slice2 T1a).
# Assertion policy: behavioral (executes the artifact) or absence-of-defect pins only.
# Presence-of-prose assertions are forbidden here — see
# skills/test-driven-development/writing-good-tests.md (string-presence trap).
#
# session-handoff has NO executable surface (no scripts/ — the whole pipeline is
# prose instructing an LLM to run ad hoc git/bd commands and write a doc), so nothing
# below can be converted to behavioral in-repo. Two categories survive:
#   1. SECURITY-FLOOR pins (deliberate divergence SD-1, registered in
#      .claude/skills/auditing-upstream-drift/SKILL.md's Known Deliberate Divergences
#      table) — the five credential-prefix pins the handoff skill must redact. These
#      MUST survive verbatim; deleting them removes a security control.
#   2. CHANGE-DETECTOR pins — retained, explicitly labelled, until a cc-eval bead
#      names the behavior. Never "fix" a CHANGE-DETECTOR failure by re-pinning the
#      new wording; convert it to behavioral/absence, or delete it once the bead
#      exists.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/session-handoff/SKILL.md"
fail=0

check_exact() {  # fixed-string, must be present
  if grep -Fq "$1" "$2"; then echo "PASS: $1"; else echo "FAIL: missing — $1 ($2)"; fail=1; fi
}

# --- CHANGE-DETECTOR — retained until cc-eval covers the announce line (behavioral
# output the agent emits at skill start). Do NOT "fix" a failure here by re-pinning
# the new prose; either convert it to behavioral or delete it under the bar above. ---
check_exact "I'm using the session-handoff skill to write a session handoff." "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the output-path convention.
# Do NOT "fix" a failure here by re-pinning the new prose; either convert it to
# behavioral or delete it under the bar above. ---
check_exact ".internal/handoff/YYYY-MM-DD[-HHMMSS]-<topic>-handoff.md" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the continuation-memory key
# format. Do NOT "fix" a failure here by re-pinning the new prose; either convert it
# to behavioral or delete it under the bar above. ---
check_exact "continuation-<date>-<topic>" "$SKILL"

# --- SECURITY FLOOR (deliberate divergence SD-1) — the five credential-prefix pins
# the handoff skill must redact. MUST survive verbatim; do not touch, reorder, or
# delete any of the five. Deleting one removes a security control regardless of any
# test-purity rationale. ---
check_exact "\`sk-\`" "$SKILL"
check_exact "\`ghp_\`" "$SKILL"
check_exact "\`AKIA\`" "$SKILL"
check_exact "\`-----BEGIN\`" "$SKILL"
check_exact "\`password=\`" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the gitignore-safety
# own-operation guardrail. Do NOT "fix" a failure here by re-pinning the new prose;
# either convert it to behavioral or delete it under the bar above. ---
check_exact "git check-ignore" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the absence of model-trigger
# surfaces (frontmatter mechanism). Do NOT "fix" a failure here by re-pinning the new
# prose; either convert it to behavioral or delete it under the bar above. ---
check_exact "disable-model-invocation: true" "$SKILL"

[ "$fail" -eq 0 ] && echo "PASS: session-handoff contract" || exit 1
