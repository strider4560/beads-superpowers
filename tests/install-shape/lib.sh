#!/usr/bin/env bash
# lib.sh — shared helpers for the install-shape suite. Sourced, not executed.
# Proves artifacts land where each harness expects — does NOT prove hooks fire.
# SHAPE_REPO_ROOT override exists for selftest.sh (guard-the-guards mutations).
set -uo pipefail

REPO_ROOT="${SHAPE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Yardstick for assert_all_skills — decoupled from the install source so selftest.sh
# can install from a mutated copy while comparing against the real checkout.
EXPECTED_SKILLS_ROOT="${SHAPE_EXPECTED_ROOT:-$REPO_ROOT}"
# The mex pin the suite holds install.sh to. Deliberately a literal, NOT read from
# install.sh — a test that derives the expected value from the code under test can
# never catch an unpinning (selftest.sh mutates the invocation and expects red).
SHAPE_MEX_PIN="0.7.1"
# The tree the sandboxed install is fed with. Defaults to the checkout; cases that
# need a DOCTORED source (an old release, a partial tree) point it at their own
# copy and set it back afterwards.
SHAPE_INSTALL_SOURCE="${SHAPE_INSTALL_SOURCE:-$REPO_ROOT}"
FAILS=0

_fail() { echo "   FAIL: $*"; FAILS=$((FAILS + 1)); }
_pass() { echo "   ok:   $*"; }
fail_count() { return "$FAILS"; }

# shape_sandbox_setup <binary>... — fresh sandbox HOME + shims for the named binaries.
shape_sandbox_setup() {
  SANDBOX=$(mktemp -d)
  # Hard isolation, checked before anything writes: every case runs with
  # HOME=$SANDBOX and mutates $HOME/.claude, $HOME/.agents/beads-superpowers and
  # $HOME/.local/state/beads-superpowers — including deletes and tamper/restore
  # steps. A sandbox that ever resolved to the real HOME would take the
  # developer's own install with it, so the suite stops rather than assert its
  # way around a failed mktemp.
  if [ -z "${SANDBOX:-}" ] || [ "$SANDBOX" = "$HOME" ] || [ "$SANDBOX" = "/" ]; then
    echo "   FATAL: sandbox HOME '${SANDBOX:-}' is not isolated from the real HOME '$HOME'" >&2
    exit 1
  fi
  SHIM_DIR="$SANDBOX/.shims"
  MARKER_DIR="$SANDBOX/.markers"
  bash "$REPO_ROOT/tests/install-shape/fixtures/make-shims.sh" "$SHIM_DIR" "$MARKER_DIR" "$@"
  # install.sh's setup_hooks hard-depends on python3; the restricted PATH below could
  # starve it on hosts where python3 lives outside /usr/bin (mise, brew, macOS).
  # Pin the host-resolved interpreter into the shim dir (stress-test plan-B1).
  ln -sf "$(command -v python3)" "$SHIM_DIR/python3"
  # mex is a hard dependency of install.sh (check_mex aborts without it), so every
  # sandbox gets a satisfied environment by default: a mex at the pin, a node at
  # mex-agent's floor, and an npm that can only ever LOG — never install. These are
  # answering stubs, not the inert marker shims above: they are meant to be invoked,
  # so they must not touch MARKER_DIR (assert_shims_never_invoked stays meaningful).
  shape_stub_mex "$SHAPE_MEX_PIN"
  shape_stub_node "v22.5.0"
  # Real npm must never be reachable from a shape test. This stub records the
  # argv and fails, so an install that shells out to npm is both visible and inert.
  cat > "$SHIM_DIR/npm" << STUB
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/npm-invocations.log"
exit 1
STUB
  chmod +x "$SHIM_DIR/npm"
  # Minimal PATH: shims + system dirs. Deliberately excludes the user's real PATH
  # so a real claude/codex/npx on this machine can't leak into detection.
  SANDBOX_PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
}

# shape_stub_mex <version> — (re)write the answering mex stub. `mex --version`
# prints <version>; anything else is a silent no-op success.
shape_stub_mex() {
  cat > "$SHIM_DIR/mex" << STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && echo "$1"
exit 0
STUB
  chmod +x "$SHIM_DIR/mex"
}

# shape_stub_node <version> — (re)write the answering node stub (e.g. "v22.5.0").
# Negative cases call it again with a below-floor version.
shape_stub_node() {
  cat > "$SHIM_DIR/node" << STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && echo "$1"
exit 0
STUB
  chmod +x "$SHIM_DIR/node"
}

shape_sandbox_teardown() { rm -rf "$SANDBOX"; }

