#!/usr/bin/env bash
# selftest.sh — guard-the-guards: mutations that MUST make the suite fail.
# A checker that cannot fail is decoration.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
rc=0

# Mutations that invoke install.sh (2 and 4) MUST run PATH-sandboxed: install.sh
# treats mex as a hard dependency and, on a host with no mex and node >= 22.5.0,
# runs a real `npm install -g mex-agent@<pin>` into the developer's global prefix.
# A test suite must never mutate the host, so those mutations reuse the shape
# suite's sandbox (shim dir with answering mex/node stubs + a logging npm that can
# only ever fail, a sandbox HOME, and a PATH that excludes the user's real one).
# lib.sh is import-only — sourcing defines variables and functions, runs nothing —
# but it recomputes REPO_ROOT from SHAPE_REPO_ROOT, so the selftest's own value is
# restored immediately after: mutations 1/19/20 point SHAPE_REPO_ROOT at mutated
# copies and must keep resolving the REAL checkout here.
# CAUTION: lib.sh's assert_* helpers report into its FAILS counter, which this
# script never reads — a failure there would be invisible. Assertions below use
# the expect_*/rc helpers instead; only the sandbox builders are reused.
_SELFTEST_REPO_ROOT="$REPO_ROOT"
# shellcheck source=tests/install-shape/lib.sh
source "$HERE/lib.sh"
REPO_ROOT="$_SELFTEST_REPO_ROOT"
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
# expect_exit_because <label> <want-exit> <substring> <cmd>... — the strict form of
# expect_red, for a guard with a documented exit-code contract. Two things are
# asserted, not one: the EXACT exit code, because callers route on it (a deny that
# arrives as 1 where the contract says 2 is a different outcome), and a substring of
# the guard's own message, because a mutation that goes red for an unrelated reason
# — a broken sandbox, a missing dependency — is a false pass wearing a red hat.
# Mutations 11/19/20 spell this shape out inline; they predate the helper and are
# left as they are.
expect_exit_because() {
  local label="$1" want="$2" needle="$3"; shift 3
  local out ec
  out="$("$@" 2>&1)"; ec=$?
  if [ "$ec" -ne "$want" ]; then
    echo "SELFTEST FAIL: '$label' exited $ec, want $want: $out"; rc=1
  elif ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "SELFTEST FAIL: '$label' failed for the wrong reason (no message naming '$needle'): $out"; rc=1
  else
    echo "SELFTEST ok: '$label' correctly fails with exit $want, naming the violation"
  fi
}
# expect_npm_untouched <label> — the sandbox npm is a stub that logs its argv and
# exits 1. These mutation scenarios run with mex already satisfied, so nothing may
# ever reach npm: an empty-or-absent log is the proof the host was not mutated.
# Deliberately rc-based rather than lib.sh's assert_npm_untouched, whose FAILS
# counter this script does not read.
expect_npm_untouched() {
  local label="$1" log="$SANDBOX/npm-invocations.log"
  if [ ! -s "$log" ]; then
    echo "SELFTEST ok: '$label' never invoked npm (host untouched)"
  else
    echo "SELFTEST FAIL: '$label' invoked npm: $(tr '\n' ';' < "$log")"; rc=1
  fi
}

# Mutation 1: source copy missing one skill dir -> the REAL assert-claude.sh must fail.
# (Runs the actual assertion code path via the SHAPE_REPO_ROOT override, not an inline re-check.
#  Note: promote_staging only WARNS below 20 skills — install exits 0 with 22/23; only the
#  suite's assert_all_skills catches the gap. That is exactly what this mutation proves.
#  SHAPE_EXPECTED_ROOT pins the assert_all_skills yardstick to the real checkout — without it
#  the mutated copy would be both install source AND ground truth, a tautology that can't fail.
#  scripts/ travels with every mutated install source here and in mutations 19/20:
#  install.sh populates the install root from it and fails the install when it is
#  missing, so a copy without it would go red for the wrong reason.)
MUT1=$(mktemp -d)
cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
      "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT1/"
