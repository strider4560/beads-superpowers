#!/usr/bin/env bash
# test-pipeline-guard.sh — contract for hooks/pipeline-guard (PreToolUse).
# Exit 2 + a one-line stderr reason blocks the tool call; exit 0 allows it.
# Every case runs the guard inside a mktemp working dir with HOME pointed at a
# mktemp home, so neither the real bundle root nor this repo's own pipeline
# state directory is ever read.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/hooks/pipeline-guard"
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
make_cwd() { # <name> [model] -> path to a working dir (session state file when a model is given)
  local cwd="$TMP/cwd-$1"; mkdir -p "$cwd"
  if [ -n "${2:-}" ]; then
    mkdir -p "$cwd/.internal/pipeline"
    printf '{"model_id":"%s","effort":null,"source":"hook","timestamp":"t"}\n' \
      "$2" > "$cwd/.internal/pipeline/session.json"
  fi
  printf '%s' "$cwd"
}

# --- runner + assertion -----------------------------------------------------

stray_stdout=""

run() { # <cwd> <home> <stdin-payload> — sets rc, err (stderr)
  # PATH_OVERRIDE, when set, replaces PATH for the guard only (jq-absence cases).
  local cwd="$1" home="$2" payload="$3"
  ( cd "$cwd" && HOME="$home" PATH="${PATH_OVERRIDE:-$PATH}" "$BASH" "$guard" ) \
    <<<"$payload" >"$TMP/stdout" 2>"$TMP/stderr"
  rc=$?
  err="$(cat "$TMP/stderr")"
  # Claude Code parses hook stdout as JSON directives, so the guard must emit
  # nothing on stdout — ever, on any path. Recorded on every run so the
  # no-stdout assertion at the end covers every case in this file.
  if [ -s "$TMP/stdout" ]; then
    stray_stdout="$stray_stdout$payload -> $(cat "$TMP/stdout")
"
  fi
  return 0
}

