#!/usr/bin/env bash
# selftest.sh — guard-the-guards: mutations that MUST make the suite fail.
# A checker that cannot fail is decoration.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
rc=0
expect_red() {  # expect_red <label> <cmd>...
  local label="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "SELFTEST FAIL: '$label' should have gone RED but passed"; rc=1
  else
    echo "SELFTEST ok: '$label' correctly fails"
  fi
}
expect_green() {  # expect_green <label> <cmd>... — the GREEN-control counterpart to expect_red.
  local label="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "SELFTEST ok: '$label' correctly passes"
  else
    echo "SELFTEST FAIL: '$label' should have gone GREEN but failed"; rc=1
  fi
}

# Mutation 1: source copy missing one skill dir -> the REAL assert-claude.sh must fail.
# (Runs the actual assertion code path via the SHAPE_REPO_ROOT override, not an inline re-check.
#  Note: promote_staging only WARNS below 20 skills — install exits 0 with 22/23; only the
#  suite's assert_all_skills catches the gap. That is exactly what this mutation proves.
#  SHAPE_EXPECTED_ROOT pins the assert_all_skills yardstick to the real checkout — without it
#  the mutated copy would be both install source AND ground truth, a tautology that can't fail.)
MUT1=$(mktemp -d)
cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
      "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT1/"
mkdir -p "$MUT1/tests"
cp -rf "$REPO_ROOT/tests/install-shape" "$MUT1/tests/install-shape"
rm -rf "$MUT1/skills/using-superpowers"
expect_red "missing skill dir (real assert-claude.sh)" \
  env SHAPE_REPO_ROOT="$MUT1" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/install-shape/assert-claude.sh"
rm -rf "$MUT1"

# Mutation 2: SessionStart entry stripped from settings.json post-install -> claude JSON assertion fails.
# Setup failures are rig breakage, NOT a caught mutation — never let them masquerade as red.
SB2=$(mktemp -d)
if ! HOME="$SB2" BEADS_SUPERPOWERS_SKILLS_DIR="$SB2/skills" bash "$REPO_ROOT/install.sh" --yes --source "$REPO_ROOT" >/dev/null 2>&1; then
  echo "SELFTEST FAIL: mutation-2 setup install failed (rig broken, not a caught mutation)"; rc=1
elif [ ! -f "$SB2/.claude/settings.json" ]; then
  echo "SELFTEST FAIL: mutation-2 setup produced no settings.json (rig broken, not a caught mutation)"; rc=1
else
  python3 - "$SB2/.claude/settings.json" << 'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d.get('hooks', {}).pop('SessionStart', None)
json.dump(d, open(p, 'w'))
PY
  expect_red "stripped SessionStart" python3 -c "
import json,sys; d=json.load(open('$SB2/.claude/settings.json'))
sys.exit(0 if 'SessionStart' in d.get('hooks',{}) else 1)"
fi
rm -rf "$SB2"

# Mutation 3: corrupted manifest JSON -> manifest assertion fails.
MUT3=$(mktemp -d)
echo '{ not json' > "$MUT3/plugin.json"
expect_red "corrupt manifest" python3 -c "import json; json.load(open('$MUT3/plugin.json'))"
rm -rf "$MUT3"

# Mutation 4: file planted after uninstall -> round-trip residue assertion fails.
# Setup failures are rig breakage, NOT a caught mutation — never let them masquerade as red.
SB4=$(mktemp -d)
if ! HOME="$SB4" BEADS_SUPERPOWERS_SKILLS_DIR="$SB4/skills" bash "$REPO_ROOT/install.sh" --yes --source "$REPO_ROOT" >/dev/null 2>&1; then
  echo "SELFTEST FAIL: mutation-4 setup install failed (rig broken, not a caught mutation)"; rc=1
elif ! HOME="$SB4" BEADS_SUPERPOWERS_SKILLS_DIR="$SB4/skills" bash "$REPO_ROOT/install.sh" --yes --uninstall >/dev/null 2>&1; then
  echo "SELFTEST FAIL: mutation-4 setup uninstall failed (rig broken, not a caught mutation)"; rc=1
else
  mkdir -p "$SB4/skills/using-superpowers" && touch "$SB4/skills/using-superpowers/SKILL.md"
  expect_red "planted residue" bash -c "[ ! -e '$SB4/skills/using-superpowers/SKILL.md' ]"
fi
rm -rf "$SB4"