mkdir -p "$MUT1/tests"
cp -rf "$REPO_ROOT/tests/install-shape" "$MUT1/tests/install-shape"
rm -rf "$MUT1/skills/using-superpowers"
expect_red "missing skill dir (real assert-claude.sh)" \
  env SHAPE_REPO_ROOT="$MUT1" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
  bash "$REPO_ROOT/tests/install-shape/assert-claude.sh"
rm -rf "$MUT1"

# Mutation 2: SessionStart entry stripped from settings.json post-install -> claude JSON assertion fails.
# Setup failures are rig breakage, NOT a caught mutation — never let them masquerade as red.
# PATH-sandboxed (aeq.12): shape_sandbox_setup supplies the sandbox HOME, the answering
# mex/node stubs and the logging npm stub, so this install can neither see nor mutate the
# host's global npm packages. `claude` is shimmed so Claude Code is detected and
# settings.json is actually written — the same detection the host PATH used to provide.
shape_sandbox_setup claude
_shape_run_install
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "SELFTEST FAIL: mutation-2 setup install failed (rig broken, not a caught mutation)"; rc=1
  sed -n '1,25p' "$SANDBOX/install.log"
elif [ ! -f "$SANDBOX/.claude/settings.json" ]; then
  echo "SELFTEST FAIL: mutation-2 setup produced no settings.json (rig broken, not a caught mutation)"; rc=1
else
  expect_npm_untouched "mutation-2 setup install"
  python3 - "$SANDBOX/.claude/settings.json" << 'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d.get('hooks', {}).pop('SessionStart', None)
json.dump(d, open(p, 'w'))
PY
  expect_red "stripped SessionStart" python3 -c "
import json,sys; d=json.load(open('$SANDBOX/.claude/settings.json'))
sys.exit(0 if 'SessionStart' in d.get('hooks',{}) else 1)"
fi
shape_sandbox_teardown

# Mutation 3: corrupted manifest JSON -> manifest assertion fails.
MUT3=$(mktemp -d)
echo '{ not json' > "$MUT3/plugin.json"
expect_red "corrupt manifest" python3 -c "import json; json.load(open('$MUT3/plugin.json'))"
rm -rf "$MUT3"

# Mutation 4: file planted after uninstall -> round-trip residue assertion fails.
# Setup failures are rig breakage, NOT a caught mutation — never let them masquerade as red.
# PATH-sandboxed (aeq.12), same rig as mutation 2. The uninstall leg is spelled out
# rather than calling lib.sh's shape_uninstall, whose failure would land in the FAILS
# counter this script never reads (silently green); here it must set rc.
shape_sandbox_setup claude
_shape_run_install
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "SELFTEST FAIL: mutation-4 setup install failed (rig broken, not a caught mutation)"; rc=1
  sed -n '1,25p' "$SANDBOX/install.log"
elif ! env HOME="$SANDBOX" BEADS_SUPERPOWERS_SKILLS_DIR="$SANDBOX/skills" PATH="$SANDBOX_PATH" \
       bash "$REPO_ROOT/install.sh" --yes --uninstall > "$SANDBOX/uninstall.log" 2>&1; then
  echo "SELFTEST FAIL: mutation-4 setup uninstall failed (rig broken, not a caught mutation)"; rc=1
  sed -n '1,25p' "$SANDBOX/uninstall.log"
else
  expect_npm_untouched "mutation-4 setup install+uninstall"
  mkdir -p "$SANDBOX/skills/using-superpowers" && touch "$SANDBOX/skills/using-superpowers/SKILL.md"
  expect_red "planted residue" bash -c "[ ! -e '$SANDBOX/skills/using-superpowers/SKILL.md' ]"
fi
shape_sandbox_teardown

# (mutations 5-10 covered the retired kb guards; removed 2026-08 (mex migration))
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
# Default-invocation pair (no path argument): pins that ROOTS defaults to
# (skills hooks docs) — not (skills hooks), which vacuously passed docs/ until
# beads-superpowers-cv6.2 — and that the docs/decisions/ allowlist entry is
# anchored to path-root position, not any-depth substring match. Rig mirrors
# Mutation 11: copy the real script to $SB12/scripts/ so its
# `cd "$(dirname "$0")/.."` lands in $SB12, giving the default ROOTS meaning
# relative to the fixture tree, not the real repo. skills/hooks/docs must all
# exist so the scan-root existence check (CLI-1) doesn't short-circuit on a
# root this fixture doesn't care about.
if ! mkdir -p "$SB12/scripts" "$SB12/hooks" "$SB12/docs/en" "$SB12/docs/decisions"; then
  echo "SELFTEST FAIL: mutation-12 default-invocation setup mkdir failed (rig broken, not a caught mutation)"; rc=1
