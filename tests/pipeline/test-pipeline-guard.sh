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

# Every case runs under a scratch HOME, and the anchor cases below create the
# install anchor and the integrity record inside it. A suite that ran against
# the real $HOME would rewrite the developer's own install, so the separation is
# asserted before the first case rather than assumed.
if [ -z "$TMP" ] || [ "$TMP" = "$HOME" ]; then
  echo "FAIL sandbox-home-differs-from-the-real-home: refusing to run against '$HOME'"
  exit 1
fi
echo "PASS sandbox-home-differs-from-the-real-home"
# The integrity cache marker hangs off XDG_RUNTIME_DIR, so it is namespaced into
# this run's temp dir: two suites running at once, or a stale marker from an
# earlier run, must never satisfy a case here.
mkdir -p "$TMP/xdg"

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
  # GUARD_OVERRIDE runs a COPY of the guard instead of this repo's — the anchored
  # copy, for the cases that tamper with the bundle-root.sh it sources.
  local cwd="$1" home="$2" payload="$3"
  ( cd "$cwd" && HOME="$home" XDG_RUNTIME_DIR="$TMP/xdg" \
      PATH="${PATH_OVERRIDE:-$PATH}" "$BASH" "${GUARD_OVERRIDE:-$guard}" ) \
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
# to carry the real shape or it would not even arm Phase 1. It resolves a tier
# only for a payload whose session_id is `session-assertfile`.
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

# The tier assert file is the other arming channel, and this payload carries no
# session_id, so the guard calls resolve_session_tier with the `-` sentinel and
# a v2 assert is treated as ABSENT (D4) — the tier stays unresolved and Rule B
# stays inert, exactly as for c_notier above. Rule B only ever restricts, so
# nothing escalates here; the fail-closed half is asserted immediately below,
# and the bound half (a payload id matching the assert) in the identity section.
run "$c_assertfile" "$h_full" "$p_src"
check "ruleB-inert-while-the-unbound-guard-treats-the-tier-assert-as-absent" 0

# The direction that matters: an assert nothing verified buys no plan-graph
# permission. Rule A denies on the unresolved tier rather than trusting it.
run "$c_assertfile" "$h_full" "$p_epic"
check "ruleA-unbound-tier-assert-does-not-authorize-the-plan-graph" 2 'Rule A'

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

# --- Rule B: the plans/ allow-list (D6) -------------------------------------
# writing-plans commits plans to a tracked plans/ directory, so a planning
# session has to be able to write one. The entry is component-anchored like the
# three beside it: it admits plans/, never plansX/.

p_plan_doc='{"tool_name":"Write","tool_input":{"file_path":"plans/x.md","content":"x"}}'
p_plan_lookalike='{"tool_name":"Write","tool_input":{"file_path":"plansX/y.md","content":"x"}}'
p_src_ts='{"tool_name":"Write","tool_input":{"file_path":"src/x.ts","content":"x"}}'
pa_plan_doc="$(abs_payload "$c_plan" plans/x.md)"

run "$c_plan" "$h_full" "$p_plan_doc"
check "ruleB-plans-write-allowed-on-the-planning-tier" 0

run "$c_plan" "$h_full" "$pa_plan_doc"
check "ruleB-absolute-plans-write-allowed-on-the-planning-tier" 0

run "$c_plan" "$h_full" "$p_plan_lookalike"
check "ruleB-plans-allow-list-is-component-anchored" 2 'Rule B'

run "$c_plan" "$h_full" "$p_src_ts"
check "ruleB-src-ts-still-denied" 2 'Rule B'

# --- NotebookEdit joins the Write|Edit class (cv6.6) ------------------------
# NotebookEdit writes a file the same way Write and Edit do, so leaving it out
# of Rules B and D advertises a control the guard does not have. It names its
# path `notebook_path`, not `file_path` — the guard reads both.

nb_payload() { # <path> -> a NotebookEdit payload naming that notebook
  printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s","new_source":"x"}}' "$1"
}

run "$c_plan" "$h_full" "$(nb_payload src/x.ipynb)"
check "ruleB-notebook-edit-of-a-source-notebook-denied" 2 'Rule B'

