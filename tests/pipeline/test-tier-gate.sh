#!/usr/bin/env bash
# test-tier-gate.sh — contract for scripts/pipeline/tier-gate.sh.
# Every case runs the gate inside a mktemp working dir with HOME pointed at a
# mktemp home, so neither the real bundle root nor this repo's own session state
# file is ever read.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$root/scripts/pipeline/tier-gate.sh"
fixture="$root/tests/pipeline/fixtures/tier-map.json"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- sandbox builders -------------------------------------------------------

make_home() { # <name> -> path to an empty HOME (no bundle root)
  local home="$TMP/home-$1"; mkdir -p "$home"; printf '%s' "$home"
}
add_bundle() { # <home> <version> — bundle root with a package.json
  mkdir -p "$1/.agents/great_cto"
  printf '{"version":"%s"}\n' "$2" > "$1/.agents/great_cto/package.json"
}
add_tier_map() { # <home> — the fixture tier-map inside that bundle root
  mkdir -p "$1/.agents/great_cto/shared"
  cp -f "$fixture" "$1/.agents/great_cto/shared/tier-map.json"
}
make_cwd() { # <name> [model] [effort] -> path to a working dir
  local cwd="$TMP/cwd-$1" effort="null"; mkdir -p "$cwd"
  if [ -n "${2:-}" ]; then
    [ -n "${3:-}" ] && effort="\"$3\""
    mkdir -p "$cwd/.internal/pipeline"
    printf '{"model_id":"%s","effort":%s,"source":"hook","timestamp":"t"}\n' \
      "$2" "$effort" > "$cwd/.internal/pipeline/session.json"
  fi
  printf '%s' "$cwd"
}

# --- runner + assertion -----------------------------------------------------

run() { # <cwd> <home> <prog> [args...] — sets rc, out (stdout), err (stderr)
  # PATH_OVERRIDE, when set, replaces PATH for the gate only (jq-absence cases).
  # stdin comes from /dev/null so it is never a tty, whether this suite is
  # launched from an interactive terminal or from `just`. --assert refuses
  # without a tty, so leaving stdin inherited would make the suite non-deterministic.
  local cwd="$1" home="$2" prog="$3"; shift 3
  out="$(cd "$cwd" && HOME="$home" PATH="${PATH_OVERRIDE:-$PATH}" \
    "$BASH" "$prog" "$@" 2>"$TMP/stderr" </dev/null)"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

# The human path through --assert needs a real terminal on stdin. `script` is the
# only portable-ish way to get one; where it is missing or behaves differently
# (BSD/macOS take different flags) those cases report a visible SKIP.
pty_ok=0
if command -v script >/dev/null 2>&1 &&
   [ "$(script -qec '[ -t 0 ] && echo TTY' /dev/null 2>/dev/null | tr -d '\r\n')" = "TTY" ]; then
  pty_ok=1
fi

run_pty() { # <cwd> <home> <prog> [args...] — same, but with a pty on stdin
  local cwd="$1" home="$2" prog="$3" cmd a; shift 3
  cmd="$(printf 'cd %q && HOME=%q %q %q' "$cwd" "$home" "$BASH" "$prog")"
  for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
  out="$(script -qec "$cmd" /dev/null | tr -d '\r')"
  rc=$?
  err="$out"   # a pty merges stdout and stderr into one stream
}

check() { # <name> <want-exit> [<ere-pattern> [stdout|stderr]] — one PASS/FAIL line
  local name="$1" want="$2" pattern="${3:-}" stream="${4:-stdout}" detail="" hay=""
  if [ "$rc" -ne "$want" ]; then
    detail="exit $rc want $want"
  elif [ -n "$pattern" ]; then
    case "$stream" in stderr) hay="$err" ;; *) hay="$out" ;; esac
    printf '%s' "$hay" | grep -qE -- "$pattern" || detail="no /$pattern/ on $stream: $hay"
  fi
  if [ -z "$detail" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: $detail"
    fails=$((fails+1))
  fi
}

# --- fixtures ---------------------------------------------------------------

h_full="$(make_home full)";         add_bundle "$h_full" "3.0.0"; add_tier_map "$h_full"
h_nobundle="$(make_home nobundle)"
h_nomap="$(make_home nomap)";       add_bundle "$h_nomap" "3.0.0"