check() { # <name> <want-exit> [<ere-pattern on stderr>] — one PASS/FAIL line
  local name="$1" want="$2" pattern="${3:-}" detail=""
  if [ "$rc" -ne "$want" ]; then
    detail="exit $rc want $want (stderr: $err)"
  elif [ -n "$pattern" ]; then
    printf '%s' "$err" | grep -qE -- "$pattern" || detail="no /$pattern/ on stderr: $err"
  fi
  if [ -z "$detail" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: $detail"
    fails=$((fails+1))
  fi
}

# --- payloads ---------------------------------------------------------------

p_epic='{"tool_name":"Bash","tool_input":{"command":"bd create -t epic \"X\""}}'
p_epic_longopt='{"tool_name":"Bash","tool_input":{"command":"bd create --type epic \"X\""}}'
p_epic_glued='{"tool_name":"Bash","tool_input":{"command":"bd create -tepic \"X\""}}'
# `=`-joined and quoted spellings. bd is Cobra/pflag-based, so `--type=epic` and
# `-t=epic` are accepted, and `bd create --help` documents the `=` form itself.
# The shell strips the quotes in `--type "epic"`, `-t 'epic'` and `--type='epic'`
# before bd sees the value, so all five create an epic exactly like `-t epic`.
p_epic_eq_long='{"tool_name":"Bash","tool_input":{"command":"bd create --type=epic \"X\""}}'
p_epic_eq_short='{"tool_name":"Bash","tool_input":{"command":"bd create -t=epic \"X\""}}'
p_epic_dq_long='{"tool_name":"Bash","tool_input":{"command":"bd create --type \"epic\" \"X\""}}'
p_epic_sq_short='{"tool_name":"Bash","tool_input":{"command":"bd create -t '"'"'epic'"'"' X"}}'
p_epic_eq_sq_long='{"tool_name":"Bash","tool_input":{"command":"bd create --type='"'"'epic'"'"' \"X\""}}'
p_import='{"tool_name":"Bash","tool_input":{"command":"bd import issues.jsonl"}}'
# Cobra finds the subcommand PAST any leading global flag, and `create` is not
# the only creation path: `bd create --help` prints `Aliases: create, new`, and
# `bd q` is documented as "Quick capture creates an issue ... Designed for
# scripting and AI agent integration". Each of these five was run against the
# installed bd v1.1.2 and created an epic.
p_epic_flag_before_subcmd='{"tool_name":"Bash","tool_input":{"command":"bd --type epic create \"X\""}}'
p_epic_eqflag_before_subcmd='{"tool_name":"Bash","tool_input":{"command":"bd --type=epic create \"X\""}}'
p_epic_global_dir='{"tool_name":"Bash","tool_input":{"command":"bd -C /tmp/db create -t epic \"X\""}}'
p_epic_alias_new='{"tool_name":"Bash","tool_input":{"command":"bd new -t epic \"X\""}}'
p_epic_quick='{"tool_name":"Bash","tool_input":{"command":"bd q -t epic \"Q1\""}}'
p_import_global_dir='{"tool_name":"Bash","tool_input":{"command":"bd -C /tmp/db import issues.jsonl"}}'
# Bulk creation. `bd create` is documented as "Create a new issue (or batch from
# markdown/graph JSON)", and `bd create --graph plan.json` was run against the
# installed bd v1.1.2: it created an epic plus a parent-child edge with no type
# flag anywhere in the command string, because the type lives in the JSON file.
# `--file` is the same shape. The short form `-f` is deliberately NOT a bulk
# flag — as a bare short flag it would deny any bd command carrying `-f` on any
# subcommand, and `bd create -f plan.md` was never verified to create an epic.
p_bulk_graph='{"tool_name":"Bash","tool_input":{"command":"bd create --graph g.json"}}'
p_bulk_f='{"tool_name":"Bash","tool_input":{"command":"bd create -f plan.md"}}'
p_bulk_file='{"tool_name":"Bash","tool_input":{"command":"bd create --file plan.md"}}'
p_bulk_graph_global='{"tool_name":"Bash","tool_input":{"command":"bd -C /tmp/db create --graph g.json"}}'
p_task_alias_new='{"tool_name":"Bash","tool_input":{"command":"bd new -t task \"X\""}}'
# Not bd. The rule keys on a `bd` token at a word boundary, so a command whose
# name merely contains or extends `bd` must still be allowed.
p_abd_epic='{"tool_name":"Bash","tool_input":{"command":"abd create -t epic \"X\""}}'
p_bdhelper_epic='{"tool_name":"Bash","tool_input":{"command":"bd-helper create -t epic \"X\""}}'
p_task='{"tool_name":"Bash","tool_input":{"command":"bd create -t task \"X\""}}'
p_task_longopt='{"tool_name":"Bash","tool_input":{"command":"bd create --type task \"X\""}}'
p_task_eq_long='{"tool_name":"Bash","tool_input":{"command":"bd create --type=task \"X\""}}'
p_src='{"tool_name":"Write","tool_input":{"file_path":"src/x.js","content":"x"}}'
p_src_edit='{"tool_name":"Edit","tool_input":{"file_path":"src/x.js","old_string":"a","new_string":"b"}}'
p_src_via_docs='{"tool_name":"Write","tool_input":{"file_path":"docs/../src/x.js","content":"x"}}'
p_internal='{"tool_name":"Write","tool_input":{"file_path":".internal/specs/a.md","content":"x"}}'
p_mex='{"tool_name":"Write","tool_input":{"file_path":".mex/lessons.md","content":"x"}}'
p_docs='{"tool_name":"Write","tool_input":{"file_path":"docs/en/x.md","content":"x"}}'
p_assert='{"tool_name":"Bash","tool_input":{"command":"bash scripts/pipeline/tier-gate.sh --assert planning"}}'
p_assert_pty='{"tool_name":"Bash","tool_input":{"command":"script -qec '"'"'bash scripts/pipeline/tier-gate.sh --assert planning'"'"' /dev/null"}}'
p_state_assert='{"tool_name":"Write","tool_input":{"file_path":".internal/pipeline/tier-assert","content":"review"}}'
p_state_session='{"tool_name":"Write","tool_input":{"file_path":".internal/pipeline/session.json","content":"{}"}}'
p_state_dotdot='{"tool_name":"Write","tool_input":{"file_path":".internal/specs/../pipeline/tier-assert","content":"review"}}'
p_state_dblslash='{"tool_name":"Write","tool_input":{"file_path":".internal//pipeline/tier-assert","content":"review"}}'
p_state_dotslash='{"tool_name":"Write","tool_input":{"file_path":"./.internal/pipeline/tier-assert","content":"review"}}'
p_state_bash='{"tool_name":"Bash","tool_input":{"command":"printf '"'"'review\\n'"'"' > .internal/pipeline/tier-assert"}}'
p_pipeline_lookalike='{"tool_name":"Write","tool_input":{"file_path":".internal/pipeline-notes.md","content":"x"}}'
# A file_path carrying an embedded newline. `docs/a\n/../../src/y.js` has the
# components docs, "a\n", "", .., .., src, y.js — it resolves ABOVE the project,
# to a source file, while its first line reads as an allowed docs/ path.
p_newline_escape='{"tool_name":"Write","tool_input":{"file_path":"docs/a\n/../../src/y.js","content":"x"}}'
# Same trick aimed at the state directory: first line "x", real target
# .internal/pipeline/tier-assert.
p_newline_state='{"tool_name":"Write","tool_input":{"file_path":"x\n/../.internal/pipeline/tier-assert","content":"review"}}'
p_malformed='{"tool_name":"Bash","tool_input":'

# --- fixtures ---------------------------------------------------------------

# The satisfied-bundle version is READ from the shipped bundle-root.sh, never
# written as a literal: raising GREAT_CTO_MIN_VERSION would otherwise turn every
# case below into a version-check failure that still looks red for the wrong
# reason. Same precaution as tests/install-shape/selftest.sh.
minver="$(sed -n 's/^GREAT_CTO_MIN_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$root/scripts/pipeline/bundle-root.sh")"
[ -n "$minver" ] || { echo "FAIL: cannot read GREAT_CTO_MIN_VERSION from bundle-root.sh" >&2; exit 1; }