run "$c_plan" "$h_full" "$(nb_payload docs/en/x.ipynb)"
check "ruleB-notebook-edit-inside-docs-allowed" 0

run "$c_orch" "$h_full" "$(nb_payload .internal/pipeline/session.json)"
check "ruleD-notebook-edit-of-the-state-dir-denied" 2 'Rule D'

# --- Rule D, bounded: the install surface (SEC-D3-RULE-D) -------------------
# The two anchors, the gate and hook files served THROUGH them, and the
# integrity record's directory are not model-writable: anything that can edit
# them can rewrite the gate that is judging it. The bound is the anchor
# SPELLING — a clone reached as the working project is ordinary source.

home_payload() { # <home> <path-under-home> [tool] -> a Write/Edit payload
  case "${3:-Write}" in
    Edit) printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/%s","old_string":"a","new_string":"b"}}' "$1" "$2" ;;
    NotebookEdit) printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/%s","new_source":"x"}}' "$1" "$2" ;;
    *) printf '{"tool_name":"Write","tool_input":{"file_path":"%s/%s","content":"x"}}' "$1" "$2" ;;
  esac
}

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/great_cto)"
check "ruleD-write-to-the-great_cto-anchor-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers)"
check "ruleD-write-to-the-beads-superpowers-anchor-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/scripts/pipeline/tier-gate.sh)"
check "ruleD-write-to-a-gate-through-the-anchor-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/hooks/pipeline-guard Edit)"
check "ruleD-edit-of-a-hook-through-the-anchor-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/great_cto/scripts/pipeline/x.sh)"
check "ruleD-write-under-the-great_cto-pipeline-dir-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/great_cto/hooks/session-start)"
check "ruleD-write-under-the-great_cto-hooks-dir-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/hooks/pipeline-guard NotebookEdit)"
check "ruleD-notebook-edit-through-the-anchor-denied" 2 'Rule D'

# The bound is `<anchor>/scripts/`, not `<anchor>/scripts/pipeline/`: the control
# files live outside the pipeline/ subdirectory too, and a rule that stops at
# pipeline/ leaves them model-writable through the anchor.
run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/scripts/scan-plan.sh)"
check "ruleD-write-to-a-script-outside-pipeline-through-the-anchor-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/great_cto/scripts/x.sh)"
check "ruleD-write-to-a-great_cto-script-outside-pipeline-denied" 2 'Rule D'

# The tier-map is the file the whole tier wall is read from: anything that can
# rewrite it can put its own model on the planning tier.
run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/great_cto/shared/tier-map.json)"
check "ruleD-write-to-the-great_cto-tier-map-denied" 2 'Rule D'

# A trailing slash on $HOME must not disable the install-surface half: the
# anchors are built off ${HOME%/}, so `/home/u/` and `/home/u` spell one anchor.
run "$c_orch" "$h_full/" "$(home_payload "$h_full" .agents/beads-superpowers/hooks/pipeline-guard)"
check "ruleD-install-surface-survives-a-trailing-slash-in-HOME" 2 'Rule D'

run "$c_orch" "$h_full/" "$(home_payload "$h_full" .local/state/beads-superpowers/record.json)"
check "ruleD-record-directory-survives-a-trailing-slash-in-HOME" 2 'Rule D'

# The integrity record is the thing the whole check rests on (SEC-R3-RECORD).
run "$c_orch" "$h_full" "$(home_payload "$h_full" .local/state/beads-superpowers/record.json)"
check "ruleD-write-to-the-integrity-record-denied" 2 'Rule D'

run "$c_orch" "$h_full" "$(home_payload "$h_full" .local/state/beads-superpowers)"
check "ruleD-write-to-the-record-directory-denied" 2 'Rule D'

# The bound, asserted: the rule covers the gate and hook surfaces served through
# the anchor, not the whole tree under it. A skill file is prose, not a gate.
run "$c_orch" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/skills/x/SKILL.md)"
check "ruleD-does-not-swallow-the-rest-of-the-anchor" 0

