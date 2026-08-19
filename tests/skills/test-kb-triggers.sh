#!/usr/bin/env bash
# Pins Trigger A (ADR-0056): brainstorming's Phase-1 context-gathering step must
# query the knowledge store before a design is proposed.
#
# Also pins Trigger D (ADR-0056): systematic-debugging's Phase-1 evidence-gathering
# step must be store-aware before re-debugging a symptom.
#
# Both are now the CB-R retrieval contract: the `mex graph scope` query, the
# read-the-routed-pages mandate, and a visible `mex retrieval:` result line.
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
if grep -qF -- 'mex graph scope' "$SKILL"; then
  echo "PASS: KB query command present (mex graph scope)"
else
  echo "FAIL: KB query command missing (mex graph scope) in $SKILL"; fail=1
fi

if grep -qF -- 'mex retrieval:' "$SKILL"; then
  echo "PASS: visible KB check result present (mex retrieval:)"
else
  echo "FAIL: visible KB check result missing (mex retrieval:) in $SKILL"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: KB trigger markers present in brainstorming/SKILL.md" || fail=1

if [ ! -f "$DEBUG_SKILL" ]; then
  echo "FAIL: missing $DEBUG_SKILL"; fail=1
else
  # CHANGE-DETECTOR — retained until cc-eval covers Trigger D (systematic-debugging
  # queries the knowledge store and reads the routed pages, with a visible
  # `mex retrieval:` line, before re-debugging a symptom). Do NOT "fix" a failure here
  # by re-pinning the new prose; either convert it to behavioral or delete it under the
  # bar above.
  if grep -qF -- 'read the routed pages' "$DEBUG_SKILL"; then
    echo "PASS: routed-pages read mandate present (read the routed pages)"
  else
    echo "FAIL: routed-pages read mandate missing (read the routed pages) in $DEBUG_SKILL"; fail=1
  fi

  if grep -qF -- 'mex graph scope' "$DEBUG_SKILL"; then
    echo "PASS: KB query command present (mex graph scope)"
  else
    echo "FAIL: KB query command missing (mex graph scope) in $DEBUG_SKILL"; fail=1
  fi

  if grep -qF -- 'mex retrieval:' "$DEBUG_SKILL"; then
    echo "PASS: visible KB check result present (mex retrieval:)"
  else
    echo "FAIL: visible KB check result missing (mex retrieval:) in $DEBUG_SKILL"; fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "PASS: KB trigger markers present in brainstorming/SKILL.md and systematic-debugging/SKILL.md" || exit 1
