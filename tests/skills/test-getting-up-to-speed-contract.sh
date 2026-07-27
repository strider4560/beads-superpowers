#!/usr/bin/env bash
# Contract test for getting-up-to-speed (ADR-0049 / stress-test B5).
# Assertion policy: behavioral (executes the artifact) or absence-of-defect pins only.
# Presence-of-prose assertions are forbidden here — see
# skills/test-driven-development/writing-good-tests.md (string-presence trap).
#
# orient.sh's OWN output-contract (sections, handoff keys, bd-absent SKIP, read-only
# source guard) is already exercised by the companion suite
# tests/skills/test-orient-script.sh (also run by `just contracts`) — not duplicated
# here. Below: (1) a behavioral test of the Step-4 handoff-freshness snippet, a real
# fenced ```bash block in SKILL.md distinct from orient.sh (orient.sh gathers raw
# data only and never computes a freshness verdict); (2) an absence-of-defect pin on
# orient.sh's real source for the FORBIDDEN --claim invariant; (3) retained,
# explicitly-labelled CHANGE-DETECTOR pins for narrative/report prose the skill
# instructs the AGENT (not a script) to emit — genuinely uncoverable in-repo without
# an LLM-driven eval harness. Never "fix" a CHANGE-DETECTOR failure by re-pinning the
# new wording; convert it to behavioral/absence, or delete it once a cc-eval bead
# exists naming the behavior.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/getting-up-to-speed/SKILL.md"
EDGE="$ROOT/skills/getting-up-to-speed/references/edge-cases.md"
ORIENT="$ROOT/skills/getting-up-to-speed/scripts/orient.sh"
fail=0

check_exact() {  # fixed-string, must be present
  if grep -Fq "$1" "$2"; then echo "PASS: $1"; else echo "FAIL: missing — $1 ($2)"; fail=1; fi
}

# --- Absence-of-defect: orient.sh must never claim work (the FORBIDDEN invariant) ---
# `bd ready --claim` is FORBIDDEN per SKILL.md Step 1 — orientation ends at the
# terminal contract and the user picks the work. test-orient-script.sh's read-only
# guard greps for mutating verbs (create/close/update/remember/forget/init/delete,
# dolt push/pull) but does not cover a --claim flag riding a read verb like `ready`;
# this pin closes that specific gap directly against the shipped script.
if grep -q -- '--claim' "$ORIENT"; then
  echo "FAIL: orient.sh invokes bd with --claim — orientation must stay read-only/non-claiming"
  fail=1
else
  echo "PASS: orient.sh never invokes --claim"
fi

# --- Behavioral: Step-4 handoff-freshness classifier (a real fenced ```bash block in
# SKILL.md — not orient.sh, which emits raw data only and never a verdict). Extracted
# with an awk range like test-finishing-branch-cleanup.sh's extract_block, adapted to
# tolerate the block's 2-space list-item indentation (the literal top-level-only
# `/^```bash$/` pattern does not match an indented fence; the `!infence` guard against
# in-fence `#` lines is preserved unchanged). ---
extract_block() {
  awk -v want="$1" '
    $0 ~ want                                    { inseg = 1; next }
    inseg && !infence && /^#+ /                  { exit }
    inseg && /^[[:space:]]*```bash[[:space:]]*$/ { infence = 1; next }
    infence && /^[[:space:]]*```[[:space:]]*$/   { exit }
    infence                                      { print }
  ' "$SKILL"
}

FRESHNESS="$(extract_block 'Synthesize through the gate')"
if [ -z "$FRESHNESS" ]; then
  echo "FAIL: could not extract the Step 4 handoff-freshness bash block from SKILL.md"
  fail=1
else
  run_freshness() {  # $1 = fixture doc path; overrides the snippet's DOC="<path>" template slot
    local doc="$1" snippet
    snippet="${FRESHNESS//DOC=\"<path>\"/DOC=\"$doc\"}"
    (eval "$snippet") 2>/dev/null
  }

  FIXDIR="$(mktemp -d)"
  trap 'rm -rf "$FIXDIR"' EXIT
  git init -q "$FIXDIR"
  git -C "$FIXDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  git -C "$FIXDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
  HEAD_SHA="$(git -C "$FIXDIR" rev-parse HEAD)"
  OLD_SHA="$(git -C "$FIXDIR" rev-parse HEAD~1)"

  # fresh: the doc's `@ <sha>` token IS current HEAD
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution
  printf '# H\n- branch @ `%s`\n' "$HEAD_SHA" > "$FIXDIR/fresh.md"
  OUT="$(cd "$FIXDIR" && run_freshness "$FIXDIR/fresh.md")"
  if [ "$OUT" = "fresh" ]; then
    echo "PASS: freshness snippet reports fresh when the doc sha is HEAD"
  else
    echo "FAIL: expected fresh, got '$OUT'"; fail=1
  fi

  # possibly-stale: the doc's `@ <sha>` token is an ancestor of HEAD (is-ancestor branch)
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution
  printf '# H\n- branch @ `%s`\n' "$OLD_SHA" > "$FIXDIR/ancestor.md"
  OUT="$(cd "$FIXDIR" && run_freshness "$FIXDIR/ancestor.md")"
  if [ "$OUT" = "possibly-stale" ]; then
    echo "PASS: freshness snippet reports possibly-stale for an ancestor sha (is-ancestor)"
  else
    echo "FAIL: expected possibly-stale, got '$OUT'"; fail=1
  fi

  # NOTE: the snippet's no-sha mtime-fallback branch is NOT exercised here. Verifying
  # it surfaced a real defect (out of scope to fix — this task owns tests/ only, not
  # skills/): when DOC_SHA is empty, `case "$HEAD" in "$DOC_SHA"*)` degenerates to a
  # bare `*` glob that always matches, so the classifier reports "fresh" instead of
  # the documented "unavailable"/mtime-fallback "possibly-stale" for a doc with no
  # `@ <sha>` token — reproduced live: `DOC_SHA=""; HEAD=x; case "$HEAD" in
  # "$DOC_SHA"*) echo fresh;; *) echo other;; esac` prints "fresh". Reported to the
  # controller for a separate fix bead; asserting the documented behavior here would
  # make this suite red for a pre-existing bug outside this task's scope, and
  # asserting the buggy behavior would enshrine it as correct.