c_plan="$(make_cwd plan model-plan-1)"                       # effort null
c_eff_ok="$(make_cwd eff-ok model-plan-1 high)"
c_eff_bad="$(make_cwd eff-bad model-plan-1 low)"
c_unknown="$(make_cwd unknown model-not-in-map)"
c_none="$(make_cwd none)"                                    # no session state file
c_assert="$(make_cwd assert)"                                # tier assert file below
mkdir -p "$c_assert/.internal/pipeline"
printf 'planning\n' > "$c_assert/.internal/pipeline/tier-assert"
c_noassert="$(make_cwd noassert)"                            # --assert refusal cases
c_pty="$(make_cwd pty)"                                      # --assert under a pty
c_orch_only="$(make_cwd orch-only model-orch-only)"
c_review_only="$(make_cwd review-only model-review-only)"
c_multi="$(make_cwd multi model-orch-1)"                     # listed in two tiers
c_broken="$TMP/cwd-broken"; mkdir -p "$c_broken/.internal/pipeline"
printf '{"model_id": "model-plan-1",\n' > "$c_broken/.internal/pipeline/session.json"

# A PATH with no jq on it, for the missing-jq diagnosis case.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sort head cat mkdir; do ln -sf "$(command -v "$b")" "$nojq/$b"; done

# tier-gate.sh with no bundle-root.sh beside it, for the failed-source case.
orphan="$TMP/orphan"; mkdir -p "$orphan"
cp -f "$root/scripts/pipeline/tier-gate.sh" "$orphan/tier-gate.sh"

# A copy of the scripts with the minimum version raised, so the shipped
# GREAT_CTO_MIN_VERSION stays at great_cto's current version.
stale="$TMP/stale-scripts"; mkdir -p "$stale"
cp -f "$root/scripts/pipeline/bundle-root.sh" "$root/scripts/pipeline/tier-gate.sh" "$stale/"
sed -i 's/^GREAT_CTO_MIN_VERSION=.*/GREAT_CTO_MIN_VERSION="999.0.0"/' "$stale/bundle-root.sh"

# --- usage ------------------------------------------------------------------

run "$c_none" "$h_full" "$gate"
check "usage-no-args-exits-2" 2
check "usage-says-run-from-the-repo-root" 2 'run from the repo root' stderr

run "$c_none" "$h_full" "$gate" --stage bogus
check "usage-unknown-stage-exits-2" 2

# --- secondary harness ------------------------------------------------------

export BEADS_SP_HARNESS=secondary
run "$c_plan" "$h_full" "$gate" --stage planning
check "secondary-harness-exits-4" 4
check "secondary-harness-stdout-starts-with-SKIP" 4 '^SKIP'
unset BEADS_SP_HARNESS

# --- bundle root ------------------------------------------------------------

run "$c_plan" "$h_nobundle" "$gate" --stage planning
check "missing-bundle-root-exits-1" 1
check "missing-bundle-root-names-install-command" 1 'great_cto/scripts/install\.sh --host all' stderr

run "$c_plan" "$h_full" "$stale/tier-gate.sh" --stage planning
check "bundle-below-min-version-exits-1" 1
check "bundle-below-min-version-says-update-great_cto" 1 'Update great_cto' stderr

run "$c_plan" "$h_nomap" "$gate" --stage planning
check "missing-tier-map-exits-1" 1
check "missing-tier-map-names-the-tier-map" 1 'tier-map missing' stderr

# --- dependency diagnosis ---------------------------------------------------

PATH_OVERRIDE="$nojq"
run "$c_plan" "$h_nomap" "$gate" --stage planning
check "missing-jq-exits-1" 1
check "missing-jq-is-diagnosed-as-jq-not-as-a-stale-bundle" 1 'jq required' stderr
unset PATH_OVERRIDE

run "$c_plan" "$h_full" "$orphan/tier-gate.sh" --stage planning
check "unloadable-bundle-root-lib-exits-1" 1
check "unloadable-bundle-root-lib-names-the-lib" 1 'cannot load bundle-root\.sh' stderr

# --- session tier resolution ------------------------------------------------

run "$c_none" "$h_full" "$gate" --stage planning
check "no-session-and-no-tier-assert-exits-1" 1
check "no-session-tells-user-to-run-assert" 1 'tier-gate\.sh --assert' stderr

run "$c_assert" "$h_full" "$gate" --stage planning
check "tier-assert-file-unblocks-stage-entry" 0

run "$c_unknown" "$h_full" "$gate" --stage planning
check "model-absent-from-tier-map-exits-1" 1
check "model-absent-from-tier-map-names-the-model" 1 "model 'model-not-in-map' not in tier-map" stderr

