#!/usr/bin/env bash
set -u
# tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier> --session <id>
# Exit: 0 pass, 1 fail-closed, 2 usage, 4 visible SKIP (secondary harness).
BSP_PIPELINE_VERSION="0.18.0"  # synced by bump-version.sh
# shellcheck source=scripts/pipeline/bundle-root.sh
. "$(dirname "$0")/bundle-root.sh" || { echo "ERROR: cannot load bundle-root.sh" >&2; exit 1; }

# Session state is read relative to the working directory, so the gate has to be
# run from the repo root. The usage string says so.
state_dir=".internal/pipeline"
usage() {
  echo "usage: tier-gate.sh --stage <planning|implementing|reviewing> | --assert <tier> --session <id>" >&2
  echo "       run from the repo root — session state is read from ./$state_dir/" >&2
  exit 2
}
# Arity is validated per form, ahead of everything else: an assert with no
# recorded identifier is treated as absent by resolve_session_tier, so the
# id-less form is a usage error rather than a write that buys nothing.
case "${1:-}" in
  --assert) [ $# -eq 4 ] && [ "$3" = "--session" ] && [ -n "$4" ] || usage ;;
  --stage)  [ $# -eq 2 ] || usage ;;
  *) usage ;;
esac

# --assert is the human remedy for a session whose model the harness did not
# report. Anything that can write the tier assert file can self-authorize any
# tier, so this branch refuses without an interactive terminal — a model's tool
# calls are never a tty. The check is the control; the "user-run only" wording
# below is only its label. Do not remove it as superfluous.
if [ "$1" = "--assert" ]; then
  [ -t 0 ] || { echo "ERROR: --assert is human-only; run it in an interactive shell" >&2; exit 1; }
  case "$2" in planning|implementation-orchestration|implementation|review) ;; *) usage ;; esac
  mkdir -p "$state_dir"
  # v2 <tier> <session-id>: the format is self-describing so a legacy, id-less
  # file is recognisably legacy and treated as absent instead of trusted.
  printf 'v2 %s %s\n' "$2" "$4" > "$state_dir/tier-assert"
  echo "tier asserted: $2 for session $4 (user-run only — the model never runs --assert)"
  exit 0
fi
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
map="$bundle/shared/tier-map.json"
[ -f "$map" ] || { echo "ERROR: tier-map missing at $map — update great_cto (see handoff doc)" >&2; exit 1; }

session="$state_dir/session.json"
# The live session identifier. An absent one is the same deny as absent session
# data (D4): with nothing to bind state to, no state file and no assert can be
# attributed to this session, so trusting either would be trusting whatever the
# last session left behind.
live_sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$live_sid" ]; then
  echo "ERROR: no live session identifier — CLAUDE_CODE_SESSION_ID is unset, and an absent identifier is treated as absent session data. Run the stage from a session whose harness exports it." >&2
  exit 1
fi
# Tier resolution is shared with hooks/pipeline-guard — one implementation in
# bundle-root.sh, two callers.
tiers="$(resolve_session_tier "$state_dir" "$map" "$live_sid")" || exit 1
got=""        # every tier this session's model is listed in, joined on one line
in_want=0     # 1 once the session is known to belong to the wanted tier
while IFS= read -r tier; do
  [ -n "$tier" ] || continue
  [ "$tier" = "$want" ] && in_want=1
  got="${got:+$got, }$tier"
done <<< "$tiers"
effort=""
# Read only from a state file this session wrote — the same binding the tier
# resolution applies, so a foreign file never supplies the effort either.
if [ -f "$session" ] && jq -e --arg s "$live_sid" '.session_id == $s' "$session" >/dev/null 2>&1; then
  effort="$(jq -r '.effort // empty' "$session")"
fi
if [ -z "$got" ]; then
  # The remedy names the path this gate was actually invoked through and the
  # identifier the assert has to be bound to, so it is runnable verbatim.
  echo "ERROR: session tier unknown for live session '$live_sid' — no session state written by it, and no tier assert bound to it." >&2
  echo "       Ask the user to run: bash $0 --assert <tier> --session $live_sid" >&2
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