# A development clone reached AS THE WORKING PROJECT is ordinary source: an
# unbounded "and their targets" rule would brick every clone on the machine.
c_clone="$(make_cwd clone model-orch-only)"
mkdir -p "$c_clone/scripts/pipeline"
p_clone_rel='{"tool_name":"Edit","tool_input":{"file_path":"scripts/pipeline/tier-gate.sh","old_string":"a","new_string":"b"}}'
run "$c_clone" "$h_full" "$p_clone_rel"
check "ruleD-edit-inside-the-working-project-clone-allowed" 0

run "$c_clone" "$h_full" "$(home_payload "$h_full" .agents/beads-superpowers/scripts/pipeline/tier-gate.sh Edit)"
check "ruleD-the-same-file-spelled-through-the-anchor-denied" 2 'Rule D'

# --- identity: a state file written by a DIFFERENT session (D4) -------------
# The payload's session_id is the live identity. The recorded id is read
# straight out of session.json, so "another session wrote this" stays distinct
# from "no tier resolved": a mismatch denies Rule A AND Rule B, an unresolved
# tier denies only Rule A.

make_sid_cwd() { # <name> <model> <recorded-session-id> -> working dir
  local cwd="$TMP/cwd-$1"; mkdir -p "$cwd/.internal/pipeline"
  printf '{"model_id":"%s","session_id":"%s","effort":null,"source":"hook","timestamp":"t"}\n' \
    "$2" "$3" > "$cwd/.internal/pipeline/session.json"
  printf '%s' "$cwd"
}
sid_epic() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"bd create -t epic \\"X\\""}}' "$1"; }
sid_task() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"bd create -t task \\"X\\""}}' "$1"; }
sid_src()  { printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"src/x.ts","content":"x"}}' "$1"; }
sid_docs() { printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"docs/en/x.md","content":"x"}}' "$1"; }

# ONE fixture, both denies. The recorded model sits on a non-planning tier, so
# neither deny can be explained by the tier: only the identity mismatch produces
# them, and Rule B could not have been reached by assigning is_planning.
c_mismatch="$(make_sid_cwd mismatch model-orch-only sess-recorded)"

run "$c_mismatch" "$h_full" "$(sid_epic sess-live)"
check "identity-mismatch-denies-the-plan-graph" 2 'Rule A'
check "identity-mismatch-rule-A-names-the-bound-assert-remedy" 2 '\-\-assert <tier> --session sess-live'
check "identity-mismatch-rule-A-names-an-absolute-gate-path" 2 'bash /.*/scripts/pipeline/tier-gate\.sh --assert'

run "$c_mismatch" "$h_full" "$(sid_src sess-live)"
check "identity-mismatch-denies-a-source-write" 2 'Rule B'
check "identity-mismatch-rule-B-names-the-bound-assert-remedy" 2 '\-\-assert <tier> --session sess-live'

# The mismatch is a Phase-2 state: Phase 1 arms on the file's existence, so a
# mismatched state file can never early-exit its way out of the rules.
run "$c_mismatch" "$h_full" "$(sid_docs sess-live)"
check "identity-mismatch-keeps-the-rule-B-allow-list" 0

# The same fixture with the MATCHING id resolves normally — proof the mismatch
# deny came from the identity check and not from the fixture being unreadable.
run "$c_mismatch" "$h_full" "$(sid_src sess-recorded)"
check "identity-match-on-a-non-planning-tier-allows-a-source-write" 0

run "$c_mismatch" "$h_full" "$(sid_epic sess-recorded)"
check "identity-match-still-denies-the-plan-graph-off-the-planning-tier" 2 'Rule A'

# A matching id on the PLANNING tier: Rule B fires as itself, with its own
# reason, never the mismatch reason.
c_plan_sid="$(make_sid_cwd plansid model-plan-1 sess-live)"
run "$c_plan_sid" "$h_full" "$(sid_src sess-live)"
check "identity-match-on-the-planning-tier-denies-with-rule-Bs-own-reason" 2 \
  '^pipeline-guard: planning-tier session cannot write source files \(Rule B\)$'

run "$c_plan_sid" "$h_full" "$(sid_epic sess-live)"
check "identity-match-on-the-planning-tier-allows-the-plan-graph" 0

# State with NO recorded id is not a mismatch — it is unbindable, so it is
# treated as absent: Rule A denies, Rule B stays inert (D17a).
run "$c_plan" "$h_full" "$(sid_epic sess-live)"
check "identity-unbindable-state-denies-the-plan-graph" 2 'Rule A'

