#!/usr/bin/env bash
# test-pipeline-guard.sh — contract for hooks/pipeline-guard (PreToolUse).
# Exit 2 + a one-line stderr reason blocks the tool call; exit 0 allows it.
# Every case runs the guard inside a mktemp working dir with HOME pointed at a
# mktemp home, so neither the real bundle root nor this repo's own pipeline
# state directory is ever read.
#
# Since the 2026-08-21 agent-authority rework the guard enforces exactly three
# things — install integrity, Rule D (state dir + install surface), and Rule S
# (subagent authority) — and reads NOTHING about the session's model. The
# retired-behavior section at the end pins the removal: state that used to
# brick a session (an unmapped model, unparsable session.json, a missing
# bundle root) must now cost nothing.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/hooks/pipeline-guard"
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

make_home() { # <name> -> path to an empty HOME
  local home="$TMP/home-$1"; mkdir -p "$home"; printf '%s' "$home"
}
make_cwd() { # <name> [armed] -> path to a working dir (armed = session state file present)
  local cwd="$TMP/cwd-$1"; mkdir -p "$cwd"
  if [ "${2:-}" = "armed" ]; then
    mkdir -p "$cwd/.internal/pipeline"
    printf '{"session_id":"sess-%s","source":"hook","timestamp":"t"}\n' \
      "$1" > "$cwd/.internal/pipeline/session.json"
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
# Orchestrator payloads carry no agent_id; subagent payloads carry one (the
# ADR-0061 amendment's standing rule: subagent detection is has("agent_id"),
# never the agent's name and never an env var).

orch() { # <tool-json-fragment> -> a main-session payload
  printf '{"session_id":"sess-main",%s}' "$1"
}
sub() { # <tool-json-fragment> -> a subagent payload
  printf '{"session_id":"sess-main","agent_id":"agent-1","agent_type":"senior-dev",%s}' "$1"
}
bash_frag() { printf '"tool_name":"Bash","tool_input":{"command":"%s"}' "$1"; }
write_frag() { printf '"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}' "$1"; }
edit_frag() { printf '"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}' "$1"; }

p_state_assert="$(orch "$(write_frag .internal/pipeline/tier-assert)")"
p_state_session="$(orch "$(write_frag .internal/pipeline/session.json)")"
p_state_dotdot="$(orch "$(write_frag .internal/specs/../pipeline/tier-assert)")"
p_state_dblslash="$(orch "$(write_frag .internal//pipeline/tier-assert)")"
p_state_dotslash="$(orch "$(write_frag ./.internal/pipeline/tier-assert)")"
p_state_bash="$(orch "$(bash_frag "printf x > .internal/pipeline/tier-assert")")"
p_pipeline_lookalike="$(orch "$(write_frag .internal/pipeline-notes.md)")"
# A file_path carrying an embedded newline: first line "x", real target
# .internal/pipeline/tier-assert. Normalization must see the WHOLE path.
p_newline_state='{"session_id":"sess-main","tool_name":"Write","tool_input":{"file_path":"x\n/../.internal/pipeline/tier-assert","content":"review"}}'
# No session_id on purpose: an id-less payload has no stable integrity-cache
# key, so the integrity cases below re-verify on every call instead of sharing
# one session's cached PASS across fixtures.
p_task='{"tool_name":"Bash","tool_input":{"command":"bd create -t task \"X\""}}'
p_malformed='{"tool_name":"Bash","tool_input":'

# --- fixtures ---------------------------------------------------------------

h_plain="$(make_home plain)"
c_armed="$(make_cwd armed armed)"
c_unarmed="$(make_cwd unarmed)"

# Armed by the (legacy) tier assert file alone: nothing reads its content any
# more, but its existence still arms Phase 1 on projects that carry one.
c_assertfile="$(make_cwd assertfile)"
mkdir -p "$c_assertfile/.internal/pipeline"
printf 'v2 planning session-assertfile\n' > "$c_assertfile/.internal/pipeline/tier-assert"

# A PATH with no jq on it, for the missing-jq case.
nojq="$TMP/bin-nojq"; mkdir -p "$nojq"
for b in bash dirname sort head cat mkdir; do ln -sf "$(command -v "$b")" "$nojq/$b"; done

# --- Rule S: subagent authority ---------------------------------------------
# A subagent does not manage beads, durable knowledge, or the plan of record.
# The main session is unrestricted by Rule S.

# bd is an ALLOW-set for subagents: reads and `bd note` (the one write
# great_cto's implementation contract grants, on the subagent's own task bead)
# pass; every other subcommand — and any spelling the scanner cannot parse —
# denies.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd create -t task \"X\"')")"
check "ruleS-subagent-bd-create-denied" 2
check "ruleS-subagent-bd-names-rule-S" 2 'Rule S'
check "ruleS-subagent-bd-reason-is-one-line" 2 '^pipeline-guard: beads are managed by the orchestrating session'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd create -t epic \"X\"')")"
check "ruleS-subagent-bd-epic-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd close x-1 --reason done')")"
check "ruleS-subagent-bd-close-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'cd /tmp && bd update x-1 --claim')")"
check "ruleS-subagent-bd-behind-a-chain-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd import issues.jsonl')")"
check "ruleS-subagent-bd-import-denied" 2 'Rule S'