fi

# --- CHANGE-DETECTOR — retained until cc-eval covers the terminal-contract output
# (the skill's closing lines telling the user it will not auto-claim or begin work).
# Do NOT "fix" a failure here by re-pinning the new prose; either convert it to
# behavioral or delete it under the bar above. ---
check_exact "I'm ready for your next instruction" "$SKILL"
check_exact "Do NOT auto-claim" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the Step-5 archive mechanism:
# the target directory (".internal/handoff/archive") and the agent's own
# success/failure narration after the mv. The mv command itself is a real one-liner in
# SKILL.md, not a fenced ```bash block, and was judged out of this task's bounded
# scope (proposed as a cc-eval follow-up in the task report rather than added here).
# Do NOT "fix" a failure here by re-pinning the new prose; either convert it to
# behavioral or delete it under the bar above. ---
check_exact ".internal/handoff/archive" "$SKILL"
check_exact "Archived consumed handoff" "$SKILL"
check_exact "left in inbox" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the emitted summary's section
# headings. Do NOT "fix" a failure here by re-pinning the new prose; either convert it
# to behavioral or delete it under the bar above. ---
check_exact "Current State" "$SKILL"
check_exact "Recent Activity" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the Current-State freshness
# display wording (the space-separated "possibly stale" in the Last-handoff line's
# display template — distinct from the hyphenated "possibly-stale" classifier token
# already covered behaviorally above), the "predates HEAD" possibly-stale narrative,
# and the continuation-pointer prune policy (key-prefix scoping, never-guess-delete,
# the "Pruned N ..." report line). These pin only the narrative/display text built on
# top of the now-behaviorally-tested classifier. Do NOT "fix" a failure here by
# re-pinning the new prose; either convert it to behavioral or delete it under the
# bar above. ---
check_exact "possibly stale" "$SKILL"
check_exact "predates HEAD" "$SKILL"
check_exact "key prefix" "$SKILL"
check_exact "never guess-delete" "$SKILL"
check_exact "Pruned N superseded continuation pointers" "$SKILL"

# --- CHANGE-DETECTOR — retained until cc-eval covers the memories-digest
# secret-redaction guardrail sentence and the bounded-digest rationale. orient.sh's
# own digest DOES redact via a python regex (scripts/orient.sh); no fixture in this
# repo currently drives that path with a secret-shaped memory body (proposed as a
# cc-eval follow-up in the task report). Do NOT "fix" a failure here by re-pinning the
# new prose; either convert it to behavioral or delete it under the bar above. ---
check_exact "never echo doc body sections that could carry secrets" "$SKILL"
check_exact "bounded by selection and shape, not by a forbidden call" "$SKILL"

# --- Scale band (Heavy threshold current; absence pin below guards the stale band) ---
# CHANGE-DETECTOR — retained until cc-eval covers the Heavy-path threshold value.
check_exact "> 150" "$SKILL"
if grep -Fq -- "> 500" "$SKILL"; then echo "FAIL: stale > 500 band"; fail=1; else echo "PASS: no stale > 500"; fi

# --- Branch-only reference shipped + pointed at ---
if [ -f "$EDGE" ]; then echo "PASS: edge-cases reference exists"; else echo "FAIL: references/edge-cases.md missing"; fail=1; fi
# CHANGE-DETECTOR — retained until cc-eval covers the edge-cases pointer and its
# possibly-stale row. Do NOT "fix" a failure here by re-pinning the new prose; either
# convert it to behavioral or delete it under the bar above.
check_exact "references/edge-cases.md" "$SKILL"
check_exact "possibly stale" "$EDGE"

[ "$fail" -eq 0 ] && echo "PASS: getting-up-to-speed contract" || exit 1