h_full="$(make_home full)";         add_bundle "$h_full" "$minver"; add_tier_map "$h_full"
h_nobundle="$(make_home nobundle)"
h_nomap="$(make_home nomap)";       add_bundle "$h_nomap" "$minver"

c_plan="$(make_cwd plan model-plan-1)"          # planning tier
c_orch="$(make_cwd orch model-orch-only)"       # implementation-orchestration tier
c_unarmed="$(make_cwd unarmed)"                 # no pipeline state at all
c_assertfile="$(make_cwd assertfile)"           # armed by the tier assert file alone
mkdir -p "$c_assertfile/.internal/pipeline"
# `v2 <tier> <session-id>` — the session-bound assert format (D4). A legacy,
# id-less line is treated as absent by resolve_session_tier, so this fixture has
# to carry the real shape or it would arm nothing.
printf 'v2 planning session-assertfile\n' > "$c_assertfile/.internal/pipeline/tier-assert"

# Armed, but the tier cannot be resolved: the harness did not report a model
# (D2 says that is the NORMAL case) and no human has asserted a tier.
c_notier="$(make_cwd notier)"
mkdir -p "$c_notier/.internal/pipeline"
printf '{"model_id":null,"effort":null,"source":"hook","timestamp":"t"}\n' \
  > "$c_notier/.internal/pipeline/session.json"

# Armed and broken: resolve_session_tier's two `return 1` paths.
c_badmodel="$(make_cwd badmodel model-not-in-the-map)"
c_badjson="$(make_cwd badjson)"
mkdir -p "$c_badjson/.internal/pipeline"
printf 'not json at all\n' > "$c_badjson/.internal/pipeline/session.json"

