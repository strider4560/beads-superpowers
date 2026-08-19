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
# Written hook must be a thin exec shim of the canonical composer (bead bb6x),
# and the canonical copy must land where the shim points.
assert_file "$SANDBOX/.claude/hooks/beads-superpowers/hooks/session-start"
# shellcheck disable=SC2016  # the '$BSP_ROOT' exec line is matched literally, not expanded
if grep -qF 'exec "$BSP_ROOT/hooks/session-start"' "$SANDBOX/.claude/hooks/beads-superpowers-session-start.sh" 2>/dev/null; then
  _pass "written hook execs the canonical composer"
else
  _fail "written hook is not an exec shim of hooks/session-start"
fi
assert_file "$SANDBOX/.claude/settings.json"
assert_json "$SANDBOX/.claude/settings.json" "'SessionStart' in d.get('hooks', {})"
assert_json "$SANDBOX/.claude/settings.json" "'UserPromptSubmit' not in d.get('hooks', {})"
# PreToolUse pipeline-guard registration (bead e4v). The guard ships through the
# PLUGIN channel — hooks/hooks.json, auto-discovered by Claude Code — so its
# registration shape is asserted on the manifest, not on the sandbox settings.json.
# install.sh's register_hook writes SessionStart only; wiring PreToolUse into the
# scripted channel is an install.sh change and is NOT covered here.
assert_json "$REPO_ROOT/hooks/hooks.json" \
  "any(e.get('matcher') == 'Bash|Write|Edit' and any('run-hook.cmd' in h.get('command', '') and h.get('command', '').endswith('pipeline-guard') for h in e.get('hooks', [])) for e in d['hooks'].get('PreToolUse', []))"
assert_no_file "$SANDBOX/.claude/hooks/beads-superpowers-reminder.sh"
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

fail_count
