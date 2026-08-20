#!/usr/bin/env bash
# test-tier-gate.sh — contract for scripts/pipeline/tier-gate.sh.
# Every case runs the gate inside a mktemp working dir with HOME pointed at a
# mktemp home, so neither the real bundle root nor this repo's own session state
# file is ever read. The sandbox HOME is load-bearing twice over now: the gate
# reads the install anchor ($HOME/.agents/beads-superpowers) and the integrity
# record ($HOME/.local/state/beads-superpowers/record.json) off HOME, so a case
# that leaked to the real HOME would read — and the record fixtures would write —
# the developer's own install. make_home refuses to hand back the real HOME.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$root/scripts/pipeline/tier-gate.sh"
fixture="$root/tests/pipeline/fixtures/tier-map.json"
real_home="$HOME"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The live session identifier every fixture session is written under. The gate
# reads it from CLAUDE_CODE_SESSION_ID (spike:
# .internal/research/2026-08-19-session-identity-spike.md).
LIVE_SID="11111111-2222-3333-4444-555555555555"
SID_ENV=(CLAUDE_CODE_SESSION_ID="$LIVE_SID")

# --- sandbox builders -------------------------------------------------------

make_home() { # <name> -> path to an empty HOME (no bundle root)
  local home="$TMP/home-$1"; mkdir -p "$home"
  # Fatal, not a FAIL line: every anchor/record case below writes under this
  # path, so a sandbox HOME that equalled the real one would damage the host
  # rather than report a failing contract.
  [ "$home" != "$real_home" ] || { echo "FATAL: sandbox HOME is the real HOME" >&2; exit 1; }
  printf '%s' "$home"
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
    printf '{"model_id":"%s","effort":%s,"session_id":"%s","source":"hook","timestamp":"t"}\n' \
      "$2" "$effort" "$LIVE_SID" > "$cwd/.internal/pipeline/session.json"
  fi
  printf '%s' "$cwd"
}

# A minimal beads-superpowers root: the two gate scripts plus the package.json
# the gate version-checks itself against. Used wherever a case needs a root that
# is NOT this repo (a raised version floor, a skewed version file).
make_root() { # <name> <package-version> -> path to the root
  local r="$TMP/root-$1"; mkdir -p "$r/scripts/pipeline"
  cp -f "$root/scripts/pipeline/bundle-root.sh" "$root/scripts/pipeline/tier-gate.sh" \
        "$r/scripts/pipeline/"
  printf '{"version":"%s"}\n' "$2" > "$r/package.json"
  printf '%s' "$r"
}

# sha256 over one file, by whichever tool this machine has. Empty sha_cmd means
# the record cases report a visible SKIP rather than a false PASS.
if command -v sha256sum >/dev/null 2>&1; then sha_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then sha_cmd=(shasum -a 256)
else sha_cmd=(); fi
sha() { local o; o="$("${sha_cmd[@]}" "$1")"; printf '%s' "${o%% *}"; }

write_record() { # <home> <target> <posture> — the out-of-anchor integrity record
  local rec="$1/.local/state/beads-superpowers" first=1 f
  mkdir -p "$rec"
  { printf '{"anchor":"%s/.agents/beads-superpowers","target":"%s","posture":"%s","version":"%s","hashes":{' \
      "$1" "$2" "$3" "$selfver"
    for f in scripts/pipeline/tier-gate.sh scripts/pipeline/bundle-root.sh \
             scripts/pipeline/graph-lint.mjs hooks/pipeline-guard; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s":"%s"' "$f" "$(sha "$2/$f")"
    done
    printf '}}\n'
  } > "$rec/record.json"
}

