#!/usr/bin/env bash
# assert-claude.sh — Tier A: full artifact + uninstall round-trip for Claude Code.
set -uo pipefail
# shellcheck source=tests/install-shape/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

shape_sandbox_setup claude
trap 'shape_sandbox_teardown' EXIT
shape_install

assert_all_skills "$SANDBOX/skills"
# ADR-0044: maintainer-only skill must never be installed
assert_no_file "$SANDBOX/skills/auditing-upstream-drift/SKILL.md"
assert_file "$SANDBOX/.claude/hooks/beads-superpowers-session-start.sh"
assert_file "$SANDBOX/.claude/settings.json"
assert_json "$SANDBOX/.claude/settings.json" "'SessionStart' in d.get('hooks', {})"
assert_json "$SANDBOX/.claude/settings.json" "'UserPromptSubmit' not in d.get('hooks', {})"
# PreToolUse pipeline-guard registration (bead e4v) on the PLUGIN channel —
# hooks/hooks.json, auto-discovered by Claude Code. The scripted channel's own
# registration is asserted against the INSTALL further down.
assert_json "$REPO_ROOT/hooks/hooks.json" \
  "any(e.get('matcher') == 'Bash|Write|Edit|NotebookEdit' and any('run-hook.cmd' in h.get('command', '') and h.get('command', '').endswith('pipeline-guard') for h in e.get('hooks', [])) for e in d['hooks'].get('PreToolUse', []))"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers-reminder.sh"

# --- pipeline install root (spec D3) ----------------------------------------
# $HOME/.agents/beads-superpowers is the SINGLE populated root on the scripted
# tiers: a real directory (never a symlink), carrying the whole shipped unit,
# with both hook registrations resolving through it. Everything below is
# asserted against the INSTALL in the sandbox HOME, never against the checkout.
ANCHOR="$SANDBOX/.agents/beads-superpowers"
RECORD="$SANDBOX/.local/state/beads-superpowers/record.json"
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
{ [ -d "$ANCHOR" ] && [ ! -L "$ANCHOR" ]; } && _pass "install root is a real directory" \
  || _fail "install root is not a real directory: $ANCHOR"
# The shipped unit, as spelled by the contract paths: tier-gate sources a sibling
# bundle-root.sh, pipeline-guard sources ../scripts/pipeline/bundle-root.sh, and
# package.json is the root's version file.
for rel in scripts/pipeline/tier-gate.sh scripts/pipeline/bundle-root.sh \
           scripts/pipeline/graph-lint.mjs scripts/scan-plan.sh \
           hooks/session-start hooks/pipeline-guard package.json \
           skills/using-superpowers/SKILL.md \
           skills/subagent-driven-development/scripts/review-package; do
  assert_file "$ANCHOR/$rel"
done

# The ownership record: posture DECLARED, the canonical target, the root's own
# version, and a hash for each of the four gate files.
ANCHOR_CANON="$(cd "$ANCHOR" 2>/dev/null && pwd -P)" || ANCHOR_CANON="$ANCHOR"
PKG_VERSION=$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed -E 's/.*"([0-9][^"]*)".*/\1/')
assert_file "$RECORD"
assert_json "$RECORD" "d.get('posture') == 'manifest-backed'"
assert_json "$RECORD" "d.get('anchor') == '$ANCHOR'"
assert_json "$RECORD" "d.get('target') == '$ANCHOR_CANON'"
assert_json "$RECORD" "d.get('version') == '$PKG_VERSION'"
assert_json "$RECORD" "sorted(d.get('hashes', {})) == ['hooks/pipeline-guard', 'scripts/pipeline/bundle-root.sh', 'scripts/pipeline/graph-lint.mjs', 'scripts/pipeline/tier-gate.sh']"

# The registered SessionStart hook is a thin exec shim into the install root, and
# the legacy canon root keeps NO populated copy of its own (spec D3).
SHIM="$SANDBOX/.claude/hooks/beads-superpowers-session-start.sh"
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
grep -qF "BSP_ROOT=\"$ANCHOR\"" "$SHIM" && _pass "SessionStart shim roots at the install root" \
  || _fail "SessionStart shim does not root at $ANCHOR"
