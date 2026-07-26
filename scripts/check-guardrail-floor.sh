#!/usr/bin/env bash
# check-guardrail-floor.sh — ADR-0049 "never remove to zero", made mechanical.
#
# Pattern rationale: matches this repo's ACTUAL guardrail vocabulary
# (MUST, NEVER, Iron Law, "## Red Flags", **Never/**Always/**Do not headings,
# FORBIDDEN). Case sensitivity is deliberately MIXED, not uniform:
#   - Bare RFC-2119 tokens (MUST, NEVER, FORBIDDEN) plus the "Iron Law" and
#     "## Red Flags" markers are case-SENSITIVE. These are deliberate
#     shouting-case / fixed-heading conventions in this repo's skills, and
#     lowercase prose ("must", "never" as ordinary English) must NOT count
#     as a guardrail. A broad case-insensitive match on these tokens
#     produced 193 matched lines repo-wide of which only 73 were real
#     guardrail markers — under that pattern a skill could lose every
#     genuine guardrail and still pass.
#   - The "**"-prefixed markers (**Never, **Always, **Do not) are
#     case-INSENSITIVE, matched via explicit [Nn]/[Aa]/[Dd]... character
#     classes (POSIX ERE has no inline case-fold flag). A heading written
#     as "**DO NOT**" or "**NEVER:**" is exactly as much a guardrail marker
#     as "**Never:**" — requiring exact title case there would let that
#     heading style silently escape the count, which is a real gap: exact
#     "\*\*Never" / "\*\*Always" matched zero occurrences of any all-caps
#     "**DO NOT**"-style heading in this repo even though such headings are
#     guardrail markers.
# Net effect: 75 matches across the library (verified) vs. 73 under the
# strictly-title-case version — the only two new matches are inline
# "**never**" / "**ALWAYS...**" bolded normative language, not ordinary
# prose picked up by accident.
#
# This is a FLOOR check, NOT a string-presence check on specific wording —
# it never asserts which marker a skill must use, only that authored
# guardrail density doesn't silently erode.
#
# Baseline semantics:
#   - The baseline file MUST exist AND have usable content. Absence (deleted,
#     lost in a bad merge/rebase, a .gitignore mistake) or an empty/all-blank
#     file both mean this guard has no reference data to compare against, so
#     either one fails loudly and exits non-zero before the per-file loop
#     runs, instead of silently skipping every file's zero/decrease checks
#     (a guard with no reference data that still prints OK is worse than no
#     guard at all — this applies to corrupt data exactly as much as to a
#     missing file).
#   - Only the FIRST matching row for a given file counts (awk ... {exit}).
#     If a baseline ever ends up with two rows for the same key (bad merge),
#     the earlier row wins deterministically and the guard still runs a real
#     check, rather than letting `prev` become a multi-line string that
#     silently disables numeric comparisons for that file. This does not
#     detect the duplicate itself — only that it doesn't break the check.
#   - Every row's count is validated as a plain non-negative integer before
#     any arithmetic runs against it (`case ... ''|*[!0-9]*)`). A row with a
#     missing, non-numeric, or otherwise malformed count FAILs loudly and
#     names the offending file, rather than letting `[ -gt ]`/`[ -lt ]` throw
#     "integer expression expected" to stderr — inside an `if`, that error
#     does NOT trip `set -e` and is evaluated as false, which would silently
#     disable both the drop-to-zero and decrease checks for that row. The
#     freshly-computed current count (`n`, from `grep -c`) gets the same
#     validation for the same reason, even though `grep -c` cannot practically
#     produce a non-numeric value on a readable file.
#   - baseline > 0, current == 0       -> FAIL (real removal-to-zero,
#                                        ADR-0049).
#   - baseline > 0, current < baseline -> FAIL (unjustified decrease).
#   - baseline == 0 (a recorded row)   -> legitimate and never re-flagged;
#                                        a skill can be a capability/
#                                        technique skill with no bright
#                                        lines (e.g. dispatching-parallel-
#                                        agents) and this never forces one
#                                        in as long as it stays at >= 0.
#   - no baseline row, current == 0    -> FAIL. A missing row cannot be
#                                        told apart from a gutted skill
#                                        whose baseline row was also
#                                        dropped, so it does NOT get the
#                                        benefit of the doubt — only a
#                                        disclosed, recorded zero is
#                                        legitimate.
#   - no baseline row, current > 0     -> INFO (genuinely new skill;
#                                        nothing lost, just needs a
#                                        baseline row added).
#
# Known limitation (accepted, not fixed here): \*\*[Nn][Ee][Vv][Ee][Rr] etc.
# have no trailing word boundary, so e.g. "**Nevertheless" would match. This
# predates this fix, is narrowing-only (a false positive that can only ever
# inflate a count, never mask a real drop), and changing the pattern again
# would churn every baseline row for a cosmetic gain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
BASELINE="scripts/guardrail-floor-baseline.txt"
if [ ! -f "$BASELINE" ]; then
  echo "FAIL: $BASELINE is missing — guardrail-floor has no reference data to check against"
  exit 1
fi
if ! grep -qE '[^[:space:]]' "$BASELINE"; then
  echo "FAIL: $BASELINE is empty (or all-blank) — guardrail-floor has no reference data to check against"
  exit 1
fi
PAT='MUST|NEVER|Iron Law|## Red Flags|FORBIDDEN|\*\*[Nn][Ee][Vv][Ee][Rr]|\*\*[Aa][Ll][Ww][Aa][Yy][Ss]|\*\*[Dd][Oo] [Nn][Oo][Tt]'
fail=0
for f in skills/*/SKILL.md; do
  n=$(grep -cE "$PAT" "$f" || true)
  case "$n" in
    ''|*[!0-9]*)
      echo "FAIL: $f produced a non-numeric guardrail count from grep -c ('$n') — cannot validate"; fail=1; continue ;;
  esac
  prev=$(awk -v k="$f" '$1==k{print $2; exit}' "$BASELINE")
  if [ -z "$prev" ]; then
    if [ "$n" -eq 0 ]; then
      echo "FAIL: $f has no baseline entry AND zero guardrail lines (indistinguishable from a gutted skill whose row was also dropped; add a baseline entry only if this zero is genuine — ADR-0049)"; fail=1
    else
      echo "INFO: $f has no baseline entry (new skill, count=$n); add one to $BASELINE"
    fi
    continue
  fi
  case "$prev" in
    ''|*[!0-9]*)
      echo "FAIL: $BASELINE has a non-numeric count for $f ('$prev') — cannot validate; fix the baseline row"; fail=1; continue ;;
  esac
  if [ "$prev" -gt 0 ] && [ "$n" -eq 0 ]; then
    echo "FAIL: $f dropped to ZERO guardrail lines (baseline $prev; ADR-0049: never remove to zero)"; fail=1; continue
  fi
  if [ "$n" -lt "$prev" ]; then
    echo "FAIL: $f guardrail lines dropped $prev -> $n; update $BASELINE with justification"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "guardrail-floor: OK (no unjustified drop-to-zero, no unjustified decrease)"
exit "$fail"