# Absolute file_path payloads. The Write and Edit tools document file_path as
# "must be absolute, not relative", so this — not the relative spelling — is the
# form production actually emits.
abs_payload() { # <cwd> <relative-path> -> a Write payload with an absolute file_path
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s/%s","content":"x"}}' "$1" "$2"
}
pa_src="$(abs_payload "$c_plan" src/x.js)"
pa_internal="$(abs_payload "$c_plan" .internal/specs/a.md)"
pa_mex="$(abs_payload "$c_plan" .mex/lessons.md)"
pa_docs="$(abs_payload "$c_plan" docs/en/x.md)"
pa_state_assert="$(abs_payload "$c_plan" .internal/pipeline/tier-assert)"
pa_state_assert_orch="$(abs_payload "$c_orch" .internal/pipeline/tier-assert)"

# A PATH with no jq on it, for the missing-jq case.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sort head cat mkdir; do ln -sf "$(command -v "$b")" "$nojq/$b"; done

# --- Rule A: only a planning-tier session mutates the plan graph -------------

run "$c_orch" "$h_full" "$p_epic"
check "ruleA-epic-denied" 2
check "ruleA-epic-names-rule-A" 2 'Rule A'
check "ruleA-epic-reason-is-one-line" 2 '^pipeline-guard: only a planning-tier session mutates the plan graph \(Rule A\)$'

run "$c_orch" "$h_full" "$p_import"
check "ruleA-import-denied" 2 'Rule A'

# The same option spelled long, and glued to its value. `bd create --type epic`
# and `bd create -tepic` are the same mutation; a guard that only catches one
# spelling advertises a control it does not have.
run "$c_orch" "$h_full" "$p_epic_longopt"
check "ruleA-long-option-type-epic-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_glued"
check "ruleA-glued-option-tepic-denied" 2 'Rule A'

# The `=`-joined and quoted spellings. Each of these reaches bd as `--type epic`
# and mutates the plan graph; each exits 0 against a pattern that only admits
# whitespace between the flag and its value.
run "$c_orch" "$h_full" "$p_epic_eq_long"
check "ruleA-equals-joined-long-option-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_eq_short"
check "ruleA-equals-joined-short-option-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_dq_long"
check "ruleA-double-quoted-value-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_sq_short"
check "ruleA-single-quoted-value-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_eq_sq_long"
check "ruleA-equals-joined-single-quoted-value-denied" 2 'Rule A'

# A global flag may precede the subcommand, `create` has the alias `new`, and
# `bd q` is a second creation path. Rule A therefore keys on a `bd` invocation
# plus an epic-type flag, not on bd's subcommand grammar.
run "$c_orch" "$h_full" "$p_epic_flag_before_subcmd"
check "ruleA-type-flag-before-the-subcommand-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_eqflag_before_subcmd"
check "ruleA-equals-joined-type-flag-before-the-subcommand-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_global_dir"
check "ruleA-global-flag-before-create-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_alias_new"
check "ruleA-create-alias-new-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_epic_quick"
check "ruleA-quick-capture-denied" 2 'Rule A'

# The import clause gets the same treatment, for the same reason.
run "$c_orch" "$h_full" "$p_import_global_dir"
check "ruleA-import-behind-a-global-flag-denied" 2 'Rule A'

# Bulk creation puts the type out-of-band, in the file the command names, so no
# type flag appears in the command string at all. The bulk-creation flags are
# therefore a third token alternative alongside the type flag and `import`.
run "$c_orch" "$h_full" "$p_bulk_graph"
check "ruleA-bulk-graph-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_bulk_f"
check "ruleA-bulk-short-file-flag-allowed" 0

run "$c_orch" "$h_full" "$p_bulk_file"
check "ruleA-bulk-long-file-flag-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_bulk_graph_global"
check "ruleA-bulk-graph-behind-a-global-flag-denied" 2 'Rule A'