make_anchor_home() { # <name> <posture> -> home whose anchor symlinks a populated root
  local home target
  home="$(make_home "$1")"; add_bundle "$home" "$minver"; add_tier_map "$home"
  target="$TMP/target-$1"
  mkdir -p "$target/scripts/pipeline" "$target/hooks" "$home/.agents"
  cp -f "$root/scripts/pipeline/tier-gate.sh" "$root/scripts/pipeline/bundle-root.sh" \
        "$root/scripts/pipeline/graph-lint.mjs" "$target/scripts/pipeline/"
  cp -f "$root/hooks/pipeline-guard" "$target/hooks/"
  cp -f "$root/package.json" "$target/package.json"
  ln -sfn "$target" "$home/.agents/beads-superpowers"
  write_record "$home" "$target" "$2"
  printf '%s' "$home"
}

# --- runner + assertion -----------------------------------------------------

run() { # <cwd> <home> <prog> [args...] — sets rc, out (stdout), err (stderr)
  # PATH_OVERRIDE, when set, replaces PATH for the gate only (jq-absence cases).
  # SID_ENV carries the live session identifier; cases override it to forge a
  # different session (CLAUDE_CODE_SESSION_ID=other) or to remove it entirely
  # (-u CLAUDE_CODE_SESSION_ID), which is why this runs through `env`.
  # stdin comes from /dev/null so it is never a tty, whether this suite is
  # launched from an interactive terminal or from `just`. --assert refuses
  # without a tty, so leaving stdin inherited would make the suite non-deterministic.
  local cwd="$1" home="$2" prog="$3"; shift 3
  out="$(cd "$cwd" && env "${SID_ENV[@]}" HOME="$home" PATH="${PATH_OVERRIDE:-$PATH}" \
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

run_pty_cmd() { # <cwd> <home> <shell-command> — run one command line under a pty
  # Used verbatim on the printed --assert remedy: the contract is that the
  # remedy string the gate prints is runnable as-is from the invoking directory.
  local cmd
  cmd="$(printf 'cd %q && HOME=%q CLAUDE_CODE_SESSION_ID=%q %s' \
           "$1" "$2" "$LIVE_SID" "$3")"
  out="$(script -qec "$cmd" /dev/null | tr -d '\r')"
  rc=$?
  err="$out"   # a pty merges stdout and stderr into one stream
}

run_pty() { # <cwd> <home> <prog> [args...] — same, but with a pty on stdin
  local cwd="$1" home="$2" prog="$3" cmd a; shift 3
  cmd="$(printf '%q %q' "$BASH" "$prog")"
  for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
  run_pty_cmd "$cwd" "$home" "$cmd"
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

# The satisfied-bundle version is READ from the shipped bundle-root.sh, never
# written as a literal: raising GREAT_CTO_MIN_VERSION would otherwise turn every
# case below into a version-check failure that still looks red for the wrong
# reason. Same precaution as tests/install-shape/selftest.sh.
minver="$(sed -n 's/^GREAT_CTO_MIN_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$root/scripts/pipeline/bundle-root.sh")"
[ -n "$minver" ] || { echo "FAIL: cannot read GREAT_CTO_MIN_VERSION from bundle-root.sh" >&2; exit 1; }
# Same precaution for the gate's own version constant: a release bump must not
# turn every case below red on a literal this suite pinned.
selfver="$(sed -n 's/^BSP_PIPELINE_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$root/scripts/pipeline/tier-gate.sh")"
[ -n "$selfver" ] || { echo "FAIL: cannot read BSP_PIPELINE_VERSION from tier-gate.sh" >&2; exit 1; }

h_full="$(make_home full)";         add_bundle "$h_full" "$minver"; add_tier_map "$h_full"
h_nobundle="$(make_home nobundle)"
h_nomap="$(make_home nomap)";       add_bundle "$h_nomap" "$minver"
# A bundle root that predates great_cto's package.json link — the transition
# state on every host, not a "0.0.0 installed" bundle.
h_nopkg="$(make_home nopkg)";       mkdir -p "$h_nopkg/.agents/great_cto"; add_tier_map "$h_nopkg"

