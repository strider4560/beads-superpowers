#!/usr/bin/env bash
# test-pipeline-state.sh — the session-start hook's pipeline surface (Task 3):
# the great_cto bundle-root advisory line and the session state file
# .internal/pipeline/session.json consumed by scripts/pipeline/tier-gate.sh.
# Task 5 extends it with the state-dir .gitignore, the distribution-anchor
# maintenance branch ($HOME/.agents/beads-superpowers) and the ownership record
# ($HOME/.local/state/beads-superpowers/record.json).
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
nogrep() { ! grepok "$1" "$2"; }                    # $1 literal · $2 haystack
filematch() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }   # $1 file · $2 exact content
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

# --- anchor/record sandbox (hard rule) --------------------------------------
# The anchor cases below create $HOME/.agents/beads-superpowers and write
# $HOME/.local/state/beads-superpowers/record.json FOR REAL. On a developer
# machine $HOME/.agents is commonly a symlink into a synced dotfiles tree, so a
# case that leaked out of the sandbox would repoint the owner's own anchor at a
# fixture. Every home comes from mk_home (mktemp -d -p "$T"); this fixture is the
# tripwire that the scratch root — and therefore every home under it — is neither
# the real HOME nor inside it.
REAL_HOME="$HOME"
sandbox_ok() {
    [ "$1" != "$REAL_HOME" ] || return 1
    case "$1/" in "$REAL_HOME"/*) return 1 ;; esac
    return 0
}
assert "scratch HOME root is outside the real HOME" "T=$T real=$REAL_HOME" sandbox_ok "$T"

anchor_of() { printf '%s/.agents/beads-superpowers' "$1"; }
record_of() { printf '%s/.local/state/beads-superpowers/record.json' "$1"; }
# Absence is lstat-shaped: a dangling symlink is PRESENT, and -e alone would miss it.
noent()   { [ ! -e "$1" ] && [ ! -L "$1" ]; }
realdir() { [ -d "$1" ] && [ ! -L "$1" ]; }

# A scratch HOME for an anchor case — hard-aborts rather than running against a
# HOME that is not a sandbox.
mk_anchor_home() {
    local h; h=$(mk_home "$1")
    sandbox_ok "$h" || { echo "FAIL: anchor case refused — HOME '$h' is not a sandbox"; exit 1; }
    printf '%s' "$h"
}

# A plugin root: the four files the manifest hashes plus the package.json whose
# version keys the manifest refresh. $1 dir · $2 version
mk_root() {
    mkdir -p "$1/scripts/pipeline" "$1/hooks"
    printf 'tier-gate\n'   > "$1/scripts/pipeline/tier-gate.sh"
    printf 'bundle-root\n' > "$1/scripts/pipeline/bundle-root.sh"
    printf 'graph-lint\n'  > "$1/scripts/pipeline/graph-lint.mjs"
    printf 'guard\n'       > "$1/hooks/pipeline-guard"
    printf '{\n  "version": "%s"\n}\n' "$2" > "$1/package.json"
}

canon() { (cd "$1" && pwd -P); }
# Same two-tool ladder the hook uses; empty when neither tool exists.
sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# $1 home · $2 workspace · $3 stdin payload
# $4 CLAUDE_EFFORT value ("" = unset, the documented no-effort-support state)
# Stderr is captured to $ERR on its own as well as echoed into the returned text:
# the advisory line lives on stderr, but so would any bash noise, and the two have
# to be told apart. PATH_OVERRIDE, when set, replaces PATH for the hook only.
# ROOT_OVERRIDE exports CLAUDE_PLUGIN_ROOT — the hook's own plugin root, which the
# anchor-maintenance branch keys on (and which also selects the nested dialect).
# RUN_QUIET=1 returns stdout ALONE, so the JSON envelope can be parsed; stderr is
# still in $ERR either way.
ERR="$T/stderr"
run_hook() {
    local eff=(env -u CLAUDE_EFFORT)
    [ -n "$4" ] && eff=(env "CLAUDE_EFFORT=$4")
    [ -n "${ROOT_OVERRIDE:-}" ] && eff+=("CLAUDE_PLUGIN_ROOT=$ROOT_OVERRIDE")
    : > "$ERR"
    printf '%s' "$3" | ( cd "$2" && HOME="$1" XDG_RUNTIME_DIR="$RUNDIR" \
        PATH="${PATH_OVERRIDE:-$PATH}" "${eff[@]}" bash "$HOOK" 2>"$ERR" )
    local rc=$?
    [ "${RUN_QUIET:-0}" = "1" ] || cat "$ERR"
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
    # D4: the guard binds the recorded id against the PreToolUse payload's
    # session_id, so the hook has to RECORD one. Without this field every armed
    # project reads as "state no session claims" and Rule B is inert.
    assert "session_id recorded from the payload" "got $(jqr '.session_id' "$state")" \
        jqok '.session_id == "pipestate-C"' "$state"
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

# --- Case AA: armed, payload with NO session_id -----------------------------
# The field is OMITTED rather than written empty. An empty recorded id would
# compare equal to an empty payload id, which is exactly the "state no session
# claims" case D4 wants treated as absent — writing "" would turn it into a
# match and hand the tier to whatever session came along.
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" '{"source":"startup","hook_event_name":"SessionStart","model":"model-x"}' ""); rc=$?
state="$ws/.internal/pipeline/session.json"
assert "hook exits 0 with no session_id in the payload" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "state file written with no session_id in the payload" "$state missing" test -f "$state"
if [ -f "$state" ]; then
    assert "session_id is absent when the payload carries none" \
        "got $(jqr 'has(\"session_id\")' "$state") / $(cat "$state")" \
        jqok 'has("session_id") | not' "$state"
    assert "model_id still recorded when the payload carries no session_id" \
        "got $(jqr '.model_id' "$state")" jqok '.model_id == "model-x"' "$state"
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
    for b in bash env id dirname date sed tr cut grep mkdir chmod rm mv cat wc head find touch \
             ln readlink sha256sum; do
        command -v "$b" >/dev/null 2>&1 || continue
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

# --- Case L: .internal/pipeline/.gitignore is written UNCONDITIONALLY ---------
# The sdd-workspace pattern: the write follows the `mkdir -p`, it is not gated on
# the file being absent. A state dir left by an earlier version — the common case
# on an upgraded machine — must be ignored too, or session.json reaches a commit.
home=$(mk_home armed); ws=$(mk_ws)
out=$(run_hook "$home" "$ws" "$(payload L1 ',"model":"model-x"')" ""); rc=$?
assert "state dir created by the hook gets a .gitignore" \
    "content: $(cat "$ws/.internal/pipeline/.gitignore" 2>&1)" \
    filematch "$ws/.internal/pipeline/.gitignore" '*'

home=$(mk_home armed); ws=$(mk_ws)
mkdir -p "$ws/.internal/pipeline"
printf 'session.json\n' > "$ws/.internal/pipeline/.gitignore"   # stale, from an earlier version
out=$(run_hook "$home" "$ws" "$(payload L2 ',"model":"model-x"')" ""); rc=$?
assert "hook exits 0 with a pre-existing state dir" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "pre-existing state dir gets the .gitignore too" \
    "content: $(cat "$ws/.internal/pipeline/.gitignore" 2>&1)" \
    filematch "$ws/.internal/pipeline/.gitignore" '*'

# --- Case M: absent anchor, dev-clone root → create + record -----------------
# The anchor cases are independent of the pipeline arming condition (mk_home none)
# — anchor maintenance is its own block.
home=$(mk_anchor_home none); ws=$(mk_ws)
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.2.3
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$clone"
out=$(run_hook "$home" "$ws" "$(payload M '')" ""); rc=$?
unset ROOT_OVERRIDE
assert "hook exits 0 while creating the anchor" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "absent anchor is created as a symlink" "no symlink at $anchor" test -L "$anchor"
assert "anchor points at the hook's own plugin root" "got $(readlink "$anchor" 2>&1)" \
    test "$(readlink "$anchor" 2>/dev/null)" = "$(canon "$clone")"
assert "record written on creation" "$record missing" test -f "$record"
if [ -f "$record" ]; then
    assert "record is valid JSON" "contents: $(cat "$record")" jqok '.' "$record"
    assert "record.anchor is the anchor path" "got $(jqr '.anchor' "$record")" \
        jqok ".anchor == \"$anchor\"" "$record"
    assert "record.target is the canonical plugin root" "got $(jqr '.target' "$record")" \
        jqok ".target == \"$(canon "$clone")\"" "$record"
    assert "a root outside \$HOME/.claude/plugins/ is dev-clone-advisory" \
        "got $(jqr '.posture' "$record")" jqok '.posture == "dev-clone-advisory"' "$record"
    assert "record.version is the root package.json version" "got $(jqr '.version' "$record")" \
        jqok '.version == "1.2.3"' "$record"
    assert "an advisory record carries no hashes" "got $(jqr '.hashes' "$record")" \
        jqok 'has("hashes") | not' "$record"
fi

if [ -z "$(sha /dev/null)" ]; then
    echo "SKIP manifest-backed cases (neither sha256sum nor shasum on PATH)"
else
# --- Case N: absent anchor, managed plugin root → manifest-backed ------------
# The discriminator is the path prefix, not "is a git working tree": a stock
# marketplace install is itself a clone.
home=$(mk_anchor_home none); ws=$(mk_ws)
mroot="$home/.claude/plugins/cache/beads-superpowers"; mk_root "$mroot" 0.18.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$mroot"
out=$(run_hook "$home" "$ws" "$(payload N '')" ""); rc=$?
unset ROOT_OVERRIDE
assert "hook exits 0 under a managed plugin root" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "managed-root anchor is created" "no symlink at $anchor" test -L "$anchor"
assert "record written under a managed plugin root" "$record missing" test -f "$record"
if [ -f "$record" ]; then
    assert "a root under \$HOME/.claude/plugins/ is manifest-backed" \
        "got $(jqr '.posture' "$record")" jqok '.posture == "manifest-backed"' "$record"
    assert "the manifest carries all four gate surfaces" \
        "got $(jqr '.hashes | keys | join(",")' "$record")" \
        jqok '.hashes | has("scripts/pipeline/tier-gate.sh") and has("scripts/pipeline/bundle-root.sh")
              and has("scripts/pipeline/graph-lint.mjs") and has("hooks/pipeline-guard")' "$record"
    assert "manifest hashes are the files' sha256" \
        "got $(jqr '.hashes["scripts/pipeline/tier-gate.sh"]' "$record")" \
        jqok ".hashes[\"scripts/pipeline/tier-gate.sh\"] == \"$(sha "$mroot/scripts/pipeline/tier-gate.sh")\"" "$record"
fi

# --- Case O: version-keyed re-hash (same home/root as N) ---------------------
# Re-hashing every session would make the record a per-session cost and would
# quietly bless a tampered file; keying it on the root's own version file means a
# `claude plugin update` refreshes the record and nothing else does.
before=$(jqr '.hashes["scripts/pipeline/tier-gate.sh"]' "$record")
printf 'tampered\n' > "$mroot/scripts/pipeline/tier-gate.sh"
ROOT_OVERRIDE="$mroot"
out=$(run_hook "$home" "$ws" "$(payload O1 '')" ""); rc=$?
unset ROOT_OVERRIDE
assert "an unchanged root version does not re-hash the manifest" \
    "was $before, now $(jqr '.hashes["scripts/pipeline/tier-gate.sh"]' "$record")" \
    jqok ".hashes[\"scripts/pipeline/tier-gate.sh\"] == \"$before\"" "$record"
printf '{\n  "version": "0.18.1"\n}\n' > "$mroot/package.json"
ROOT_OVERRIDE="$mroot"
out=$(run_hook "$home" "$ws" "$(payload O2 '')" ""); rc=$?
unset ROOT_OVERRIDE
assert "a bumped root version refreshes record.version" "got $(jqr '.version' "$record")" \
    jqok '.version == "0.18.1"' "$record"
assert "a bumped root version re-hashes the manifest" \
    "got $(jqr '.hashes["scripts/pipeline/tier-gate.sh"]' "$record")" \
    jqok ".hashes[\"scripts/pipeline/tier-gate.sh\"] == \"$(sha "$mroot/scripts/pipeline/tier-gate.sh")\"" "$record"

# --- Case T: manifest-backed root, no hash tool on PATH ---------------------
# Reported, no record, and — the acceptance criterion — the bootstrap envelope is
# emitted unharmed. The gates then fail closed on the record-absent state.
nohash="$T/bin-nohash"; mk_bin "$nohash"; rm -f "$nohash/sha256sum" "$nohash/shasum"
ln -sf "$(command -v jq)" "$nohash/jq"
home=$(mk_anchor_home none); ws=$(mk_ws)
mroot="$home/.claude/plugins/cache/beads-superpowers"; mk_root "$mroot" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$mroot"; PATH_OVERRIDE="$nohash"; RUN_QUIET=1
out=$(run_hook "$home" "$ws" "$(payload T '')" ""); rc=$?
unset ROOT_OVERRIDE PATH_OVERRIDE RUN_QUIET
assert "hook exits 0 with no hash tool on PATH" "rc=$rc (stderr: $(cat "$ERR"))" test "$rc" -eq 0
assert "no record is written when the manifest cannot be hashed" \
    "record written without hashes" test ! -e "$record"
assert "no anchor is created when no record can back it" "symlink at $anchor" noent "$anchor"
assert "the missing hash tool is reported on the hook's output channel" \
    "stderr: $(cat "$ERR")" grepok 'cannot hash the pipeline manifest' "$(cat "$ERR")"
assert "a valid additionalContext envelope survives the missing hash tool" \
    "stdout: $out" jqok '.hookSpecificOutput.additionalContext | type == "string"' <(printf '%s' "$out")

# --- Case U: a foreign anchor is not repointed by the version-keyed refresh ---
# The refresh must be gated on the anchor being ours (link == record.target), not
# merely on the record naming our root: otherwise a plugin update would silently
# adopt an anchor somebody else repointed.
home=$(mk_anchor_home none); ws=$(mk_ws)
mroot="$home/.claude/plugins/cache/beads-superpowers"; mk_root "$mroot" 1.0.0
foreign="$home/foreign"; mk_root "$foreign" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$mroot"; out=$(run_hook "$home" "$ws" "$(payload U1 '')" ""); unset ROOT_OVERRIDE
ln -sfn "$foreign" "$anchor"                                   # a third party takes the anchor
printf '{\n  "version": "1.0.1"\n}\n' > "$mroot/package.json"   # …and then the plugin updates
ROOT_OVERRIDE="$mroot"; out=$(run_hook "$home" "$ws" "$(payload U2 '')" ""); rc=$?; unset ROOT_OVERRIDE
assert "hook exits 0 on a foreign anchor with a bumped root version" "rc=$rc" test "$rc" -eq 0
assert "a version bump does not repoint a foreign anchor" "got $(readlink "$anchor" 2>&1)" \
    test "$(readlink "$anchor" 2>/dev/null)" = "$foreign"
assert "a version bump does not rewrite the record behind a foreign anchor" \
    "got $(jqr '.version' "$record")" jqok '.version == "1.0.0"' "$record"

# --- Case W: a posture change on refresh is reported, never silent -----------
# One HOME, two roots: a managed plugin install and a dev clone maintain the SAME
# anchor, so the posture flips to whichever ran last. The flip stays possible —
# the last writer legitimately owns the anchor — but a manifest-backed host
# silently becoming advisory is exactly the downgrade the residual says must be
# noisy.
home=$(mk_anchor_home none); ws=$(mk_ws)
mroot="$home/.claude/plugins/cache/beads-superpowers"; mk_root "$mroot" 1.0.0
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$mroot"; out=$(run_hook "$home" "$ws" "$(payload W1 '')" ""); unset ROOT_OVERRIDE
ROOT_OVERRIDE="$clone"; out=$(run_hook "$home" "$ws" "$(payload W2 '')" ""); rc=$?; unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 while the posture changes" "rc=$rc (stderr: $err)" test "$rc" -eq 0
assert "a posture downgrade names both postures on stderr" "stderr: $err" \
    grepok 'posture manifest-backed → dev-clone-advisory' "$err"
assert "a posture downgrade names the old and the new target" "stderr: $err" \
    grepok "$(canon "$mroot") → $(canon "$clone")" "$err"
assert "a reported posture downgrade still takes effect (noisy, not impossible)" \
    "got $(jqr '.posture' "$record")" jqok '.posture == "dev-clone-advisory"' "$record"

# --- Case Y: a manifest-backed root with no readable version → no record -----
# The manifest refresh is keyed on the version, so an empty one freezes the
# hashes at whatever they were and the record attests a root that cannot say
# what it is. Manifest-backed only: an advisory record carries no attestation.
home=$(mk_anchor_home none); ws=$(mk_ws)
mroot="$home/.claude/plugins/cache/beads-superpowers"; mk_root "$mroot" 1.0.0
rm -f "$mroot/package.json"
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$mroot"; out=$(run_hook "$home" "$ws" "$(payload Y '')" ""); rc=$?; unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 on a versionless managed root" "rc=$rc (stderr: $err)" test "$rc" -eq 0
assert "a versionless managed root writes no record" "record: $(cat "$record" 2>&1)" \
    test ! -e "$record"
assert "a versionless managed root creates no anchor" "anchor: $(ls -ld "$anchor" 2>&1)" \
    noent "$anchor"
assert "a versionless managed root is reported" "stderr: $err" \
    grepok 'no readable package.json version' "$err"
fi

# --- Case P: our symlink + a moved plugin root → repoint and refresh ---------
home=$(mk_anchor_home none); ws=$(mk_ws)
r1="$home/dev/one"; mk_root "$r1" 1.0.0
r2="$home/dev/two"; mk_root "$r2" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$r1"; out=$(run_hook "$home" "$ws" "$(payload P1 '')" ""); unset ROOT_OVERRIDE
ROOT_OVERRIDE="$r2"; out=$(run_hook "$home" "$ws" "$(payload P2 '')" ""); rc=$?; unset ROOT_OVERRIDE
assert "hook exits 0 while repointing" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "a moved plugin root repoints the anchor" "got $(readlink "$anchor" 2>&1)" \
    test "$(readlink "$anchor" 2>/dev/null)" = "$(canon "$r2")"
assert "a moved plugin root refreshes record.target" "got $(jqr '.target' "$record")" \
    jqok ".target == \"$(canon "$r2")\"" "$record"

# --- Case Q: an anchor that does not match the record → report, never repoint -
home=$(mk_anchor_home none); ws=$(mk_ws)
r1="$home/dev/one"; mk_root "$r1" 1.0.0
foreign="$home/foreign"; mk_root "$foreign" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$r1"; out=$(run_hook "$home" "$ws" "$(payload Q1 '')" ""); unset ROOT_OVERRIDE
ln -sfn "$foreign" "$anchor"    # a third party takes the anchor
ROOT_OVERRIDE="$r1"; out=$(run_hook "$home" "$ws" "$(payload Q2 '')" ""); rc=$?; unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 on a foreign anchor" "rc=$rc" test "$rc" -eq 0
assert "a foreign anchor is reported loudly" "stderr: $err" \
    grepok 'does not match the ownership record' "$err"
assert "a foreign anchor is never silently repointed" "got $(readlink "$anchor" 2>&1)" \
    test "$(readlink "$anchor" 2>/dev/null)" = "$foreign"
assert "a foreign anchor does not rewrite the record" "got $(jqr '.target' "$record")" \
    jqok ".target == \"$(canon "$r1")\"" "$record"

# --- Case V: an anchor symlink with NO record at all -------------------------
# The spec's fail-closed state: a bare `ln -s` plus stub scripts must not be
# adopted. Nothing is repointed and nothing is written, so the gates keep denying
# on record-absent.
home=$(mk_anchor_home none); ws=$(mk_ws)
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
mkdir -p "$(dirname "$anchor")"; ln -sfn "$home/planted" "$anchor"
ROOT_OVERRIDE="$clone"
out=$(run_hook "$home" "$ws" "$(payload V '')" ""); rc=$?
unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 on an unrecorded anchor" "rc=$rc (stderr: $err)" test "$rc" -eq 0
assert "an unrecorded anchor is reported" "stderr: $err" \
    grepok 'does not match the ownership record' "$err"
assert "an unrecorded anchor is not adopted" "got $(readlink "$anchor" 2>&1)" \
    test "$(readlink "$anchor" 2>/dev/null)" = "$home/planted"
assert "no record is minted for an unrecorded anchor" "record written" test ! -e "$record"

# --- Case R: anchor is a real directory (installer-populated) → stand down ----
home=$(mk_anchor_home none); ws=$(mk_ws)
anchor=$(anchor_of "$home"); record=$(record_of "$home")
mkdir -p "$anchor/scripts/pipeline"
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.0.0
ROOT_OVERRIDE="$clone"
out=$(run_hook "$home" "$ws" "$(payload R '')" ""); rc=$?
unset ROOT_OVERRIDE
assert "hook exits 0 against an installer-populated anchor" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "a real-directory anchor is left a real directory" "anchor is now $(ls -ld "$anchor" 2>&1)" \
    realdir "$anchor"
assert "the hook writes no record for an installer-owned anchor" "record written" \
    test ! -e "$record"
assert "a populated anchor is not reported as missing" "stderr: $(cat "$ERR")" \
    nogrep 'root missing' "$(cat "$ERR")"

# --- Case S: the hook's own root IS the anchor → report, write nothing -------
# The scripted-tier shim exports CLAUDE_PLUGIN_ROOT=<anchor>; with the root
# removed there is nothing to point at, and creating the symlink anyway would
# make the anchor point at itself.
home=$(mk_anchor_home none); ws=$(mk_ws)
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$anchor"
out=$(run_hook "$home" "$ws" "$(payload S '')" ""); rc=$?
unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 when its own root is the anchor" "rc=$rc (stderr: $err)" test "$rc" -eq 0
assert "a missing root is reported, not symlinked to itself" "stderr: $err" \
    grepok 'root missing — re-run install.sh' "$err"
assert "no anchor is created when the hook's own root is the anchor" \
    "created $(ls -ld "$anchor" 2>&1)" noent "$anchor"
assert "no record is written when the hook's own root is the anchor" "record written" \
    test ! -e "$record"

# --- Case X: an unusable plugin root is never attested -----------------------
# CLAUDE_PLUGIN_ROOT is harness-supplied and can be junk — tests/hooks/test-dedup-marker.sh
# passes a bare `x`. A relative or absent root written into the record would bless a
# dangling anchor whose meaning depends on each reader's cwd.
# $1 case tag · $2 CLAUDE_PLUGIN_ROOT value · $3 description
bad_root_case() {
    local home ws anchor record out rc err
    home=$(mk_anchor_home none); ws=$(mk_ws)
    anchor=$(anchor_of "$home"); record=$(record_of "$home")
    ROOT_OVERRIDE="$2"
    out=$(run_hook "$home" "$ws" "$(payload "$1" '')" ""); rc=$?
    unset ROOT_OVERRIDE
    err=$(cat "$ERR")
    assert "hook exits 0 with $3" "rc=$rc (stderr: $err)" test "$rc" -eq 0
    assert "$3 creates no anchor" "anchor: $(ls -ld "$anchor" 2>&1)" noent "$anchor"
    assert "$3 writes no record" "record: $(cat "$record" 2>&1)" test ! -e "$record"
    assert "$3 is reported" "stderr: $err" grepok 'is not an existing absolute directory' "$err"
}
bad_root_case X1 x                'a relative plugin root'
bad_root_case X2 "$T/absent-root" 'an absent plugin root'

# --- Case Z: a regular file sits at the anchor path --------------------------
# Every other anomalous anchor state is reported; a plain file fell through all
# four branches without a word, leaving the gates to deny with no explanation.
home=$(mk_anchor_home none); ws=$(mk_ws)
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
mkdir -p "$(dirname "$anchor")"; printf 'not an anchor\n' > "$anchor"
ROOT_OVERRIDE="$clone"; out=$(run_hook "$home" "$ws" "$(payload Z '')" ""); rc=$?; unset ROOT_OVERRIDE
err=$(cat "$ERR")
assert "hook exits 0 with a regular file at the anchor path" "rc=$rc (stderr: $err)" \
    test "$rc" -eq 0
assert "a regular file at the anchor path is reported" "stderr: $err" \
    grepok 'neither a symlink nor a directory' "$err"
assert "a regular file at the anchor path is left untouched" "content: $(cat "$anchor" 2>&1)" \
    filematch "$anchor" 'not an anchor'
assert "no record is written for a regular file at the anchor path" "record written" \
    test ! -e "$record"

# --- Case AB: a HOME with a trailing slash -----------------------------------
# Every OTHER actor — bundle-root.sh's BSP_ANCHOR/RECORD_PATH, the guard's
# pre-source literals, Rule D's great_cto anchor — builds its paths from
# `${HOME%/}`. If this hook builds the anchor it RECORDS from a bare `$HOME`,
# a trailing-slash HOME writes `/home/u//.agents/beads-superpowers` into
# record.anchor, which no reader's `${HOME%/}` spelling ever equals: every gate
# reads the record as "does not describe this anchor" and denies. And because
# the anchor symlink still resolves and still matches record.target, the
# refresh branch stands down and rewrites the same broken record every session
# — a permanent brick, not a transient one.
home=$(mk_anchor_home none); ws=$(mk_ws)
clone="$home/dev/beads-superpowers"; mk_root "$clone" 1.0.0
anchor=$(anchor_of "$home"); record=$(record_of "$home")
ROOT_OVERRIDE="$clone"; out=$(run_hook "$home/" "$ws" "$(payload AB '')" ""); rc=$?; unset ROOT_OVERRIDE
assert "hook exits 0 with a trailing slash in HOME" "rc=$rc (out: $out)" test "$rc" -eq 0
assert "record written under a trailing-slash HOME" "$record missing" test -f "$record"
if [ -f "$record" ]; then
    assert "record.anchor carries no doubled slash under a trailing-slash HOME" \
        "got $(jqr '.anchor' "$record")" jqok '.anchor | test("//") | not' "$record"
    assert "record.anchor is the \${HOME%/} spelling every reader builds" \
        "got $(jqr '.anchor' "$record")" jqok ".anchor == \"$anchor\"" "$record"
fi

[ "$fail" -eq 0 ] && echo "PASS: session-start pipeline state" || exit 1
