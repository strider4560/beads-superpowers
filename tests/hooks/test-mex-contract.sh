#!/usr/bin/env bash
# tests/hooks/test-mex-contract.sh — pins the mex-agent 0.7.1 CLI behaviors the .mex/
# durable-knowledge integration depends on. Runs against a SCRATCH git repo (mktemp -d,
# outside the repo tree) with HOME redirected there too — it never touches this repo's
# .mex/ or the user's ~/.mex/telemetry-id. A future mex that regresses any of the 5
# pinned behaviors below must fail THIS test rather than silently break the skills.
#
# Every expectation here comes from the verified observation note
# .internal/research/2026-08-mex-cli-surface.md (mex-agent@0.7.1, node:22). Section
# references below point at the transcript that pins each assertion.
#
# set -uo pipefail, NOT -e: assertions capture output and inspect exit codes explicitly,
# and a zero-match grep/parse must reach its FAIL diagnostic instead of aborting silently.
set -uo pipefail
export LC_ALL=C

# --- SKIP contract (visible, mirrors the node/shellcheck SKIP convention) -----------
# run-hook-tests.sh treats a non-zero exit as FAIL, so guard rather than fail. The
# contract is pinned to ONE mex version: a different version is unpinned, not passing.
command -v mex >/dev/null 2>&1 || { echo "SKIP (mex not installed)"; exit 0; }

PINNED="0.7.1"
# §6: `mex --version` prints a bare semver plus newline — no `v` prefix, no program name.
ver_raw=$(mex --version 2>/dev/null)
ver=$(printf '%s' "$ver_raw" | head -1 | tr -d '\r')
[ "$ver" = "$PINNED" ] || { echo "SKIP (mex ${ver:-unknown} != pinned $PINNED)"; exit 0; }

# mex is an npm package with engines.node >= 22.5, so node is present wherever mex runs.
# Parsing JSON with node (not grep) is what makes behaviors 2 and 4 real round-trips.
command -v node >/dev/null 2>&1 \
  || { echo "FAIL: node not found, but mex requires node >= 22.5 — rig broken"; exit 1; }

T=$(mktemp -d) || { echo "FAIL: mktemp -d failed (rig broken)"; exit 1; }
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
export HOME="$T/home"
mkdir -p "$HOME" "$T/repo/src" || { echo "FAIL: could not build scratch dirs"; exit 1; }
cd "$T/repo" || { echo "FAIL: could not enter scratch repo"; exit 1; }

# Bounded runner — mex prompts read stdin, so an unfed prompt must time out loudly
# rather than hang the suite. `timeout` is coreutils; fall back if it is absent.
run_mex() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 mex "$@"; else mex "$@"; fi
}

# --- fixture: the same shape as the observation note's scratch repo (§1c) -----------
# git repo + package.json + README + two committed src/*.js files. The source files
# matter: `mex setup` builds .mex/graph.db from them, so a graph-less run is a real
# regression here and not just an empty-directory artifact.
{
  git init -q . \
    && git config user.email "test@example.com" \
    && git config user.name "mex contract test" \
    && printf '{"name":"mexcontract","version":"1.0.0"}\n' > package.json \
    && printf '# mexcontract\n\nScratch fixture.\n' > README.md \
    && printf 'function helper(n) { return n + 1; }\nfunction greet(name) { return helper(name.length); }\nmodule.exports = { greet, helper };\n' > src/index.js \
    && printf 'const { greet } = require("./index.js");\nfunction main() { return greet("world"); }\nmodule.exports = { main };\n' > src/main.js \
    && git add -A \
    && git commit -qm "fixture" ;
} >/dev/null 2>&1 \
  || { echo "FAIL: setup — could not build the scratch git fixture (rig broken, not a mex regression)"; exit 1; }

# --- 1. `mex setup` completes and writes the FULL scaffold -------------------------
# §1b/§2b: `mex setup` has no non-interactive flag. With stdin closed it exits 0 having
# written only the 11 markdown files — no config.json, no graph.db. Asserting
# "ROUTER.md exists && exit 0" is therefore FALSE-GREEN on that partial path. Two
# things are pinned together: pipe-driving the two prompts (`1` = Claude Code,
# `n` = do not install globally) works, and the resulting census is the complete
# 13-file layout from §2b.
setup_out=$(printf '1\nn\n' | run_mex setup 2>&1)
setup_rc=$?
[ "$setup_rc" -eq 0 ] \
  || { printf 'FAIL: mex setup exited %s (want 0)\n%s\n' "$setup_rc" "$setup_out"; exit 1; }

[ -f .mex/ROUTER.md ] || { echo "FAIL: mex setup did not create .mex/ROUTER.md"; exit 1; }

expected_census=".mex/AGENTS.md
.mex/ROUTER.md
.mex/SETUP.md
.mex/SYNC.md
.mex/config.json
.mex/context/architecture.md
.mex/context/conventions.md
.mex/context/decisions.md
.mex/context/setup.md
.mex/context/stack.md
.mex/graph.db
.mex/patterns/INDEX.md
.mex/patterns/README.md"
actual_census=$(find .mex -type f | sort)
[ "$actual_census" = "$expected_census" ] || {
  printf 'FAIL: .mex/ census does not match the pinned 13-file complete-setup layout.\n'
  printf -- '--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_census" "$actual_census"
  printf 'A census missing config.json/graph.db is the stdin-closed PARTIAL scaffold (note 1b).\n'
  exit 1
}
echo "PASS (1/5): mex setup pipe-drives to completion and writes the full 13-file scaffold"