c_plan="$(make_cwd plan model-plan-1)"                       # effort null
c_eff_ok="$(make_cwd eff-ok model-plan-1 high)"
c_eff_bad="$(make_cwd eff-bad model-plan-1 low)"
c_unknown="$(make_cwd unknown model-not-in-map)"
c_none="$(make_cwd none)"                                    # no session state file
c_assert="$(make_cwd assert)"                                # tier assert file below
mkdir -p "$c_assert/.internal/pipeline"
printf 'v2 planning %s\n' "$LIVE_SID" > "$c_assert/.internal/pipeline/tier-assert"
c_legacy="$(make_cwd legacy)"                                # pre-v2 bare tier name
mkdir -p "$c_legacy/.internal/pipeline"
printf 'planning\n' > "$c_legacy/.internal/pipeline/tier-assert"
c_foreign="$(make_cwd foreign)"                              # v2 assert, another session
mkdir -p "$c_foreign/.internal/pipeline"
printf 'v2 planning other-session\n' > "$c_foreign/.internal/pipeline/tier-assert"
c_noassert="$(make_cwd noassert)"                            # --assert refusal cases
c_pty="$(make_cwd pty)"                                      # --assert under a pty
c_rt="$(make_cwd roundtrip)"                                 # printed-remedy round trip
c_orch_only="$(make_cwd orch-only model-orch-only)"
c_review_only="$(make_cwd review-only model-review-only)"
c_multi="$(make_cwd multi model-orch-1)"                     # listed in two tiers
c_broken="$TMP/cwd-broken"; mkdir -p "$c_broken/.internal/pipeline"
printf '{"model_id": "model-plan-1",\n' > "$c_broken/.internal/pipeline/session.json"

# A PATH with no jq on it, for the missing-jq diagnosis case.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sort head cat mkdir; do ln -sf "$(command -v "$b")" "$nojq/$b"; done

# The same PATH with jq restored but neither hash tool on it: a hashing tool
# that is unavailable at verification time is treated exactly as an unreadable
# record, so it must not degrade into a pass.
nohash="$TMP/bin-nohash"; mkdir -p "$nohash"
for b in bash dirname sort head cat mkdir jq; do ln -sf "$(command -v "$b")" "$nohash/$b"; done

# tier-gate.sh with no bundle-root.sh beside it, for the failed-source case.
orphan="$TMP/orphan"; mkdir -p "$orphan"
cp -f "$root/scripts/pipeline/tier-gate.sh" "$orphan/tier-gate.sh"

# A copy of the scripts with the minimum version raised, so the shipped
# GREAT_CTO_MIN_VERSION stays at great_cto's current version. It is a full mini
# root, not a bare pair of scripts: the gate version-checks itself against
# ../../package.json, so a rootless copy would fail that check first and the
# stale-bundle case would go red for the wrong reason.
r_stale="$(make_root stale "$selfver")"
sed -i 's/^GREAT_CTO_MIN_VERSION=.*/GREAT_CTO_MIN_VERSION="999.0.0"/' "$r_stale/scripts/pipeline/bundle-root.sh"

# A mini root whose version file disagrees with the gate's own constant.
r_verbad="$(make_root verbad 9.9.9)"

