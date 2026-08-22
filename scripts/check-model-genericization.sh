#!/usr/bin/env bash
# check-model-genericization.sh — bd-1f5w: hardcoded Claude model names
# (haiku/sonnet/opus/fable) must not appear in harness-neutral distributed
# content — the plugin ships to 10 harnesses where those names mean nothing.
# Skills phrase model choice as capability tiers ("fast/cheap model",
# "stronger model"). Allowlisted as deliberately harness-specific (ADR-0041
# pattern): skills/using-superpowers/references/ and
# example-workflow/agents/yegge.md. docs/ is scanned too (published site
# prose ships harness-neutral, same as skills/) except docs/decisions/,
# which CLAUDE.md documents as gitignored local ADR working notes, not
# distributed product content — ADR prose narrates real model names on
# purpose (beads-superpowers-cv6.2).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
if [ "$#" -gt 0 ]; then ROOTS=("$@"); else ROOTS=(skills hooks docs); fi
ALLOW_RE='^[^:]*(skills/using-superpowers/references/|example-workflow/agents/yegge\.md|docs/decisions/)'   # path-field anchored
VIOLATIONS="$(grep -rniE '\b(haiku|sonnet|opus|fable)\b' "${ROOTS[@]}" 2>/dev/null | grep -Ev "$ALLOW_RE" || true)"
if [ -n "$VIOLATIONS" ]; then
  echo "model-genericization: FAIL — hardcoded model name outside the allowlist (capability tiers only, bd-1f5w):"
  echo "$VIOLATIONS"
  exit 1
fi
echo "model-genericization: OK (no hardcoded Claude model names in harness-neutral content)"