elif ! cp -f "$REPO_ROOT/scripts/check-model-genericization.sh" "$SB12/scripts/check-model-genericization.sh"; then
  echo "SELFTEST FAIL: mutation-12 default-invocation setup cp failed (rig broken, not a caught mutation)"; rc=1
else
  echo 'dispatch with model: "sonnet"' > "$SB12/docs/en/some-page.md"
  expect_red "model genericization: default invocation, hardcoded model name under docs/en/" \
    bash "$SB12/scripts/check-model-genericization.sh"
  rm -f "$SB12/docs/en/some-page.md"
  echo 'dispatch with model: "sonnet"' > "$SB12/docs/decisions/0099-example.md"
  expect_green "model genericization: default invocation, docs/decisions/ path-root anchor (control)" \
    bash "$SB12/scripts/check-model-genericization.sh"
fi
# SD-R2-001: pin the CLI-1 existence check itself. Every case above pre-creates
# every scan root, so the check never fires in this file — a future edit that
# reorders the loop below the grep, drops it in a merge, or weakens the
# predicate would restore the original vacuous-pass defect while this whole
# suite stayed green. $SB12 itself exists (mktemp -d above); only the child
# path is absent, so this needs no extra setup and runs unconditionally.
expect_exit_because "model genericization: absent scan root fails loud, not vacuous (SD-R2-001)" 1 "does not exist" \
  bash "$REPO_ROOT/scripts/check-model-genericization.sh" "$SB12/no-such-root"
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

# Mutation 14: CB-C capture-contract line — a NON-signature clause reworded at one site
# must fail RED (proves assert_line_identical catches full-line drift, not just the signature
# slice). Same fixture-isolation as Mutation 13; the real tree is never touched.
SB14=$(mktemp -d)
if ! (cd "$REPO_ROOT" && git ls-files -z skills .claude/skills hooks CLAUDE.md scripts/check-convention-sync.sh | xargs -0 -I{} cp --parents {} "$SB14"/); then
  echo "SELFTEST FAIL: mutation-14 setup copy failed (rig broken, not a caught mutation)"; rc=1