# --- 2. `mex log --type decision` appends one JSON line, lazily -------------------
# §2c/§3: the event log lives at .mex/events/decisions.jsonl (NOT .mex/decisions.jsonl,
# and NOT the .mex/context/decisions.md prose page). Neither the directory nor the file
# is created by setup — both appear on the first `mex log`. §3: bare `mex log` records
# kind "note"; recording a decision REQUIRES --type decision.
EVENTS=".mex/events/decisions.jsonl"
[ -e "$EVENTS" ] && { echo "FAIL: $EVENTS existed before any mex log — laziness contract changed"; exit 1; }

log_out=$(run_mex log --type decision "test decision" 2>&1)
log_rc=$?
[ "$log_rc" -eq 0 ] \
  || { printf 'FAIL: mex log --type decision exited %s (want 0)\n%s\n' "$log_rc" "$log_out"; exit 1; }
[ -f "$EVENTS" ] || { echo "FAIL: mex log did not create $EVENTS lazily"; exit 1; }

# Round-trip the appended line through a real JSON parser: exactly one line, valid JSON,
# kind (or type) "decision", message preserved verbatim.
log_kind=$(node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  if (lines.length !== 1) { console.error("line count " + lines.length + ", want 1"); process.exit(3); }
  const o = JSON.parse(lines[0]);
  if (o.message !== "test decision") { console.error("message=" + JSON.stringify(o.message)); process.exit(4); }
  process.stdout.write(String(o.kind ?? o.type ?? ""));
' "$EVENTS" 2>&1)
node_rc=$?
[ "$node_rc" -eq 0 ] \
  || { printf 'FAIL: %s did not round-trip as one JSON line: %s\n' "$EVENTS" "$log_kind"; exit 1; }
[ "$log_kind" = "decision" ] \
  || { echo "FAIL: logged event kind is '$log_kind', want 'decision' (--type decision regressed)"; exit 1; }
echo "PASS (2/5): mex log --type decision creates $EVENTS lazily and appends one decision-kind JSON line"

# --- 3. `mex check` exits 0 on a fresh scaffold ------------------------------------
# §4a/§4d: a stock scaffold is NOT clean — it scores 79/100 with 7 BROKEN_LINK warnings
# from mex's own placeholder rows in patterns/INDEX.md. Exit code tracks ERROR count,
# not the drift score, so only the exit code is asserted here. Any gate that demands a
# warning-free report would fail out of the box.
check_out=$(run_mex check 2>&1)
check_rc=$?
[ "$check_rc" -eq 0 ] \
  || { printf 'FAIL: mex check on a fresh scaffold exited %s (want 0 — warnings are allowed, errors are not)\n%s\n' "$check_rc" "$check_out"; exit 1; }
echo "PASS (3/5): mex check exits 0 on a fresh scaffold (warnings allowed)"

# --- 4. `mex graph scope` emits JSONL ---------------------------------------------
# §5a/§5d: output is JSONL — one JSON object per line, first line a {"type":"meta",...}
# envelope. Exit code is deliberately NOT asserted: scope exits 0 on a zero-match query
# AND on {"type":"error","code":"GRAPH_UNAVAILABLE"}, so $? carries no signal. Callers
# must parse the envelope; this pin encodes that the first line is machine-readable.
scope_out=$(run_mex graph scope "anything" 2>&1)
scope_first=$(printf '%s\n' "$scope_out" | head -1)
[ -n "$scope_first" ] || { echo "FAIL: mex graph scope emitted no output"; exit 1; }
scope_type=$(node -e '
  const o = JSON.parse(process.argv[1]);
  if (o === null || typeof o !== "object" || Array.isArray(o)) { console.error("not a JSON object"); process.exit(3); }
  process.stdout.write(String(o.type ?? ""));
' "$scope_first" 2>&1)
scope_rc=$?
[ "$scope_rc" -eq 0 ] \
  || { printf 'FAIL: first mex graph scope line is not a JSON object: %s\n--- line ---\n%s\n' "$scope_type" "$scope_first"; exit 1; }
[ -n "$scope_type" ] \
  || { printf 'FAIL: first mex graph scope line has no "type" key — JSONL envelope changed\n--- line ---\n%s\n' "$scope_first"; exit 1; }
echo "PASS (4/5): mex graph scope emits JSONL whose first line parses as JSON (type=$scope_type)"

# --- 5. `mex --version` prints exactly the pinned version --------------------------
# §6: raw bytes are `0.7.1\n` — bare semver, one line. A version check can compare
# $(mex --version) to 0.7.1 with no parsing, which is what the SKIP guard above does.
[ "$ver_raw" = "$PINNED" ] \
  || { printf 'FAIL: mex --version is not exactly %s (no v prefix, single line). Raw: %s\n' "$PINNED" "$(printf '%s' "$ver_raw" | od -c | head -2)"; exit 1; }
echo "PASS (5/5): mex --version prints exactly $PINNED"

echo "PASS: mex CLI contract — all 5 behaviors pinned [mex $PINNED]"