# shellcheck disable=SC2016,SC2015  # the '$BSP_ROOT' lines are matched literally, not expanded
grep -qF 'export CLAUDE_PLUGIN_ROOT="$BSP_ROOT"' "$SHIM" && _pass "SessionStart shim exports CLAUDE_PLUGIN_ROOT" \
  || _fail "SessionStart shim does not export CLAUDE_PLUGIN_ROOT=<install root>"
# shellcheck disable=SC2016,SC2015  # the '$BSP_ROOT' exec line is matched literally, not expanded
grep -qF 'exec "$BSP_ROOT/hooks/session-start"' "$SHIM" && _pass "SessionStart shim execs the canonical composer" \
  || _fail "SessionStart shim is not an exec shim of hooks/session-start"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers/hooks/session-start"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers/skills"

# PreToolUse on the SCRIPTED channel, asserted against the install: the matcher
# covers the Task 4 tool set (NotebookEdit included — its payloads carry
# notebook_path) and the command resolves through the install root.
assert_json "$SANDBOX/.claude/settings.json" \
  "any(e.get('matcher') == 'Bash|Write|Edit|NotebookEdit' and any('$ANCHOR/hooks/pipeline-guard' in h.get('command', '') for h in e.get('hooks', [])) for e in d.get('hooks', {}).get('PreToolUse', []))"

# great_cto's literal spelling, run verbatim: it must reach the gate's OWN logic.
# "No such file or directory" means the root is not where the contract says; a
# version or record ERROR means the install did not attest what it wrote.
run_tier_gate() { # [VAR=VAL ...] — the anchored gate, from a repo-shaped cwd
  ( cd "$SANDBOX" && HOME="$SANDBOX" PATH="$SANDBOX_PATH" env "$@" \
      bash "$SANDBOX/.agents/beads-superpowers/scripts/pipeline/tier-gate.sh" --stage planning ) 2>&1
}
gate_out="$(run_tier_gate)"; gate_rc=$?
if printf '%s\n' "$gate_out" | grep -qF "No such file or directory"; then
  _fail "tier-gate through the install root did not resolve: $gate_out"
elif printf '%s\n' "$gate_out" | grep -qE "integrity record|integrity check failed|was repointed"; then
  _fail "tier-gate denied on its own install's record: $gate_out"
elif printf '%s\n' "$gate_out" | grep -qF "is running against beads-superpowers root"; then
  _fail "tier-gate version self-check failed against the install root: $gate_out"
elif printf '%s\n' "$gate_out" | grep -qE "great_cto bundle root not found|jq required by tier-gate"; then
  _pass "tier-gate reached its own gate logic through the install root (exit $gate_rc)"
else
  _fail "tier-gate output does not name any of its own gate checks: $gate_out"
fi
# The record path is FIXED, so the run is insensitive to XDG_STATE_HOME (R5-001):
# the same install, read by the same gate, must answer identically either way.
gate_out_xdg="$(run_tier_gate XDG_STATE_HOME="$SANDBOX/xdg-elsewhere")"; gate_rc_xdg=$?
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
{ [ "$gate_rc" = "$gate_rc_xdg" ] && [ "$gate_out" = "$gate_out_xdg" ]; } \
  && _pass "tier-gate is insensitive to XDG_STATE_HOME set vs unset" \
  || _fail "tier-gate differed with XDG_STATE_HOME set (exit $gate_rc/$gate_rc_xdg): $gate_out_xdg"

