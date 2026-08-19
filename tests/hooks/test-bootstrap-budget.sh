#!/usr/bin/env bash
# test-bootstrap-budget.sh — guard the always-injected session bootstrap size (ADR-0039).
# SCOPE: SKILL.md FILE bytes only. bd prime output and conditional warnings are
# deliberately OUT of budget — they are environment-sized and dedup-guarded.
# Do not "fix" this test to measure the full injection; that makes it flaky.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start"
SKILL="$ROOT/skills/using-superpowers/SKILL.md"
CEILING=6144
WRAPPER_CEILING=1024
fail=0
size=$(wc -c < "$SKILL")
if [ "$size" -gt "$CEILING" ]; then
  echo "FAIL: using-superpowers/SKILL.md is ${size} bytes (> ${CEILING})"; fail=1
fi
# Static wrapper template (the session_context_raw assignment line in the hook,
# variable names unexpanded) must stay small too.
# Renamed session_context -> session_context_raw (Task 2, raw/one-escape contract) — pattern updated to match.
wrapper=$(grep -m1 'session_context_raw=' "$ROOT/hooks/session-start" | wc -c)
if [ "$wrapper" -gt "$WRAPPER_CEILING" ]; then
  echo "FAIL: session-start wrapper template is ${wrapper} bytes (> ${WRAPPER_CEILING})"; fail=1
fi
if [ "$fail" = 0 ]; then
  echo "PASS: bootstrap ${size}B <= ${CEILING}B; wrapper ${wrapper}B <= ${WRAPPER_CEILING}B"
fi

# --- composed-mode budget + latency (Task 2: --emit-plain) ---
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/ws/.mex" "$TMP/home/.claude" "$TMP/run"
cat > "$TMP/bin/bd" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  config)   printf '' ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$TMP/bin/bd"
# Isolated HOME: a real dev machine's ~/.claude/settings.json may itself register a
# "bd prime" hook, tripping the dedup guard (see test-composer-assembly.sh).
export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
export XDG_RUNTIME_DIR="$TMP/run"   # marker isolation + distinct events per invocation (see test-composer-assembly.sh)

# overflow fixture: a 64KB .mex/lessons.md hot page — proves CLAMPING to the total
# envelope budget (ADR-0052), not just observing a small fixture. Run from an isolated
# workspace: composing against the repo's own .mex/ would make the size non-deterministic.
printf 'router\n' > "$TMP/ws/.mex/ROUTER.md"
big=$(printf 'B%.0s' {1..1024})
for _ in $(seq 1 64); do printf '%s\n' "$big"; done > "$TMP/ws/.mex/lessons.md"
# single sourced read: constants + pointer size from the hook's own definitions.
# Must run BEFORE the cd below: sourcing re-resolves $0 (this script's own relative
# path) from the current directory.
# shellcheck disable=SC1090
read -r BUDGET WRAP PTR < <(BSP_SOURCED=1 . "$HOOK"; printf '%s %s %s\n' "$BSP_ENVELOPE_BUDGET" "$BSP_WRAP_OVERHEAD" "$(bsp_bd_pointer | wc -c)")
[ -n "${BUDGET:-}" ] || { echo "FAIL: BSP_ENVELOPE_BUDGET not defined pre-seam"; fail=1; }
cd "$TMP/ws"
out=$(printf '{"session_id":"budget-a","source":"startup"}' | bash "$HOOK" --emit-plain)
sz=$(printf '%s\n' "$out" | wc -c)
[ "$sz" -le "${BUDGET:-0}" ] || { echo "FAIL: composed output ${sz}B > envelope budget ${BUDGET:-unset}B under overflow fixture"; fail=1; }
# the clamp must be visible, not silent: an over-cap hot page always carries the marker
printf '%s\n' "$out" | grep -qF "run mex-curator]" || { echo "FAIL: over-cap hot page clamped without the truncation marker"; fail=1; }
# floor deadlock guard: worst-case bootstrap (SKILL.md at its 6144B ceiling) must
# still leave room for the beads wrapper + pointer (stress-test B5 arithmetic)
[ $((BUDGET - CEILING - WRAP - PTR)) -ge 0 ] || { echo "FAIL: floor deadlock — budget cannot fit max bootstrap + pointer"; fail=1; }
if [ "$fail" = 0 ]; then
  echo "PASS: composed ${sz}B <= budget ${BUDGET}B under overflow fixture; floor margin $((BUDGET - CEILING - WRAP - PTR))B"
fi

# --- hard 10,000-CHAR threshold, measured on the real escaped string ---
# BSP_ENVELOPE_BUDGET counts RAW bytes; Claude Code's out-of-line threshold counts
# characters of the ESCAPED additionalContext, and escaping is expansive. Comparing
# raw bytes to the budget cannot catch the budget being set too high, so this runs
# the hook end-to-end in the Claude dialect against an escape-hostile fixture and
# measures the escaped string itself. 10000 is the harness's hard number — do NOT
# rewrite it in terms of a hook constant; that is the thing under test.
mkdir -p "$TMP/hostile/.mex"
printf 'router\n' > "$TMP/hostile/.mex/ROUTER.md"
# every byte escapes to two: quotes, backslashes, newlines only. ~8KB, well over cap.
hostile='""""\\\\'
for _ in $(seq 1 900); do printf '%s\n' "$hostile"; done > "$TMP/hostile/.mex/lessons.md"
cd "$TMP/hostile"
hout=$(printf '{"session_id":"budget-c","source":"startup"}' \
       | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK")
hesc=$(printf '%s\n' "$hout" | sed -n 's/^ *"additionalContext": "\(.*\)"$/\1/p')
if [ -z "$hesc" ]; then
  echo "FAIL: could not extract additionalContext from Claude-dialect output"; fail=1
elif [ "${#hesc}" -ge 10000 ]; then
  echo "FAIL: escaped additionalContext is ${#hesc} chars (>= the hard 10000 threshold)"; fail=1
else
  echo "PASS: escaped additionalContext ${#hesc} chars < 10000 under the escape-hostile fixture"
fi
cd "$TMP/ws"

# latency budget: full composition under 5s wall-clock
t0=$(date +%s)
printf '{"session_id":"budget-b","source":"startup"}' | bash "$HOOK" --emit-plain >/dev/null
t1=$(date +%s)
[ $((t1 - t0)) -lt 5 ] || { echo "FAIL: hook took $((t1 - t0))s (>=5s budget)"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "PASS: latency $((t1 - t0))s < 5s"
fi
exit "$fail"