run "$c_broken" "$h_full" "$gate" --stage planning
check "unparsable-session-json-exits-1" 1
check "unparsable-session-json-names-the-file" 1 'session\.json' stderr
if printf '%s' "$err" | grep -q -- '--assert'; then
  echo "FAIL unparsable-session-json-does-not-offer-the---assert-remedy: $err"; fails=$((fails+1))
else
  echo "PASS unparsable-session-json-does-not-offer-the---assert-remedy"
fi

# --- --assert is human-only -------------------------------------------------
# The terminal check sits ahead of the tier-name validation, so a non-tty caller
# passing a bogus tier is still refused as non-human rather than told its tier
# name is wrong.

run "$c_noassert" "$h_full" "$gate" --assert planning
check "assert-without-a-tty-exits-1" 1
check "assert-without-a-tty-says-human-only" 1 'human-only' stderr
if [ -e "$c_noassert/.internal/pipeline/tier-assert" ]; then
  echo "FAIL assert-without-a-tty-writes-no-tier-assert-file: the file was written"
  fails=$((fails+1))
else
  echo "PASS assert-without-a-tty-writes-no-tier-assert-file"
fi

run "$c_noassert" "$h_full" "$gate" --assert bogus
check "assert-unknown-tier-without-a-tty-is-refused-before-tier-validation" 1 'human-only' stderr

if [ "$pty_ok" -eq 1 ]; then
  run_pty "$c_pty" "$h_full" "$gate" --assert planning
  check "assert-with-a-tty-exits-0" 0
  if [ -f "$c_pty/.internal/pipeline/tier-assert" ]; then
    echo "PASS assert-with-a-tty-writes-the-tier-assert-file"
  else
    echo "FAIL assert-with-a-tty-writes-the-tier-assert-file: no file"
    fails=$((fails+1))
  fi
  run_pty "$c_pty" "$h_full" "$gate" --assert bogus
  check "assert-with-a-tty-unknown-tier-exits-2" 2
else
  echo "SKIP assert-with-a-tty-*: no working 'script' pty helper on this machine"
fi

# --- stage -> tier mapping --------------------------------------------------

run "$c_plan" "$h_full" "$gate" --stage planning
check "stage-planning-matches-planning-tier" 0
check "null-effort-prints-human-set-convention-advisory" 0 'intended session effort: high .* human-set convention'

run "$c_plan" "$h_full" "$gate" --stage implementing
check "stage-implementing-mismatch-exits-1" 1
check "stage-implementing-requires-implementation-orchestration-tier" 1 "requires tier 'implementation-orchestration'" stderr
check "stage-implementing-mismatch-names-found-tier" 1 "is 'planning'" stderr

run "$c_plan" "$h_full" "$gate" --stage reviewing
check "stage-reviewing-mismatch-exits-1" 1
check "stage-reviewing-requires-review-tier" 1 "requires tier 'review'" stderr

run "$c_orch_only" "$h_full" "$gate" --stage implementing
check "stage-implementing-passes-for-an-implementation-orchestration-model" 0

run "$c_review_only" "$h_full" "$gate" --stage reviewing
check "stage-reviewing-passes-for-a-review-model" 0

# A model listed in two tiers is in the wanted tier for both of them.
run "$c_multi" "$h_full" "$gate" --stage implementing
check "multi-tier-model-passes-implementing" 0
check "multi-tier-ok-line-names-one-tier" 0 '^tier-gate OK: implementation-orchestration \('

run "$c_multi" "$h_full" "$gate" --stage reviewing
check "multi-tier-model-passes-reviewing" 0
check "multi-tier-ok-line-names-one-tier-reviewing" 0 '^tier-gate OK: review \('

run "$c_multi" "$h_full" "$gate" --stage planning
check "multi-tier-model-still-fails-a-tier-it-is-not-in" 1
check "multi-tier-mismatch-lists-found-tiers-on-one-line" 1 \
  "is 'implementation-orchestration, review'" stderr

# --- session effort ---------------------------------------------------------

run "$c_eff_ok" "$h_full" "$gate" --stage planning
check "effort-matching-tier-map-exits-0" 0

run "$c_eff_bad" "$h_full" "$gate" --stage planning
check "effort-mismatch-exits-1" 1
check "effort-mismatch-names-found-effort" 1 "is 'low'" stderr
check "effort-mismatch-names-required-effort" 1 "requires session effort 'high'" stderr

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: tier-gate ($fails failing)"; exit 1; fi
echo "PASS: tier-gate"
