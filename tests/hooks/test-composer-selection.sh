#!/usr/bin/env bash
# tests/hooks/test-composer-selection.sh — unit-tests the mex composer (bsp_compose_mex)
# through the BSP_SOURCED=1 seam. Byte-exact `cmp` against independently constructed
# fixtures: the 2 KB hot-page cap is a BYTE cap, so char-counting must fail here.
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/session-start"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

HEADER='## Durable Knowledge (mex)'
ROUTER='Router: read .mex/ROUTER.md for task-scoped pages. Retrieval: mex graph scope "<task>".'
MARKER='[truncated — lessons.md exceeds the 2 KB hot-page cap; run mex-curator]'
NUDGE='No .mex/ found — run the project-init skill to set up mex.'

# --- harness: bd/mex on PATH BOOBY-TRAPPED. The composer reads .mex/ files and must
# never shell out (routing/ranking is not hook policy) — a call fails the suite loudly.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'FAKE'
#!/usr/bin/env bash
echo "FAIL: composer shelled out to $(basename "$0") ($*)" >&2
exit 97
FAKE
cp -f "$TMP/bin/bd" "$TMP/bin/mex"
chmod +x "$TMP/bin/bd" "$TMP/bin/mex"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
BSP_SOURCED=1 . "$HOOK"

# constant is the product-wide hot-page cap (spec 2026-08-18)
[ "${BSP_MEX_CEILING:-unset}" = "2048" ] \
  || { echo "FAIL: BSP_MEX_CEILING is '${BSP_MEX_CEILING:-unset}', want 2048"; exit 1; }

# --- (a) router + lessons present -> header, router line, verbatim lessons, no marker
mkdir -p "$TMP/a/.mex"; cd "$TMP/a"
printf 'ROUTER BODY (never inlined — pointer only)\n' > .mex/ROUTER.md
printf 'LESSON ONE\nLESSON TWO\n' > .mex/lessons.md
{ printf '%s\n\n%s\n\n' "$HEADER" "$ROUTER"; printf 'LESSON ONE\nLESSON TWO\n'; } > "$TMP/a.want"
bsp_compose_mex > "$TMP/a.got"
cmp -s "$TMP/a.want" "$TMP/a.got" || { echo "FAIL (a): section not emitted verbatim"; diff "$TMP/a.want" "$TMP/a.got" || true; exit 1; }
grep -qF "ROUTER BODY" "$TMP/a.got" && { echo "FAIL (a): ROUTER.md inlined — it is a pointer, not payload"; exit 1; }

# --- (b) lessons > 2048 bytes -> EXACTLY the first 2048 bytes, then the marker.
# Fixture: 2048 'A' then a tail sentinel, so the expected prefix is known without
# re-deriving it from the implementation.
mkdir -p "$TMP/b/.mex"; cd "$TMP/b"
{ printf 'A%.0s' {1..2048}; printf '\nTAILSENTINEL\n'; } > .mex/lessons.md
{ printf '%s\n\n%s\n\n' "$HEADER" "$ROUTER"; printf 'A%.0s' {1..2048}; printf '\n%s\n' "$MARKER"; } > "$TMP/b.want"
bsp_compose_mex > "$TMP/b.got"
cmp -s "$TMP/b.want" "$TMP/b.got" || { echo "FAIL (b): over-cap page not clipped to 2048B + marker"; diff "$TMP/b.want" "$TMP/b.got" || true; exit 1; }
grep -qF "TAILSENTINEL" "$TMP/b.got" && { echo "FAIL (b): content past the cap injected"; exit 1; }

# frame-overhead invariant the assembly math depends on: everything the section adds
# around the lessons bytes (header + router + marker + separators) must fit the 256B
# reserve, or min(BSP_MEX_CEILING + 256, allowance) under-reserves.
overhead=$(( $(wc -c < "$TMP/b.got") - 2048 ))
[ "$overhead" -le 256 ] || { echo "FAIL (b): section frame is ${overhead}B > the 256B reserve"; exit 1; }

