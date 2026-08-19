#!/usr/bin/env bash
# assert-tier-b.sh <harness> — Tier B: best-effort harnesses get GUIDANCE, not files.
# Asserts: detection fires + native-install hint prints (drift-prone user-facing string),
# in-repo manifest (if any) parses + version-matches. Nothing else is claimed.
set -uo pipefail
# shellcheck source=tests/install-shape/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HARNESS="$1"
row=$(awk -F'\t' -v h="$HARNESS" '$1==h' "$REPO_ROOT/tests/install-shape/tier-b.tsv")
[ -n "$row" ] || { echo "FAIL: no tier-b.tsv row for $HARNESS"; exit 1; }
BIN=$(echo "$row" | cut -f2)
MANIFEST=$(echo "$row" | cut -f3)
HINT=$(echo "$row" | cut -f4)
MEX_HINT=$(echo "$row" | cut -f5)

shape_sandbox_setup "$BIN"
trap 'shape_sandbox_teardown' EXIT
shape_install

assert_in_log "$HINT"
# Tier B gets no files, but the mex dependency is stated to every harness alike.
assert_in_log "$MEX_HINT"
assert_npm_untouched
assert_shims_never_invoked
# Tier B receives no per-harness files from install.sh — prove we don't pretend otherwise:
assert_no_file "$SANDBOX/.$HARNESS"

if [ "$MANIFEST" != "-" ]; then
  assert_file "$REPO_ROOT/$MANIFEST"
  PKG_V=$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed -E 's/.*"([0-9][^"]*)".*/\1/')
  assert_json "$REPO_ROOT/$MANIFEST" "d.get('version') == '$PKG_V'"
fi

shape_sandbox_teardown
fail_count
