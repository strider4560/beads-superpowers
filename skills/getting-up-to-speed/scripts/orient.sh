#!/usr/bin/env bash
# orient.sh — getting-up-to-speed Phase 1 data gatherer. RAW DATA ONLY: no verdicts,
# no freshness classification, no advisory language. Judgment (continuity, freshness,
# scale-path choice) stays with the agent in Phases 3-4 — this script only gathers.
# Invocation: bash scripts/orient.sh   (read-only; safe anywhere, exits 0 always)
set -uo pipefail

echo "== scale =="
TRACKED=$(git ls-files 2>/dev/null | wc -l | tr -d ' '); echo "tracked=$TRACKED"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo "git=1" || echo "git=0"

if ! command -v bd >/dev/null 2>&1 || ! bd ready -n 1 >/dev/null 2>&1; then
    echo "== ledger =="; echo "SKIP (bd absent or no beads workspace)"
    echo "== ready ==";  echo "SKIP"
    echo "== in-progress =="; echo "SKIP"
    echo "== blocked =="; echo "SKIP"
    echo "== mex =="; echo "SKIP"
else
    echo "== ledger =="
    bd count --by-status 2>/dev/null | head -10
    bd count --by-priority 2>/dev/null | head -10
    echo "== ready =="
    bd ready -n 10 2>/dev/null | head -14
    echo "== in-progress =="
    bd query "status=in_progress" -n 10 2>/dev/null | head -12
    echo "== blocked =="
    bd blocked 2>/dev/null | head -12
    echo "== mex =="
    if [ ! -d .mex ]; then
        echo "ABSENT"
    else
        echo "PRESENT"
        if command -v mex >/dev/null 2>&1; then
            # Exit code AND first output line, both raw: `mex check` exits 0 WITH
            # warnings, so the code alone under-reports and the text alone
            # over-reports. The agent reads both; this script judges neither.
            mex_out=$(mex check 2>&1); mex_rc=$?
            echo "check: exit=$mex_rc $(printf '%s\n' "$mex_out" | head -1)"
        else
            echo "check: exit=127 (mex not on PATH)"
        fi
        head -20 .mex/lessons.md 2>/dev/null
    fi
fi

echo "== handoff =="
# shellcheck disable=SC2012  # mtime-sort intended (naming isn't lexically sortable); filenames are controlled, not adversarial
newest=$(ls -t .internal/handoff/*.md 2>/dev/null | head -1)
if [ -n "$newest" ]; then
    echo "path=$newest"
    echo "head_sha=$(git rev-parse HEAD 2>/dev/null || echo none)"
    echo "doc_sha=$(grep -m1 -oE '@ *[`*]*[0-9a-f]{7,40}' "$newest" 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -1)"
    echo "doc_mtime=$(stat -c %Y "$newest" 2>/dev/null || stat -f %m "$newest" 2>/dev/null)"
    echo "last_commit_time=$(git log -1 --format=%ct 2>/dev/null || echo none)"
    # shellcheck disable=SC2012  # count only; filenames are controlled, not adversarial
    echo "inbox_count=$(ls .internal/handoff/*.md 2>/dev/null | wc -l | tr -d ' ')"
else
    echo "none"
fi

exit 0
