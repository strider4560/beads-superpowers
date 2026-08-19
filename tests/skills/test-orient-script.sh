#!/usr/bin/env bash
# tests/skills/test-orient-script.sh — run: bash tests/skills/test-orient-script.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/skills/getting-up-to-speed/scripts/orient.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" && cd "$TMP"
git init -q . && git commit -q --allow-empty -m init

# read-only guard: script source must contain no mutating commands
[ -f "$SCRIPT" ] || { echo "FAIL: script missing"; exit 1; }
grep -nE 'bd (create|close|update|remember|forget|init|delete)|bd dolt (push|pull)' "$SCRIPT" \
  && { echo "FAIL: mutating command in orient.sh"; exit 1; }

# with fake bd: all sections present
cat > "$TMP/bin/bd" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  ready)     printf 'ok ready row\n' ;;
  count)     printf 'Total: 3\nopen: 3\n' ;;
  query)     printf 'No issues found\n' ;;
  blocked)   printf 'No blocked issues\n' ;;
  memories)  printf 'Memories (3):\n' ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$TMP/bin/bd"
out=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT")
for s in scale ledger ready in-progress blocked mex handoff; do
  echo "$out" | grep -q "== $s ==" || { echo "FAIL: section $s missing"; exit 1; }
done

# handoff detection: newest inbox doc surfaced with raw freshness inputs
mkdir -p .internal/handoff
# shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution
printf '# H\n- branch @ `abc1234`\n' > .internal/handoff/2026-01-01-old-handoff.md
sleep 0.02 2>/dev/null || sleep 1
# shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution
printf '# H\n- branch @ `def5678`\n' > .internal/handoff/2026-01-02-new-handoff.md
out=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT")
echo "$out" | grep -q "2026-01-02-new-handoff.md" || { echo "FAIL: newest handoff not detected"; exit 1; }
echo "$out" | grep -q "doc_sha=def5678" || { echo "FAIL: doc sha not extracted"; exit 1; }
echo "$out" | grep -q "inbox_count=2" || { echo "FAIL: inbox count wrong"; exit 1; }

# no verdict language ever
echo "$out" | grep -qiE 'fresh|stale|consistent|verdict' && { echo "FAIL: verdict language in raw digest"; exit 1; }

# bd absent: visible SKIP, still exits 0
out2=$(PATH="/usr/bin:/bin" bash "$SCRIPT")
echo "$out2" | grep -q "SKIP" || { echo "FAIL: no visible SKIP without bd"; exit 1; }
echo "PASS: orient.sh"
