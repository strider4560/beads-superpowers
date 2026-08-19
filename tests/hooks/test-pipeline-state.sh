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
# stderr must carry advisory lines only — never a bash diagnostic naming the hook.
no_shell_noise() { ! grep -qE 'session-start: line [0-9]+:|Permission denied' "$1"; }
# No `session.json.$$` temp left behind in $1's state dir, on any path.
no_temp() { [ -z "$(find "$1/.internal/pipeline" -maxdepth 1 -name 'session.json.*' -print -quit 2>/dev/null)" ]; }

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
# Stderr is captured to $ERR on its own as well as echoed into the returned text:
# the advisory line lives on stderr, but so would any bash noise, and the two have
# to be told apart. PATH_OVERRIDE, when set, replaces PATH for the hook only.
ERR="$T/stderr"
run_hook() {
    local eff=(env -u CLAUDE_EFFORT)
    [ -n "$4" ] && eff=(env "CLAUDE_EFFORT=$4")
    : > "$ERR"
    printf '%s' "$3" | ( cd "$2" && HOME="$1" XDG_RUNTIME_DIR="$RUNDIR" \
        PATH="${PATH_OVERRIDE:-$PATH}" "${eff[@]}" bash "$HOOK" 2>"$ERR" )
    local rc=$?
    cat "$ERR"
    return "$rc"
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
assert "bundle-root line still prints when armed" "advisory line absent (rc=$rc)" \
    grepok 'great_cto bundle root: present' "$out"
assert "state file written when armed" "$state missing" test -f "$state"
assert "no session.json.\$\$ temp left behind on the success path" \
    "leftover: $(find "$ws/.internal/pipeline" -maxdepth 1 -name 'session.json.*' 2>/dev/null)" \
    no_temp "$ws"
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
assert "bundle-root line still prints when armed with no model" "advisory line absent (rc=$rc)" \
    grepok 'great_cto bundle root: present' "$out"
assert "state file written with no model and no effort" "$state missing" test -f "$state"
if [ -f "$state" ]; then
    assert "model_id is null when stdin has no model key" "got $(jqr '.model_id' "$state")" \
        jqok '.model_id == null' "$state"
    assert "effort is null when \$CLAUDE_EFFORT is unset" "got $(jqr '.effort' "$state")" \
        jqok '.effort == null' "$state"
fi

# --- Case E: armed, .internal/pipeline/ exists but is not writable ----------
# The write is best-effort; what must never happen is bash leaking a redirect
# failure to stderr on every single session start. A stale session.json is
# retained untouched (the gate then authorizes against it — a residual recorded
# in D15#2, not this case's concern).
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP unwritable-state-dir (running as root: chmod 500 does not deny)"
else
    home=$(mk_home armed); ws=$(mk_ws)
    mkdir -p "$ws/.internal/pipeline"
    printf '{"model_id":"stale-sentinel","effort":null,"source":"hook","timestamp":"x"}\n' \
        > "$ws/.internal/pipeline/session.json"
    chmod 500 "$ws/.internal/pipeline"
    out=$(run_hook "$home" "$ws" "$(payload E ',"model":"model-x"')" ""); rc=$?
    chmod 700 "$ws/.internal/pipeline"
    assert "hook exits 0 with an unwritable state dir" "rc=$rc" test "$rc" -eq 0
    assert "unwritable state dir leaks no bash error to stderr" "stderr: $(cat "$ERR")" \
        no_shell_noise "$ERR"
    assert "unwritable state dir leaves the existing session.json untouched" \
        "got $(jqr '.model_id' "$ws/.internal/pipeline/session.json")" \
        jqok '.model_id == "stale-sentinel"' "$ws/.internal/pipeline/session.json"
fi

# --- Cases F/G: .model present but not a string -----------------------------
# `select(type == "string")` is what rejects these. Without it a truthy non-string
# survives `// empty` and reaches the state file, where the gate would compare a
# number or a rendered object against tier-map model ids.
# $1 case tag · $2 payload fragment · $3 description
nonstring_model_case() {
    local home ws state rc out
    home=$(mk_home armed); ws=$(mk_ws)
    out=$(run_hook "$home" "$ws" "$(payload "$1" "$2")" ""); rc=$?
    state="$ws/.internal/pipeline/session.json"
    assert "hook exits 0 with .model as $3" "rc=$rc (out: $out)" test "$rc" -eq 0
    assert "model_id is null when .model is $3" "got $(jqr '.model_id' "$state")" \
        jqok '.model_id == null' "$state"
}
nonstring_model_case F ',"model":42' 'a number'
nonstring_model_case G ',"model":{"id":"model-x"}' 'an object'

# --- Case H: malformed stdin JSON -------------------------------------------
# A truncated payload still yields a session_id to the hook's sed-based dedup, so
# the block runs; jq refuses to parse it and the model must land as null rather
# than as a partially-scraped string.
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" '{"session_id":"pipestate-H","source":"startup","model":"model-x"' ""); rc=$?
state="$ws/.internal/pipeline/session.json"
assert "hook exits 0 on malformed stdin JSON" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "malformed stdin JSON leaks no bash error to stderr" "stderr: $(cat "$ERR")" \
    no_shell_noise "$ERR"
assert "model_id is null on malformed stdin JSON" "got $(jqr '.model_id' "$state")" \
    jqok '.model_id == null' "$state"

# --- Case I: a spoofed model id inside another string value -----------------
# The stated reason for parsing .model with jq rather than the file's existing
# greedy sed extraction: an escaped "model": "spoof" inside .cwd must not win.
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload I ',"cwd":"/repo \"model\": \"spoof\" end"')" ""); rc=$?
state="$ws/.internal/pipeline/session.json"
assert "hook exits 0 with a spoof string in .cwd" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "an escaped model id inside .cwd is not read as the model" \
    "got $(jqr '.model_id' "$state")" jqok '.model_id == null' "$state"

