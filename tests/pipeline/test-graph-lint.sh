#!/usr/bin/env bash
# test-graph-lint.sh — contract for scripts/pipeline/graph-lint.mjs.
# Every case runs the lint against a mutation of tests/pipeline/fixtures/graph-valid.json
# written into a mktemp dir, with the fixture roster and the fixture tier-map passed
# explicitly, so the suite never reads a real great_cto install.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
lint="$root/scripts/pipeline/graph-lint.mjs"
valid="$root/tests/pipeline/fixtures/graph-valid.json"
roster="$root/tests/pipeline/fixtures/roster.mjs"
tiermap="$root/tests/pipeline/fixtures/tier-map.json"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v node >/dev/null 2>&1 || { echo "SKIP (node not installed)"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP (jq not installed — mutations need it)"; exit 0; }

# --- runner + assertion -----------------------------------------------------

run() { # <args...> — raw argv for the lint; sets rc, out (stdout), err (stderr)
  out="$(node "$lint" "$@" 2>"$TMP/stderr" </dev/null)"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

run_state() { # <state-file> — the standard invocation against one state dump
  run --initiative fx-ini --state "$1" --roster "$roster" --tier-map "$tiermap"
}

mutate() { # <name> <jq-filter> — sets $f to the path of the mutated state file.
  # Runs in the current shell, not a command substitution: a subshell's
  # fails=$((fails+1)) never reaches the summary.
  f="$TMP/state-$1.json"
  jq "$2" "$valid" > "$f" || { echo "FAIL $1: jq mutation failed"; fails=$((fails+1)); }
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

# --- usage ------------------------------------------------------------------

run
check "usage-no-args-exits-2" 2
check "usage-names-the-required-flags" 2 'graph-lint\.mjs --initiative' stderr

run --state "$valid"
check "usage-missing-initiative-exits-2" 2

run --initiative fx-ini
check "usage-missing-state-exits-2" 2

run --initiative fx-ini --state "$valid" --bogus x
check "usage-unknown-flag-exits-2" 2
check "usage-unknown-flag-names-it" 2 'bogus' stderr

run --initiative fx-ini --state
check "usage-flag-without-a-value-exits-2" 2

# --- input files ------------------------------------------------------------

run_state "$TMP/does-not-exist.json"
check "missing-state-file-exits-2" 2
check "missing-state-file-names-the-path" 2 'does-not-exist\.json' stderr

printf '{"id": "fx-ini",\n' > "$TMP/state-broken.json"
run_state "$TMP/state-broken.json"
check "unparsable-state-file-exits-2" 2
check "unparsable-state-file-names-the-path" 2 'state-broken\.json' stderr

printf '{"issues": []}\n' > "$TMP/state-object.json"
run_state "$TMP/state-object.json"
check "state-file-that-is-not-an-array-exits-2" 2

run --initiative fx-ini --state "$valid" --roster "$TMP/no-roster.mjs" --tier-map "$tiermap"
check "missing-roster-exits-2" 2
check "missing-roster-names-the-path" 2 'no-roster\.mjs' stderr

run --initiative fx-ini --state "$valid" --roster "$roster" --tier-map "$TMP/no-map.json"
check "missing-tier-map-exits-2" 2
check "missing-tier-map-names-the-path" 2 'no-map\.json' stderr

# --- the valid fixture ------------------------------------------------------
# The fixture's child epics inherit the `initiative` label from the initiative
# epic, exactly as `bd create` produces (controller decision D4), so this case
# exiting 0 is also the assertion that the lint does not require that label to
# be unique in the graph.

run_state "$valid"
check "valid-fixture-exits-0" 0
check "valid-fixture-reports-the-initiative-on-stdout" 0 '^graph-lint OK: fx-ini'
if [ -n "$err" ]; then
  echo "FAIL valid-fixture-prints-nothing-on-stderr: $err"; fails=$((fails+1))
else
  echo "PASS valid-fixture-prints-nothing-on-stderr"
fi

# --- check 1: the initiative bead -------------------------------------------

run --initiative fx-nope --state "$valid" --roster "$roster" --tier-map "$tiermap"
check "initiative-absent-from-state-exits-1" 1
check "initiative-absent-from-state-names-the-id" 1 '^fx-nope: ' stderr

mutate ini-not-epic '(.[] | select(.id=="fx-ini") | .issue_type) = "task"'
run_state "$f"
check "initiative-that-is-not-an-epic-exits-1" 1
check "initiative-that-is-not-an-epic-names-id-and-field" 1 '^fx-ini: issue_type:' stderr

mutate ini-unlabelled '(.[] | select(.id=="fx-ini") | .labels) = ["chore"]'
run_state "$f"
check "initiative-without-the-initiative-label-exits-1" 1
check "initiative-without-the-initiative-label-names-id-and-field" 1 '^fx-ini: labels:' stderr

mutate ini-no-labels 'del(.[] | select(.id=="fx-ini") | .labels)'
run_state "$f"
check "initiative-with-labels-omitted-entirely-exits-1" 1
check "initiative-with-labels-omitted-names-id-and-field" 1 '^fx-ini: labels:' stderr

# --- check 2: child epic Success Criteria ------------------------------------

mutate ep-no-success '(.[] | select(.id=="fx-ep2") | .description) = "No heading here."'
run_state "$f"
check "epic-missing-success-criteria-exits-1" 1
check "epic-missing-success-criteria-names-id-and-field" 1 '^fx-ep2: description:' stderr
check "epic-missing-success-criteria-names-the-heading" 1 '## Success Criteria' stderr

# --- check 3: child epic reviewers -------------------------------------------

mutate ep-bad-reviewer '(.[] | select(.id=="fx-ep1") | .metadata.reviewers) = ["architect","not-a-reviewer"]'
run_state "$f"
check "epic-with-an-unknown-reviewer-exits-1" 1
check "epic-with-an-unknown-reviewer-names-id-and-field" 1 '^fx-ep1: metadata\.reviewers:' stderr
check "epic-with-an-unknown-reviewer-names-the-reviewer" 1 'not-a-reviewer' stderr

mutate ep-no-reviewers 'del(.[] | select(.id=="fx-ep1") | .metadata.reviewers)'
run_state "$f"
check "epic-with-no-reviewers-exits-1" 1
check "epic-with-no-reviewers-names-id-and-field" 1 '^fx-ep1: metadata\.reviewers:' stderr

# An implementation agent is not a review agent: membership is checked against
# REVIEW_AGENTS, not against the union of the two rosters.
mutate ep-impl-reviewer '(.[] | select(.id=="fx-ep1") | .metadata.reviewers) = ["senior-dev"]'
run_state "$f"
check "epic-reviewed-by-an-implementation-only-agent-exits-1" 1
check "epic-reviewed-by-an-implementation-only-agent-names-id-and-field" 1 '^fx-ep1: metadata\.reviewers:' stderr

# --- check 4: task Acceptance Criteria ---------------------------------------

mutate task-no-acceptance '(.[] | select(.id=="fx-t2") | .description) = "Just prose."'
run_state "$f"
check "task-missing-acceptance-criteria-exits-1" 1
check "task-missing-acceptance-criteria-names-id-and-field" 1 '^fx-t2: description:' stderr
check "task-missing-acceptance-criteria-names-the-heading" 1 '## Acceptance Criteria' stderr

# --- check 5: task implementation agent --------------------------------------

mutate task-bad-agent '(.[] | select(.id=="fx-t1") | .metadata.implementation_agent) = "not-an-agent"'
run_state "$f"
check "task-with-an-unknown-implementation-agent-exits-1" 1
check "task-with-an-unknown-implementation-agent-names-id-and-field" 1 \
  '^fx-t1: metadata\.implementation_agent:' stderr
check "task-with-an-unknown-implementation-agent-names-the-agent" 1 'not-an-agent' stderr

mutate task-no-metadata 'del(.[] | select(.id=="fx-t1") | .metadata)'
run_state "$f"
check "task-with-metadata-omitted-entirely-exits-1" 1
check "task-with-metadata-omitted-names-the-implementation-agent-field" 1 \
  '^fx-t1: metadata\.implementation_agent:' stderr
check "task-with-metadata-omitted-names-the-tier-field" 1 '^fx-t1: metadata\.tier:' stderr

# A review agent is not an implementation agent.
mutate task-review-agent '(.[] | select(.id=="fx-t1") | .metadata.implementation_agent) = "architect"'
run_state "$f"
check "task-implemented-by-a-review-only-agent-exits-1" 1
check "task-implemented-by-a-review-only-agent-names-id-and-field" 1 \
  '^fx-t1: metadata\.implementation_agent:' stderr

# --- check 6: task tier ------------------------------------------------------

mutate task-bad-tier '(.[] | select(.id=="fx-t3") | .metadata.tier) = "not-a-tier"'
run_state "$f"
check "task-with-an-unknown-tier-exits-1" 1
check "task-with-an-unknown-tier-names-id-and-field" 1 '^fx-t3: metadata\.tier:' stderr
check "task-with-an-unknown-tier-names-the-tier" 1 'not-a-tier' stderr

# --- check 7a: dependency cycle over blocks edges ----------------------------

mutate task-cycle '(.[] | select(.id=="fx-t1") | .dependencies) += [{"issue_id":"fx-t1","depends_on_id":"fx-t3","type":"blocks","metadata":"{}"}]'
run_state "$f"
check "blocks-cycle-exits-1" 1
check "blocks-cycle-names-a-bead-in-the-cycle-and-the-field" 1 '^fx-t[123]: dependencies:' stderr
check "blocks-cycle-says-cycle" 1 'cycle' stderr

# Two disjoint cycles are two violations. Reporting only the first contradicts
# the one-line-per-violation contract every other check honours, and forces the
# reader to re-run the lint once per cycle.
mutate two-cycles '(.[] | select(.id=="fx-t1") | .dependencies) += [{"issue_id":"fx-t1","depends_on_id":"fx-t3","type":"blocks","metadata":"{}"}] | (.[] | select(.id=="fx-ep1") | .dependencies) += [{"issue_id":"fx-ep1","depends_on_id":"fx-ep2","type":"blocks","metadata":"{}"}]'
run_state "$f"
check "two-disjoint-blocks-cycles-exit-1" 1
check "two-disjoint-blocks-cycles-report-the-epic-cycle" 1 'blocks dependency cycle:.*fx-ep2 -> fx-ep1' stderr
check "two-disjoint-blocks-cycles-report-the-task-cycle" 1 'blocks dependency cycle:.*fx-t1 -> fx-t3' stderr

# A parent-child edge back to an ancestor is not a blocks edge, so the cycle
# walk must not see it. This is the negative control for "blocks edges only".
mutate parent-child-not-a-cycle '(.[] | select(.id=="fx-ep1") | .dependencies) += [{"issue_id":"fx-ep1","depends_on_id":"fx-t1","type":"parent-child","metadata":"{}"}]'
run_state "$f"
check "parent-child-edges-are-not-walked-by-the-cycle-check" 0

# --- check 7b: a task's parent must be an epic of this initiative ------------

mutate task-parent-is-the-initiative '(.[] | select(.id=="fx-t1") | .dependencies[] | select(.type=="parent-child") | .depends_on_id) = "fx-ini" | (.[] | select(.id=="fx-t1") | .parent) = "fx-ini"'
run_state "$f"
check "task-parented-directly-to-the-initiative-exits-1" 1
check "task-parented-directly-to-the-initiative-names-id-and-field" 1 '^fx-t1: parent:' stderr

mutate task-parent-is-a-task '(.[] | select(.id=="fx-t2") | .dependencies[] | select(.type=="parent-child") | .depends_on_id) = "fx-t1" | (.[] | select(.id=="fx-t2") | .parent) = "fx-t1"'
run_state "$f"
check "task-parented-to-another-task-exits-1" 1
check "task-parented-to-another-task-names-id-and-field" 1 '^fx-t2: parent:' stderr

# --- scope: beads outside the initiative are not judged ----------------------
# fx-out-ep/fx-out-t are malformed on every check the lint makes. The valid
# fixture exiting 0 above already proves they are ignored; this asserts that
# mutating one of them still cannot fail the lint.

mutate outside-worse '(.[] | select(.id=="fx-out-t") | .description) = ""'
run_state "$f"
check "beads-outside-the-initiative-are-not-judged" 0

# --- every violation is reported, not just the first -------------------------

mutate two-violations '(.[] | select(.id=="fx-t1") | .metadata.implementation_agent) = "not-an-agent" | (.[] | select(.id=="fx-ep2") | .description) = "No heading."'
run_state "$f"
check "two-violations-exit-1" 1
check "two-violations-report-the-task" 1 '^fx-t1: metadata\.implementation_agent:' stderr
check "two-violations-report-the-epic" 1 '^fx-ep2: description:' stderr

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: graph-lint ($fails failing)"; exit 1; fi
echo "PASS: graph-lint"