run "$c_orch" "$h_full" "$p_task"
check "ruleA-task-allowed" 0

run "$c_orch" "$h_full" "$p_task_longopt"
check "ruleA-long-option-type-task-allowed" 0

run "$c_orch" "$h_full" "$p_task_eq_long"
check "ruleA-equals-joined-long-option-task-allowed" 0

run "$c_orch" "$h_full" "$p_task_alias_new"
check "ruleA-alias-new-with-a-task-type-allowed" 0

# The word boundary is real: neither of these invokes bd.
run "$c_orch" "$h_full" "$p_abd_epic"
check "ruleA-abd-is-not-bd-allowed" 0

run "$c_orch" "$h_full" "$p_bdhelper_epic"
check "ruleA-bd-helper-is-not-bd-allowed" 0

# Rule A is scoped to non-planning tiers: the planning session is the one that
# is supposed to be creating epics.
run "$c_plan" "$h_full" "$p_epic"
check "ruleA-does-not-fire-on-the-planning-tier" 0

# D17a: an unresolved tier DENIES Rule A, and says how to fix it.
run "$c_notier" "$h_full" "$p_epic"
check "ruleA-unresolved-tier-denies" 2 'Rule A'
check "ruleA-unresolved-tier-names-the---assert-remedy" 2 '\-\-assert'

run "$c_notier" "$h_full" "$p_task"
check "ruleA-unresolved-tier-still-allows-a-task" 0

# --- Rule B: a planning-tier session cannot write source files --------------

run "$c_plan" "$h_full" "$p_src"
check "ruleB-src-write-denied" 2
check "ruleB-src-write-reason-is-one-line" 2 '^pipeline-guard: planning-tier session cannot write source files \(Rule B\)$'

run "$c_plan" "$h_full" "$p_src_edit"
check "ruleB-src-edit-denied" 2 'Rule B'

run "$c_plan" "$h_full" "$p_internal"
check "ruleB-internal-allowed" 0

run "$c_plan" "$h_full" "$p_mex"
check "ruleB-mex-allowed" 0

run "$c_plan" "$h_full" "$p_docs"
check "ruleB-docs-allowed" 0

# The Write and Edit tools require an ABSOLUTE file_path. These four are the
# form the harness actually sends; a relative-only allow-list denies all of them.
run "$c_plan" "$h_full" "$pa_src"
check "ruleB-absolute-src-denied" 2 'Rule B'

run "$c_plan" "$h_full" "$pa_internal"
check "ruleB-absolute-internal-allowed" 0

run "$c_plan" "$h_full" "$pa_mex"
check "ruleB-absolute-mex-allowed" 0

run "$c_plan" "$h_full" "$pa_docs"
check "ruleB-absolute-docs-allowed" 0

# An allowed prefix followed by `..` lands on a source file. The allow-list must
# be read after normalization, not before it.
run "$c_plan" "$h_full" "$p_src_via_docs"
check "ruleB-dotdot-escape-from-docs-denied" 2 'Rule B'

# Normalization must see the WHOLE path. A newline inside file_path must not
# truncate it into a prefix that reads as allowed.
run "$c_plan" "$h_full" "$p_newline_escape"
check "ruleB-newline-in-path-does-not-truncate-the-allow-list-check" 2 'Rule B'

# Rule B is scoped to the planning tier: an implementation session writes source.
run "$c_orch" "$h_full" "$p_src"
check "ruleB-does-not-fire-off-the-planning-tier" 0

# D17a: Rule B stays INERT when the tier is unresolved. Denying every Write in
# that state would brick a session with no model-side remedy, because --assert
# is human-only under D13.
run "$c_notier" "$h_full" "$p_src"
check "ruleB-unresolved-tier-stays-inert" 0