# --- Cases J/K: jq absent, and jq present but failing -----------------------
# jq is a de-facto third arming clause (D15#1): no jq, no state file, and the gate
# then demands a user-run --assert. Sandboxed PATH in the style of the jq-absence
# case in tests/pipeline/test-tier-gate.sh.
mk_bin() {
    local d="$1" b
    mkdir -p "$d"
    for b in bash env id dirname date sed tr cut grep mkdir chmod rm mv cat wc head find touch; do
        ln -sf "$(command -v "$b")" "$d/$b"
    done
}
nojq="$T/bin-nojq";   mk_bin "$nojq"
badjq="$T/bin-badjq"; mk_bin "$badjq"
printf '#!/bin/sh\nexit 1\n' > "$badjq/jq"; chmod +x "$badjq/jq"

home=$(mk_home armed); ws=$(mk_ws)
PATH_OVERRIDE="$nojq"
out=$(run_hook "$home" "$ws" "$(payload J ',"model":"model-x"')" ""); rc=$?
unset PATH_OVERRIDE
assert "hook exits 0 with jq off PATH" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "no state file when jq is absent" "session.json written on a jq-less machine" \
    test ! -e "$ws/.internal/pipeline/session.json"

home=$(mk_home armed); ws=$(mk_ws)
PATH_OVERRIDE="$badjq"
out=$(run_hook "$home" "$ws" "$(payload K ',"model":"model-x"')" ""); rc=$?
unset PATH_OVERRIDE
assert "hook exits 0 when jq fails" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "no state file when jq fails" "session.json written from a failed jq" \
    test ! -e "$ws/.internal/pipeline/session.json"
assert "no session.json.\$\$ temp left behind on the jq-failure path" \
    "leftover: $(find "$ws/.internal/pipeline" -maxdepth 1 -name 'session.json.*' 2>/dev/null)" \
    no_temp "$ws"

[ "$fail" -eq 0 ] && echo "PASS: session-start pipeline state" || exit 1