# The guard's integrity negative cases deny at exit 2 SPECIFICALLY — a "nonzero"
# assertion would pass on exit 1, which does not block a PreToolUse call.
# The fixture is armed (Phase 1 is a file-existence test) and carries the
# great_cto root the tier resolution needs, so the ONLY thing under test is the
# record. The payload carries no session_id, so the guard's per-session
# integrity cache is never keyed and every case is verified afresh.
GC_MINVER="$(sed -n 's/^GREAT_CTO_MIN_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$REPO_ROOT/scripts/pipeline/bundle-root.sh")"
mkdir -p "$SANDBOX/.agents/great_cto/shared" "$SANDBOX/proj/.internal/pipeline"
printf '{"version":"%s"}\n' "$GC_MINVER" > "$SANDBOX/.agents/great_cto/package.json"
cp -f "$REPO_ROOT/tests/pipeline/fixtures/tier-map.json" "$SANDBOX/.agents/great_cto/shared/tier-map.json"
printf '{"model_id":"model-plan-1","effort":null,"source":"hook","timestamp":"t"}\n' \
  > "$SANDBOX/proj/.internal/pipeline/session.json"
run_guard() { # -> stdout+stderr; $? is the guard's exit code
  ( cd "$SANDBOX/proj" && HOME="$SANDBOX" PATH="$SANDBOX_PATH" \
      bash "$ANCHOR/hooks/pipeline-guard" <<< '{"tool_name":"Bash","tool_input":{"command":"ls"}}' ) 2>&1
}
guard_out="$(run_guard)"; guard_rc=$?
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
[ "$guard_rc" -eq 0 ] && _pass "guard allows a benign call on an intact install (control)" \
  || _fail "guard denied an intact install (exit $guard_rc): $guard_out"
printf '\n// tampered\n' >> "$ANCHOR/scripts/pipeline/graph-lint.mjs"
guard_out="$(run_guard)"; guard_rc=$?
if [ "$guard_rc" -ne 2 ]; then
  _fail "guard exited $guard_rc on a tampered manifest file; the deny code is 2: $guard_out"
elif ! printf '%s\n' "$guard_out" | grep -qF "install integrity"; then
  _fail "guard denied a tampered manifest for the wrong reason: $guard_out"
else
  _pass "guard denies a tampered manifest file at exit 2"
fi
cp -f "$REPO_ROOT/scripts/pipeline/graph-lint.mjs" "$ANCHOR/scripts/pipeline/graph-lint.mjs"
mv -f "$RECORD" "$RECORD.away"
guard_out="$(run_guard)"; guard_rc=$?
if [ "$guard_rc" -ne 2 ]; then
  _fail "guard exited $guard_rc with the record deleted; the deny code is 2: $guard_out"
elif ! printf '%s\n' "$guard_out" | grep -qF "install integrity"; then
  _fail "guard denied a deleted record for the wrong reason: $guard_out"
else
  _pass "guard denies a deleted record at exit 2"
fi
mv -f "$RECORD.away" "$RECORD"
# Default install must NOT place the yegge agent (opt-in via --with-yegge, bead 3krn)
assert_no_file "$SANDBOX/.claude/agents/yegge.md"
assert_file "$SANDBOX/skills/.beads-superpowers-version"
grep -q ":local$" "$SANDBOX/skills/.beads-superpowers-version" || _fail "version file tier != local"
# mex is a hard dependency: the pin is stated to the user, and a satisfied mex
# means the installer touches nobody's global npm packages.
assert_mex_advertised
assert_npm_untouched
assert_shims_never_invoked

# Round-trip: uninstall removes artifacts; designed settings backup MUST remain.
shape_uninstall
assert_no_file "$SANDBOX/skills/using-superpowers/SKILL.md"
assert_no_file "$SANDBOX/.claude/agents/yegge.md"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers-session-start.sh"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers"
assert_no_file "$SANDBOX/skills/.beads-superpowers-version"
# The removing installer is the one that introduced the artifacts (D1 rollback):
# the install root and the ownership record go with them.
assert_no_file "$ANCHOR"
assert_no_file "$RECORD"
if [ -f "$SANDBOX/.claude/settings.json" ]; then
  assert_json "$SANDBOX/.claude/settings.json" "'beads-superpowers' not in json.dumps(d)"