# _shape_run_install [extra-flags...] — the sandboxed install invocation itself.
# Sets INSTALL_RC; asserts nothing (callers decide what the expected outcome is).
_shape_run_install() {
  HOME="$SANDBOX" BEADS_SUPERPOWERS_SKILLS_DIR="$SANDBOX/skills" PATH="$SANDBOX_PATH" \
    bash "$REPO_ROOT/install.sh" --yes --source "$SHAPE_INSTALL_SOURCE" "$@" > "$SANDBOX/install.log" 2>&1
  INSTALL_RC=$?
}

# shape_install [extra-flags...] — run the local-source install inside the sandbox.
shape_install() {
  _shape_run_install "$@"
  [ "$INSTALL_RC" -eq 0 ] || { _fail "install.sh exited $INSTALL_RC"; sed -n '1,25p' "$SANDBOX/install.log"; }
}

# shape_install_expect_abort [extra-flags...] — for negative cases: the install
# MUST exit non-zero. A zero exit is the failure (a silent half-install).
shape_install_expect_abort() {
  _shape_run_install "$@"
  # shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
  [ "$INSTALL_RC" -ne 0 ] && _pass "install.sh aborted (exit $INSTALL_RC) as expected" \
    || { _fail "install.sh exited 0; expected an abort"; sed -n '1,25p' "$SANDBOX/install.log"; }
}

shape_uninstall() {
  HOME="$SANDBOX" BEADS_SUPERPOWERS_SKILLS_DIR="$SANDBOX/skills" PATH="$SANDBOX_PATH" \
    bash "$REPO_ROOT/install.sh" --yes --uninstall > "$SANDBOX/uninstall.log" 2>&1 \
    || _fail "uninstall exited non-zero"
}

# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
assert_file()    { [ -f "$1" ] && _pass "file $1" || _fail "missing file: $1"; }
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
assert_no_file() { [ ! -e "$1" ] && _pass "absent $1" || _fail "should not exist: $1"; }
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
assert_dir()     { [ -d "$1" ] && _pass "dir $1" || _fail "missing dir: $1"; }

# assert_json <file> <python-expr over parsed json bound to d>
assert_json() {
  local f="$1" expr="$2"
  if python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(0 if ($expr) else 1)" 2>/dev/null; then
    _pass "json $f :: $expr"
  else
    _fail "json assertion failed on $f :: $expr"
  fi
}

# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
assert_in_log()     { grep -qF -- "$1" "$SANDBOX/install.log" && _pass "log has: $1" || _fail "log missing: $1"; }
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
assert_not_in_log() { grep -qF -- "$1" "$SANDBOX/install.log" && _fail "log should NOT have: $1" || _pass "log lacks: $1"; }

# The install must tell the user, in words, which mex it depends on — the pinned
# coordinate, not a vague "mex". Drift-prone user-facing string, same class as the
# Tier B native-install hints.
assert_mex_advertised() { assert_in_log "mex-agent@$SHAPE_MEX_PIN"; }

# No npm call at all. The positive cases run with mex already present, and an
# installer that reaches for npm anyway is mutating a machine it was not asked to.
assert_npm_untouched() {
  local log="$SANDBOX/npm-invocations.log"
  if [ ! -s "$log" ]; then
    _pass "npm never invoked"
  else
    _fail "npm was invoked: $(tr '\n' ';' < "$log")"
  fi
}

# Exactly one npm call, and it names the pin. Catches both "installed nothing" and
# "installed something unpinned" (mex-agent@latest).
assert_npm_attempted_pinned() {
  local log="$SANDBOX/npm-invocations.log" total matched
  if [ ! -f "$log" ]; then
    _fail "npm was never invoked; expected one pinned install"
    return
  fi
  total=$(wc -l < "$log" | tr -d ' ')
  matched=$(grep -cF -- "install -g mex-agent@$SHAPE_MEX_PIN" "$log")
  if [ "$total" = 1 ] && [ "$matched" = 1 ]; then
    _pass "npm invoked exactly once, pinned: install -g mex-agent@$SHAPE_MEX_PIN"
  else
    _fail "expected exactly one 'install -g mex-agent@$SHAPE_MEX_PIN'; log has $total line(s), $matched matching: $(tr '\n' ';' < "$log")"
  fi
}

# Every skill dir in the checkout must be installed (ground truth = ls skills/).
assert_all_skills() {
  local target="$1" s d
  for d in "$EXPECTED_SKILLS_ROOT"/skills/*/; do
    s=$(basename "$d")
    [ -d "$target/$s" ] || _fail "skill not installed in $target: $s"
  done
  _pass "all checkout skills present in $target"
}

# Shims must be detected, never executed (--source bypasses Tiers 1-2).
assert_shims_never_invoked() {
  local m
  if compgen -G "$MARKER_DIR/*.invoked" > /dev/null; then
    for m in "$MARKER_DIR"/*.invoked; do _fail "shim was executed: $(basename "$m" .invoked)"; done
  else
    _pass "no shim was ever executed"
  fi
}