run "$c_plan" "$h_full" "$(sid_src sess-live)"
check "identity-unbindable-state-leaves-rule-B-inert" 0

# A payload with no session_id at all keeps the pre-identity posture: there is
# nothing to bind against, so session.json's model is still authoritative and a
# v2 assert is still treated as absent. Asserting it here is what stops the
# absent case from silently drifting into the mismatch case.
run "$c_plan" "$h_full" "$p_src"
check "identity-absent-payload-id-keeps-the-session-state-authoritative" 2 'Rule B'

# With the live id fed in, a v2 tier-assert bound to THAT session resolves — the
# other half of D4, and the reason the assert file carries an id at all.
run "$c_assertfile" "$h_full" "$(sid_src session-assertfile)"
check "identity-bound-tier-assert-resolves-the-planning-tier" 2 'Rule B'

run "$c_assertfile" "$h_full" "$(sid_src other-session)"
check "identity-tier-assert-bound-to-another-session-stays-absent" 0

# --- end to end: the id the hook writes is the id the guard binds on (D4) ----
# Every case above hand-writes session.json. That leaves the one thing D4
# actually rests on untested: hooks/session-start has to RECORD the payload's
# session_id, or the recorded id is absent on every armed project, the tier
# never resolves, and Rule B is inert everywhere. This case builds session.json
# by RUNNING the hook, then runs the guard against it with the same id — so the
# dependency between the two files is pinned mechanically, not by inspection.
h_e2e="$(make_home e2e)"; add_bundle "$h_e2e" "$minver"; add_tier_map "$h_e2e"
c_e2e="$TMP/cwd-e2e"; mkdir -p "$c_e2e"
( cd "$c_e2e" && HOME="$h_e2e" XDG_RUNTIME_DIR="$TMP/xdg" "$BASH" "$root/hooks/session-start" \
    <<<'{"session_id":"sess-e2e","source":"startup","hook_event_name":"SessionStart","model":"model-plan-1"}' \
  ) >/dev/null 2>&1
e2e_state="$c_e2e/.internal/pipeline/session.json"
if grep -Eq '"session_id"[[:space:]]*:[[:space:]]*"sess-e2e"' "$e2e_state" 2>/dev/null; then
  echo "PASS e2e-session-start-records-the-payload-session-id"
else
  echo "FAIL e2e-session-start-records-the-payload-session-id: $(cat "$e2e_state" 2>/dev/null)"
  fails=$((fails+1))
fi

run "$c_e2e" "$h_e2e" "$(sid_src sess-e2e)"
check "e2e-hook-written-state-resolves-the-planning-tier-and-rule-B-denies" 2 'Rule B'

run "$c_e2e" "$h_e2e" "$(sid_docs sess-e2e)"
check "e2e-hook-written-state-keeps-the-rule-B-allow-list" 0

# The two sides have to SPELL the id the same way. session-start records it
# through `tr -cd 'a-zA-Z0-9_-' | cut -c1-64`; a guard that compared the payload
# raw would read every call of a session whose id carries anything else — a dot,
# a colon, or more than 64 bytes — as an identity mismatch, denying Rules A and B
# for the whole session and printing a remedy that carries the raw id the writer
# would mangle again. The fixture model sits on a NON-planning tier, so a source
# write is allowed when the id binds and denied only if it reads as a mismatch.
h_e2ed="$(make_home e2edot)"; add_bundle "$h_e2ed" "$minver"; add_tier_map "$h_e2ed"
c_e2ed="$TMP/cwd-e2edot"; mkdir -p "$c_e2ed"
( cd "$c_e2ed" && HOME="$h_e2ed" XDG_RUNTIME_DIR="$TMP/xdg" "$BASH" "$root/hooks/session-start" \
    <<<'{"session_id":"sess.dot.e2e","source":"startup","hook_event_name":"SessionStart","model":"model-orch-only"}' \
  ) >/dev/null 2>&1
run "$c_e2ed" "$h_e2ed" "$(sid_src sess.dot.e2e)"
check "e2e-a-dotted-session-id-binds-instead-of-reading-as-a-mismatch" 0