else
  # Reword the non-signature 'near-duplicate' tail of the CB-C line at ONE site.
  sed 's/adding a near-duplicate/adding a duplicate/' \
    "$SB14/skills/test-driven-development/SKILL.md" > "$SB14/skills/test-driven-development/SKILL.md.tmp" \
    && mv -f "$SB14/skills/test-driven-development/SKILL.md.tmp" "$SB14/skills/test-driven-development/SKILL.md"
  # Rig-broken guard (stress-test P2): the sed MUST have changed the file; a stale target
  # string would silently no-op and masquerade as a guard regression.
  if cmp -s "$SB14/skills/test-driven-development/SKILL.md" "$REPO_ROOT/skills/test-driven-development/SKILL.md"; then
    echo "SELFTEST FAIL: mutation-14 changed nothing (stale fixture, not a caught mutation)"; rc=1
  fi
  expect_red "convention-sync: CB-C non-signature clause reworded at one site" \
    bash "$SB14/scripts/check-convention-sync.sh"
  cp -f "$REPO_ROOT/skills/test-driven-development/SKILL.md" "$SB14/skills/test-driven-development/SKILL.md"
  expect_green "convention-sync: CB-C unmutated copy (control)" \
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
  # The pad is DERIVED from the budget and the file's own length, never a literal.
  # This mutation appended a fixed 60 lines until 2026-08: enough while SKILL.md
  # was 478 lines, and silently no-longer-a-mutation once Task 6's refactor took it
  # to 381 (381 + 60 = 441, under the 500-line budget). The rig caught its own dead
  # mutation, which is the rig working; a hardcoded count is what made it possible.
  # Reading the budget out of the guard's own comparison and appending
  # (budget - lines + 1) breaches by construction at any file length and any future
  # budget. An unreadable budget is rig breakage, NOT a caught mutation.
  sdd18="$SB18/skills/subagent-driven-development/SKILL.md"
  budget18="$(grep -oE '"\$lines" -ge [0-9]+' "$SB18/tests/skills/test-sdd-structure.sh" | grep -oE '[0-9]+$')"
  case "${budget18:-}" in
    ''|*[!0-9]*)
      echo "SELFTEST FAIL: mutation-18 could not read the line budget out of test-sdd-structure.sh (rig broken, not a caught mutation)"; rc=1 ;;
    *)
      # grep -c '' is the guard's own counting method — wc -l would disagree on a
      # file with no trailing newline and could leave the pad one line short.
      pad18=$(( budget18 - $(grep -c '' "$sdd18") + 1 ))
      [ "$pad18" -lt 1 ] && pad18=1
      for _ in $(seq 1 "$pad18"); do echo >> "$sdd18"; done
      # Rig-broken guard (stress-test P2): the append MUST have carried the file over
      # the budget, or the RED below would be measuring something else.
      if [ "$(grep -c '' "$sdd18")" -lt "$budget18" ]; then
        echo "SELFTEST FAIL: mutation-18 left SKILL.md under the $budget18-line budget (rig broken, not a caught mutation)"; rc=1
      fi
      expect_exit_because "sdd structure: SKILL.md over the line budget" 1 "C1 budget" \
        bash "$SB18/tests/skills/test-sdd-structure.sh"
      cp -f "$REPO_ROOT/skills/subagent-driven-development/SKILL.md" "$sdd18"
      expect_green "sdd structure: SKILL.md back under budget (control)" \
        bash "$SB18/tests/skills/test-sdd-structure.sh" ;;
  esac
fi
rm -rf "$SB18"

# Mutation 19: the mex consent line deleted from install.sh — the user is no longer
# told which mex the install depends on, so assert_mex_advertised must fail RED.
# The consent line is state-aware (found / below_pin / unreadable / missing), and every
# arm states the pin, so deleting one arm's text would leave the others advertising it.
# Deleting every line that mentions the `mex_consent` variable removes the whole
# advertisement (the arms plus the echo) and nothing else, leaving an empty `case`.
# Same rig as Mutation 1 (mutated copy as install source, real checkout as the
# skills yardstick), running the REAL assert-claude.sh. Setup failures are rig
# breakage, NOT a caught mutation.
MUT19=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT19/"; then
  echo "SELFTEST FAIL: mutation-19 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT19/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT19/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-19 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  grep -v 'mex_consent' "$MUT19/install.sh" > "$MUT19/install.sh.tmp" \
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
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT20/"; then
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

# make_pipeline_home <dir> — a HOME carrying a great_cto bundle root the shipped
# bundle-root.sh accepts, plus the fixture tier-map. Shared by mutations 21 and 22,
# which both need the pipeline's hard dependencies satisfied so that the case under
# test is the ONLY thing that can go red.
# The bundle version is READ from bundle-root.sh, never written as a literal: Task 14
# raises GREAT_CTO_MIN_VERSION, and a literal here would quietly turn both mutations
# into version-check failures that still look red — the same rot that killed
# mutation 18's fixed line count. Returns 1 (rig broken) if the constant is unreadable.
make_pipeline_home() {
  local home="$1" minver
  minver="$(sed -n 's/^GREAT_CTO_MIN_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$REPO_ROOT/scripts/pipeline/bundle-root.sh")"
  [ -n "$minver" ] || return 1
  mkdir -p "$home/.agents/great_cto/shared" || return 1
  printf '{"version":"%s"}\n' "$minver" > "$home/.agents/great_cto/package.json" || return 1
  cp -f "$REPO_ROOT/tests/pipeline/fixtures/tier-map.json" \
     "$home/.agents/great_cto/shared/tier-map.json" || return 1
}

