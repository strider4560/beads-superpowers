#!/usr/bin/env bash
set -u
# tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier>
# Exit: 0 pass, 1 fail-closed, 2 usage, 4 visible SKIP (secondary harness).
# shellcheck source=scripts/pipeline/bundle-root.sh
. "$(dirname "$0")/bundle-root.sh"

usage() { echo "usage: tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier>" >&2; exit 2; }
[ $# -eq 2 ] || usage

state_dir=".internal/pipeline"
if [ "$1" = "--assert" ]; then
  case "$2" in planning|implementation-orchestration|implementation|review) ;; *) usage ;; esac
  mkdir -p "$state_dir"
  printf '%s\n' "$2" > "$state_dir/tier-assert"
  echo "tier asserted: $2 (user-run only — the model never runs --assert)"
  exit 0
fi
[ "$1" = "--stage" ] || usage
case "$2" in
  planning) want="planning" ;;
  implementing) want="implementation-orchestration" ;;
  reviewing) want="review" ;;
  *) usage ;;
esac

if [ "${BEADS_SP_HARNESS:-}" = "secondary" ]; then
  echo "SKIP tier-gate: this harness does not expose the session model (secondary harness)"
  exit 4
fi

bundle="$(resolve_bundle_root)" || exit 1
map="$bundle/shared/tier-map.json"
[ -f "$map" ] || { echo "ERROR: tier-map missing at $map — update great_cto (see handoff doc)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required by tier-gate" >&2; exit 1; }

got=""
effort=""
if [ -f "$state_dir/session.json" ]; then
  model="$(jq -r '.model_id // empty' "$state_dir/session.json")"
  effort="$(jq -r '.effort // empty' "$state_dir/session.json")"
  if [ -n "$model" ]; then
    got="$(jq -r --arg m "$model" '.tiers | to_entries[] | select(.value.models | index($m)) | .key' "$map")"
    [ -n "$got" ] || { echo "ERROR: model '$model' not in tier-map — update $map" >&2; exit 1; }
  fi
fi
if [ -z "$got" ] && [ -f "$state_dir/tier-assert" ]; then
  got="$(cat "$state_dir/tier-assert")"
fi
if [ -z "$got" ]; then
  echo "ERROR: session tier unknown. Ask the user to run: bash scripts/pipeline/tier-gate.sh --assert <tier>" >&2
  exit 1
fi
if [ "$got" != "$want" ]; then
  echo "ERROR: stage '$1 $2' requires tier '$want' but this session is '$got'. Switch sessions/models." >&2
  exit 1
fi

eff="$(jq -r --arg t "$want" '.tiers[$t].session_effort // "default"' "$map")"
# The session effort is only script-detectable when the model supports the effort
# parameter (spike: .internal/research/2026-08-19-harness-detection-spike.md). A
# null effort is normal, not an error — it falls back to the human-set convention.
if [ -n "$effort" ]; then
  if [ "$effort" != "$eff" ]; then
    echo "ERROR: stage '$1 $2' requires session effort '$eff' but this session is '$effort'. Restart at the required effort." >&2
    exit 1
  fi
  echo "tier-gate OK: $got (session effort: $effort)"
  exit 0
fi
echo "tier-gate OK: $got (intended session effort: $eff — human-set convention)"
exit 0
