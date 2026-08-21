#!/usr/bin/env bash
set -u
# tier-gate.sh --stage <planning|implementing|reviewing>
# Exit: 0 pass, 1 fail-closed, 2 usage.
#
# Pipeline preflight. The name is historical — kept because it is a contract
# path great_cto's stage skills and the release preflight invoke verbatim.
# Since the 2026-08-21 agent-authority rework this gate verifies the INSTALL,
# never the session: it proves the anchored root is intact and the great_cto
# bundle is present at the required floor before a stage runs. It reads NOTHING
# about the session's model, size, or effort — the retired session-model tier
# wall bricked sessions whenever a harness reported a model spelling its map
# did not list, and no stage property ever actually depended on the model id.
# Model/effort per role remain dispatch-time economy (great_cto's
# shared/tier-map.json via resolve-role.mjs), not gated authority.
BSP_PIPELINE_VERSION="0.18.0"  # synced by bump-version.sh
# shellcheck source=scripts/pipeline/bundle-root.sh
. "$(dirname "$0")/bundle-root.sh" || { echo "ERROR: cannot load bundle-root.sh" >&2; exit 1; }

usage() {
  echo "usage: tier-gate.sh --stage <planning|implementing|reviewing>" >&2
  exit 2
}
[ "${1:-}" = "--stage" ] && [ $# -eq 2 ] || usage
case "$2" in
  planning|implementing|reviewing) ;;
  *) usage ;;
esac

# Checked before the bundle root so a missing jq is diagnosed as a missing jq,
# not as a stale great_cto (resolve_bundle_root reads the version with jq).
command -v jq >/dev/null || { echo "ERROR: jq required by tier-gate" >&2; exit 1; }

# Version pinning: the commit-time constant above against the root's version
# file. The two travel together on both supported channels, so this catches a
# gate running against a root it did not ship with — including great_cto's
# flag-less spellings, which have no other handshake (spec D3).
root_pkg="$(dirname "$0")/../../package.json"
root_ver="$(jq -r '.version // empty' "$root_pkg" 2>/dev/null)" || root_ver=""
if [ "$root_ver" != "$BSP_PIPELINE_VERSION" ]; then
  echo "ERROR: tier-gate $BSP_PIPELINE_VERSION is running against beads-superpowers root '${root_ver:-unreadable}' ($root_pkg). Re-run beads-superpowers' install.sh, or update the plugin, so the root and the gates match." >&2
  exit 1
fi

# The anchored install's integrity record. A repo-relative/dev invocation is
# supported: verify_record says so on stderr and still checks the anchor.
verify_record "$(dirname "$0")" || exit 1

bundle="$(resolve_bundle_root)" || exit 1
# Bundle completeness: shared/tier-map.json is dispatch policy (role → model
# economy, read by great_cto's resolve-role.mjs), and a bundle without it is a
# pre-rework great_cto the pipeline cannot dispatch through.
[ -f "$bundle/shared/tier-map.json" ] || { echo "ERROR: shared/tier-map.json missing under $bundle — update great_cto (see handoff doc)" >&2; exit 1; }

echo "pipeline preflight OK ($2): install verified, great_cto bundle present"
exit 0
