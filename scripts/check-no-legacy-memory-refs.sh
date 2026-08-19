#!/usr/bin/env bash
# check-no-legacy-memory-refs.sh — the kb/memory retirement is permanent (spec 2026-08-18).
# Forbid legacy durable-knowledge plumbing in distributed skill text and the hook.
#
# ONE allowlisted site: skills/project-init/SKILL.md's "## Migrating from knowledge-beads"
# section, which must name the retired commands in order to retire them. The exclusion is
# PATH-scoped, never content-scoped — that file is dropped from the sweep and then checked
# separately with a heading-range assertion, so a legacy string anywhere ELSE in the same
# file still fails. If the migration section is ever removed, the file must be fully clean.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
pattern='bd remember|bd memories|bd forget|bd recall|-l kb\b|--label kb'
ALLOW_FILE='skills/project-init/SKILL.md'
ALLOW_HEADING='## Migrating from knowledge-beads'
roots=(skills/ .claude/skills/ example-workflow/ .opencode/ hooks/session-start)
for r in "${roots[@]}"; do
  [ -e "$r" ] || { echo "FAIL: scan root missing: $r"; exit 1; }
done
hits=$(grep -rnE "$pattern" "${roots[@]}")
status=$?
if [ "$status" -ge 2 ]; then
  echo "FAIL: grep error (exit $status) — coverage not established"
  exit 1
fi
# Path-scoped exclusion of the single allowlisted file (checked separately below).
hits=$(printf '%s\n' "$hits" | grep -vE "^${ALLOW_FILE}:" | grep -v '^$')
if [ -n "$hits" ]; then
  echo "FAIL: legacy memory/knowledge-bead references found:"
  echo "$hits"
  fail=1
else
  echo "OK: no legacy memory references in scan roots (excluding $ALLOW_FILE)"
fi

# --- allowlisted file: every match must sit inside the migration section ---
if [ ! -f "$ALLOW_FILE" ]; then
  echo "FAIL: allowlisted file missing: $ALLOW_FILE"
  exit 1
fi
if grep -qF -- "$ALLOW_HEADING" "$ALLOW_FILE"; then
  # Range = the heading line through the line before the next "## " heading (or EOF).
  range=$(awk -v head="$ALLOW_HEADING" '
    index($0, head) == 1 && !s { s = NR; next }
    s && /^## / && !e { e = NR - 1 }
    END { if (s && !e) e = NR; print s "|" e }
  ' "$ALLOW_FILE")
  start=${range%|*}
  end=${range#*|}
  outside=$(grep -nE "$pattern" "$ALLOW_FILE" | awk -F: -v s="$start" -v e="$end" '$1 < s || $1 > e')
  if [ -n "$outside" ]; then
    echo "FAIL: legacy references in $ALLOW_FILE outside '$ALLOW_HEADING' (lines $start-$end):"
    echo "$outside"
    fail=1
  else
    echo "OK: $ALLOW_FILE legacy references confined to lines $start-$end ($ALLOW_HEADING)"
  fi
else
  # No migration section => no allowance; the file must be clean like every other site.
  outside=$(grep -nE "$pattern" "$ALLOW_FILE")
  if [ -n "$outside" ]; then
    echo "FAIL: legacy references in $ALLOW_FILE with no '$ALLOW_HEADING' section to allow them:"
    echo "$outside"
    fail=1
  else
    echo "OK: $ALLOW_FILE clean (no migration section, no legacy references)"
  fi
fi
exit "$fail"