# A global flag ahead of the subcommand is an unparsable spelling: deny.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd -C /tmp/db create -t task \"X\"')")"
check "ruleS-subagent-bd-global-flag-denied" 2 'Rule S'

# The allow-set: reads and notes stay open to subagents.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd ready -n 5')")"
check "ruleS-subagent-bd-read-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd show x-1 --short')")"
check "ruleS-subagent-bd-show-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd note x-1 \"progress\"')")"
check "ruleS-subagent-bd-note-allowed" 0

# A benign call cannot smuggle a mutating one past the scanner: every bd
# invocation in the command is inspected, not just the first.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd show x-1 && bd close x-1')")"
check "ruleS-subagent-bd-chain-second-invocation-denied" 2 'Rule S'

# The deny names the agent type, so the orchestrator can see WHO was told no.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd close x-1')")"
check "ruleS-deny-names-the-agent-type" 2 "senior-dev"

# The word boundary is real: neither of these invokes bd.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'abd create -t epic \"X\"')")"
check "ruleS-abd-is-not-bd-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'bd-helper create -t epic \"X\"')")"
check "ruleS-bd-helper-is-not-bd-allowed" 0

# mex WRITE surfaces are denied; mex reads are how subagents consume routed
# knowledge and stay allowed.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex log --type decision \"d\"')")"
check "ruleS-subagent-mex-log-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex setup')")"
check "ruleS-subagent-mex-setup-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex sync')")"
check "ruleS-subagent-mex-sync-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex graph scope \"task\"')")"
check "ruleS-subagent-mex-read-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex check')")"
check "ruleS-subagent-mex-check-allowed" 0

# `mex logs`/`remex log` are not `mex log`: both boundaries are component-real.
run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'mex logs')")"
check "ruleS-mex-logs-is-not-mex-log-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'remex log x')")"
check "ruleS-remex-is-not-mex-allowed" 0

# Durable knowledge and the plan of record are write-denied by path.
run "$c_armed" "$h_plain" "$(sub "$(write_frag .mex/lessons.md)")"
check "ruleS-subagent-mex-write-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(edit_frag .mex/context/decisions.md)")"
check "ruleS-subagent-mex-edit-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(write_frag plans/2026-08-21-x.md)")"
check "ruleS-subagent-plans-write-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(write_frag .internal/plans/x.md)")"
check "ruleS-subagent-internal-plans-write-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(write_frag .internal/specs/x.md)")"
check "ruleS-subagent-specs-write-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(write_frag .worktrees/g1/plans/x.md)")"
check "ruleS-subagent-worktree-plans-write-denied" 2 'Rule S'

