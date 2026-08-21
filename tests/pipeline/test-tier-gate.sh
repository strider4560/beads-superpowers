#!/usr/bin/env bash
# test-tier-gate.sh — contract for scripts/pipeline/tier-gate.sh.
# Exit: 0 pass, 1 fail-closed, 2 usage.
#
# Since the 2026-08-21 agent-authority rework the gate is a pipeline PREFLIGHT:
# it verifies the install (version handshake, integrity record, great_cto
# bundle presence at the floor) and reads NOTHING about the session — no model,
# no effort, no session id, no state files. The retired-behavior section pins
# that: fixtures that used to deny (unmapped model, absent session id, foreign
# session state) must now pass, and the removed --assert form is a usage error.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$root/scripts/pipeline/tier-gate.sh"
fixture="$root/tests/pipeline/fixtures/tier-map.json"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ -z "$TMP" ] || [ "$TMP" = "$HOME" ]; then
  echo "FAIL sandbox-home-differs-from-the-real-home: refusing to run against '$HOME'"
  exit 1
fi
echo "PASS sandbox-home-differs-from-the-real-home"

# --- sandbox builders -------------------------------------------------------

make_home() { local home="$TMP/home-$1"; mkdir -p "$home"; printf '%s' "$home"; }
add_bundle() { # <home> <version>
  mkdir -p "$1/.agents/great_cto"
  printf '{"version":"%s"}\n' "$2" > "$1/.agents/great_cto/package.json"
}
add_tier_map() { # <home>
  mkdir -p "$1/.agents/great_cto/shared"
  cp -f "$fixture" "$1/.agents/great_cto/shared/tier-map.json"
}

run() { # <cwd> <home> <args...> — sets rc, out, err
  local cwd="$1" home="$2"; shift 2
  ( cd "$cwd" && HOME="$home" PATH="${PATH_OVERRIDE:-$PATH}" \
      "$BASH" "${GATE_OVERRIDE:-$gate}" "$@" ) >"$TMP/stdout" 2>"$TMP/stderr"
  rc=$?
  out="$(cat "$TMP/stdout")"; err="$(cat "$TMP/stderr")"
  return 0
}

check() { # <name> <want-exit> [<ere on stderr+stdout>]
  local name="$1" want="$2" pattern="${3:-}" detail=""
  if [ "$rc" -ne "$want" ]; then
    detail="exit $rc want $want (stderr: $err)"
  elif [ -n "$pattern" ]; then
    printf '%s\n%s' "$err" "$out" | grep -qE -- "$pattern" || detail="no /$pattern/ in output: $err $out"
  fi
  if [ -z "$detail" ]; then echo "PASS $name"; else
    echo "FAIL $name: $detail"; fails=$((fails+1)); fi
}

# The satisfied-bundle version is READ from the shipped bundle-root.sh, never
# written as a literal: raising GREAT_CTO_MIN_VERSION would otherwise turn every
# case below into a version-check failure that still looks red for the wrong
# reason.
minver="$(sed -n 's/^GREAT_CTO_MIN_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$root/scripts/pipeline/bundle-root.sh")"
[ -n "$minver" ] || { echo "FAIL: cannot read GREAT_CTO_MIN_VERSION from bundle-root.sh" >&2; exit 1; }

h_full="$(make_home full)";     add_bundle "$h_full" "$minver"; add_tier_map "$h_full"
h_nobundle="$(make_home nobundle)"
h_old="$(make_home old)";       add_bundle "$h_old" "0.0.1";    add_tier_map "$h_old"
h_nomap="$(make_home nomap)";   add_bundle "$h_nomap" "$minver"
cwd="$TMP/cwd"; mkdir -p "$cwd"

# --- usage ------------------------------------------------------------------

run "$cwd" "$h_full"
check "usage-no-args-is-a-usage-error" 2 'usage'

run "$cwd" "$h_full" --stage
check "usage-stage-without-a-name-is-a-usage-error" 2 'usage'

run "$cwd" "$h_full" --stage deploying
check "usage-unknown-stage-is-a-usage-error" 2 'usage'

run "$cwd" "$h_full" --stage planning extra
check "usage-extra-args-are-a-usage-error" 2 'usage'

# The retired human-remedy form: an assert has nothing to assert any more, so
# the spelling is a usage error rather than a state write.
run "$cwd" "$h_full" --assert planning --session s-1
check "retired---assert-is-a-usage-error" 2 'usage'