run "$c_e2ed" "$h_e2ed" "$(sid_epic sess.dot.e2e)"
check "e2e-a-dotted-session-id-denies-the-plan-graph-on-its-own-tier-not-on-a-mismatch" 2 \
  '^pipeline-guard: only a planning-tier session mutates the plan graph \(Rule A\)$'

# Sanitizing is not the same as ignoring: a genuinely different session is still
# a mismatch after both sides are folded.
run "$c_e2ed" "$h_e2ed" "$(sid_src other.session.id)"
check "e2e-sanitization-still-catches-a-genuinely-different-session" 2 'Rule B'

# --- Phase-2 install integrity (D3, R4-004) ---------------------------------
# verify_record's four failure states are a DENY AT EXIT 2 here: exit 1 does not
# block a PreToolUse call, so "nonzero" is not the assertion — 2 is. The check
# lives inside Phase 2, after the activation early exit, so an unarmed project
# with a corrupted record is still never denied.

if command -v sha256sum >/dev/null 2>&1; then sha_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then sha_cmd=(shasum -a 256)
else sha_cmd=(); fi
sha256_of() { local o; o="$("${sha_cmd[@]}" "$1")"; printf '%s' "${o%% *}"; }

write_record() { # <home> <target> [posture] — the out-of-anchor integrity record
  local rec="$1/.local/state/beads-superpowers" first=1 f
  mkdir -p "$rec"
  { printf '{"anchor":"%s/.agents/beads-superpowers","target":"%s","posture":"%s","hashes":{' \
      "$1" "$2" "${3:-manifest-backed}"
    for f in scripts/pipeline/tier-gate.sh scripts/pipeline/bundle-root.sh \
             scripts/pipeline/graph-lint.mjs hooks/pipeline-guard; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s":"%s"' "$f" "$(sha256_of "$2/$f")"
    done
    printf '}}\n'
  } > "$rec/record.json"
}

make_anchor_home() { # <name> [posture] -> HOME with a bundle, a populated anchor and a matching record
  local home="$TMP/home-$1" target="$TMP/target-$1"
  mkdir -p "$home/.agents" "$target/scripts/pipeline" "$target/hooks"
  add_bundle "$home" "$minver"; add_tier_map "$home"
  cp -f "$root/scripts/pipeline/tier-gate.sh" "$root/scripts/pipeline/bundle-root.sh" \
        "$root/scripts/pipeline/graph-lint.mjs" "$target/scripts/pipeline/"
  cp -f "$root/hooks/pipeline-guard" "$target/hooks/"
  ln -sfn "$target" "$home/.agents/beads-superpowers"
  write_record "$home" "$target" "${2:-manifest-backed}"
  printf '%s' "$home"
}

if [ "${#sha_cmd[@]}" -eq 0 ]; then
  echo "SKIP integrity cases (neither sha256sum nor shasum installed)"
