#!/usr/bin/env bash
# test-source-flag.sh — install.sh --source installs from the local checkout, no network.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
fail=0
# install.sh hard-depends on the great_cto bundle root under $HOME, which is this
# sandbox -- provision it so the run reaches the --source path under test.
mkdir -p "$SANDBOX/.agents/great_cto"

HOME="$SANDBOX" BEADS_SUPERPOWERS_SKILLS_DIR="$SANDBOX/skills" \
  bash "$REPO_ROOT/install.sh" --yes --source "$REPO_ROOT" > "$SANDBOX/install.log" 2>&1 \
  || { echo "FAIL: install exited non-zero"; sed -n '1,30p' "$SANDBOX/install.log"; exit 1; }

# Every skill dir in the checkout must land
for d in "$REPO_ROOT"/skills/*/; do
  s=$(basename "$d")
  [ -d "$SANDBOX/skills/$s" ] || { echo "FAIL: skill not installed: $s"; fail=1; }
done
# Version file records the local tier
grep -q ":local$" "$SANDBOX/skills/.beads-superpowers-version" \
  || { echo "FAIL: version file missing ':local' tier"; fail=1; }
# Version came from package.json, not a network resolve
v=$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed -E 's/.*"([0-9][^"]*)".*/\1/')
grep -q "^${v}:" "$SANDBOX/skills/.beads-superpowers-version" \
  || { echo "FAIL: version file does not start with package.json version $v"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: --source local install"
exit "$fail"
