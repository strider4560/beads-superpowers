#!/usr/bin/env bash
# Sourced lib. resolve_bundle_root: echo the great_cto bundle root or fail
# with the install instruction. The hard dependency check of the pipeline.
# Task 14 raises GREAT_CTO_MIN_VERSION to the rework release.
GREAT_CTO_MIN_VERSION="3.0.0"
resolve_bundle_root() {
  local root="${HOME}/.agents/great_cto"
  if [ ! -d "$root" ]; then
    echo "ERROR: great_cto bundle root not found at $root" >&2
    echo "beads-superpowers requires great_cto. Install it:" >&2
    echo "  git clone https://github.com/strider4560/great_cto ~/Develop/great_cto && ~/Develop/great_cto/scripts/install.sh --host all" >&2
    return 1
  fi
  local ver
  ver="$(jq -r '.version // "0.0.0"' "$root/package.json" 2>/dev/null || echo "0.0.0")"
  if [ "$(printf '%s\n%s\n' "$GREAT_CTO_MIN_VERSION" "$ver" | sort -V | head -1)" != "$GREAT_CTO_MIN_VERSION" ]; then
    echo "ERROR: great_cto $ver installed but >= $GREAT_CTO_MIN_VERSION required. Update great_cto." >&2
    return 1
  fi
  echo "$root"
}
