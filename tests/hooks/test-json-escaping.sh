#!/usr/bin/env bash
# test-json-escaping.sh — verify session-start escape_for_json produces
# valid JSON when injected content contains double-quotes, backslashes, and real newlines.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0

# Build a temp plugin tree with the hook and a crafted fixture file.
# Layout mirrors production: hooks/ and skills/using-superpowers/ siblings.
tmp=$(mktemp -d)
mkdir -p "$tmp/hooks" "$tmp/skills/using-superpowers"
cp -f "$ROOT/hooks/session-start" "$tmp/hooks/session-start"
# Scratch HOME for every hook run below: the hook maintains
# $HOME/.agents/beads-superpowers and writes $HOME/.local/state/beads-superpowers/,
# and on a developer machine $HOME/.agents is commonly a synced dotfiles tree.
mkdir -p "$tmp/home"

# Fixture: contains a double-quote, a backslash, and multiple real newlines.
# All three require escape_for_json to produce valid JSON.
printf 'line one has a "double-quote"\nline two has a backslash \\\nline three is clean\n' \
  > "$tmp/skills/using-superpowers/SKILL.md"

# Run hook and pipe output directly to jq -e . (do NOT echo "$var" | jq — echo mangles \n).
# Generic dialect (no harness env vars) → top-level { "additionalContext": "..." }.
if HOME="$tmp/home" bash "$tmp/hooks/session-start" 2>/dev/null | jq -e . >/dev/null 2>&1; then
  echo "PASS: escape_for_json — output is valid JSON with quotes, backslashes, and newlines in content"
else
  echo "FAIL: escape_for_json — output is NOT valid JSON"
  echo "--- raw hook output ---"
  HOME="$tmp/home" bash "$tmp/hooks/session-start" 2>/dev/null || true
  echo "--- end ---"
  fail=1
fi

# --- C0 control bytes in the mex hot page must not break the envelope ---
# JSON forbids raw U+0000-U+001F inside a string. A pasted transcript in
# .mex/lessons.md can carry 0x0C (form feed) or 0x1B (ESC); one of them reaching
# the output unescaped costs the session ALL of its injected context.
# Parser is real, not a regex: jq, else python3, else node, else visible SKIP.
json_ok() {
  if command -v jq >/dev/null 2>&1; then jq -e . >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -m json.tool >/dev/null 2>&1
  elif command -v node >/dev/null 2>&1; then
    node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>JSON.parse(d))' >/dev/null 2>&1
  else return 2; fi
}
ctl=$(mktemp -d)
mkdir -p "$ctl/ws/.mex" "$ctl/home/.claude" "$ctl/run"
printf 'router\n' > "$ctl/ws/.mex/ROUTER.md"
printf 'lesson one\x0cform feed above\nlesson two\x1bescape above\n' > "$ctl/ws/.mex/lessons.md"
ctl_out=$(cd "$ctl/ws" && printf '{"session_id":"ctl-a","source":"startup"}' \
  | HOME="$ctl/home" XDG_RUNTIME_DIR="$ctl/run" bash "$tmp/hooks/session-start" 2>/dev/null)
if printf '%s\n' "$ctl_out" | json_ok; then
  echo "PASS: C0 control bytes (0x0C, 0x1B) in .mex/lessons.md — output still parses as JSON"
else
  rc=$?
  if [ "$rc" = 2 ]; then
    echo "SKIP: C0 control-byte case — no JSON parser available (jq, python3, node all absent)"
  else
    echo "FAIL: C0 control bytes in .mex/lessons.md make hook output unparseable"
    fail=1
  fi
fi
rm -rf "$ctl"

rm -rf "$tmp"
exit $fail