# The tier assert file is the other arming channel, and resolves a tier too.
run "$c_assertfile" "$h_full" "$p_src"
check "ruleB-fires-when-the-tier-came-from-the-tier-assert-file" 2 'Rule B'

# --- Rule C: --assert is human-only (D13a) ----------------------------------

run "$c_plan" "$h_full" "$p_assert"
check "ruleC-bare-assert-denied" 2
check "ruleC-bare-assert-reason-is-one-line" 2 '^pipeline-guard: --assert is human-only; ask the user to run it \(Rule C\)$'

# A model can defeat tier-gate's tty check by wrapping the call in `script`.
# The guard must match the pattern anywhere in the command string.
run "$c_plan" "$h_full" "$p_assert_pty"
check "ruleC-script-wrapped-assert-denied" 2 'Rule C'

# Rule C applies at every tier, not only planning.
run "$c_orch" "$h_full" "$p_assert"
check "ruleC-denied-at-a-non-planning-tier-too" 2 'Rule C'

# --- Rule D: the pipeline state directory is not model-writable (D13b) ------

run "$c_plan" "$h_full" "$p_state_assert"
check "ruleD-write-to-tier-assert-denied" 2
check "ruleD-write-to-tier-assert-reason-is-one-line" 2 '^pipeline-guard: the pipeline state directory is not model-writable \(Rule D\)$'

run "$c_plan" "$h_full" "$p_state_session"
check "ruleD-write-to-session-json-denied" 2 'Rule D'

run "$c_plan" "$h_full" "$p_state_bash"
check "ruleD-bash-redirect-into-the-state-dir-denied" 2 'Rule D'

# Four path spellings that all RESOLVE inside the state directory. D13b requires
# resolution, not a substring test: each of these reaches the same file.
run "$c_plan" "$h_full" "$p_state_dotdot"
check "ruleD-dotdot-path-denied" 2 'Rule D'

run "$c_plan" "$h_full" "$p_state_dblslash"
check "ruleD-double-slash-path-denied" 2 'Rule D'

run "$c_plan" "$h_full" "$p_state_dotslash"
check "ruleD-leading-dot-slash-path-denied" 2 'Rule D'

run "$c_plan" "$h_full" "$pa_state_assert"
check "ruleD-absolute-path-denied" 2 'Rule D'

# Rule D is evaluated before Rule B's .internal/ allowance, and at every tier.
run "$c_orch" "$h_full" "$p_state_assert"
check "ruleD-denied-at-a-non-planning-tier-too" 2 'Rule D'

run "$c_orch" "$h_full" "$pa_state_assert_orch"
check "ruleD-absolute-path-denied-at-a-non-planning-tier-too" 2 'Rule D'

run "$c_plan" "$h_full" "$p_internal"
check "ruleD-leaves-rule-Bs-internal-allowance-intact" 0

# `.internal/pipeline-notes.md` is not inside the state directory. Rule D is
# component-anchored, so it does not swallow a same-prefix sibling.
run "$c_plan" "$h_full" "$p_pipeline_lookalike"
check "ruleD-does-not-fire-on-a-same-prefix-sibling" 0

# Off the planning tier Rule D is the only rule reading file_path, so a newline
# that truncates the path is a clean bypass of the state-directory deny.
run "$c_orch" "$h_full" "$p_newline_state"
check "ruleD-newline-in-path-does-not-truncate-the-state-dir-check" 2 'Rule D'

# --- unarmed: no pipeline state -> allow everything, cost nothing -----------
# No bundle root, no tier-map and no jq on PATH, because phase 1 must not touch
# any of them. Every payload above, plus malformed stdin, must exit 0.