# --- pass: the install preflight --------------------------------------------

run "$cwd" "$h_full" --stage planning
check "preflight-planning-passes" 0 'preflight OK'

run "$cwd" "$h_full" --stage implementing
check "preflight-implementing-passes" 0 'preflight OK'

run "$cwd" "$h_full" --stage reviewing
check "preflight-reviewing-passes" 0 'preflight OK'

# --- fail-closed: the install half ------------------------------------------

run "$cwd" "$h_nobundle" --stage planning
check "missing-bundle-root-fails-closed" 1 'great_cto'

run "$cwd" "$h_old" --stage planning
check "below-floor-bundle-fails-closed" 1 'required'

run "$cwd" "$h_nomap" --stage planning
check "missing-tier-map-fails-closed" 1 'tier-map'

# Version handshake: a gate running against a root whose package.json version
# differs from its own commit-time constant refuses (spec D3). The gate resolves
# the root two directories up from itself, so the skewed copy gets its own root.
skew="$TMP/skew-root"; mkdir -p "$skew/scripts/pipeline"
cp -f "$root/scripts/pipeline/tier-gate.sh" "$root/scripts/pipeline/bundle-root.sh" "$skew/scripts/pipeline/"
printf '{"version":"0.0.0-skewed"}\n' > "$skew/package.json"
GATE_OVERRIDE="$skew/scripts/pipeline/tier-gate.sh"
run "$cwd" "$h_full" --stage planning
unset GATE_OVERRIDE
check "version-handshake-mismatch-fails-closed" 1 'install\.sh'

# Missing jq is diagnosed as missing jq, not as a stale great_cto.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sed head cat grep sort; do ln -sf "$(command -v "$b")" "$nojq/$b"; done
PATH_OVERRIDE="$nojq"
run "$cwd" "$h_full" --stage planning
unset PATH_OVERRIDE
check "missing-jq-fails-closed-and-names-jq" 1 'jq'

# Integrity: a present anchor whose record does not verify fails the preflight.
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  h_anchor="$(make_home anchor)"; add_bundle "$h_anchor" "$minver"; add_tier_map "$h_anchor"
  mkdir -p "$h_anchor/.agents" "$TMP/anchor-target"
  ln -sfn "$TMP/anchor-target" "$h_anchor/.agents/beads-superpowers"
  mkdir -p "$h_anchor/.local/state/beads-superpowers"
  printf '{"anchor": ' > "$h_anchor/.local/state/beads-superpowers/record.json"
  run "$cwd" "$h_anchor" --stage planning
  check "integrity-unreadable-record-under-a-present-anchor-fails-closed" 1 'install\.sh'
else
  echo "SKIP integrity case (no sha256 tool)"
fi

# --- retired behavior: the session is not read --------------------------------
# Everything that used to brick a stage under the session-model tier wall must
# now be invisible to the gate.

# A state file recording a model no map ever listed, written by some other
# session, with no live session id exported: the old gate denied all three ways;
# the preflight reads none of it.
mkdir -p "$cwd/.internal/pipeline"
printf '{"model_id":"some-model[1m]","session_id":"another-session","effort":"low"}\n' \
  > "$cwd/.internal/pipeline/session.json"
printf 'v2 review some-other-session\n' > "$cwd/.internal/pipeline/tier-assert"
( unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true )
run "$cwd" "$h_full" --stage planning
check "retired-session-state-is-not-read" 0 'preflight OK'

run "$cwd" "$h_full" --stage implementing
check "retired-no-stage-is-tier-walled" 0 'preflight OK'

# BEADS_SP_HARNESS=secondary used to SKIP at exit 4 because the gate needed the
# session model and that harness could not supply one. The preflight needs no
# model, so the same env now runs the same checks.
( cd "$cwd" && HOME="$h_full" BEADS_SP_HARNESS=secondary "$BASH" "$gate" --stage planning ) \
  >"$TMP/stdout" 2>"$TMP/stderr"; rc=$?; out="$(cat "$TMP/stdout")"; err="$(cat "$TMP/stderr")"
check "retired-secondary-harness-no-longer-skips" 0 'preflight OK'

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: tier-gate ($fails failing)"; exit 1; fi
echo "PASS: tier-gate"
