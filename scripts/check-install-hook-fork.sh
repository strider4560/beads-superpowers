#!/usr/bin/env bash
# check-install-hook-fork.sh — anti-fork guard (bead bb6x): install.sh's written
# hook is either a thin exec shim of hooks/session-start (checkout tiers) or a
# policy-free minimal fallback (npx tier). Session-start composition policy —
# bd prime capture, envelope budgeting, and any retrieval/ranking the agent owns
# — lives ONLY in hooks/session-start; if any of these patterns reappear in
# install.sh, the 4th fork is back.
#
# What the npx fallback IS allowed to do: print static pointers and read the two
# mex hot-page files under the same 2048-byte cap ('head -c 2048 .mex/lessons.md'
# plus the truncation marker). Reading a file is not policy. Shelling out to the
# mex binary is — routing/ranking belongs to the agent at retrieval time, and a
# forked copy here would drift from the composer.
# 'salience' and 'bd memories --json' are the retired memory-selection surface
# (spec 2026-08-18); they stay pinned so a resurrection fails loudly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$ROOT/install.sh}"   # override for self-testing against a fixture
rc=0
# shellcheck disable=SC2016  # '$(bd prime' / '$(mex ' are literal forbidden patterns, not expansions
for pat in 'salience' 'bd memories --json' '$(bd prime' '$(mex ' 'BSP_MEX_CEILING' 'BSP_ENVELOPE_BUDGET'; do
  if hits=$(grep -nF -- "$pat" "$TARGET"); then
    echo "install-hook-fork: FAIL — forbidden pattern '$pat' in ${TARGET##*/}:"
    echo "$hits"
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "install-hook-fork: OK (no session-start policy forked into install.sh)"
exit "$rc"
