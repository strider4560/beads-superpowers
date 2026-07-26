#!/usr/bin/env bash
# check-guardrail-floor.sh — ADR-0049 "never remove to zero", made mechanical.
#
# Pattern rationale: matches this repo's ACTUAL guardrail vocabulary
# (MUST, NEVER, Iron Law, "## Red Flags", **Never, **Always, **Do not,
# FORBIDDEN), case-SENSITIVE. These are deliberate authored markers, so
# case is signal, not noise: a broad case-insensitive pattern (e.g. also
# matching "must"/"never" as generic English) let ordinary prose count as
# guardrails — measured repo-wide, that produced 193 matched lines of
# which only 73 were real guardrail markers, meaning a skill could lose
# every genuine guardrail and still pass. The precise pattern above
# matches exactly those 73 real markers.
#
# This is a FLOOR check, NOT a string-presence check on specific wording —
# it never asserts which marker a skill must use, only that authored
# guardrail density doesn't silently erode.
#
# The zero-check is RELATIVE to the baseline, not absolute: it fails only
# when a skill had count > 0 in the baseline and now has 0 (a real
# removal-to-zero per ADR-0049). A skill baselined at 0 is a legitimate
# capability/technique skill that deliberately carries no bright lines
# (e.g. dispatching-parallel-agents uses "## Common Mistakes" / "## When
# NOT to Use" instead) and must NOT be forced to invent guardrails just to
# pass an absolute floor. A file with no baseline entry at all (a new
# skill) never fails this check — it is reported informationally so a
# baseline entry can be added.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
BASELINE="scripts/guardrail-floor-baseline.txt"
PAT='MUST|NEVER|Iron Law|## Red Flags|\*\*Never|\*\*Always|\*\*Do not|FORBIDDEN'
fail=0
for f in skills/*/SKILL.md; do
  n=$(grep -cE "$PAT" "$f" || true)
  prev=""
  if [ -f "$BASELINE" ]; then
    prev=$(awk -v k="$f" '$1==k{print $2}' "$BASELINE")
  fi
  if [ -z "$prev" ]; then
    echo "INFO: $f has no baseline entry (new skill, count=$n); add one to $BASELINE"
    continue
  fi
  if [ "$prev" -gt 0 ] && [ "$n" -eq 0 ]; then
    echo "FAIL: $f dropped to ZERO guardrail lines (baseline $prev; ADR-0049: never remove to zero)"; fail=1; continue
  fi
  if [ "$n" -lt "$prev" ]; then
    echo "FAIL: $f guardrail lines dropped $prev -> $n; update $BASELINE with justification"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "guardrail-floor: OK (no unjustified drop-to-zero, no unjustified decrease)"
exit "$fail"