PATH_OVERRIDE="$nojq"
unarmed_bad=0
for p in "$p_epic" "$p_epic_longopt" "$p_epic_glued" "$p_import" "$p_task" \
         "$p_epic_eq_long" "$p_epic_eq_short" "$p_epic_dq_long" \
         "$p_epic_sq_short" "$p_epic_eq_sq_long" "$p_task_eq_long" \
         "$p_epic_flag_before_subcmd" "$p_epic_eqflag_before_subcmd" \
         "$p_epic_global_dir" "$p_epic_alias_new" "$p_epic_quick" \
         "$p_import_global_dir" "$p_task_alias_new" "$p_abd_epic" \
         "$p_bdhelper_epic" \
         "$p_src" "$p_src_edit" "$p_src_via_docs" "$p_internal" "$p_mex" \
         "$p_docs" "$p_assert" "$p_assert_pty" "$p_state_assert" \
         "$p_state_session" "$p_state_dotdot" "$p_state_dblslash" \
         "$p_state_dotslash" "$p_state_bash" "$p_pipeline_lookalike" \
         "$p_newline_escape" "$p_newline_state" \
         "$pa_src" "$pa_state_assert" "$p_malformed"; do
  run "$c_unarmed" "$h_nobundle" "$p"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL unarmed-allows-all: exit $rc on payload: $p"
    unarmed_bad=$((unarmed_bad+1)); fails=$((fails+1))
  fi
done
unset PATH_OVERRIDE
[ "$unarmed_bad" -eq 0 ] && echo "PASS unarmed-allows-all"

# --- armed error paths: strict fail-closed ----------------------------------

run "$c_plan" "$h_full" "$p_malformed"
check "armed-malformed-stdin-denies" 2
check "armed-malformed-stdin-says-pipeline-guard" 2 '^pipeline-guard: '

PATH_OVERRIDE="$nojq"
run "$c_plan" "$h_full" "$p_task"
check "armed-missing-jq-denies" 2 'jq'
unset PATH_OVERRIDE

run "$c_plan" "$h_nobundle" "$p_task"
check "armed-missing-bundle-root-denies" 2

run "$c_plan" "$h_nomap" "$p_task"
check "armed-missing-tier-map-denies" 2

# resolve_session_tier's two error returns. Neither is reachable from any case
# above, and both must deny rather than fall through to an unresolved tier.
run "$c_badmodel" "$h_full" "$p_task"
check "armed-model-absent-from-tier-map-denies" 2 '^pipeline-guard: '

run "$c_badjson" "$h_full" "$p_task"
check "armed-unparsable-session-json-denies" 2 '^pipeline-guard: '

# The guard's own diagnostics must not leak into the deny reason. resolve_bundle_root
# and resolve_session_tier both print multi-line advice on stderr; the guard's call
# sites suppress it, and a PreToolUse deny reason is one line.
run "$c_badmodel" "$h_full" "$p_task"
if [ "$rc" -eq 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ]; then
  echo "PASS armed-model-absent-from-tier-map-reason-is-one-line"
else
  echo "FAIL armed-model-absent-from-tier-map-reason-is-one-line: exit $rc, stderr: $err"
  fails=$((fails+1))
fi

# --- stdout must stay empty on every path -----------------------------------
# Claude Code parses hook stdout as JSON directives, so anything the guard
# prints there is a directive it did not mean to issue.

if [ -z "$stray_stdout" ]; then
  echo "PASS guard-never-writes-to-stdout"
else
  echo "FAIL guard-never-writes-to-stdout: $stray_stdout"
  fails=$((fails+1))
fi

# --- dispatch path: run-hook.cmd must fail closed when bash is absent (D17b) -
# The Windows batch branch cannot execute on this platform, so this is a static
# assertion on the source. A PreToolUse guard whose dispatcher exits 0 when it
# cannot find bash is an absent security control, not a degraded one.

if grep -qE '^exit /b 0[[:space:]]*$' "$root/hooks/run-hook.cmd"; then
  echo "FAIL run-hook-cmd-fails-closed-without-bash: batch branch still ends 'exit /b 0'"
  fails=$((fails+1))
else
  echo "PASS run-hook-cmd-fails-closed-without-bash"
fi

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: pipeline-guard ($fails failing)"; exit 1; fi
echo "PASS: pipeline-guard"