# Mutation 11: check-zh-docs.sh's completeness assertion (Task 8) — every
# docs/*.md page must be registered as the EN member of a pair, else it
# silently escapes zh-parity checking. Rig mirrors Mutation 1 (copy real
# artifacts into a scratch tree, run the REAL script from its copied
# location) rather than an env-var override: check-zh-docs.sh resolves its
# repo root via `cd "$(dirname "$0")/.."`, so copying the actual script to
# $SB11/scripts/ and invoking it from there makes that cd land in $SB11 with
# no code changes needed. The pairs array is hardcoded text in the copied
# script itself, so the scratch docs/ dir only needs the files under test —
# no need to replicate all 6 real doc pages. Setup failures are rig
# breakage, NOT a caught mutation — never let them masquerade as red.
SB11=$(mktemp -d)
if ! mkdir -p "$SB11/scripts" "$SB11/docs/en" "$SB11/docs/zh"; then
  echo "SELFTEST FAIL: mutation-11 setup 'mkdir scripts docs/en docs/zh' failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -f "$REPO_ROOT/scripts/check-zh-docs.sh" "$SB11/scripts/check-zh-docs.sh"; then
  echo "SELFTEST FAIL: mutation-11 setup 'cp check-zh-docs.sh' failed (rig broken, not a caught mutation)"; rc=1
elif ! { printf '# readme\n' > "$SB11/README.md" && printf '# 说明\n' > "$SB11/README.zh-CN.md"; }; then
  echo "SELFTEST FAIL: mutation-11 setup 'write README fixtures' failed (rig broken, not a caught mutation)"; rc=1
elif ! echo "# orphan docs page" > "$SB11/docs/en/orphan-page.md"; then
  echo "SELFTEST FAIL: mutation-11 setup 'write orphan-page.md' failed (rig broken, not a caught mutation)"; rc=1
else
  out11=$(bash "$SB11/scripts/check-zh-docs.sh" 2>&1); ec11=$?
  if [ "$ec11" -eq 0 ]; then
    echo "SELFTEST FAIL: 'zh-parity structural: EN page without ZH twin' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out11" | grep -qF "docs/zh/orphan-page.md missing"; then
    echo "SELFTEST FAIL: 'zh-parity structural: EN page without ZH twin' failed for the wrong reason (no message naming docs/zh/orphan-page.md)"; rc=1
  else
    echo "SELFTEST ok: 'zh-parity structural: EN page without ZH twin' correctly fails, naming the missing twin"
  fi
  # GREEN control, same scratch dir: provide a valid ZH twin (MT frontmatter +
  # banner) — proves the structural assertion discriminates rather than
  # always-failing.
  if ! printf -- '---\nmachine_translated: true\n---\n!!! warning "机器翻译"\n\n# 孤页\n' > "$SB11/docs/zh/orphan-page.md"; then
    echo "SELFTEST FAIL: mutation-11 setup 'write ZH twin' failed (rig broken, not a caught mutation)"; rc=1
  else
    expect_green "zh-parity structural: paired page needs no fix" \
      bash "$SB11/scripts/check-zh-docs.sh"
  fi
fi
rm -rf "$SB11"

# Mutation 12: check-model-genericization.sh (bd-1f5w) — a skill file carrying
# a hardcoded Claude model name must fail RED; the same content under the
# ADR-0041 reference-file allowlist must pass GREEN (proves the allowlist
# discriminates rather than always failing). Fixture-isolated: mktemp -d,
# guard invoked with an explicit search-root arg — the real skills/ tree is
# never touched. Setup failures are rig breakage, NOT a caught mutation.
SB12=$(mktemp -d)
if ! mkdir -p "$SB12/skills/some-skill" "$SB12/skills/using-superpowers/references"; then
  echo "SELFTEST FAIL: mutation-12 setup mkdir failed (rig broken, not a caught mutation)"; rc=1
else
  echo 'dispatch with model: "haiku"' > "$SB12/skills/some-skill/SKILL.md"
  expect_red "model genericization: hardcoded model name in skill" \
    bash "$REPO_ROOT/scripts/check-model-genericization.sh" "$SB12/skills"
  rm -f "$SB12/skills/some-skill/SKILL.md"
  echo 'dispatch with model: "haiku"' > "$SB12/skills/using-superpowers/references/claude-code.md"
  expect_green "model genericization: allowlisted reference file (control)" \
    bash "$REPO_ROOT/scripts/check-model-genericization.sh" "$SB12/skills"
fi
rm -rf "$SB12"