# Anchored-install fixtures. Each home carries $HOME/.agents/beads-superpowers
# as a symlink to a populated root plus the out-of-anchor integrity record.
if [ "${#sha_cmd[@]}" -gt 0 ]; then
  h_rec="$(make_anchor_home rec manifest-backed)"
  t_rec="$TMP/target-rec"
  h_adv="$(make_anchor_home adv dev-clone-advisory)"
  printf '\n# tampered\n' >> "$TMP/target-adv/scripts/pipeline/graph-lint.mjs"
  h_tamper="$(make_anchor_home tamper manifest-backed)"
  printf '\n# tampered\n' >> "$TMP/target-tamper/scripts/pipeline/graph-lint.mjs"
  # Anchor present, record deleted: a bare mkdir + stub scripts must be
  # fail-closed, not a silent win.
  h_norec="$(make_anchor_home norec manifest-backed)"
  rm -f "$h_norec/.local/state/beads-superpowers/record.json"
  # Anchor repointed after the record was written.
  h_repoint="$(make_anchor_home repoint manifest-backed)"
  mkdir -p "$TMP/elsewhere-repoint"
  ln -sfn "$TMP/elsewhere-repoint" "$h_repoint/.agents/beads-superpowers"
  # Dangling anchor symlink: present as an entry, so its record check applies.
  h_dangle="$(make_anchor_home dangle manifest-backed)"
  ln -sfn "$TMP/does-not-exist-dangle" "$h_dangle/.agents/beads-superpowers"
fi

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

run "$c_plan" "$h_full" "$r_stale/scripts/pipeline/tier-gate.sh" --stage planning
check "bundle-below-min-version-exits-1" 1
check "bundle-below-min-version-says-update-great_cto" 1 'Update great_cto' stderr

run "$c_plan" "$h_nopkg" "$gate" --stage planning
check "bundle-without-package-json-exits-1" 1
check "bundle-without-package-json-says-it-predates-the-link" 1 'predates the package\.json link' stderr
check "bundle-without-package-json-names-the-installer-re-run" 1 'install\.sh --host all' stderr
if printf '%s' "$err" | grep -q '0\.0\.0'; then
  echo "FAIL bundle-without-package-json-does-not-report-0.0.0-installed: $err"; fails=$((fails+1))
else
  echo "PASS bundle-without-package-json-does-not-report-0.0.0-installed"
fi

run "$c_plan" "$h_nomap" "$gate" --stage planning
check "missing-tier-map-exits-1" 1
check "missing-tier-map-names-the-tier-map" 1 'tier-map missing' stderr

# --- version pinning --------------------------------------------------------
# The gate refuses to run against a root it did not ship with: the constant and
# the version file travel together on both supported channels, so this covers
# every caller, great_cto's flag-less spellings included.

run "$c_plan" "$h_full" "$r_verbad/scripts/pipeline/tier-gate.sh" --stage planning
check "root-version-mismatch-exits-1" 1
check "root-version-mismatch-names-both-versions" 1 "$selfver.*9\.9\.9|9\.9\.9.*$selfver" stderr
check "root-version-mismatch-names-a-reinstall-remedy" 1 'install\.sh|plugin' stderr

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

# --- session identity (D4) --------------------------------------------------
# The state file and the tier assert are both bound to the session that wrote
# them. An absent or mismatched identifier is the same deny as absent session
# data, and the deny carries the live identifier plus a remedy derived from $0.

SID_ENV=(CLAUDE_CODE_SESSION_ID=live-b)
run "$c_plan" "$h_full" "$gate" --stage planning
check "session-written-by-another-session-exits-1" 1
check "identity-mismatch-prints-the-live-identifier" 1 'live-b' stderr
check "identity-mismatch-remedy-binds-the-live-identifier" 1 '--assert <tier> --session live-b' stderr
check "identity-mismatch-remedy-names-the-invoked-path" 1 "bash $gate --assert" stderr
SID_ENV=(CLAUDE_CODE_SESSION_ID="$LIVE_SID")

SID_ENV=(-u CLAUDE_CODE_SESSION_ID)
run "$c_plan" "$h_full" "$gate" --stage planning
check "absent-live-identifier-exits-1" 1
check "absent-live-identifier-names-the-variable" 1 'CLAUDE_CODE_SESSION_ID' stderr
SID_ENV=(CLAUDE_CODE_SESSION_ID="$LIVE_SID")

run "$c_legacy" "$h_full" "$gate" --stage planning
check "legacy-id-less-tier-assert-is-treated-as-absent" 1
check "legacy-tier-assert-still-offers-the-assert-remedy" 1 '--assert <tier> --session' stderr