# An allowed prefix followed by `..` must not reach a denied path: the deny
# list is read after normalization.
run "$c_armed" "$h_plain" "$(sub "$(write_frag "docs/../.mex/lessons.md")")"
check "ruleS-dotdot-into-mex-denied" 2 'Rule S'

# Absolute spellings — the form the harness actually sends — deny the same way.
run "$c_armed" "$h_plain" "$(sub "$(write_frag "$c_armed/.mex/lessons.md")")"
check "ruleS-absolute-mex-write-denied" 2 'Rule S'

run "$c_armed" "$h_plain" "$(sub "$(write_frag "$c_armed/plans/x.md")")"
check "ruleS-absolute-plans-write-denied" 2 'Rule S'

# What a subagent is FOR stays open: source, tests, docs, scratch.
run "$c_armed" "$h_plain" "$(sub "$(write_frag src/x.js)")"
check "ruleS-subagent-source-write-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(edit_frag tests/x.test.js)")"
check "ruleS-subagent-test-edit-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(write_frag docs/en/x.md)")"
check "ruleS-subagent-docs-write-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(write_frag .internal/sdd/task-1-report.md)")"
check "ruleS-subagent-internal-scratch-write-allowed" 0

run "$c_armed" "$h_plain" "$(sub "$(bash_frag 'npm test')")"
check "ruleS-subagent-ordinary-bash-allowed" 0

# `plansX/` is not `plans/`: the deny list is component-anchored.
run "$c_armed" "$h_plain" "$(sub "$(write_frag plansX/y.md)")"
check "ruleS-plans-deny-is-component-anchored" 0

# The ORCHESTRATOR (no agent_id) is unrestricted by Rule S — beads, mex, plans
# and epics are exactly its job. This is the rework's core property: nothing
# about the main session's writes or bd usage is gated any more.
run "$c_armed" "$h_plain" "$(orch "$(bash_frag 'bd create -t epic \"X\"')")"
check "ruleS-orchestrator-bd-epic-allowed" 0

run "$c_armed" "$h_plain" "$(orch "$(bash_frag 'bd import issues.jsonl')")"
check "ruleS-orchestrator-bd-import-allowed" 0

run "$c_armed" "$h_plain" "$(orch "$(bash_frag 'mex log --type decision \"d\"')")"
check "ruleS-orchestrator-mex-log-allowed" 0

run "$c_armed" "$h_plain" "$(orch "$(write_frag .mex/lessons.md)")"
check "ruleS-orchestrator-mex-write-allowed" 0

run "$c_armed" "$h_plain" "$(orch "$(write_frag plans/x.md)")"
check "ruleS-orchestrator-plans-write-allowed" 0

run "$c_armed" "$h_plain" "$(orch "$(write_frag src/x.js)")"
check "ruleS-orchestrator-source-write-allowed" 0

# Rule S keys on agent_id PRESENCE, not on the agent's name: a payload with an
# agent_id and no agent_type is still a subagent, and an unknown name changes
# nothing — there is no name table to go stale.
run "$c_armed" "$h_plain" '{"session_id":"s","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"bd close x-1"}}'
check "ruleS-agent-id-without-agent-type-still-denies" 2 'Rule S'

run "$c_armed" "$h_plain" '{"session_id":"s","agent_id":"a1","agent_type":"never-seen-before","tool_name":"Bash","tool_input":{"command":"bd close x-1"}}'
check "ruleS-unknown-agent-type-denies-without-bricking" 2 'Rule S'

run "$c_armed" "$h_plain" '{"session_id":"s","agent_id":"a1","agent_type":"never-seen-before","tool_name":"Bash","tool_input":{"command":"npm test"}}'
check "ruleS-unknown-agent-type-still-runs-ordinary-commands" 0