# --- (c) .mex/ absent -> the nudge line and NOTHING else
mkdir -p "$TMP/c"; cd "$TMP/c"
printf '%s\n' "$NUDGE" > "$TMP/c.want"
bsp_compose_mex > "$TMP/c.got"
cmp -s "$TMP/c.want" "$TMP/c.got" || { echo "FAIL (c): absent-store output is not the bare nudge line"; diff "$TMP/c.want" "$TMP/c.got" || true; exit 1; }

# --- (d) BYTES, not chars: em-dash is 3 bytes. 700 em-dashes = 2100B; the cap lands
# INSIDE the 683rd (682*3 = 2046, +2 = 2048), so the expected content is 682 whole
# em-dashes plus the first two bytes (E2 80) of a split one — and the marker must still
# arrive whole on its own line. Char-counting would emit 2048 CHARS (6144B).
mkdir -p "$TMP/d/.mex"; cd "$TMP/d"
{ printf '—%.0s' {1..700}; printf '\n'; } > .mex/lessons.md
{ printf '%s\n\n%s\n\n' "$HEADER" "$ROUTER"; printf '—%.0s' {1..682}; printf '\xe2\x80'; printf '\n%s\n' "$MARKER"; } > "$TMP/d.want"
bsp_compose_mex > "$TMP/d.got"
cmp -s "$TMP/d.want" "$TMP/d.got" || { echo "FAIL (d): multibyte page truncated on chars, not bytes"; cmp "$TMP/d.want" "$TMP/d.got" || true; exit 1; }
grep -qxF "$MARKER" "$TMP/d.got" || { echo "FAIL (d): marker split or fused into the truncated content"; exit 1; }

# --- (e) empty lessons.md -> header + router only, no empty block, no marker
mkdir -p "$TMP/e/.mex"; cd "$TMP/e"
: > .mex/lessons.md
printf '%s\n\n%s\n' "$HEADER" "$ROUTER" > "$TMP/e.want"
bsp_compose_mex > "$TMP/e.got"
cmp -s "$TMP/e.want" "$TMP/e.got" || { echo "FAIL (e): empty lessons.md did not collapse to header+router"; diff "$TMP/e.want" "$TMP/e.got" || true; exit 1; }
# same for a store with no lessons.md at all
rm -f .mex/lessons.md
bsp_compose_mex > "$TMP/e2.got"
cmp -s "$TMP/e.want" "$TMP/e2.got" || { echo "FAIL (e): missing lessons.md did not collapse to header+router"; diff "$TMP/e.want" "$TMP/e2.got" || true; exit 1; }

# --- (f) caller clamp: an explicit ceiling truncates the lessons portion FURTHER and
# keeps the marker (assembly passes the envelope remainder when it is below 2048).
cd "$TMP/b"
{ printf '%s\n\n%s\n\n' "$HEADER" "$ROUTER"; printf 'A%.0s' {1..100}; printf '\n%s\n' "$MARKER"; } > "$TMP/f.want"
bsp_compose_mex 100 > "$TMP/f.got"
cmp -s "$TMP/f.want" "$TMP/f.got" || { echo "FAIL (f): explicit ceiling not honoured"; diff "$TMP/f.want" "$TMP/f.got" || true; exit 1; }
# degenerate clamp: ceiling 0 drops the page but MUST keep the marker (silent loss is worse)
bsp_compose_mex 0 > "$TMP/f0.got"
grep -qxF "$MARKER" "$TMP/f0.got" || { echo "FAIL (f): zero ceiling dropped the truncation marker"; exit 1; }
grep -qF "AAAA" "$TMP/f0.got" && { echo "FAIL (f): content injected at ceiling 0"; exit 1; }

echo "PASS: mex composer (router pointer, 2048B byte cap, marker, absent-store nudge)"
