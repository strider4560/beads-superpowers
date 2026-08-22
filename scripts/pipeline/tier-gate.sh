#!/usr/bin/env bash
set -u
# tier-gate.sh --stage <planning|implementing|reviewing> | --phase
# Exit: 0 pass, 1 fail-closed, 2 usage.
#
# Pipeline preflight. The name is historical — kept because it is a contract
# path great_cto's stage skills and the release preflight invoke verbatim.
# Since the 2026-08-21 agent-authority rework this gate verifies the INSTALL,
# never the session: it proves the anchored root is intact and the great_cto
# bundle is present at the required floor before a stage runs. It reads NOTHING
# about the session's model, size, or effort — the retired session-model tier
# wall bricked sessions whenever a harness reported a model spelling its map
# did not list, and no stage property ever actually depended on the model id.
# Model/effort per role remain dispatch-time economy (great_cto's
# shared/tier-map.json via resolve-role.mjs), not gated authority.
#
# --phase is the ORIENTATION mode: agent-run, read-only, and advisory. It reads
# the bead graph (and, with no initiative in flight, the planning artifacts
# under .internal/) and reports which pipeline phase the project is in plus a
# one-line `next:` recommendation, so the orchestrating agent can guide the
# user instead of the user firing scripts by hand. It gates nothing: the
# install checks stay with --stage, and --phase works even where great_cto is
# absent. Only the `phase:` and `next:` line prefixes are contract; the
# evidence lines between them are prose.
BSP_PIPELINE_VERSION="0.19.0"  # synced by bump-version.sh
# shellcheck source=scripts/pipeline/bundle-root.sh
. "$(dirname "$0")/bundle-root.sh" || { echo "ERROR: cannot load bundle-root.sh" >&2; exit 1; }

usage() {
  echo "usage: tier-gate.sh --stage <planning|implementing|reviewing> | --phase" >&2
  echo "       run from the repo root — bead state and planning artifacts are cwd-relative" >&2
  exit 2
}
case "${1:-}" in
  --stage) [ $# -eq 2 ] || usage
           case "$2" in planning|implementing|reviewing) ;; *) usage ;; esac ;;
  --phase) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

# Checked before the bundle root so a missing jq is diagnosed as a missing jq,
# not as a stale great_cto (resolve_bundle_root reads the version with jq).
command -v jq >/dev/null || { echo "ERROR: jq required by tier-gate" >&2; exit 1; }

