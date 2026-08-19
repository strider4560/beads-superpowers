#!/usr/bin/env bash
# tests/hooks/test-composer-assembly.sh
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/session-start"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/ws/.mex" "$TMP/bare" "$TMP/run"
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

echo "PASS: composer assembly"