# Mutation 13: check-convention-sync.sh (ADR-0058) — a repo copy whose
# brainstorming/SKILL.md loses the KB read-depth fragment must fail RED; the
# unmutated copy must pass GREEN (proves the KB_SITES block discriminates).
# Fixture-isolated: the tracked guard-relevant slice is copied into mktemp -d
# preserving relative paths; the real tree is never touched. Setup failures
# are rig breakage, NOT a caught mutation.
SB13=$(mktemp -d)
if ! (cd "$REPO_ROOT" && git ls-files -z skills .claude/skills hooks CLAUDE.md scripts/check-convention-sync.sh | xargs -0 -I{} cp --parents {} "$SB13"/); then
  echo "SELFTEST FAIL: mutation-13 setup copy failed (rig broken, not a caught mutation)"; rc=1
else
  grep -v -- "hits are pointers, not knowledge" "$SB13/skills/brainstorming/SKILL.md" > "$SB13/skills/brainstorming/SKILL.md.tmp" \
    && mv -f "$SB13/skills/brainstorming/SKILL.md.tmp" "$SB13/skills/brainstorming/SKILL.md"
  expect_red "convention-sync: stripped KB read-depth fragment" \
    bash "$SB13/scripts/check-convention-sync.sh"
  cp -f "$REPO_ROOT/skills/brainstorming/SKILL.md" "$SB13/skills/brainstorming/SKILL.md"
  expect_green "convention-sync: unmutated copy (control)" \
    bash "$SB13/scripts/check-convention-sync.sh"
fi
rm -rf "$SB13"

# Mutation 14: CB-4 memory-convention line — a NON-signature clause reworded at one site
# must fail RED (proves assert_line_identical catches full-line drift, not just the signature
# slice). Same fixture-isolation as Mutation 13; the real tree is never touched.
SB14=$(mktemp -d)
if ! (cd "$REPO_ROOT" && git ls-files -z skills .claude/skills hooks CLAUDE.md scripts/check-convention-sync.sh | xargs -0 -I{} cp --parents {} "$SB14"/); then
  echo "SELFTEST FAIL: mutation-14 setup copy failed (rig broken, not a caught mutation)"; rc=1
else
  # Reword the non-signature 'near-duplicate' tail of the CB-4 line at ONE site.
  sed 's/adding a near-duplicate/adding a duplicate/' \
    "$SB14/skills/test-driven-development/SKILL.md" > "$SB14/skills/test-driven-development/SKILL.md.tmp" \
    && mv -f "$SB14/skills/test-driven-development/SKILL.md.tmp" "$SB14/skills/test-driven-development/SKILL.md"
  # Rig-broken guard (stress-test P2): the sed MUST have changed the file; a stale target
  # string would silently no-op and masquerade as a guard regression.
  if cmp -s "$SB14/skills/test-driven-development/SKILL.md" "$REPO_ROOT/skills/test-driven-development/SKILL.md"; then
    echo "SELFTEST FAIL: mutation-14 changed nothing (stale fixture, not a caught mutation)"; rc=1
  fi
  expect_red "convention-sync: CB-4 non-signature clause reworded at one site" \
    bash "$SB14/scripts/check-convention-sync.sh"
  cp -f "$REPO_ROOT/skills/test-driven-development/SKILL.md" "$SB14/skills/test-driven-development/SKILL.md"
  expect_green "convention-sync: CB-4 unmutated copy (control)" \
    bash "$SB14/scripts/check-convention-sync.sh"
fi
rm -rf "$SB14"

# Mutation 15: CB-3 Capture-gate block — a NON-signature line reworded at one site must fail
# RED (proves assert_block_identical catches block drift beyond the signature line).
SB15=$(mktemp -d)
if ! (cd "$REPO_ROOT" && git ls-files -z skills .claude/skills hooks CLAUDE.md scripts/check-convention-sync.sh | xargs -0 -I{} cp --parents {} "$SB15"/); then
  echo "SELFTEST FAIL: mutation-15 setup copy failed (rig broken, not a caught mutation)"; rc=1
