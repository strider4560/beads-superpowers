#!/usr/bin/env bash
# tests/hooks/test-composer-assembly.sh
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/session-start"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/ws/.mex" "$TMP/bare" "$TMP/run" "$TMP/cap/.mex" "$TMP/nobd"
# Envelope constant read from the hook's own definition (single source of truth).
# Must run BEFORE any cd: sourcing re-resolves $0 (this script's relative path).
# shellcheck disable=SC1090
read -r BUDGET < <(BSP_SOURCED=1 . "$HOOK"; printf '%s\n' "$BSP_ENVELOPE_BUDGET")
[ -n "${BUDGET:-}" ] || { echo "FAIL: BSP_ENVELOPE_BUDGET not readable pre-seam"; exit 1; }
# bd-free PATH for the independence case: only the utilities the hook itself needs.
for _c in bash dirname cat sed tr cut id mkdir chmod find touch wc head grep; do
  _p=$(command -v "$_c") && ln -sf "$_p" "$TMP/nobd/$_c"
done
command -v bd >/dev/null 2>&1 && [ -e "$TMP/nobd/bd" ] && { echo "FAIL: bd leaked into the bd-free PATH"; exit 1; }
cat > "$TMP/bin/bd" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  config)   printf '' ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$TMP/bin/bd"
printf 'HOTPAGE LESSON BODY\n' > "$TMP/ws/.mex/lessons.md"
printf 'router body\n' > "$TMP/ws/.mex/ROUTER.md"
mkdir -p "$TMP/home/.claude"   # isolated HOME: a real dev machine's ~/.claude/settings.json may
                               # itself register a "bd prime" hook (e.g. via `bd setup claude`),
                               # which would trip the dedup guard and suppress <beads-context>
                               # (same isolation pattern as test-bd-prime-dedup.sh / test-session-start-warnings.sh)
export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
export XDG_RUNTIME_DIR="$TMP/run"   # marker isolation (Task 3 adds a dedup marker; this test must never touch real markers)
cd "$TMP/ws"   # .mex/ store; no .beads here; no settings files

# distinct stdin per invocation: each run its own event (dedup-marker-safe once Task 3 lands)
out=$(printf '{"session_id":"t2-a","source":"startup"}' | bash "$HOOK" --emit-plain)
echo "$out" | grep -q "hookSpecificOutput" && { echo "FAIL: JSON envelope in plain mode"; exit 1; }
echo "$out" | grep -q "## Durable Knowledge (mex)" || { echo "FAIL: mex section header absent"; exit 1; }
echo "$out" | grep -q "Router: read .mex/ROUTER.md" || { echo "FAIL: router pointer line absent"; exit 1; }
echo "$out" | grep -q "HOTPAGE LESSON BODY" || { echo "FAIL: composed lessons hot page absent"; exit 1; }
echo "$out" | grep -q "bd ready" || { echo "FAIL: bd pointer block absent"; exit 1; }
echo "$out" | grep -q "Persistent Memories" && { echo "FAIL: retired memory section present"; exit 1; }

# JSON mode still emits envelope (distinct session id → distinct event)
outj=$(printf '{"session_id":"t2-b","source":"startup"}' | CLAUDE_PLUGIN_ROOT=x bash "$HOOK")
echo "$outj" | grep -q '"hookSpecificOutput"' || { echo "FAIL: JSON envelope missing"; exit 1; }
echo "$outj" | grep -q 'HOTPAGE LESSON BODY' || { echo "FAIL: composed lessons hot page absent from JSON mode"; exit 1; }

# no .mex/ store → in-context nudge, no header, no stale lessons content
cd "$TMP/bare"
outn=$(printf '{"session_id":"t2-c","source":"startup"}' | bash "$HOOK" --emit-plain)
echo "$outn" | grep -qF "No .mex/ found — run the project-init skill to set up mex." || { echo "FAIL: absent-store nudge not injected"; exit 1; }
echo "$outn" | grep -q "## Durable Knowledge (mex)" && { echo "FAIL: section header emitted without a store"; exit 1; }
echo "$outn" | grep -q "bd ready" || { echo "FAIL: bd pointer block absent in nudge mode"; exit 1; }

# --- product contract: a cap-COMPLIANT hot page (exactly 2048B) must inject WHOLE.
# End-to-end through the real assembly, so the envelope arithmetic is what is proven,
# not the composer's default ceiling. 2048 'A' with no trailing newline: the injected
# run must be exactly 2048 long, with no truncation marker, and the whole output must
# still fit the envelope budget.
printf 'A%.0s' {1..2048} > "$TMP/cap/.mex/lessons.md"
printf 'router body\n' > "$TMP/cap/.mex/ROUTER.md"
[ "$(wc -c < "$TMP/cap/.mex/lessons.md")" = 2048 ] || { echo "FAIL: cap fixture is not exactly 2048B"; exit 1; }
cd "$TMP/cap"
outc=$(printf '{"session_id":"t2-d","source":"startup"}' | bash "$HOOK" --emit-plain)
run=$(printf '%s\n' "$outc" | grep -oE 'A{100,}' | awk '{print length}')
[ "${run:-0}" = 2048 ] || { echo "FAIL: cap-compliant hot page injected ${run:-0}B, want 2048B whole"; exit 1; }
printf '%s\n' "$outc" | grep -qF "run mex-curator]" && { echo "FAIL: truncation marker on a cap-compliant page"; exit 1; }
szc=$(printf '%s\n' "$outc" | wc -c)
[ "$szc" -le "$BUDGET" ] || { echo "FAIL: whole 2048B page pushes output to ${szc}B > envelope ${BUDGET}B"; exit 1; }

# --- mex is independent of bd: a .mex/ store with bd absent from PATH still gets the
# Durable Knowledge section (durable knowledge is a mex store, not a beads feature).
cd "$TMP/ws"
outb=$(printf '{"session_id":"t2-e","source":"startup"}' | env -i PATH="$TMP/nobd" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" bash "$HOOK" --emit-plain 2>/dev/null)
echo "$outb" | grep -q "## Durable Knowledge (mex)" || { echo "FAIL: mex section suppressed when bd is absent"; exit 1; }
echo "$outb" | grep -q "HOTPAGE LESSON BODY" || { echo "FAIL: hot page suppressed when bd is absent"; exit 1; }
echo "$outb" | grep -q "bd ready" && { echo "FAIL: bd pointer emitted with bd absent"; exit 1; }
# and the absent-store nudge survives a bd-free environment too
cd "$TMP/bare"
outbn=$(printf '{"session_id":"t2-f","source":"startup"}' | env -i PATH="$TMP/nobd" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" bash "$HOOK" --emit-plain 2>/dev/null)
echo "$outbn" | grep -qF "No .mex/ found — run the project-init skill to set up mex." || { echo "FAIL: absent-store nudge suppressed when bd is absent"; exit 1; }

echo "PASS: composer assembly"
