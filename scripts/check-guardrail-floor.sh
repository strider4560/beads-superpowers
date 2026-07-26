#!/usr/bin/env bash
# check-guardrail-floor.sh — ADR-0049 "never remove to zero", made mechanical.
# Counts guardrail lines per skill. FAILS if any skill reaches zero, or if a
# count decreases without a recorded baseline entry justifying it.
# This is a FLOOR check (count >= 1), NOT a string-presence check: it never
# asserts specific wording, so it is not a change-detector.
# Matching is case-INsensitive: skills use mixed casing for guardrail
# headers (e.g. "**Never:**" title-case, not just shouting-case "NEVER") —
# a case-sensitive count undercounts real guardrail content and produces
# false zero-floor failures on files that already carry guardrails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
BASELINE="scripts/guardrail-floor-baseline.txt"
PAT='MUST NOT|MUST|NEVER|ALWAYS|Iron Law'
fail=0
for f in skills/*/SKILL.md; do
  n=$(grep -icE "$PAT" "$f" || true)
  if [ "$n" -eq 0 ]; then
    echo "FAIL: $f has ZERO guardrail lines (ADR-0049: never remove to zero)"; fail=1; continue
  fi
  if [ -f "$BASELINE" ]; then
    prev=$(awk -v k="$f" '$1==k{print $2}' "$BASELINE")
    if [ -n "$prev" ] && [ "$n" -lt "$prev" ]; then
      echo "FAIL: $f guardrail lines dropped $prev -> $n; update $BASELINE with justification"; fail=1
    fi
  fi
done
[ "$fail" -eq 0 ] && echo "guardrail-floor: OK (no skill at zero, no unjustified decrease)"
exit "$fail"
