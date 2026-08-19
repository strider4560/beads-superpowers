#!/usr/bin/env bash
# test-pipeline-state.sh — the session-start hook's pipeline surface (Task 3):
# the great_cto bundle-root advisory line and the session state file
# .internal/pipeline/session.json consumed by scripts/pipeline/tier-gate.sh.
#
# ARMING CONDITION: the state file is written ONLY when both the bundle root
# ($HOME/.agents/great_cto) and the tier-map (<root>/shared/tier-map.json) exist.
# The advisory line reports bundle-root presence alone — it is not the arming
# condition, so a root-without-tier-map machine prints "present" and stays unarmed.
#
# set -uo pipefail, NOT -e: every case captures output and inspects it explicitly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start"
fail=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUNDIR="$T/run"; mkdir -p "$RUNDIR"

# $1 name · $2 FAIL detail · $3.. predicate command
assert() {
    local name="$1" detail="$2"; shift 2
    if "$@"; then echo "PASS $name"; else echo "FAIL $name: $detail"; fail=1; fi
}
grepok() { printf '%s' "$2" | grep -qF -- "$1"; }   # $1 literal · $2 haystack
jqok()   { jq -e "$1" "$2" >/dev/null 2>&1; }       # $1 filter · $2 file
jqr()    { jq -r "$1" "$2" 2>&1; }                  # $1 filter · $2 file (diagnostics)

# Sandboxed HOME per case so no case can read the real bundle root.
# mode: none = no bundle root · root = bundle root only · armed = root + tier-map
mk_home() {
    local h; h=$(mktemp -d -p "$T")
    case "$1" in
        root)  mkdir -p "$h/.agents/great_cto" ;;
        armed) mkdir -p "$h/.agents/great_cto/shared"
               printf '{"tiers":{}}\n' > "$h/.agents/great_cto/shared/tier-map.json" ;;
    esac
    printf '%s' "$h"
}

# Sandboxed workspace so no case can write this repo's own .internal/pipeline/.
mk_ws() { mktemp -d -p "$T"; }

# $1 home · $2 workspace · $3 stdin payload
# $4 CLAUDE_EFFORT value ("" = unset, the documented no-effort-support state)
run_hook() {
    local eff=(env -u CLAUDE_EFFORT)
    [ -n "$4" ] && eff=(env "CLAUDE_EFFORT=$4")
    printf '%s' "$3" | ( cd "$2" && HOME="$1" XDG_RUNTIME_DIR="$RUNDIR" "${eff[@]}" bash "$HOOK" 2>&1 )
}

# Distinct session_id per case: the hook's event-scoped dedup marker suppresses a
# second same-(session_id,source) event within 60s.
payload() { printf '{"session_id":"pipestate-%s","source":"startup","hook_event_name":"SessionStart"%s}' "$1" "$2"; }

# --- Case A: bundle root present, tier-map absent ---------------------------
home=$(mk_home root); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload A '')" ""); rc=$?
assert "bundle-root line says present" "advisory line absent (rc=$rc)" \
    grepok 'great_cto bundle root: present' "$out"
assert "hook exits 0 with bundle root present" "rc=$rc" test "$rc" -eq 0
assert "no state file when tier-map absent" "session.json written on a root-only (unarmed) machine" \
    test ! -e "$ws/.internal/pipeline/session.json"

# --- Case B: bundle root absent ---------------------------------------------
home=$(mk_home none); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload B '')" ""); rc=$?
assert "bundle-root line says MISSING" "advisory line absent (rc=$rc)" \
    grepok 'great_cto bundle root: MISSING (pipeline gates will fail closed)' "$out"
assert "hook exits 0 with bundle root absent" "rc=$rc" test "$rc" -eq 0
assert "no state file when bundle root absent" "session.json written with no bundle root" \
    test ! -e "$ws/.internal/pipeline/session.json"

# --- Case C: armed, model in stdin, CLAUDE_EFFORT exported ------------------
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload C ',"model":"model-x"')" high); rc=$?
state="$ws/.internal/pipeline/session.json"
assert "hook exits 0 when armed" "rc=$rc" test "$rc" -eq 0
assert "state file written when armed" "$state missing" test -f "$state"
if [ -f "$state" ]; then
    assert "state file is valid JSON" "contents: $(cat "$state")" jqok '.' "$state"
    assert "state file carries all four schema keys" "keys: $(jqr 'keys|join(",")' "$state")" \
        jqok 'has("model_id") and has("effort") and has("source") and has("timestamp")' "$state"
    assert "model_id read from stdin .model" "got $(jqr '.model_id' "$state")" \
        jqok '.model_id == "model-x"' "$state"
    assert "effort read from \$CLAUDE_EFFORT" "got $(jqr '.effort' "$state")" \
        jqok '.effort == "high"' "$state"
    assert "source is hook" "got $(jqr '.source' "$state")" jqok '.source == "hook"' "$state"
    assert "timestamp is a non-empty string" "got $(jqr '.timestamp' "$state")" \
        jqok '.timestamp | type == "string" and length > 0' "$state"
fi

# --- Case D: armed, no model key, CLAUDE_EFFORT unset -----------------------
# Both absences are documented-normal: .model is omitted after /clear or when a
# session is restored through conversation recovery, and $CLAUDE_EFFORT is unset
# when the model has no effort parameter. Neither may error, and both must land
# as JSON null.
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload D '')" ""); rc=$?
state="$ws/.internal/pipeline/session.json"
assert "hook exits 0 with no model and no effort" "rc=$rc" test "$rc" -eq 0
assert "state file written with no model and no effort" "$state missing" test -f "$state"
if [ -f "$state" ]; then
    assert "model_id is null when stdin has no model key" "got $(jqr '.model_id' "$state")" \
        jqok '.model_id == null' "$state"
    assert "effort is null when \$CLAUDE_EFFORT is unset" "got $(jqr '.effort' "$state")" \
        jqok '.effort == null' "$state"
fi

[ "$fail" -eq 0 ] && echo "PASS: session-start pipeline state" || exit 1
