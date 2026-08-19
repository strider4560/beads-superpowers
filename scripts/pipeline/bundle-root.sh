#!/usr/bin/env bash
# Sourced lib. resolve_bundle_root: echo the great_cto bundle root or fail
# with the install instruction. The hard dependency check of the pipeline.
# GREAT_CTO_MIN_VERSION is the great_cto rework release: the pipeline needs
# planning-with-reviews without its wrapper role, implementing-epics without
# plan import, and shared/tier-map.json. great_cto ships that as a minor over
# 3.0.0. If it cuts the rework at a different version, this constant moves
# with it — nothing reconciles the two repos automatically.
GREAT_CTO_MIN_VERSION="3.1.0"
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

# resolve_session_tier <state-dir> <tier-map> — which tier(s) this session is in.
# The session state file's model is authoritative; the human-asserted tier file is
# the fallback for a session whose model the harness did not report. Prints one
# tier name per line on stdout. Empty output means "unresolved", which is not an
# error — the caller decides what an unknown tier costs it.
# Returns 1 only on broken state: an unparsable session file, or a model the
# tier-map does not list. Callers: tier-gate.sh, hooks/pipeline-guard.
resolve_session_tier() {
  local state_dir="$1" map="$2" session="$1/session.json" model tiers
  if [ -f "$session" ]; then
    jq -e . "$session" >/dev/null 2>&1 || {
      echo "ERROR: session state file '$session' is not valid JSON. Delete it and start a new session so the hook rewrites it." >&2
      return 1
    }
    model="$(jq -r '.model_id // empty' "$session")"
    if [ -n "$model" ]; then
      # A model may legitimately sit in more than one tier (orchestration and
      # review can share one), so this is membership, not a single resolved name.
      tiers="$(jq -r --arg m "$model" \
        '[.tiers | to_entries[] | select(.value.models | index($m)) | .key] | .[]' "$map")"
      [ -n "$tiers" ] || { echo "ERROR: model '$model' not in tier-map — update $map" >&2; return 1; }
      printf '%s\n' "$tiers"
      return 0
    fi
  fi
  [ -f "$state_dir/tier-assert" ] && cat "$state_dir/tier-assert"
  return 0
}