# Mutation 21: tier-gate.sh (Task 2) — a session whose model the tier-map does not
# list must fail RED at exit 1, naming the model; the same sandbox with a listed
# model must pass GREEN (control, proves the tier check discriminates rather than
# always failing). Sandboxed the way tests/pipeline/test-tier-gate.sh sandboxes:
# a mktemp HOME holding the fixture bundle root and tier-map, and a mktemp cwd
# holding the session state file, so neither the real great_cto install nor this
# repo's own .internal/pipeline/ is ever read. jq is a hard dependency of the gate,
# so its absence is a visible SKIP — never a red, which would credit a missing tool
# as a caught mutation.
SB21=$(mktemp -d)
if ! command -v jq > /dev/null 2>&1; then
  echo "SELFTEST SKIP: mutation-21 (tier-gate) needs jq, which is not installed"
elif ! make_pipeline_home "$SB21/home"; then
  echo "SELFTEST FAIL: mutation-21 setup could not build the bundle-root HOME (rig broken, not a caught mutation)"; rc=1
elif ! mkdir -p "$SB21/cwd/.internal/pipeline"; then
  echo "SELFTEST FAIL: mutation-21 setup mkdir failed (rig broken, not a caught mutation)"; rc=1
else
  # The state file and the live identifier must agree (D4): state written by a
  # different session is treated as absent, so an unbound fixture would deny for
  # the wrong reason and both cases below would stop testing the tier check.
  SID21="selftest-21-session"
  run_tier_gate_21() { # <model> — the gate at stage planning for that session model
    printf '{"model_id":"%s","effort":null,"session_id":"%s","source":"hook","timestamp":"t"}\n' \
      "$1" "$SID21" > "$SB21/cwd/.internal/pipeline/session.json" || return 1
    ( cd "$SB21/cwd" && HOME="$SB21/home" CLAUDE_CODE_SESSION_ID="$SID21" \
      bash "$REPO_ROOT/scripts/pipeline/tier-gate.sh" --stage planning < /dev/null )
  }
  expect_exit_because "tier-gate: session model absent from the tier-map" 1 "not in tier-map" \
    run_tier_gate_21 model-not-in-tier-map
  expect_green "tier-gate: session model listed in the tier-map (control)" \
    run_tier_gate_21 model-plan-1
fi
rm -rf "$SB21"

# Mutation 22: hooks/pipeline-guard (Task 4) — malformed stdin must fail RED at
# exit 2 (the PreToolUse deny code), naming the payload; a well-formed payload in
# the same sandbox must pass GREEN (control).
# The sandbox MUST be armed. Phase 1 is a bare file-existence test and an unarmed
# project exits 0 for everything, malformed stdin included — so an unarmed sandbox
# here would assert the opposite of what this mutation claims. The session state
# file is what arms it, and it carries a planning-tier model so the GREEN control's
# `ls` is judged by the same armed path the RED payload takes.
SB22=$(mktemp -d)
if ! command -v jq > /dev/null 2>&1; then
  echo "SELFTEST SKIP: mutation-22 (pipeline-guard) needs jq, which is not installed"
elif ! make_pipeline_home "$SB22/home"; then
  echo "SELFTEST FAIL: mutation-22 setup could not build the bundle-root HOME (rig broken, not a caught mutation)"; rc=1
elif ! mkdir -p "$SB22/cwd/.internal/pipeline"; then
  echo "SELFTEST FAIL: mutation-22 setup mkdir failed (rig broken, not a caught mutation)"; rc=1
elif ! printf '{"model_id":"model-plan-1","effort":null,"source":"hook","timestamp":"t"}\n' \
        > "$SB22/cwd/.internal/pipeline/session.json"; then
  echo "SELFTEST FAIL: mutation-22 setup could not arm the sandbox (rig broken, not a caught mutation)"; rc=1
else
  run_pipeline_guard_22() { # <payload> — the armed guard reading that payload on stdin
    ( cd "$SB22/cwd" && HOME="$SB22/home" bash "$REPO_ROOT/hooks/pipeline-guard" ) <<< "$1"
  }
  expect_exit_because "pipeline-guard: malformed stdin, armed" 2 "not valid JSON" \
    run_pipeline_guard_22 '{"tool_name":"Bash","tool_input":'
  expect_green "pipeline-guard: well-formed stdin, armed (control)" \
    run_pipeline_guard_22 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
