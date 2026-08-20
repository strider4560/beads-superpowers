#!/usr/bin/env bash
# Sourced lib. resolve_bundle_root: echo the great_cto bundle root or fail
# with the install instruction. The hard dependency check of the pipeline.
# GREAT_CTO_MIN_VERSION is the great_cto rework release: the pipeline needs
# planning-with-reviews without its wrapper role, implementing-epics without
# plan import, and shared/tier-map.json. great_cto ships that as a minor over
# 3.0.0. If it cuts the rework at a different version, this constant moves
# with it — nothing reconciles the two repos automatically.
GREAT_CTO_MIN_VERSION="3.1.0"

# The beads-superpowers install anchor and the out-of-anchor integrity record
# that governs it. The record path is FIXED — never $XDG_STATE_HOME: the four
# actors that read or write it (install.sh, session-start, and the two gate
# surfaces) resolve env vars in four different process trees, and a
# writer/verifier divergence reads as record-absent, which is a hard deny
# (spec D3, R5-001). The record lives outside both anchors and outside any
# synced tree, so a dotfiles sync cannot propagate one host's hashes.
BSP_ANCHOR="${HOME}/.agents/beads-superpowers"
RECORD_PATH="${HOME}/.local/state/beads-superpowers/record.json"

resolve_bundle_root() {
  local root="${HOME}/.agents/great_cto"
  if [ ! -d "$root" ]; then
    echo "ERROR: great_cto bundle root not found at $root" >&2
    echo "beads-superpowers requires great_cto. Install it:" >&2
    echo "  git clone https://github.com/strider4560/great_cto ~/Develop/great_cto && ~/Develop/great_cto/scripts/install.sh --host all" >&2
    return 1
  fi
  # A root without the version file is the transition state on every host —
  # great_cto only started shipping package.json in the rework — and its remedy
  # is the installer re-run, not a version upgrade. Reporting it as "0.0.0
  # installed" sends the reader to the wrong fix.
  if [ ! -f "$root/package.json" ]; then
    echo "ERROR: bundle root predates the package.json link; re-run great_cto's scripts/install.sh --host all" >&2
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

# verify_record <script-dir> — verify the anchored install against its record.
# Returns 0 (nothing claimed, or the claim checks out) or 1 with one stderr line.
# Callers map 1 to their own surface's failure: exit 1 for the script gates,
# deny at exit 2 for the PreToolUse hook. The binding semantics are fixed and
# shared with the JS gate (spec D3, "Record-binding semantics"):
#   1. presence is tested on the anchor ENTRY (lstat) — a dangling symlink is
#      PRESENT, so its record check applies and fails closed instead of skipping;
#   2. the record is selected by anchor path, and the anchor's canonical target
#      must equal record.target — a repoint is reported as a repoint;
#   3. the hashes are verified over the files under record.target, the attested
#      root, not under whatever root this script was invoked from;
#   4. a gate running outside record.target is a repo-relative/dev invocation —
#      supported, not denied — and says so while still running checks 1-3.
verify_record() {
  local script_dir="$1" rec="$RECORD_PATH" anchor="$BSP_ANCHOR"
  [ -e "$anchor" ] || [ -L "$anchor" ] || return 0   # no anchor, no claim

  if [ ! -r "$rec" ] || ! jq -e . "$rec" >/dev/null 2>&1; then
    echo "ERROR: $anchor exists but its integrity record $rec is missing or unreadable — a root with no record is not trusted. Re-run beads-superpowers' install.sh (or start a session so the plugin-channel maintainer rewrites it)." >&2
    return 1
  fi
  local rec_anchor target posture
  rec_anchor="$(jq -r '.anchor // empty' "$rec")"
  target="$(jq -r '.target // empty' "$rec")"
  posture="$(jq -r '.posture // empty' "$rec")"
  # A record for a different anchor, or one with no target to attest, buys the
  # anchor nothing: it is unreadable, which is the same deny as absent.
  if [ "$rec_anchor" != "$anchor" ] || [ -z "$target" ]; then
    echo "ERROR: integrity record $rec does not describe $anchor (it records anchor '$rec_anchor', target '$target') — treat it as unreadable and re-run beads-superpowers' install.sh." >&2
    return 1
  fi

  local canon tcanon
  canon="$(cd "$anchor" 2>/dev/null && pwd -P)" || canon=""
  if [ -z "$canon" ]; then
    echo "ERROR: $anchor does not resolve (dangling symlink or unreadable directory); the record attests '$target'. Re-run beads-superpowers' install.sh." >&2
    return 1
  fi
  tcanon="$(cd "$target" 2>/dev/null && pwd -P)" || tcanon=""
  [ -n "$tcanon" ] || tcanon="$target"
  if [ "$canon" != "$tcanon" ]; then
    echo "ERROR: $anchor was repointed: it resolves to '$canon' but the record attests '$tcanon'. Re-run beads-superpowers' install.sh to re-attest, or restore the anchor." >&2
    return 1
  fi

  local sdir
  sdir="$(cd "$script_dir" 2>/dev/null && pwd -P)" || sdir=""
  case "$sdir" in
    "$tcanon"|"$tcanon"/*) ;;
    *) echo "NOTE: running unpinned copy (not the anchored install) at ${sdir:-$script_dir}; the anchored root at $anchor is still verified." >&2 ;;
  esac

  case "$posture" in
    dev-clone-advisory)
      # Advisory by DECLARATION, never by absence: an unpinned root says so in
      # its own record, so a deleted manifest can never masquerade as one.
      echo "NOTE: $anchor is advisory (unpinned root) by declared posture — its manifest is not verified." >&2
      return 0 ;;
    manifest-backed) ;;
    *)
      echo "ERROR: integrity record $rec declares no known posture ('$posture') — treat it as unreadable and re-run beads-superpowers' install.sh." >&2
      return 1 ;;
  esac

  local -a hasher
  if command -v sha256sum >/dev/null 2>&1; then hasher=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then hasher=(shasum -a 256)
  else
    # A hashing tool missing at verification time is treated exactly as an
    # unreadable record — the alternative is a silent pass on an unverified root.
    echo "ERROR: no sha256 tool on PATH (sha256sum or shasum): the integrity record $rec cannot be verified, which is treated as unreadable." >&2
    return 1
  fi
  # The manifest must BE a manifest: a missing, empty or non-object `hashes` on a
  # manifest-backed record would otherwise verify nothing and return 0.
  if ! jq -e '(.hashes | type) == "object" and (.hashes | length) > 0' "$rec" >/dev/null 2>&1; then
    echo "ERROR: integrity record $rec declares posture manifest-backed but carries no usable hash manifest — treat it as unreadable and re-run beads-superpowers' install.sh." >&2
    return 1
  fi
  local rel want got
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    want="$(jq -r --arg k "$rel" '.hashes[$k]' "$rec")"
    got="$("${hasher[@]}" "$tcanon/$rel" 2>/dev/null)" || got=""
    got="${got%% *}"
    if [ -z "$got" ]; then
      echo "ERROR: integrity record $rec lists '$rel' but it is missing or unreadable under $tcanon. Re-run beads-superpowers' install.sh." >&2
      return 1
    fi
    if [ "$got" != "$want" ]; then
      echo "ERROR: integrity check failed: $tcanon/$rel does not match its recorded hash. Restore the file, or re-run beads-superpowers' install.sh to re-attest the root." >&2
      return 1
    fi
  done < <(jq -r '.hashes | keys[]' "$rec")
  return 0
}

# resolve_session_tier <state-dir> <tier-map> [<live-session-id>] — which tier(s)
# this session is in.
# The session state file's model is authoritative; the human-asserted tier file is
# the fallback for a session whose model the harness did not report. Prints one
# tier name per line on stdout. Empty output means "unresolved", which is not an
# error — the caller decides what an unknown tier costs it.
# Returns 1 only on broken state: an unparsable session file, or a model the
# tier-map does not list. Callers: tier-gate.sh, hooks/pipeline-guard.
# With a live session id passed as $3 both sources are identity-bound (D4):
# state written by a DIFFERENT session, and a tier assert recorded for one, are
# treated as ABSENT rather than trusted — the caller's absent-data deny then
# covers the mismatch. The argument is optional so the PreToolUse guard, which
# resolves identity from its own payload, keeps its two-argument call site.
resolve_session_tier() {
  local state_dir="$1" map="$2" live="${3-}" bind=0 session="$1/session.json" model tiers
  [ "$#" -ge 3 ] && bind=1
  if [ -f "$session" ]; then
    jq -e . "$session" >/dev/null 2>&1 || {
      echo "ERROR: session state file '$session' is not valid JSON. Delete it and start a new session so the hook rewrites it." >&2
      return 1
    }
    if [ "$bind" -eq 1 ] &&
       ! jq -e --arg s "$live" '.session_id == $s' "$session" >/dev/null 2>&1; then
      model=""     # another session's state file — absent, not authoritative
    else
      model="$(jq -r '.model_id // empty' "$session")"
    fi
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
  # tier-assert is `v2 <tier> <session-id>` on one line. Anything else — the
  # legacy bare tier name, extra fields, an empty file — is treated as absent:
  # an assert that cannot be bound to a session is not an assert (D4).
  if [ -f "$state_dir/tier-assert" ]; then
    local ver="" tier="" sid="" extra=""
    read -r ver tier sid extra < "$state_dir/tier-assert" || true
    if [ "$ver" = "v2" ] && [ -n "$tier" ] && [ -n "$sid" ] && [ -z "$extra" ] &&
       { [ "$bind" -eq 0 ] || [ "$sid" = "$live" ]; }; then
      printf '%s\n' "$tier"
    fi
  fi
  return 0
}