else
  h_anchor="$(make_anchor_home integrity-ok)"
  c_int="$(make_cwd integrity model-orch-only)"

  run "$c_int" "$h_anchor" "$p_task"
  check "integrity-a-record-that-verifies-allows-the-call" 0

  # The Phase-1 contract, unchanged: an unarmed project never reaches Phase 2,
  # so a deleted record cannot deny it.
  h_norecord="$(make_anchor_home integrity-norecord)"
  rm -f "$h_norecord/.local/state/beads-superpowers/record.json"
  run "$c_unarmed" "$h_norecord" "$p_task"
  check "integrity-unarmed-project-with-a-deleted-record-is-not-denied" 0

  run "$c_int" "$h_norecord" "$p_task"
  check "integrity-deleted-record-under-a-present-anchor-denies-at-exit-2" 2 'install\.sh'

  h_tampered="$(make_anchor_home integrity-tampered)"
  printf '# tampered\n' >> "$TMP/target-integrity-tampered/scripts/pipeline/tier-gate.sh"
  run "$c_int" "$h_tampered" "$p_task"
  check "integrity-tampered-hash-denies-at-exit-2" 2 'integrity'
  # verify_record prints a NOTE line before its ERROR whenever the running gate
  # is outside the attested target — which is exactly this suite's situation. A
  # PreToolUse deny reason is ONE line, so the guard must not forward both.
  if [ "$rc" -eq 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ]; then
    echo "PASS integrity-deny-reason-is-one-line"
  else
    echo "FAIL integrity-deny-reason-is-one-line: exit $rc, stderr: $err"
    fails=$((fails+1))
  fi

  h_unreadable="$(make_anchor_home integrity-unreadable)"
  printf '{"anchor": ' > "$h_unreadable/.local/state/beads-superpowers/record.json"
  run "$c_int" "$h_unreadable" "$p_task"
  check "integrity-unparsable-record-denies-at-exit-2" 2 'install\.sh'

  # A missing hashing tool is treated exactly as an unreadable record: the
  # alternative is a silent pass on an unverified root.
  nosha="$TMP/bin-nosha"; mkdir -p "$nosha"
  for b in bash jq cat dirname sort head mkdir chmod stat id; do
    bp="$(command -v "$b")" && ln -sf "$bp" "$nosha/$b"
  done
  PATH_OVERRIDE="$nosha"
  run "$c_int" "$h_anchor" "$p_task"
  unset PATH_OVERRIDE
  check "integrity-missing-hash-tool-denies-at-exit-2" 2 'sha256'

  # Hashing every gate file on every Bash/Write/Edit call would be a fork storm
  # on the hot path, so a PASS is cached once per session, keyed on the RECORD's
  # mtime. The three cases below are that contract: cached, still cached after a
  # hashed file changes (between-call detection, disclosed), re-verified the
  # moment the record itself is rewritten.
  h_cache="$(make_anchor_home integrity-cache)"
  c_cache="$(make_cwd cache model-orch-only)"
  rec_cache="$h_cache/.local/state/beads-superpowers/record.json"
  touch -m -t 202001010000 "$rec_cache"
  run "$c_cache" "$h_cache" "$(sid_task sess-cache)"
  check "integrity-cached-verification-allows-the-call" 0
  if find "$TMP/xdg" -name 'integrity-sess-cache-*' 2>/dev/null | grep -q .; then
    echo "PASS integrity-verification-is-cached-per-session"
  else
    echo "FAIL integrity-verification-is-cached-per-session: no marker under $TMP/xdg"
    fails=$((fails+1))
  fi

  printf '# tampered\n' >> "$TMP/target-integrity-cache/scripts/pipeline/tier-gate.sh"
  run "$c_cache" "$h_cache" "$(sid_task sess-cache)"
  check "integrity-cache-key-is-the-record-not-the-hashed-files" 0

  touch -m -t 202001010001 "$rec_cache"
  run "$c_cache" "$h_cache" "$(sid_task sess-cache)"
  check "integrity-a-rewritten-record-re-verifies-and-denies" 2 'integrity'

  # A failure is never cached: the very next call must deny again.
  run "$c_cache" "$h_cache" "$(sid_task sess-cache)"
  check "integrity-a-failure-is-never-cached" 2 'integrity'

  # --- the check may not trust the file that implements it (SEC-R3-RECORD) ---
  # verify_record lives in bundle-root.sh, and bundle-root.sh is itself a
  # manifest entry. Sourcing first and calling it afterwards means appending
  # `verify_record() { return 0; }` to the anchored copy disables the check that
  # would have caught the append. So the guard hashes the bundle-root.sh it is
  # about to source against the record BEFORE sourcing it.
  # The guard under test here is the ANCHORED COPY — that is the only way its
  # `dirname $0` sibling is the tampered file, which is what production does.
  h_selfcheck="$(make_anchor_home integrity-selfcheck)"
  printf 'verify_record() { return 0; }\n' \
    >> "$TMP/target-integrity-selfcheck/scripts/pipeline/bundle-root.sh"
  GUARD_OVERRIDE="$h_selfcheck/.agents/beads-superpowers/hooks/pipeline-guard"
  run "$c_int" "$h_selfcheck" "$(sid_task sess-selfcheck)"
  check "integrity-a-neutered-bundle-root-is-caught-before-it-is-sourced" 2 'bundle-root\.sh'

  # A record that attests nothing about the file cannot license sourcing it: a
  # manifest-backed posture whose manifest has no entry for bundle-root.sh is a
  # deny, not a skip.
  h_noentry="$(make_anchor_home integrity-noentry)"
  GUARD_OVERRIDE="$h_noentry/.agents/beads-superpowers/hooks/pipeline-guard"
  printf '{"anchor":"%s/.agents/beads-superpowers","target":"%s","posture":"manifest-backed","hashes":{"hooks/pipeline-guard":"%s"}}\n' \
    "$h_noentry" "$TMP/target-integrity-noentry" \
    "$(sha256_of "$TMP/target-integrity-noentry/hooks/pipeline-guard")" \
    > "$h_noentry/.local/state/beads-superpowers/record.json"
  run "$c_int" "$h_noentry" "$(sid_task sess-noentry)"
  check "integrity-an-unattested-bundle-root-denies-at-exit-2" 2 'bundle-root\.sh'

  # A hash tool is required to run the pre-source check at all, so its absence is
  # a deny — the same posture verify_record already takes.
  GUARD_OVERRIDE="$h_anchor/.agents/beads-superpowers/hooks/pipeline-guard"
  PATH_OVERRIDE="$nosha"
  run "$c_int" "$h_anchor" "$(sid_task sess-nosha-anchored)"
  unset PATH_OVERRIDE
  check "integrity-pre-source-check-denies-when-no-hash-tool-exists" 2 'sha256'

  # Declared-advisory postures attest nothing, so there is nothing to check
  # against and the pre-source check stands down — the same carve-out
  # verify_record makes for an unpinned root.
  h_advisory="$(make_anchor_home integrity-advisory dev-clone-advisory)"
  printf '# advisory tampering\n' \
    >> "$TMP/target-integrity-advisory/scripts/pipeline/bundle-root.sh"
  GUARD_OVERRIDE="$h_advisory/.agents/beads-superpowers/hooks/pipeline-guard"
  run "$c_int" "$h_advisory" "$(sid_task sess-advisory)"
  check "integrity-dev-clone-advisory-posture-is-not-denied" 0
  unset GUARD_OVERRIDE

  # --- the pre-source check hashes the ATTESTED copy, not a sibling ---------
  # The record attests files under record.target. A guard running from OUTSIDE
  # that target — two supported channels installed at skewed versions, or a
  # repo-relative invocation — has a sibling bundle-root.sh that the record
  # says nothing about, so comparing THAT file against the record's hash denies
  # every single tool call, with a remedy (re-run install.sh) that re-attests
  # the other root and changes nothing. The three cases below fix the subject of
  # the hash to the copy the record actually attests, which is the same subject
  # verify_record uses for the rest of the manifest.
  h_skew="$(make_anchor_home integrity-skew)"
  printf '\n# skewed channel: this copy is not byte-identical to the repo sibling\n' \
    >> "$TMP/target-integrity-skew/scripts/pipeline/bundle-root.sh"
  write_record "$h_skew" "$TMP/target-integrity-skew"
  run "$c_int" "$h_skew" "$p_task"
  check "integrity-skewed-channels-hash-the-attested-copy-not-the-guards-sibling" 0

  # ...and SOURCE it too. The attested copy here raises the great_cto floor to a
  # version no fixture bundle satisfies, so the deny reason names the floor only
  # if the attested copy is what got sourced; the repo's own sibling would have
  # accepted the fixture bundle and allowed the call.
  h_skewsrc="$(make_anchor_home integrity-skew-sourced)"
  sed -i.bak 's/^GREAT_CTO_MIN_VERSION=.*/GREAT_CTO_MIN_VERSION="999.0.0"/' \
    "$TMP/target-integrity-skew-sourced/scripts/pipeline/bundle-root.sh"
  rm -f "$TMP/target-integrity-skew-sourced/scripts/pipeline/bundle-root.sh.bak"
  write_record "$h_skewsrc" "$TMP/target-integrity-skew-sourced"
  run "$c_int" "$h_skewsrc" "$p_task"
  check "integrity-skewed-channels-source-the-attested-copy" 2 'below the required version'

  # A tampered attested copy is caught by the PRE-SOURCE check — before the
  # function it defines is trusted — not later by verify_record. The message
  # tells the two apart: the pre-source deny names the manifest key, the
  # verify_record deny names an absolute path under the target.
  h_skewtamper="$(make_anchor_home integrity-skew-tampered)"
  printf 'verify_record() { return 0; }\n' \
    >> "$TMP/target-integrity-skew-tampered/scripts/pipeline/bundle-root.sh"
  run "$c_int" "$h_skewtamper" "$p_task"
  check "integrity-a-tampered-attested-copy-is-caught-before-it-is-sourced" 2 \
    'install integrity: scripts/pipeline/bundle-root\.sh does not match its recorded hash'

  # Nothing to hash and nothing to source is a deny, never a fall-back to the
  # unattested sibling.
  h_skewgone="$(make_anchor_home integrity-skew-missing)"
  rm -f "$TMP/target-integrity-skew-missing/scripts/pipeline/bundle-root.sh"
  run "$c_int" "$h_skewgone" "$p_task"
  check "integrity-a-missing-attested-copy-denies-at-exit-2" 2 'bundle-root\.sh'

  # --- end to end on the plugin channel, with a trailing slash in HOME ------
  # The record's WRITER is hooks/session-start on this channel and its READER is
  # this guard, and the two build the anchor path independently. Every reader
  # spells it `${HOME%/}`; a writer using a bare `$HOME` records
  # `/home/u//.agents/beads-superpowers` under a trailing-slash HOME, which no
  # reader's spelling equals — so the record describes "some other anchor" and
  # every tool call is denied. It also self-perpetuates: the anchor still
  # resolves and still matches record.target, so the refresh branch stands down
  # and rewrites the identical broken record next session. Writer and reader are
  # therefore run against each other here rather than checked apart.
  h_slash="$(make_home trailing-slash)"; add_bundle "$h_slash" "$minver"; add_tier_map "$h_slash"
  managed="$h_slash/.claude/plugins/cache/beads-superpowers"
  mkdir -p "$managed/scripts/pipeline" "$managed/hooks"
  cp -f "$root/scripts/pipeline/tier-gate.sh" "$root/scripts/pipeline/bundle-root.sh" \
        "$root/scripts/pipeline/graph-lint.mjs" "$managed/scripts/pipeline/"
  cp -f "$root/hooks/pipeline-guard" "$managed/hooks/"
  cp -f "$root/package.json" "$managed/package.json"
  c_slash="$TMP/cwd-trailing-slash"; mkdir -p "$c_slash"
  ( cd "$c_slash" && HOME="$h_slash/" XDG_RUNTIME_DIR="$TMP/xdg" \
      CLAUDE_PLUGIN_ROOT="$managed" "$BASH" "$root/hooks/session-start" \
      <<<'{"session_id":"sess-slash","source":"startup","hook_event_name":"SessionStart","model":"model-orch-only"}' \
    ) >/dev/null 2>&1
  rec_slash="$h_slash/.local/state/beads-superpowers/record.json"
  if [ "$(jq -r '.anchor' "$rec_slash" 2>/dev/null)" = "$h_slash/.agents/beads-superpowers" ]; then
    echo "PASS e2e-trailing-slash-HOME-records-the-anchor-every-reader-spells"
  else
    echo "FAIL e2e-trailing-slash-HOME-records-the-anchor-every-reader-spells: $(jq -r '.anchor' "$rec_slash" 2>&1)"
    fails=$((fails+1))
  fi
  run "$c_slash" "$h_slash/" "$(sid_task sess-slash)"
  check "e2e-trailing-slash-HOME-record-is-accepted-by-the-guard-that-reads-it" 0
fi

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
# The deny has to carry the REASON, not just the fact. A bare "could not be resolved"
# leaves every Bash, Write and Edit call denied for the whole session with nothing the
# user can act on — and the --assert remedy named elsewhere cannot clear this state,
# because resolve_session_tier reaches its tier-assert fallback only when session.json
# yields an EMPTY model. An unmapped model returns 1 before that.
check "armed-model-absent-from-tier-map-names-the-model" 2 "model-not-in-the-map"
check "armed-model-absent-from-tier-map-names-the-tier-map-remedy" 2 'tier-map'

run "$c_badjson" "$h_full" "$p_task"
check "armed-unparsable-session-json-denies" 2 '^pipeline-guard: '
check "armed-unparsable-session-json-names-the-reason" 2 'not valid JSON'

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