fi
rm -rf "$SB22"

# Mutation 23: graph-lint.mjs (Task 5) — a plan graph carrying a blocks cycle must
# fail RED at exit 1, naming the cycle; the unmutated fixture must pass GREEN
# (control). The cycle is built with jq from tests/pipeline/fixtures/graph-valid.json
# into a mktemp dir — the fixture itself is read-only here — closing fx-t1 -> fx-t2
# -> fx-t3 back onto fx-t1. node and jq are both required to build and run it, so
# either one missing is a visible SKIP rather than a red.
# Run under a scratch HOME, exactly as mutations 21 and 22 are: graph-lint's own
# integrity self-check reads the install anchor and the ownership record out of
# $HOME, so under the developer's real HOME this mutation would be judged by
# whatever that machine's install happens to look like.
SB23=$(mktemp -d)
if ! command -v node > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "SELFTEST SKIP: mutation-23 (graph-lint) needs node and jq"
elif ! make_pipeline_home "$SB23/home"; then
  echo "SELFTEST FAIL: mutation-23 setup could not build the bundle-root HOME (rig broken, not a caught mutation)"; rc=1
elif ! jq '(.[] | select(.id=="fx-t1") | .dependencies) += [{"issue_id":"fx-t1","depends_on_id":"fx-t3","type":"blocks","metadata":"{}"}]' \
        "$REPO_ROOT/tests/pipeline/fixtures/graph-valid.json" > "$SB23/state-cycle.json"; then
  echo "SELFTEST FAIL: mutation-23 setup jq mutation failed (rig broken, not a caught mutation)"; rc=1
elif cmp -s "$SB23/state-cycle.json" "$REPO_ROOT/tests/pipeline/fixtures/graph-valid.json"; then
  echo "SELFTEST FAIL: mutation-23 changed nothing (stale fixture ids, not a caught mutation)"; rc=1
else
  run_graph_lint_23() { # <state-file>
    HOME="$SB23/home" node "$REPO_ROOT/scripts/pipeline/graph-lint.mjs" --initiative fx-ini --state "$1" \
      --roster "$REPO_ROOT/tests/pipeline/fixtures/roster.mjs" \
      --tier-map "$REPO_ROOT/tests/pipeline/fixtures/tier-map.json"
  }
  expect_exit_because "graph-lint: blocks dependency cycle in the plan graph" 1 "cycle" \
    run_graph_lint_23 "$SB23/state-cycle.json"
  expect_green "graph-lint: unmutated valid fixture (control)" \
    run_graph_lint_23 "$REPO_ROOT/tests/pipeline/fixtures/graph-valid.json"
fi
rm -rf "$SB23"

