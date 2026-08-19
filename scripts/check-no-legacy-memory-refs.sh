#!/usr/bin/env bash
# check-no-legacy-memory-refs.sh — the kb/memory retirement is permanent (spec 2026-08-18).
# Forbid legacy durable-knowledge plumbing in distributed skill text and the hook.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
pattern='bd remember|bd memories|bd forget|bd recall|-l kb\b|--label kb'
roots=(skills/ .claude/skills/ example-workflow/ hooks/session-start)
for r in "${roots[@]}"; do
  [ -e "$r" ] || { echo "FAIL: scan root missing: $r"; exit 1; }
done
hits=$(grep -rnE "$pattern" "${roots[@]}")
status=$?
if [ "$status" -ge 2 ]; then
  echo "FAIL: grep error (exit $status) — coverage not established"
  exit 1
fi
if [ -n "$hits" ]; then
  echo "FAIL: legacy memory/knowledge-bead references found:"
  echo "$hits"
  fail=1
else
  echo "OK: no legacy memory references in scan roots"
fi
exit "$fail"