run "$c_foreign" "$h_full" "$gate" --stage planning
check "tier-assert-bound-to-another-session-is-treated-as-absent" 1

# --- resolve_session_tier arity + the `-` sentinel (D4) ---------------------
# The live identifier is a REQUIRED third argument. An optional one makes the
# unbound path the silent default, so a caller that simply forgot it gets
# unbound behaviour with no signal. A surface that genuinely has no live
# identity spells that deliberately: `-`.
# These call the function directly rather than through the gate, because the
# gate can only ever produce the three-argument form.

check_empty() { # <name> <want-exit> — exit code plus empty stdout
  if [ "$rc" -ne "$2" ]; then
    echo "FAIL $1: exit $rc want $2"; fails=$((fails+1))
  elif [ -n "$out" ]; then
    echo "FAIL $1: stdout is not empty: $out"; fails=$((fails+1))
  else
    echo "PASS $1"
  fi
}

rst() { # <args...> — source bundle-root.sh and call resolve_session_tier
  out="$("$BASH" -c '
    . "$1/scripts/pipeline/bundle-root.sh"
    shift
    resolve_session_tier "$@"' _ "$root" "$@" 2>"$TMP/stderr")"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

arity_msg='resolve_session_tier requires exactly three arguments'
map_full="$h_full/.agents/great_cto/shared/tier-map.json"

rst "$c_assert/.internal/pipeline" "$map_full"
check "two-argument-call-exits-1" 1
check "two-argument-call-names-the-arity-contract" 1 "$arity_msg" stderr
check "two-argument-call-names-the-sentinel" 1 "'-'" stderr
if [ "$(printf '%s\n' "$err" | grep -c .)" -eq 1 ]; then
  echo "PASS arity-error-is-one-line"
else
  echo "FAIL arity-error-is-one-line: $err"; fails=$((fails+1))
fi
check_empty "two-argument-call-prints-no-tier" 1

rst "$c_assert/.internal/pipeline" "$map_full" "$LIVE_SID" extra
check "four-argument-call-exits-1" 1
check "four-argument-call-names-the-arity-contract" 1 "$arity_msg" stderr

rst
check "zero-argument-call-exits-1" 1
check "zero-argument-call-names-the-arity-contract" 1 "$arity_msg" stderr

# The sentinel: session.json binding is skipped, tier-assert v2 entries are
# treated ABSENT. The safer of the two readings — an unverified assert is the
# self-authorization path D4 exists to close, and an unresolved tier is an
# already-designed state for both callers (D17a).
rst "$c_assert/.internal/pipeline" "$map_full" -
check_empty "sentinel-treats-a-matching-v2-tier-assert-as-absent" 0

rst "$c_foreign/.internal/pipeline" "$map_full" -
check_empty "sentinel-treats-a-foreign-v2-tier-assert-as-absent" 0

rst "$c_legacy/.internal/pipeline" "$map_full" -
check_empty "sentinel-treats-a-legacy-tier-assert-as-absent" 0

# The other half of the sentinel: a session.json is still read, whoever wrote it.
c_othersession="$TMP/cwd-othersession"; mkdir -p "$c_othersession/.internal/pipeline"
printf '{"model_id":"model-plan-1","effort":null,"session_id":"some-other-session","source":"hook","timestamp":"t"}\n' \
  > "$c_othersession/.internal/pipeline/session.json"
rst "$c_othersession/.internal/pipeline" "$map_full" -
check "sentinel-skips-session-json-binding" 0 '^planning$'

# Bound calls are unchanged by the arity fix.
rst "$c_assert/.internal/pipeline" "$map_full" "$LIVE_SID"
check "bound-call-resolves-a-matching-v2-tier-assert" 0 '^planning$'

rst "$c_foreign/.internal/pipeline" "$map_full" "$LIVE_SID"
check_empty "bound-call-treats-a-foreign-v2-tier-assert-as-absent" 0

rst "$c_othersession/.internal/pipeline" "$map_full" "$LIVE_SID"
check_empty "bound-call-treats-another-sessions-state-file-as-absent" 0

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

run "$c_noassert" "$h_full" "$gate" --assert planning --session "$LIVE_SID"
check "assert-without-a-tty-exits-1" 1
check "assert-without-a-tty-says-human-only" 1 'human-only' stderr
if [ -e "$c_noassert/.internal/pipeline/tier-assert" ]; then
  echo "FAIL assert-without-a-tty-writes-no-tier-assert-file: the file was written"
  fails=$((fails+1))
else
  echo "PASS assert-without-a-tty-writes-no-tier-assert-file"
fi

run "$c_noassert" "$h_full" "$gate" --assert bogus --session "$LIVE_SID"
check "assert-unknown-tier-without-a-tty-is-refused-before-tier-validation" 1 'human-only' stderr

# An assert with no recorded identifier is treated as absent, so the gate never
# accepts the id-less form at all: it is a usage error, ahead of the tty check.
run "$c_noassert" "$h_full" "$gate" --assert planning
check "assert-without---session-exits-2" 2
check "assert-without---session-prints-the-four-argument-usage" 2 '--assert <tier> --session <id>' stderr

if [ "$pty_ok" -eq 1 ]; then
  run_pty "$c_pty" "$h_full" "$gate" --assert planning --session "$LIVE_SID"
  check "assert-with-a-tty-exits-0" 0
  if [ "$(cat "$c_pty/.internal/pipeline/tier-assert" 2>/dev/null)" = "v2 planning $LIVE_SID" ]; then
    echo "PASS assert-with-a-tty-writes-the-v2-session-bound-tier-assert-file"
  else
    echo "FAIL assert-with-a-tty-writes-the-v2-session-bound-tier-assert-file: $(cat "$c_pty/.internal/pipeline/tier-assert" 2>/dev/null)"
    fails=$((fails+1))
  fi
  run_pty "$c_pty" "$h_full" "$gate" --assert bogus --session "$LIVE_SID"
  check "assert-with-a-tty-unknown-tier-exits-2" 2

  # The round trip the acceptance criteria name: the deny prints a remedy, a
  # human runs it verbatim from a second (interactive) shell, and the gate then
  # passes. <tier> is the one placeholder the human fills in.
  run "$c_rt" "$h_full" "$gate" --stage planning
  check "round-trip-starts-from-a-deny" 1
  remedy="$(printf '%s\n' "$err" | sed -n 's/.*Ask the user to run: //p' | head -1)"
  remedy="${remedy/<tier>/planning}"
  if [ -n "$remedy" ]; then
    run_pty_cmd "$c_rt" "$h_full" "$remedy"
    check "round-trip-printed-remedy-runs-verbatim" 0
    run "$c_rt" "$h_full" "$gate" --stage planning
    check "round-trip-gate-passes-after-the-remedy" 0
  else
    echo "FAIL round-trip-printed-remedy-runs-verbatim: no remedy on stderr: $err"
    fails=$((fails+1))
  fi
else
  echo "SKIP assert-with-a-tty-* and round-trip-*: no working 'script' pty helper on this machine"
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

# --- integrity record -------------------------------------------------------
# Anchor presence is tested on the entry itself, the record is selected by
# anchor path, the anchor's canonical target must equal record.target, and the
# hashes are verified over the files under that target — not under whatever root
# this gate happens to be running from.

run "$c_plan" "$h_full" "$gate" --stage planning
check "no-anchor-means-no-record-claim" 0
if printf '%s' "$err" | grep -q 'integrity record'; then
  echo "FAIL no-anchor-does-not-mention-the-record: $err"; fails=$((fails+1))
else
  echo "PASS no-anchor-does-not-mention-the-record"
fi

if [ "${#sha_cmd[@]}" -eq 0 ]; then
  echo "SKIP integrity-record-*: no sha256sum or shasum on this machine"
else
  run "$c_plan" "$h_rec" "$gate" --stage planning
  check "valid-record-does-not-block-the-gate" 0
  check "gate-outside-the-attested-root-self-reports" 0 'running unpinned copy \(not the anchored install\)' stderr

  run "$c_plan" "$h_rec" "$t_rec/scripts/pipeline/tier-gate.sh" --stage planning
  check "gate-inside-the-attested-root-passes" 0
  if printf '%s' "$err" | grep -q 'running unpinned copy'; then
    echo "FAIL gate-inside-the-attested-root-does-not-self-report: $err"; fails=$((fails+1))
  else
    echo "PASS gate-inside-the-attested-root-does-not-self-report"
  fi

  run "$c_plan" "$h_tamper" "$gate" --stage planning
  check "tampered-manifest-file-exits-1" 1
  check "tampered-manifest-names-the-file-and-the-hash" 1 'graph-lint\.mjs.*hash' stderr

  run "$c_plan" "$h_norec" "$gate" --stage planning
  check "anchor-present-with-no-record-exits-1" 1
  check "record-absent-names-the-record-path" 1 '\.local/state/beads-superpowers/record\.json' stderr

  run "$c_plan" "$h_repoint" "$gate" --stage planning
  check "repointed-anchor-exits-1" 1
  check "repointed-anchor-names-the-repoint" 1 'repointed' stderr
  if printf '%s' "$err" | grep -q 'hash'; then
    echo "FAIL repointed-anchor-is-not-reported-as-a-hash-mismatch: $err"; fails=$((fails+1))
  else
    echo "PASS repointed-anchor-is-not-reported-as-a-hash-mismatch"
  fi

  run "$c_plan" "$h_dangle" "$gate" --stage planning
  check "dangling-anchor-symlink-is-present-so-the-record-check-applies" 1
  check "dangling-anchor-says-it-does-not-resolve" 1 'does not resolve' stderr

  run "$c_plan" "$h_adv" "$gate" --stage planning
  check "declared-dev-clone-advisory-posture-does-not-block" 0
  check "advisory-posture-is-reported" 0 'advisory \(unpinned root\)' stderr

  PATH_OVERRIDE="$nohash"
  run "$c_plan" "$h_rec" "$gate" --stage planning
  check "missing-hash-tool-is-treated-as-an-unreadable-record" 1
  check "missing-hash-tool-names-the-tools" 1 'sha256sum|shasum' stderr
  unset PATH_OVERRIDE

  # A malformed record must land on the unreadable-record deny, not verify
  # nothing and return 0.
  h_empty="$(make_anchor_home empty manifest-backed)"
  jq '.hashes = {}' "$h_empty/.local/state/beads-superpowers/record.json" \
    > "$TMP/empty-record.json" && cp -f "$TMP/empty-record.json" "$h_empty/.local/state/beads-superpowers/record.json"
  run "$c_plan" "$h_empty" "$gate" --stage planning
  check "manifest-backed-record-with-no-hashes-exits-1" 1
  check "manifest-backed-record-with-no-hashes-says-unreadable" 1 'unreadable' stderr

  h_other="$(make_anchor_home other manifest-backed)"
  jq '.anchor = "/somewhere/else"' "$h_other/.local/state/beads-superpowers/record.json" \
    > "$TMP/other-record.json" && cp -f "$TMP/other-record.json" "$h_other/.local/state/beads-superpowers/record.json"
  run "$c_plan" "$h_other" "$gate" --stage planning
  check "record-for-another-anchor-exits-1" 1
  check "record-for-another-anchor-says-it-does-not-describe-this-anchor" 1 'does not describe' stderr
fi

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: tier-gate ($fails failing)"; exit 1; fi
echo "PASS: tier-gate"