fi
if compgen -G "$SANDBOX/.claude/settings.json.backup-*" > /dev/null; then
  _pass "designed settings backup present"
else
  _fail "designed settings.json.backup-* missing after uninstall"
fi

# Opt-in round-trip: --with-yegge installs the agent; uninstall removes it (bead 3krn)
shape_install --with-yegge
assert_file "$SANDBOX/.claude/agents/yegge.md"
assert_all_skills "$SANDBOX/skills"
assert_mex_advertised
assert_npm_untouched
assert_shims_never_invoked
shape_uninstall
assert_no_file "$SANDBOX/.claude/agents/yegge.md"

shape_sandbox_teardown

# Negative sub-case A: mex absent, node at the floor — the installer must attempt
# the PINNED npm install and abort loudly when it fails (npm stub always fails).
# Fresh sandbox: the npm-invocations log must belong to this case alone.
shape_sandbox_setup claude
rm -f "$SHIM_DIR/mex"
shape_install_expect_abort
assert_npm_attempted_pinned
assert_in_log "npm install -g mex-agent@$SHAPE_MEX_PIN failed."
assert_in_log "Install it manually, then re-run this installer:"
shape_sandbox_teardown

# Negative sub-case B: mex absent AND node below mex-agent's floor — unsatisfiable,
# so the abort must come BEFORE consent and npm must never be reached.
shape_sandbox_setup claude
rm -f "$SHIM_DIR/mex"
shape_stub_node "v20.0.0"
shape_install_expect_abort
assert_in_log "node 20.0.0 is below mex-agent@$SHAPE_MEX_PIN's Node floor 22.5.0."
assert_in_log "Install Node >= 22.5.0, then re-run this installer."
# Pre-consent: the consent banner never printed, and nothing was mutated.
assert_not_in_log "This script installs the beads-superpowers skill suite"
assert_npm_untouched
shape_sandbox_teardown

# Sub-case C: a plugin-channel symlink already sits at the anchor. The installer
# must never write THROUGH it — it removes the link (and the record that blessed
# it) and creates a real directory, leaving the former target tree untouched.
shape_sandbox_setup claude
FORMER="$SANDBOX/former-plugin-root"
mkdir -p "$FORMER/hooks" "$FORMER/scripts/pipeline" "$SANDBOX/.agents" \
         "$SANDBOX/.local/state/beads-superpowers"
echo "former plugin root marker" > "$FORMER/hooks/session-start"
echo "former gate" > "$FORMER/scripts/pipeline/tier-gate.sh"
printf '{"version":"9.9.9"}\n' > "$FORMER/package.json"
ln -sfn "$FORMER" "$SANDBOX/.agents/beads-superpowers"
printf '{"anchor":"%s","target":"%s","posture":"dev-clone-advisory","version":"9.9.9"}\n' \
  "$SANDBOX/.agents/beads-superpowers" "$FORMER" \
  > "$SANDBOX/.local/state/beads-superpowers/record.json"
FORMER_BEFORE="$( (cd "$FORMER" && find . | sort && find . -type f -exec sha256sum {} + | sort) )"
shape_install
FORMER_AFTER="$( (cd "$FORMER" && find . | sort && find . -type f -exec sha256sum {} + | sort) )"
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
{ [ -d "$SANDBOX/.agents/beads-superpowers" ] && [ ! -L "$SANDBOX/.agents/beads-superpowers" ]; } \
  && _pass "pre-existing anchor symlink replaced by a real directory" \
  || _fail "anchor is still a symlink after a scripted install"
# shellcheck disable=SC2015  # _pass/_fail always succeed, so A && B || C can't misfire
[ "$FORMER_BEFORE" = "$FORMER_AFTER" ] && _pass "former symlink target tree unmodified" \
  || _fail "the installer wrote through the anchor symlink into $FORMER"
assert_json "$SANDBOX/.local/state/beads-superpowers/record.json" \
  "d.get('posture') == 'manifest-backed' and d.get('target') != '$FORMER'"
shape_sandbox_teardown

fail_count