else
  # Reword the non-signature 'Both' option description inside the Capture-gate JSON at ONE site.
  sed 's/A lasting decision and a lesson worth reusing/A lasting decision plus a reusable lesson/' \
    "$SB15/skills/writing-plans/SKILL.md" > "$SB15/skills/writing-plans/SKILL.md.tmp" \
    && mv -f "$SB15/skills/writing-plans/SKILL.md.tmp" "$SB15/skills/writing-plans/SKILL.md"
  # Rig-broken guard (stress-test P2): confirm the mutation actually landed inside the block.
  if cmp -s "$SB15/skills/writing-plans/SKILL.md" "$REPO_ROOT/skills/writing-plans/SKILL.md"; then
    echo "SELFTEST FAIL: mutation-15 changed nothing (stale fixture, not a caught mutation)"; rc=1
  fi
  expect_red "convention-sync: CB-3 non-signature line reworded at one site" \
    bash "$SB15/scripts/check-convention-sync.sh"
  cp -f "$REPO_ROOT/skills/writing-plans/SKILL.md" "$SB15/skills/writing-plans/SKILL.md"
  expect_green "convention-sync: CB-3 unmutated copy (control)" \
    bash "$SB15/scripts/check-convention-sync.sh"
fi
rm -rf "$SB15"

# Mutation 16: strip the CB-3 start-anchor line at ALL CB-3 sites — extraction yields empty at
# every site; the guard must NOT pass vacuously. Must fail RED (anti-vacuous guard).
SB16=$(mktemp -d)
if ! (cd "$REPO_ROOT" && git ls-files -z skills .claude/skills hooks CLAUDE.md scripts/check-convention-sync.sh | xargs -0 -I{} cp --parents {} "$SB16"/); then
  echo "SELFTEST FAIL: mutation-16 setup copy failed (rig broken, not a caught mutation)"; rc=1
else
  for s in brainstorming writing-plans stress-test systematic-debugging; do
    grep -v -- "present the Capture gate" "$SB16/skills/$s/SKILL.md" > "$SB16/skills/$s/SKILL.md.tmp" \
      && mv -f "$SB16/skills/$s/SKILL.md.tmp" "$SB16/skills/$s/SKILL.md"
  done
  # Rig-broken guard (stress-test P2): confirm the anchor strip actually landed at a
  # representative site; a renamed anchor would silently no-op.
  if cmp -s "$SB16/skills/brainstorming/SKILL.md" "$REPO_ROOT/skills/brainstorming/SKILL.md"; then
    echo "SELFTEST FAIL: mutation-16 changed nothing (stale anchor, not a caught mutation)"; rc=1
  fi
  expect_red "convention-sync: CB-3 anchor stripped at all sites (anti-vacuous)" \
    bash "$SB16/scripts/check-convention-sync.sh"
fi
rm -rf "$SB16"

# Mutation 17: test-sdd-structure.sh (Task 6) — deleting the SDD skill's
# breaker-trip.md context-pointer target must fail RED (dangling pointer);
# the unmutated copy must pass GREEN (control, proves discrimination).
# Fixture-isolated by direct copy (not git ls-files, like mutations 13-16):
# the guard script tests/skills/test-sdd-structure.sh is new in this same
# task and may not be tracked yet when this selftest runs, so git ls-files
# would silently omit it and understate the fixture. Copying
# skills/subagent-driven-development/ and the guard script by explicit path
# into mktemp -d, preserving the guard's expected ROOT-relative layout
# (tests/skills/<script> + skills/<dir>), reproduces exactly what the guard
# resolves via "$(dirname "$0")/../..". The real tree is never touched.
SB17=$(mktemp -d)
if ! mkdir -p "$SB17/skills" "$SB17/tests/skills"; then
  echo "SELFTEST FAIL: mutation-17 setup mkdir failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -rf "$REPO_ROOT/skills/subagent-driven-development" "$SB17/skills/subagent-driven-development"; then
  echo "SELFTEST FAIL: mutation-17 setup copy skill dir failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -f "$REPO_ROOT/tests/skills/test-sdd-structure.sh" "$SB17/tests/skills/test-sdd-structure.sh"; then
  echo "SELFTEST FAIL: mutation-17 setup copy guard script failed (rig broken, not a caught mutation)"; rc=1
else
  rm -f "$SB17/skills/subagent-driven-development/references/breaker-trip.md"
  expect_red "sdd structure: dangling breaker-trip.md pointer" \
    bash "$SB17/tests/skills/test-sdd-structure.sh"
  cp -f "$REPO_ROOT/skills/subagent-driven-development/references/breaker-trip.md" \
    "$SB17/skills/subagent-driven-development/references/breaker-trip.md"
  expect_green "sdd structure: pointer target restored (control)" \
    bash "$SB17/tests/skills/test-sdd-structure.sh"
fi
rm -rf "$SB17"

