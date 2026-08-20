#!/usr/bin/env bash
# test-graph-lint.sh — contract for scripts/pipeline/graph-lint.mjs.
# Every case runs the lint against a mutation of tests/pipeline/fixtures/graph-valid.json
# written into a mktemp dir, with the fixture roster and the fixture tier-map passed
# explicitly, so the suite never reads a real great_cto install.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
lint="$root/scripts/pipeline/graph-lint.mjs"
valid="$root/tests/pipeline/fixtures/graph-valid.json"
stamped="$root/tests/pipeline/fixtures/graph-stamped.json"
roster="$root/tests/pipeline/fixtures/roster.mjs"
tiermap="$root/tests/pipeline/fixtures/tier-map.json"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v node >/dev/null 2>&1 || { echo "SKIP (node not installed)"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP (jq not installed — mutations need it)"; exit 0; }

# --- sandbox HOME -----------------------------------------------------------
# The lint reads the anchor $HOME/.agents/beads-superpowers and the integrity
# record under $HOME/.local/state, so every case runs under a scratch HOME. A
# suite that used the real one would read the operator's own install and, on the
# anchor cases, create directories inside it.

sandbox_home="$TMP/home"
if [ -z "$sandbox_home" ] || [ "$sandbox_home" = "$HOME" ]; then
  echo "FAIL sandbox-home-differs-from-the-real-home: refusing to run against '$HOME'"
  exit 1
fi
mkdir -p "$sandbox_home"
echo "PASS sandbox-home-differs-from-the-real-home"

# --- runner + assertion -----------------------------------------------------

RUN_CWD=""   # per-case cwd; --require-stamps resolves stamps against it
RUN_HOME=""  # per-case HOME; the anchor and the record hang off it
RUN_LINT=""  # per-case script path; the version self-check reads ../../package.json

run() { # <args...> — raw argv for the lint; sets rc, out (stdout), err (stderr)
  out="$(cd "${RUN_CWD:-$root}" && HOME="${RUN_HOME:-$sandbox_home}" \
    node "${RUN_LINT:-$lint}" "$@" 2>"$TMP/stderr" </dev/null)"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

run_state() { # <state-file> [extra-args...] — the standard invocation
  local state="$1"; shift
  run --initiative fx-ini --state "$state" --roster "$roster" --tier-map "$tiermap" "$@"
}

mutate_from() { # <base-fixture> <name> <jq-filter> — sets $f to the mutated file.
  # Runs in the current shell, not a command substitution: a subshell's
  # fails=$((fails+1)) never reaches the summary.
  f="$TMP/state-$2.json"
  jq "$3" "$1" > "$f" || { echo "FAIL $2: jq mutation failed"; fails=$((fails+1)); }
}

mutate() { # <name> <jq-filter> — a mutation of the unstamped valid fixture
  mutate_from "$valid" "$@"
}

mutate_stamped() { # <name> <jq-filter> — a mutation of the stamped fixture
  mutate_from "$stamped" "$@"
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

# --- --require-stamps: the flag itself ---------------------------------------
# A hermetic cwd holding exactly what the stamped fixture claims: the plan the
# initiative names, and the one directory a task's paths entry claims. The stamp
# checks resolve against the cwd, so judging them against this repo's own tree
# would make the suite depend on files no case created.

plan_cwd="$TMP/plan-cwd"; mkdir -p "$plan_cwd/plans" "$plan_cwd/src"
: > "$plan_cwd/plans/2026-08-19-fixture.md"

run --require-stamps --initiative fx-ini --state "$valid" --roster "$roster" --tier-map "$tiermap"
check "require-stamps-is-a-boolean-flag-not-a-usage-error" 1

RUN_CWD="$plan_cwd"
run_state "$stamped" --require-stamps
check "stamped-fixture-with-require-stamps-exits-0" 0
check "stamped-fixture-with-require-stamps-reports-the-initiative" 0 '^graph-lint OK: fx-ini'
RUN_CWD=""

# Without the flag the stamps are not read at all: a pre-stamp graph stays in
# contract for the structural checks (the unstamped valid fixture exiting 0
# above is the other half of that pair).
run_state "$stamped"
check "stamped-fixture-without-the-flag-exits-0" 0

run_state "$valid" --require-stamps
check "unstamped-fixture-with-require-stamps-exits-1" 1
check "unstamped-fixture-with-require-stamps-names-the-plan-path" 1 '^fx-ini: metadata\.plan_path:' stderr
check "unstamped-fixture-with-require-stamps-names-a-task-paths-field" 1 '^fx-t[123]: metadata\.paths:' stderr

# --- --require-stamps: the initiative's plan_path ----------------------------
# The initiative bead is outside the member walk, so this check is written
# against it directly rather than inside the task loop.

RUN_CWD="$plan_cwd"

mutate_stamped ini-plan-missing-file '(.[] | select(.id=="fx-ini") | .metadata.plan_path) = "plans/does-not-exist.md"'
run_state "$f" --require-stamps
check "plan-path-naming-a-missing-file-exits-1" 1
check "plan-path-naming-a-missing-file-names-id-and-field" 1 '^fx-ini: metadata\.plan_path:' stderr
check "plan-path-naming-a-missing-file-names-the-path" 1 'plans/does-not-exist\.md' stderr

mutate_stamped ini-plan-not-md '(.[] | select(.id=="fx-ini") | .metadata.plan_path) = "plans/2026-08-19-fixture.txt"'
run_state "$f" --require-stamps
check "plan-path-that-is-not-a-markdown-file-exits-1" 1
check "plan-path-that-is-not-a-markdown-file-names-id-and-field" 1 '^fx-ini: metadata\.plan_path:' stderr

mutate_stamped ini-plan-empty '(.[] | select(.id=="fx-ini") | .metadata.plan_path) = ""'
run_state "$f" --require-stamps
check "empty-plan-path-exits-1" 1
check "empty-plan-path-names-id-and-field" 1 '^fx-ini: metadata\.plan_path:' stderr

mutate_stamped ini-plan-absent 'del(.[] | select(.id=="fx-ini") | .metadata.plan_path)'
run_state "$f" --require-stamps
check "absent-plan-path-exits-1" 1
check "absent-plan-path-names-id-and-field" 1 '^fx-ini: metadata\.plan_path:' stderr

# A markdown file that exists on the host but resolves outside the cwd is not a
# plan inside the repo: the check is existence *and* in-repo resolution.
: > "$TMP/outside.md"
mutate_stamped ini-plan-outside '(.[] | select(.id=="fx-ini") | .metadata.plan_path) = "../outside.md"'
run_state "$f" --require-stamps
check "plan-path-resolving-outside-the-cwd-exits-1" 1
check "plan-path-resolving-outside-the-cwd-names-id-and-field" 1 '^fx-ini: metadata\.plan_path:' stderr

# --- --require-stamps: canonical metadata.paths ------------------------------

mutate_stamped task-paths-absent 'del(.[] | select(.id=="fx-t2") | .metadata.paths)'
run_state "$f" --require-stamps
check "task-without-paths-exits-1" 1
check "task-without-paths-names-id-and-field" 1 '^fx-t2: metadata\.paths:' stderr

mutate_stamped task-paths-empty '(.[] | select(.id=="fx-t2") | .metadata.paths) = []'
run_state "$f" --require-stamps
check "task-with-an-empty-paths-array-exits-1" 1
check "task-with-an-empty-paths-array-names-id-and-field" 1 '^fx-t2: metadata\.paths:' stderr

# One case per rejected spelling: each is a distinct rule, and a single "some
# path is wrong" case would pass with any one of them implemented.
noncanonical() { # <name> <json-array-literal> <ere-naming-the-entry>
  mutate_stamped "$1" "(.[] | select(.id==\"fx-t2\") | .metadata.paths) = $2"
  run_state "$f" --require-stamps
  check "paths-$1-exits-1" 1
  check "paths-$1-names-id-and-field" 1 '^fx-t2: metadata\.paths:' stderr
  check "paths-$1-names-the-entry" 1 "$3" stderr
}

noncanonical leading-dot-slash   '["./x.md"]'            '\./x\.md'
noncanonical absolute            '["/abs"]'              '/abs'
noncanonical empty-segment       '["a//b"]'              'a//b'
noncanonical dot-dot-segment     '["a/../b"]'            'a/\.\./b'
noncanonical interior-dot-segment '["src/./a.ts"]'       'src/\./a\.ts'
noncanonical backslash           '["a\\b"]'              'a\\b'
noncanonical duplicate-entries   '["src/a.ts","src/a.ts"]' 'src/a\.ts'
noncanonical directory-without-a-trailing-slash '["src"]' "'src'"

# The accepted spellings, byte-exact: a relative file and a directory claim.
mutate_stamped task-paths-canonical '(.[] | select(.id=="fx-t2") | .metadata.paths) = ["src/a.ts","src/"]'
run_state "$f" --require-stamps
check "canonical-paths-exit-0" 0

RUN_CWD=""

# --- version self-check ------------------------------------------------------
# The pinned constant is compared against the version file of the root the
# script was loaded from, so a copy of the lint under a skewed root fails while
# the same copy under a matching root passes.

pkg_version="$(jq -r .version "$root/package.json")"

make_root() { # <name> <version> -> path to a root holding a copy of the lint
  local r="$TMP/root-$1"
  mkdir -p "$r/scripts/pipeline"
  cp -f "$lint" "$r/scripts/pipeline/graph-lint.mjs"
  printf '{"name":"fixture-root","version":"%s"}\n' "$2" > "$r/package.json"
  printf '%s' "$r"
}

RUN_LINT="$(make_root skewed 0.0.0-not-the-pinned-version)/scripts/pipeline/graph-lint.mjs"
run_state "$valid"
check "root-version-skew-exits-1" 1
check "root-version-skew-names-the-version-field" 1 '^graph-lint: version:' stderr

RUN_LINT="$(make_root matching "$pkg_version")/scripts/pipeline/graph-lint.mjs"
run_state "$valid"
check "matching-root-version-exits-0" 0

RUN_LINT="$(make_root no-package-json "$pkg_version")/scripts/pipeline/graph-lint.mjs"
rm -f "$TMP/root-no-package-json/package.json"
run_state "$valid"
check "unreadable-root-version-exits-1" 1
check "unreadable-root-version-names-the-version-field" 1 '^graph-lint: version:' stderr

RUN_LINT=""

# --- integrity record --------------------------------------------------------
# Anchor absent is the dev-clone case and skips silently — the valid fixture
# above already asserts an empty stderr under a HOME with no anchor.

sha256_of() { # <file> -> lowercase hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

canon() { # <dir> -> its canonical path (no realpath(1) dependency)
  (cd "$1" && pwd -P)
}

make_anchored_home() { # <name> -> path to a HOME holding the anchor, no record
  local h="$TMP/home-$1"
  mkdir -p "$h/.agents/beads-superpowers"
  printf '%s' "$h"
}

make_linked_home() { # <name> <target> -> HOME whose anchor is a symlink to <target>
  local h="$TMP/home-$1"
  mkdir -p "$h/.agents"
  ln -sfn "$2" "$h/.agents/beads-superpowers"
  printf '%s' "$h"
}

write_record() { # <home> <json>
  mkdir -p "$1/.local/state/beads-superpowers"
  printf '%s\n' "$2" > "$1/.local/state/beads-superpowers/record.json"
}

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "SKIP record cases (neither sha256sum nor shasum installed)"
else
  RUN_HOME="$(make_anchored_home no-record)"
  run_state "$valid"
  check "anchor-without-a-record-exits-1" 1
  check "anchor-without-a-record-names-the-record-path" 1 'record\.json' stderr

  RUN_HOME="$(make_anchored_home advisory)"
  write_record "$RUN_HOME" "$(jq -n --arg a "$RUN_HOME/.agents/beads-superpowers" \
    '{anchor:$a, target:$a, posture:"dev-clone-advisory", version:"0.0.0"}')"
  run_state "$valid"
  check "dev-clone-advisory-record-exits-0" 0
  check "dev-clone-advisory-record-notes-the-posture-on-stderr" 0 'advisory' stderr

  manifest_json() { # <home> <target> <graph-lint-digest> -> the record JSON
    jq -n --arg a "$1/.agents/beads-superpowers" --arg t "$2" --arg v "$pkg_version" \
      --arg tg "$(sha256_of "$root/scripts/pipeline/tier-gate.sh")" \
      --arg br "$(sha256_of "$root/scripts/pipeline/bundle-root.sh")" \
      --arg gl "$3" \
      --arg pg "$(sha256_of "$root/hooks/pipeline-guard")" \
      '{anchor:$a, target:$t, posture:"manifest-backed", version:$v,
        hashes:{"scripts/pipeline/tier-gate.sh":$tg,
                "scripts/pipeline/bundle-root.sh":$br,
                "scripts/pipeline/graph-lint.mjs":$gl,
                "hooks/pipeline-guard":$pg}}'
  }

  # The attested root is the anchor's target, so an anchor that resolves to this
  # repo is what a manifest of this repo's files describes. Hashing under the
  # *running* script's root instead would deny an untampered dev clone.
  root_canon="$(canon "$root")"

  RUN_HOME="$(make_linked_home manifest-ok "$root_canon")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "$(sha256_of "$lint")")"
  run_state "$valid"
  check "manifest-backed-record-matching-the-target-exits-0" 0
  if printf '%s' "$err" | grep -qE 'unpinned'; then
    echo "FAIL manifest-backed-record-run-from-the-anchored-root-prints-no-unpinned-note: $err"; fails=$((fails+1))
  else
    echo "PASS manifest-backed-record-run-from-the-anchored-root-prints-no-unpinned-note"
  fi

  RUN_HOME="$(make_linked_home manifest-tampered "$root_canon")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "0000000000000000000000000000000000000000000000000000000000000000")"
  run_state "$valid"
  check "manifest-backed-record-with-a-wrong-hash-exits-1" 1
  check "manifest-backed-record-with-a-wrong-hash-names-the-file" 1 'graph-lint\.mjs' stderr

  # Running a copy of the lint from somewhere else is a repo-relative/dev
  # invocation: supported, and the hashes are still verified — under the
  # attested target, not under the copy's own root, which holds none of the
  # manifest's files. It says so on stderr rather than denying.
  RUN_LINT="$(make_root unpinned "$pkg_version")/scripts/pipeline/graph-lint.mjs"
  RUN_HOME="$(make_linked_home manifest-unpinned "$root_canon")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "$(sha256_of "$lint")")"
  run_state "$valid"
  check "manifest-verified-under-the-target-from-another-root-exits-0" 0
  check "running-outside-the-attested-target-self-reports-on-stderr" 0 \
    'running unpinned copy \(not the anchored install\)' stderr
  RUN_LINT=""

  # A repointed anchor is a repoint, not a hash mismatch: the record attests one
  # target and the anchor now resolves to another, so the manifest describes
  # files the anchor no longer serves.
  mkdir -p "$TMP/elsewhere"
  RUN_HOME="$(make_linked_home repointed "$(canon "$TMP/elsewhere")")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "$(sha256_of "$lint")")"
  run_state "$valid"
  check "repointed-anchor-exits-1" 1
  check "repointed-anchor-names-the-repoint" 1 "resolves to .*elsewhere.* but the record attests" stderr
  if printf '%s' "$err" | grep -qE 'hash mismatch'; then
    echo "FAIL repointed-anchor-does-not-report-a-hash-mismatch: $err"; fails=$((fails+1))
  else
    echo "PASS repointed-anchor-does-not-report-a-hash-mismatch"
  fi

  # lstat semantics: a dangling anchor symlink is PRESENT, so its record check
  # applies. Testing the resolved entry instead would let a deleted target
  # silently skip the whole check.
  RUN_HOME="$(make_linked_home dangling-no-record "$TMP/gone")"
  run_state "$valid"
  check "dangling-anchor-without-a-record-exits-1" 1
  check "dangling-anchor-without-a-record-names-the-record-path" 1 'record\.json' stderr

  RUN_HOME="$(make_linked_home dangling-with-record "$TMP/gone")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "$(sha256_of "$lint")")"
  run_state "$valid"
  check "dangling-anchor-with-a-record-exits-1" 1
  check "dangling-anchor-with-a-record-names-the-anchor" 1 'beads-superpowers' stderr

  RUN_HOME="$(make_anchored_home manifest-no-hashes)"
  write_record "$RUN_HOME" "$(jq -n --arg a "$RUN_HOME/.agents/beads-superpowers" \
    '{anchor:$a, target:$a, posture:"manifest-backed", version:"0.0.0"}')"
  run_state "$valid"
  check "manifest-backed-record-without-hashes-exits-1" 1

  RUN_HOME="$(make_anchored_home unparsable-record)"
  write_record "$RUN_HOME" '{"posture": '
  run_state "$valid"
  check "unparsable-record-exits-1" 1

  # A record that describes a DIFFERENT anchor buys this anchor nothing: it is
  # unreadable, which is the same deny as absent. The bash verify_record has
  # said so since it shipped; the lint has to agree, or one gate trusts a record
  # the other rejects and the two surfaces disagree about the same install.
  RUN_HOME="$(make_linked_home foreign-anchor "$root_canon")"
  write_record "$RUN_HOME" "$(manifest_json "$RUN_HOME" "$root_canon" "$(sha256_of "$lint")" |
    jq '.anchor = "/somewhere/else/.agents/beads-superpowers"')"
  run_state "$valid"
  check "record-describing-another-anchor-exits-1" 1
  check "record-describing-another-anchor-names-the-mismatch" 1 'does not describe' stderr

  RUN_HOME="$(make_anchored_home unknown-posture)"
  write_record "$RUN_HOME" "$(jq -n --arg a "$RUN_HOME/.agents/beads-superpowers" \
    '{anchor:$a, target:$a, posture:"something-else", version:"0.0.0"}')"
  run_state "$valid"
  check "record-with-an-unknown-posture-exits-1" 1

  RUN_HOME=""
fi

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: graph-lint ($fails failing)"; exit 1; fi
echo "PASS: graph-lint"
