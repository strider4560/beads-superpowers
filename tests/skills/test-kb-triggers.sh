#!/usr/bin/env bash
# Pins Trigger A (ADR-0056): brainstorming's Phase-1 context-gathering step must
# query the beads-native KB before a design is proposed.
#
# Also pins Trigger D (ADR-0056): systematic-debugging's Phase-1 evidence-gathering
# step must be store-aware — querying BOTH `bd memories` (prior root-cause/lesson
# memories) AND `bd list --label` (prior decision/design knowledge-beads) before
# re-debugging a symptom — with a visible `KB check` result line.
#
# Assertion policy: behavioral (executes the artifact) or absence-of-defect pins only.
# Presence-of-prose assertions are forbidden here — see
# skills/test-driven-development/writing-good-tests.md (string-presence trap).
#
# Neither skill has an executable surface for this trigger: querying the KB before
# proposing a design / re-debugging a symptom is an instruction to an LLM, not a
# script — nothing here can run and produce these strings as output. Every check
# below is CHANGE-DETECTOR: retained and explicitly labelled until a cc-eval bead
# names the behavior (proposed in the task report). Never "fix" a CHANGE-DETECTOR
# failure by re-pinning the new wording; convert it to behavioral/absence, or delete
# it once the bead exists.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/brainstorming/SKILL.md"
DEBUG_SKILL="$ROOT/skills/systematic-debugging/SKILL.md"
fail=0

if [ ! -f "$SKILL" ]; then
  echo "FAIL: missing $SKILL"; exit 1
fi

# CHANGE-DETECTOR — retained until cc-eval covers Trigger A (brainstorming queries
# the KB before proposing a design). Do NOT "fix" a failure here by re-pinning the
# new prose; either convert it to behavioral or delete it under the bar above.
if grep -qF -- 'bd list --label' "$SKILL"; then
  echo "PASS: KB query command present (bd list --label)"
else
  echo "FAIL: KB query command missing (bd list --label) in $SKILL"; fail=1
fi

if grep -qF -- 'KB check' "$SKILL"; then
  echo "PASS: visible KB check result present (KB check)"
else
  echo "FAIL: visible KB check result missing (KB check) in $SKILL"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: KB trigger markers present in brainstorming/SKILL.md" || fail=1

if [ ! -f "$DEBUG_SKILL" ]; then
  echo "FAIL: missing $DEBUG_SKILL"; fail=1
else
  # CHANGE-DETECTOR — retained until cc-eval covers Trigger D (systematic-debugging
  # queries both bd memories and bd list --label, with a visible KB check line,
  # before re-debugging a symptom). Do NOT "fix" a failure here by re-pinning the new
  # prose; either convert it to behavioral or delete it under the bar above.
  if grep -qF -- 'bd memories' "$DEBUG_SKILL"; then
    echo "PASS: memory-store query present (bd memories)"
  else
    echo "FAIL: memory-store query missing (bd memories) in $DEBUG_SKILL"; fail=1
  fi

  if grep -qF -- 'bd list --label' "$DEBUG_SKILL"; then
    echo "PASS: KB query command present (bd list --label)"
  else
    echo "FAIL: KB query command missing (bd list --label) in $DEBUG_SKILL"; fail=1
  fi

  if grep -qF -- 'KB check' "$DEBUG_SKILL"; then
    echo "PASS: visible KB check result present (KB check)"
  else
    echo "FAIL: visible KB check result missing (KB check) in $DEBUG_SKILL"; fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "PASS: KB trigger markers present in brainstorming/SKILL.md and systematic-debugging/SKILL.md" || exit 1