if [ "$1" = "--phase" ]; then
  command -v bd >/dev/null || { echo "ERROR: bd required by tier-gate --phase" >&2; exit 1; }
  # One dump, closed set: --all because "every task closed, epic still open" is
  # exactly the reviewing signal, and closed tasks are invisible without it.
  dump="$(bd list --json --all -n 0 2>&1)" || { echo "ERROR: bd list failed: $dump" >&2; exit 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$dump" || {
    echo "ERROR: bd list --json did not produce an issue array — surface this and stop" >&2
    exit 1
  }
  # The graph model is the captured writing-plans structure: an open epic-type
  # bead labeled `initiative`, epics as its parent-child children, tasks as
  # theirs. Depth is fixed by construction, so two membership passes replace a
  # general closure. A child's parent-child dependency points AT its parent
  # (`depends_on_id` — same reading as graph-lint.mjs).
  summary="$(jq -c '
    def pcp: [(.dependencies // [])[] | select(.type=="parent-child") | .depends_on_id];
    def lbl(x): ((.labels // []) | index(x)) != null;
    . as $all
    | [ $all[] | select(.status!="closed") | select(lbl("needs-planning")) | .id ] as $np
    | [ $all[] | select(.issue_type=="epic") | select(lbl("initiative")) | select(.status!="closed")
        | {id, title} ] as $inits
    | ($inits | map(.id)) as $iids
    | [ $all[] | select(.issue_type=="epic") | select(lbl("initiative") | not)
        | . + {parents: pcp}
        | select([.parents[] | select(. as $p | ($iids | index($p)) != null)] | length > 0) ] as $epics
    | ($epics | map(.id)) as $eids
    | [ $all[] | select(.issue_type=="task")
        | . + {parents: pcp}
        | select([.parents[] | select(. as $p | ($eids | index($p)) != null)] | length > 0) ] as $tasks
    | [ $epics[] | select(.status!="closed") | .id as $e
        | ($tasks | map(select((.parents | index($e)) != null))) as $ts
        | {id: $e, title, t_total: ($ts|length), t_closed: ($ts | map(select(.status=="closed")) | length)}
      ] as $rollup
    | { np: $np,
        inits: $inits,
        epics_open: ($rollup | length),
        epics_closed: ($epics | map(select(.status=="closed")) | length),
        t_open: ($tasks | map(select(.status=="open")) | length),
        t_inprog: ($tasks | map(select(.status=="in_progress")) | length),
        t_held: ($tasks | map(select(.status=="blocked" or .status=="deferred")) | length),
        t_closed: ($tasks | map(select(.status=="closed")) | length),
        review_epics: ($rollup | map(select(.t_total > 0 and .t_total == .t_closed)) | map({id, title})),
        active_epics: ($rollup | map(select(.t_total > .t_closed)) | length) }
  ' <<<"$dump")" || { echo "ERROR: could not summarize the bead graph" >&2; exit 1; }

  np_n="$(jq -r '.np | length' <<<"$summary")"
  init_n="$(jq -r '.inits | length' <<<"$summary")"
  active="$(jq -r '.active_epics' <<<"$summary")"
  rev_n="$(jq -r '.review_epics | length' <<<"$summary")"
  first_init="$(jq -r '.inits[0].id // empty' <<<"$summary")"
  first_rev="$(jq -r '.review_epics[0].id // empty' <<<"$summary")"

  phase="" next="" spec="" reviews=""
  if [ "$init_n" -gt 0 ]; then
    if [ "$active" -gt 0 ]; then
      phase="implementing"
      next="implementation session — great_cto's implementing-epics against initiative $first_init"
    elif [ "$rev_n" -gt 0 ]; then
      phase="reviewing"
      next="great_cto's reviewing-epics for epic $first_rev"
    else
      phase="capturing"
      next="planning session — re-run the writing-plans capture for initiative $first_init until graph-lint passes"
    fi
  elif [ "$np_n" -gt 0 ]; then
    phase="planning-needed"
    next="planning session — drain the open needs-planning beads (brainstorming → planning-with-reviews → writing-plans)"
  else
    spec="$(ls -t .internal/specs/*.md 2>/dev/null | head -1)"
    if [ -n "$spec" ]; then
      phase="planning"
      # <YYYY-MM-DD>-<topic>.md → the topic slug the review stage keys its
      # artifact directory on.
      topic="$(basename "$spec" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"
      if [ -d ".internal/reviews/$topic/planning" ]; then
        reviews="present"
        next="planning session — resume at the writing-plans capture for spec $spec"
      else
        reviews="absent"
        next="planning session — resume at great_cto's planning-with-reviews for spec $spec"
      fi
    else
      phase="idle"
      next="no pipeline work in flight — begin with brainstorming"
    fi
  fi
  [ "$np_n" -gt 0 ] && [ "$phase" != "planning-needed" ] &&
    next="$next; $np_n needs-planning bead(s) await the next planning session"

  echo "phase: $phase"
  jq -r '.inits[] | "- open initiative: \(.id) \"\(.title)\""' <<<"$summary"
  if [ "$init_n" -gt 0 ]; then
    jq -r '"- epics: \(.epics_open) open / \(.epics_closed) closed; tasks: \(.t_open) open, \(.t_inprog) in_progress, \(.t_held) blocked/deferred, \(.t_closed) closed"' <<<"$summary"
    [ "$rev_n" -gt 0 ] &&
      jq -r '.review_epics[] | "- epic awaiting review: \(.id) \"\(.title)\""' <<<"$summary"
  fi
  [ -n "$spec" ] && echo "- newest spec: $spec (planning reviews: $reviews)"
  if [ "$np_n" -gt 0 ]; then
    jq -r '"- needs-planning beads open: \(.np | length) (\(.np | join(", ")))"' <<<"$summary"
  else
    echo "- needs-planning beads open: 0"
  fi
  echo "next: $next"
  exit 0
fi

# Version pinning: the commit-time constant above against the root's version
# file. The two travel together on both supported channels, so this catches a
# gate running against a root it did not ship with — including great_cto's
# flag-less spellings, which have no other handshake (spec D3).
root_pkg="$(dirname "$0")/../../package.json"
root_ver="$(jq -r '.version // empty' "$root_pkg" 2>/dev/null)" || root_ver=""
if [ "$root_ver" != "$BSP_PIPELINE_VERSION" ]; then
  echo "ERROR: tier-gate $BSP_PIPELINE_VERSION is running against beads-superpowers root '${root_ver:-unreadable}' ($root_pkg). Re-run beads-superpowers' install.sh, or update the plugin, so the root and the gates match." >&2
  exit 1
fi

# The anchored install's integrity record. A repo-relative/dev invocation is
# supported: verify_record says so on stderr and still checks the anchor.
verify_record "$(dirname "$0")" || exit 1

bundle="$(resolve_bundle_root)" || exit 1
# Bundle completeness: shared/tier-map.json is dispatch policy (role → model
# economy, read by great_cto's resolve-role.mjs), and a bundle without it is a
# pre-rework great_cto the pipeline cannot dispatch through.
[ -f "$bundle/shared/tier-map.json" ] || { echo "ERROR: shared/tier-map.json missing under $bundle — update great_cto (see handoff doc)" >&2; exit 1; }

echo "pipeline preflight OK ($2): install verified, great_cto bundle present"
exit 0