# --- Rule D: the pipeline state directory is not model-writable --------------

run "$c_armed" "$h_plain" "$p_state_assert"
check "ruleD-write-to-tier-assert-denied" 2
check "ruleD-write-to-tier-assert-reason-is-one-line" 2 '^pipeline-guard: the pipeline state directory is not model-writable \(Rule D\)$'

run "$c_armed" "$h_plain" "$p_state_session"
check "ruleD-write-to-session-json-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$p_state_bash"
check "ruleD-bash-redirect-into-the-state-dir-denied" 2 'Rule D'

# Four path spellings that all RESOLVE inside the state directory. The rule
# requires resolution, not a substring test: each reaches the same file.
run "$c_armed" "$h_plain" "$p_state_dotdot"
check "ruleD-dotdot-path-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$p_state_dblslash"
check "ruleD-double-slash-path-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$p_state_dotslash"
check "ruleD-leading-dot-slash-path-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(orch "$(write_frag "$c_armed/.internal/pipeline/tier-assert")")"
check "ruleD-absolute-path-denied" 2 'Rule D'

# Rule D applies to subagents too — Rule S adds to it, never replaces it.
run "$c_armed" "$h_plain" "$(sub "$(write_frag .internal/pipeline/session.json)")"
check "ruleD-subagent-write-to-the-state-dir-denied" 2 'Rule D'

# `.internal/pipeline-notes.md` is not inside the state directory. Rule D is
# component-anchored, so it does not swallow a same-prefix sibling.
run "$c_armed" "$h_plain" "$p_pipeline_lookalike"
check "ruleD-does-not-fire-on-a-same-prefix-sibling" 0

run "$c_armed" "$h_plain" "$p_newline_state"
check "ruleD-newline-in-path-does-not-truncate-the-state-dir-check" 2 'Rule D'

# NotebookEdit writes a file the same way Write and Edit do; it names its path
# `notebook_path`, not `file_path` — the guard reads both.
run "$c_armed" "$h_plain" '{"session_id":"s","tool_name":"NotebookEdit","tool_input":{"notebook_path":".internal/pipeline/session.json","new_source":"x"}}'
check "ruleD-notebook-edit-of-the-state-dir-denied" 2 'Rule D'

run "$c_armed" "$h_plain" '{"session_id":"s","agent_id":"a1","tool_name":"NotebookEdit","tool_input":{"notebook_path":".mex/x.ipynb","new_source":"x"}}'
check "ruleS-notebook-edit-into-mex-denied-for-a-subagent" 2 'Rule S'

# --- Rule D, bounded: the install surface (SEC-D3-RULE-D) -------------------
# The two anchors, the gate and hook files served THROUGH them, great_cto's
# shared/ policy data, and the integrity record's directory are not
# model-writable: anything that can edit them can rewrite the gate that is
# judging it. The bound is the anchor SPELLING — a clone reached as the working
# project is ordinary source.

home_payload() { # <home> <path-under-home> [tool] -> a Write/Edit payload
  case "${3:-Write}" in
    Edit) printf '{"session_id":"s","tool_name":"Edit","tool_input":{"file_path":"%s/%s","old_string":"a","new_string":"b"}}' "$1" "$2" ;;
    NotebookEdit) printf '{"session_id":"s","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/%s","new_source":"x"}}' "$1" "$2" ;;
    *) printf '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"%s/%s","content":"x"}}' "$1" "$2" ;;
  esac
}

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto)"
check "ruleD-write-to-the-great_cto-anchor-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers)"
check "ruleD-write-to-the-beads-superpowers-anchor-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/scripts/pipeline/tier-gate.sh)"
check "ruleD-write-to-a-gate-through-the-anchor-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/hooks/pipeline-guard Edit)"
check "ruleD-edit-of-a-hook-through-the-anchor-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto/scripts/pipeline/x.sh)"
check "ruleD-write-under-the-great_cto-pipeline-dir-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto/hooks/session-start)"
check "ruleD-write-under-the-great_cto-hooks-dir-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/hooks/pipeline-guard NotebookEdit)"
check "ruleD-notebook-edit-through-the-anchor-denied" 2 'Rule D'

