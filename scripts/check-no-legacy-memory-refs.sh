#!/usr/bin/env bash
# check-no-legacy-memory-refs.sh — the kb/memory retirement is permanent (spec 2026-08-18).
# Forbid legacy durable-knowledge plumbing in distributed skill text and the hook.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
pattern='bd remember|bd memories|bd forget|-l kb,|--label kb'
hits=$(grep -rnE "$pattern" skills/ hooks/session-start 2>/dev/null)
if [ -n "$hits" ]; then
  echo "FAIL: legacy memory/knowledge-bead references found:"
  echo "$hits"
  fail=1
else
  echo "OK: no legacy memory references in skills/ or hooks/session-start"
fi
exit "$fail"