# Mutation 24: install.sh no longer populates the install root (spec D3) — the
# call sites are deleted, so nothing lands at $HOME/.agents/beads-superpowers and
# great_cto's literal spellings resolve to nothing. The REAL assert-claude.sh
# must go RED naming the missing root. This is the hole the design closes (the
# root reaching NEITHER tier), so a suite that stays green without it is
# decoration. Same rig as mutations 19/20.
MUT24=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT24/"; then
  echo "SELFTEST FAIL: mutation-24 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT24/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT24/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-24 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  # The CALL sites only — `populate_anchor_root "` never matches the definition
  # line, so the function survives and the mutated installer is still valid bash.
  grep -v 'populate_anchor_root "' "$MUT24/install.sh" > "$MUT24/install.sh.tmp" \
    && mv -f "$MUT24/install.sh.tmp" "$MUT24/install.sh"
  if cmp -s "$MUT24/install.sh" "$REPO_ROOT/install.sh"; then
    echo "SELFTEST FAIL: mutation-24 changed nothing (stale call-site text, not a caught mutation)"; rc=1
  fi
  out24=$(env SHAPE_REPO_ROOT="$MUT24" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/tests/install-shape/assert-claude.sh" 2>&1); ec24=$?
  if [ "$ec24" -eq 0 ]; then
    echo "SELFTEST FAIL: 'install root never populated' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out24" | grep -qF "install root is not a real directory"; then
    echo "SELFTEST FAIL: 'install root never populated' failed for the wrong reason (no missing-root message)"; rc=1
  else
    echo "SELFTEST ok: 'install root never populated' correctly fails, naming the missing root"
  fi
fi
rm -rf "$MUT24"

# Mutation 25: the pre-0.18 composer branch is disabled, so a source that ships
# hooks/session-start but no install root silently drops to the policy-free
# minimal hook — bd prime capture, envelope budgeting and routing gone with no
# message. The condition is rewritten to `false` rather than deleted: the branch
# body survives and the mutated installer is still valid bash. Same rig as 19/20/24.
MUT25=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT25/"; then
  echo "SELFTEST FAIL: mutation-25 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT25/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT25/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-25 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  sed 's|^  elif \[ -n "\$source_root" \] && \[ -f "\$source_root/hooks/session-start" \]; then$|  elif false; then|' \
    "$MUT25/install.sh" > "$MUT25/install.sh.tmp" && mv -f "$MUT25/install.sh.tmp" "$MUT25/install.sh"
  if cmp -s "$MUT25/install.sh" "$REPO_ROOT/install.sh"; then
    echo "SELFTEST FAIL: mutation-25 changed nothing (stale composer-branch text, not a caught mutation)"; rc=1
  fi
  out25=$(env SHAPE_REPO_ROOT="$MUT25" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/tests/install-shape/assert-claude.sh" 2>&1); ec25=$?
  if [ "$ec25" -eq 0 ]; then
    echo "SELFTEST FAIL: 'pre-0.18 composer branch disabled' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out25" | grep -qF "silent hook downgrade"; then
    echo "SELFTEST FAIL: 'pre-0.18 composer branch disabled' failed for the wrong reason (no downgrade message)"; rc=1
  else
    echo "SELFTEST ok: 'pre-0.18 composer branch disabled' correctly fails, naming the silent downgrade"
  fi
fi
rm -rf "$MUT25"

# Mutation 26: the failed-install rollback never arms — the flag stays false, so a
# tier that populates the install root and then fails leaves an attested, hookless
# root standing, permanently pinned for every later session. Deleting the single
# arming line is the smallest change that reproduces it. Same rig as 19/20/24.
MUT26=$(mktemp -d)
if ! cp -rf "$REPO_ROOT/skills" "$REPO_ROOT/example-workflow" "$REPO_ROOT/hooks" "$REPO_ROOT/.opencode" \
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" "$MUT26/"; then
  echo "SELFTEST FAIL: mutation-26 setup copy failed (rig broken, not a caught mutation)"; rc=1
elif ! { mkdir -p "$MUT26/tests" && cp -rf "$REPO_ROOT/tests/install-shape" "$MUT26/tests/install-shape"; }; then
  echo "SELFTEST FAIL: mutation-26 setup copy of tests/install-shape failed (rig broken, not a caught mutation)"; rc=1
else
  grep -v '^  ANCHOR_CREATED_THIS_RUN=true$' "$MUT26/install.sh" > "$MUT26/install.sh.tmp" \
    && mv -f "$MUT26/install.sh.tmp" "$MUT26/install.sh"
  if cmp -s "$MUT26/install.sh" "$REPO_ROOT/install.sh"; then
    echo "SELFTEST FAIL: mutation-26 changed nothing (stale rollback-flag text, not a caught mutation)"; rc=1
  fi
  out26=$(env SHAPE_REPO_ROOT="$MUT26" SHAPE_EXPECTED_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/tests/install-shape/assert-claude.sh" 2>&1); ec26=$?
  if [ "$ec26" -eq 0 ]; then
    echo "SELFTEST FAIL: 'failed-install rollback disarmed' should have gone RED but passed"; rc=1
  elif ! printf '%s\n' "$out26" | grep -qE "should not exist: .*(\.agents/beads-superpowers|record\.json)"; then
    echo "SELFTEST FAIL: 'failed-install rollback disarmed' failed for the wrong reason (no surviving-root message)"; rc=1
  else
    echo "SELFTEST ok: 'failed-install rollback disarmed' correctly fails, naming the root a failed install left behind"
  fi
fi
rm -rf "$MUT26"

exit "$rc"