# The bound is `<anchor>/scripts/`, not `<anchor>/scripts/pipeline/`: the control
# files live outside the pipeline/ subdirectory too.
run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/scripts/scan-plan.sh)"
check "ruleD-write-to-a-script-outside-pipeline-through-the-anchor-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto/scripts/x.sh)"
check "ruleD-write-to-a-great_cto-script-outside-pipeline-denied" 2 'Rule D'

# shared/ is dispatch policy (tier-map roles, review schemas): anything that can
# rewrite it steers every dispatch that reads it.
run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto/shared/tier-map.json)"
check "ruleD-write-to-the-great_cto-tier-map-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/great_cto/shared/review-report.schema.json)"
check "ruleD-write-under-great_cto-shared-denied" 2 'Rule D'

# A trailing slash on $HOME must not disable the install-surface half: the
# anchors are built off ${HOME%/}, so `/home/u/` and `/home/u` spell one anchor.
run "$c_armed" "$h_plain/" "$(home_payload "$h_plain" .agents/beads-superpowers/hooks/pipeline-guard)"
check "ruleD-install-surface-survives-a-trailing-slash-in-HOME" 2 'Rule D'

run "$c_armed" "$h_plain/" "$(home_payload "$h_plain" .local/state/beads-superpowers/record.json)"
check "ruleD-record-directory-survives-a-trailing-slash-in-HOME" 2 'Rule D'

# The integrity record is the thing the whole check rests on (SEC-R3-RECORD).
run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .local/state/beads-superpowers/record.json)"
check "ruleD-write-to-the-integrity-record-denied" 2 'Rule D'

run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .local/state/beads-superpowers)"
check "ruleD-write-to-the-record-directory-denied" 2 'Rule D'

# The bound, asserted: the rule covers the gate and hook surfaces served through
# the anchor, not the whole tree under it. A skill file is prose, not a gate.
run "$c_armed" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/skills/x/SKILL.md)"
check "ruleD-does-not-swallow-the-rest-of-the-anchor" 0

# A development clone reached AS THE WORKING PROJECT is ordinary source: an
# unbounded "and their targets" rule would brick every clone on the machine.
c_clone="$(make_cwd clone armed)"
mkdir -p "$c_clone/scripts/pipeline"
run "$c_clone" "$h_plain" "$(orch "$(edit_frag scripts/pipeline/tier-gate.sh)")"
check "ruleD-edit-inside-the-working-project-clone-allowed" 0

run "$c_clone" "$h_plain" "$(home_payload "$h_plain" .agents/beads-superpowers/scripts/pipeline/tier-gate.sh Edit)"
check "ruleD-the-same-file-spelled-through-the-anchor-denied" 2 'Rule D'

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