# Mutation 18: test-sdd-structure.sh (Task 6) — pushing SDD's SKILL.md past
# the 500-line C1 budget must fail RED; the unmutated copy must pass GREEN
# (control). Same fixture-isolation as mutation 17.
SB18=$(mktemp -d)
if ! mkdir -p "$SB18/skills" "$SB18/tests/skills"; then
  echo "SELFTEST FAIL: mutation-18 setup mkdir failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -rf "$REPO_ROOT/skills/subagent-driven-development" "$SB18/skills/subagent-driven-development"; then
  echo "SELFTEST FAIL: mutation-18 setup copy skill dir failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -f "$REPO_ROOT/tests/skills/test-sdd-structure.sh" "$SB18/tests/skills/test-sdd-structure.sh"; then
  echo "SELFTEST FAIL: mutation-18 setup copy guard script failed (rig broken, not a caught mutation)"; rc=1
else
  for _ in $(seq 1 60); do echo >> "$SB18/skills/subagent-driven-development/SKILL.md"; done
  expect_red "sdd structure: SKILL.md over the 500-line budget" \
    bash "$SB18/tests/skills/test-sdd-structure.sh"
  cp -f "$REPO_ROOT/skills/subagent-driven-development/SKILL.md" \
    "$SB18/skills/subagent-driven-development/SKILL.md"
  expect_green "sdd structure: SKILL.md back under budget (control)" \
    bash "$SB18/tests/skills/test-sdd-structure.sh"
fi
rm -rf "$SB18"

# Mutation 19: the mex consent line deleted from install.sh — the user is no longer
# told which mex the install depends on, so assert_mex_advertised must fail RED.
# Same rig as Mutation 1 (mutated copy as install source, real checkout as the
# skills yardstick), running the REAL assert-claude.sh. Setup failures are rig
# breakage, NOT a caught mutation.
MUT19=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT19/"; then
  echo "SELFTEST FAIL: mutation-19 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT19/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT19/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-19 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  grep -v 'Installs mex-agent@' "$MUT19/install.sh" > "$MUT19/install.sh.tmp" \
    && mv -f "$MUT19/install.sh.tmp" "$MUT19/install.sh"
  if cmp -s "$MUT19/install.sh" "$REPO_ROOT/install.sh"; then
    echo "SELFTEST FAIL: mutation-19 changed nothing (stale consent-line text, not a caught mutation)"; rc=1
  fi
  out19=$(env SHAPE_REPO_ROOT="$MUT19" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/tests/install-shape/assert-claude.sh" 2>&1); ec19=$?
  if [ "$ec19" -eq 0 ]; then
    echo "SELFTEST FAIL: 'mex consent line deleted' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out19" | grep -qF "log missing: mex-agent@0.7.1"; then
    echo "SELFTEST FAIL: 'mex consent line deleted' failed for the wrong reason (no assert_mex_advertised message)"; rc=1
  else
    echo "SELFTEST ok: 'mex consent line deleted' correctly fails, naming the missing pin"
  fi
fi
rm -rf "$MUT19"

# Mutation 20: the npm invocation unpinned (mex-agent@latest) — the installer would
# pull an arbitrary version, so assert_npm_attempted_pinned in the negative sub-case
# must fail RED. The pin literal lives in lib.sh, never read from install.sh, which
# is what lets this mutation be caught at all.
MUT20=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT20/"; then
  echo "SELFTEST FAIL: mutation-20 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT20/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT20/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-20 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  sed 's|npm install -g "mex-agent@${MEX_PIN}"|npm install -g "mex-agent@latest"|' \
    "$MUT20/install.sh" > "$MUT20/install.sh.tmp" && mv -f "$MUT20/install.sh.tmp" "$MUT20/install.sh"
  if cmp -s "$MUT20/install.sh" "$REPO_ROOT/install.sh"; then
    echo "SELFTEST FAIL: mutation-20 changed nothing (stale npm-invocation text, not a caught mutation)"; rc=1
  fi
  out20=$(env SHAPE_REPO_ROOT="$MUT20" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/tests/install-shape/assert-claude.sh" 2>&1); ec20=$?
  if [ "$ec20" -eq 0 ]; then
    echo "SELFTEST FAIL: 'unpinned npm invocation' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out20" | grep -qF "expected exactly one 'install -g mex-agent@0.7.1'"; then
    echo "SELFTEST FAIL: 'unpinned npm invocation' failed for the wrong reason (no assert_npm_attempted_pinned message)"; rc=1
  else
    echo "SELFTEST ok: 'unpinned npm invocation' correctly fails, naming the pin mismatch"
  fi
fi
rm -rf "$MUT20"

exit "$rc"
