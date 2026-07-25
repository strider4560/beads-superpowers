#!/usr/bin/env bash
# tests/skills/test-sdd-scripts.sh — run: bash tests/skills/test-sdd-scripts.sh
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)/skills/subagent-driven-development"
WS="$SKILL_DIR/scripts/sdd-workspace"
TB="$SKILL_DIR/scripts/task-brief"
RP="$SKILL_DIR/scripts/review-package"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q . && git commit -q --allow-empty -m init

mkdir -p plans
cat > plans/alpha-plan.md <<'PLAN'
### Task 1: Alpha
alpha body
### Task 2: Second
second body
PLAN
cat > plans/beta-plan.md <<'PLAN'
### Task 1: Beta-One
beta-one body
PLAN

# 1. per-plan directory
dir=$("$WS" plans/alpha-plan.md)
case "$dir" in
  */.internal/sdd/alpha-plan) : ;;
  *) echo "FAIL: unexpected workspace path: $dir"; exit 1 ;;
esac
[ -d "$dir" ] || { echo "FAIL: workspace dir not created"; exit 1; }

# 2. different plans, different directories
dir2=$("$WS" plans/beta-plan.md)
[ "$dir" != "$dir2" ] || { echo "FAIL: two plans shared one workspace"; exit 1; }

# 3. no args -> exit 2
rc=0; "$WS" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: no-arg exit was $rc, want 2"; exit 1; }

# 4. missing plan -> exit 2, no fallback dir
rc=0; "$WS" plans/missing.md >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: missing-plan exit was $rc, want 2"; exit 1; }
[ ! -d "$(git rev-parse --show-toplevel)/.internal/sdd/missing" ] \
  || { echo "FAIL: created a workspace for a missing plan"; exit 1; }

# 5. self-ignoring base
base="$(git rev-parse --show-toplevel)/.internal/sdd"
[ "$(cat "$base/.gitignore")" = "*" ] || { echo "FAIL: base .gitignore not '*'"; exit 1; }

# 6. briefs do not collide across plans
"$TB" plans/alpha-plan.md 1 >/dev/null
"$TB" plans/beta-plan.md 1 >/dev/null
a="$dir/task-1-brief.md"; b="$dir2/task-1-brief.md"
if [ ! -f "$a" ] || [ ! -f "$b" ]; then
  echo "FAIL: briefs not in per-plan dirs"; exit 1
fi
grep -q "alpha body" "$a" || { echo "FAIL: alpha brief has wrong content"; exit 1; }
grep -q "beta-one body" "$b" || { echo "FAIL: beta brief has wrong content"; exit 1; }

# 7. explicit OUTFILE still overrides
"$TB" plans/alpha-plan.md 1 "$TMP/explicit-brief.md" >/dev/null
[ -f "$TMP/explicit-brief.md" ] || { echo "FAIL: OUTFILE override ignored"; exit 1; }

# 8. review-package rejects the old 3-arg shape
echo one > f.txt && git add f.txt && git commit -q -m c1
base_sha=$(git rev-parse HEAD)
echo two >> f.txt && git commit -q -am c2
head_sha=$(git rev-parse HEAD)
rc=0; "$RP" "$base_sha" "$head_sha" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: old-shape review-package exit $rc, want 2"; exit 1; }

# 9. review-package writes into the plan workspace
"$RP" plans/alpha-plan.md "$base_sha" "$head_sha" >/dev/null
found=$(find "$dir" -maxdepth 1 -name 'review-*.diff' | grep -c '' || true)
[ "$found" -eq 1 ] || { echo "FAIL: review diff not in plan workspace (found $found)"; exit 1; }

echo "PASS: sdd plan-scoped workspace + callers"