make_anchor_home() { # <name> [posture] -> HOME with a populated anchor and a matching record
  local home="$TMP/home-$1" target="$TMP/target-$1"
  mkdir -p "$home/.agents" "$target/scripts/pipeline" "$target/hooks"
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
  c_int="$(make_cwd integrity armed)"

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
  c_cache="$(make_cwd cache armed)"
  rec_cache="$h_cache/.local/state/beads-superpowers/record.json"
  touch -m -t 202001010000 "$rec_cache"
  run "$c_cache" "$h_cache" "$(orch "$(bash_frag 'echo x')")"
  check "integrity-cached-verification-allows-the-call" 0
  if find "$TMP/xdg" -name 'integrity-sess-main-*' 2>/dev/null | grep -q .; then
    echo "PASS integrity-verification-is-cached-per-session"
  else
    echo "FAIL integrity-verification-is-cached-per-session: no marker under $TMP/xdg"
    fails=$((fails+1))
  fi

  printf '# tampered\n' >> "$TMP/target-integrity-cache/scripts/pipeline/tier-gate.sh"
  run "$c_cache" "$h_cache" "$(orch "$(bash_frag 'echo x')")"
  check "integrity-cache-key-is-the-record-not-the-hashed-files" 0

  touch -m -t 202001010001 "$rec_cache"
  run "$c_cache" "$h_cache" "$(orch "$(bash_frag 'echo x')")"
  check "integrity-a-rewritten-record-re-verifies-and-denies" 2 'integrity'

  # A failure is never cached: the very next call must deny again.
  run "$c_cache" "$h_cache" "$(orch "$(bash_frag 'echo x')")"
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
  run "$c_int" "$h_selfcheck" "$(orch "$(bash_frag 'echo x')")"
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
  run "$c_int" "$h_noentry" "$(orch "$(bash_frag 'echo x')")"
  check "integrity-an-unattested-bundle-root-denies-at-exit-2" 2 'bundle-root\.sh'

  # A hash tool is required to run the pre-source check at all, so its absence is
  # a deny — the same posture verify_record already takes.
  GUARD_OVERRIDE="$h_anchor/.agents/beads-superpowers/hooks/pipeline-guard"
  PATH_OVERRIDE="$nosha"
  run "$c_int" "$h_anchor" "$(orch "$(bash_frag 'echo x')")"
  unset PATH_OVERRIDE
  check "integrity-pre-source-check-denies-when-no-hash-tool-exists" 2 'sha256'

  # Declared-advisory postures attest nothing, so there is nothing to check
  # against and the pre-source check stands down — the same carve-out
  # verify_record makes for an unpinned root.
  h_advisory="$(make_anchor_home integrity-advisory dev-clone-advisory)"
  printf '# advisory tampering\n' \
    >> "$TMP/target-integrity-advisory/scripts/pipeline/bundle-root.sh"
  GUARD_OVERRIDE="$h_advisory/.agents/beads-superpowers/hooks/pipeline-guard"
  run "$c_int" "$h_advisory" "$(orch "$(bash_frag 'echo x')")"
  check "integrity-dev-clone-advisory-posture-is-not-denied" 0
  unset GUARD_OVERRIDE

  # --- the pre-source check hashes the ATTESTED copy, not a sibling ---------
  # The record attests files under record.target. A guard running from OUTSIDE
  # that target — two supported channels installed at skewed versions, or a
  # repo-relative invocation — has a sibling bundle-root.sh that the record
  # says nothing about, so comparing THAT file against the record's hash denies
  # every single tool call, with a remedy (re-run install.sh) that re-attests
  # the other root and changes nothing. The cases below fix the subject of
  # the hash to the copy the record actually attests, which is the same subject
  # verify_record uses for the rest of the manifest.
  h_skew="$(make_anchor_home integrity-skew)"
  printf '\n# skewed channel: this copy is not byte-identical to the repo sibling\n' \
    >> "$TMP/target-integrity-skew/scripts/pipeline/bundle-root.sh"
  write_record "$h_skew" "$TMP/target-integrity-skew"
  run "$c_int" "$h_skew" "$p_task"
  check "integrity-skewed-channels-hash-the-attested-copy-not-the-guards-sibling" 0

  # A tampered attested copy is caught by the PRE-SOURCE check — before the
  # function it defines is trusted — not later by verify_record.
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
fi

# --- retired behavior: nothing about the session model is read any more ------
# These fixtures reproduce every state that used to brick a whole session under
# the session-model tier wall. Each must now cost nothing: the guard does not
# read session.json's content, does not resolve a tier, and does not require a
# bundle root or tier-map at all.

# A model id the old tier-map never listed (the `claude-opus-5[1m]` incident).
c_oldmodel="$(make_cwd oldmodel)"
mkdir -p "$c_oldmodel/.internal/pipeline"
printf '{"model_id":"some-model[1m]","session_id":"sess-x","source":"hook"}\n' \
  > "$c_oldmodel/.internal/pipeline/session.json"
run "$c_oldmodel" "$h_plain" "$(orch "$(write_frag src/x.js)")"
check "retired-an-unmapped-model-no-longer-denies-anything" 0

run "$c_oldmodel" "$h_plain" "$(orch "$(bash_frag 'bd create -t epic \"X\"')")"
check "retired-an-unmapped-model-no-longer-gates-the-plan-graph" 0

# Unparsable session state: armed (the file exists), but its content is never
# parsed, so it cannot deny.
c_badjson="$(make_cwd badjson)"
mkdir -p "$c_badjson/.internal/pipeline"
printf 'not json at all\n' > "$c_badjson/.internal/pipeline/session.json"
run "$c_badjson" "$h_plain" "$(orch "$(write_frag src/x.js)")"
check "retired-unparsable-session-state-no-longer-denies" 0

# No bundle root and no tier-map under an armed project: the guard no longer
# resolves anything through great_cto (tier-gate.sh checks the install at stage
# entry instead).
run "$c_armed" "$h_plain" "$(orch "$(write_frag src/x.js)")"
check "retired-a-missing-bundle-root-no-longer-denies" 0

# A session state file written by a DIFFERENT session no longer restricts this
# one: identity binding existed to stop foreign state authorizing a tier, and
# there is no tier to authorize.
run "$c_armed" "$h_plain" '{"session_id":"a-totally-different-session","tool_name":"Write","tool_input":{"file_path":"src/x.js","content":"x"}}'
check "retired-foreign-session-state-no-longer-restricts-writes" 0

# The legacy tier-assert file still arms Phase 1 (Rule D keeps protecting the
# state dir) but grants and denies nothing else.
run "$c_assertfile" "$h_plain" "$(orch "$(write_frag src/x.js)")"
check "retired-a-legacy-tier-assert-grants-and-denies-nothing" 0

run "$c_assertfile" "$h_plain" "$p_state_assert"
check "retired-a-legacy-tier-assert-still-arms-rule-D" 2 'Rule D'

# --- unarmed: no pipeline state -> allow everything, cost nothing -----------
# No bundle root, no tier-map and no jq on PATH, because phase 1 must not touch
# any of them. Every payload class above, plus malformed stdin, must exit 0.

PATH_OVERRIDE="$nojq"
unarmed_bad=0
for p in "$p_task" "$p_state_assert" "$p_state_session" "$p_state_dotdot" \
         "$p_state_dblslash" "$p_state_dotslash" "$p_state_bash" \
         "$p_pipeline_lookalike" "$p_newline_state" "$p_malformed" \
         "$(sub "$(bash_frag 'bd close x-1')")" \
         "$(sub "$(write_frag .mex/lessons.md)")" \
         "$(sub "$(write_frag plans/x.md)")" \
         "$(orch "$(write_frag src/x.js)")" \
         "$(orch "$(bash_frag 'bd create -t epic \"X\"')")"; do
  run "$c_unarmed" "$h_plain" "$p"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL unarmed-allows-all: exit $rc on payload: $p"
    unarmed_bad=$((unarmed_bad+1)); fails=$((fails+1))
  fi
done
unset PATH_OVERRIDE
[ "$unarmed_bad" -eq 0 ] && echo "PASS unarmed-allows-all"

# --- armed error paths: strict fail-closed ----------------------------------

run "$c_armed" "$h_plain" "$p_malformed"
check "armed-malformed-stdin-denies" 2
check "armed-malformed-stdin-says-pipeline-guard" 2 '^pipeline-guard: '

PATH_OVERRIDE="$nojq"
run "$c_armed" "$h_plain" "$p_task"
check "armed-missing-jq-denies" 2 'jq'
unset PATH_OVERRIDE

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
