#!/usr/bin/env bash
set -u
# tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier>
# Exit: 0 pass, 1 fail-closed, 2 usage, 4 visible SKIP (secondary harness).
# shellcheck source=scripts/pipeline/bundle-root.sh
. "$(dirname "$0")/bundle-root.sh" || { echo "ERROR: cannot load bundle-root.sh" >&2; exit 1; }

# Session state is read relative to the working directory, so the gate has to be
# run from the repo root. The usage string says so.
state_dir=".internal/pipeline"
usage() {
  echo "usage: tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier>" >&2
  echo "       run from the repo root — session state is read from ./$state_dir/" >&2
  exit 2
}
[ $# -eq 2 ] || usage

# --assert is the human remedy for a session whose model the harness did not
# report. Anything that can write the tier assert file can self-authorize any
# tier, so this branch refuses without an interactive terminal — a model's tool
# calls are never a tty. The check is the control; the "user-run only" wording
# below is only its label. Do not remove it as superfluous.
if [ "$1" = "--assert" ]; then
  [ -t 0 ] || { echo "ERROR: --assert is human-only; run it in an interactive shell" >&2; exit 1; }
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

# Checked before the bundle root so a missing jq is diagnosed as a missing jq,
# not as a stale great_cto (resolve_bundle_root reads the version with jq).
command -v jq >/dev/null || { echo "ERROR: jq required by tier-gate" >&2; exit 1; }

bundle="$(resolve_bundle_root)" || exit 1
map="$bundle/shared/tier-map.json"
[ -f "$map" ] || { echo "ERROR: tier-map missing at $map — update great_cto (see handoff doc)" >&2; exit 1; }

session="$state_dir/session.json"
# Tier resolution is shared with hooks/pipeline-guard — one implementation in
# bundle-root.sh, two callers.
tiers="$(resolve_session_tier "$state_dir" "$map")" || exit 1
got=""        # every tier this session's model is listed in, joined on one line
in_want=0     # 1 once the session is known to belong to the wanted tier
while IFS= read -r tier; do
  [ -n "$tier" ] || continue
  [ "$tier" = "$want" ] && in_want=1
  got="${got:+$got, }$tier"
done <<< "$tiers"
effort=""
[ -f "$session" ] && effort="$(jq -r '.effort // empty' "$session")"
if [ -z "$got" ]; then
  echo "ERROR: session tier unknown. Ask the user to run: bash scripts/pipeline/tier-gate.sh --assert <tier>" >&2
  exit 1
fi
if [ "$in_want" -ne 1 ]; then
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
  echo "tier-gate OK: $want (session effort: $effort)"
  exit 0
fi
echo "tier-gate OK: $want (intended session effort: $eff — human-set convention)"
exit 0
