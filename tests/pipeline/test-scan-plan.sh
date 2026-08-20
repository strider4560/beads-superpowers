#!/usr/bin/env bash
# test-scan-plan.sh — contract for scripts/scan-plan.sh (spec D6).
# Every case writes a fixture plan into a mktemp dir and scans THAT, so the
# suite never reads a real plan. Token-shaped fixtures are assembled at run
# time from fragments: a literal `ghp_`+36 or a literal JWT sitting in a
# tracked test file is itself the leak this scanner exists to prevent.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
scan="$root/scripts/scan-plan.sh"
fails=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture builder --------------------------------------------------------

mkfix() { # <name> — writes stdin to $TMP/<name>.md and sets $f to its path
  f="$TMP/$1.md"; cat > "$f"
}

# --- runner + assertion -----------------------------------------------------

run() { # <args...> — raw argv for the scanner; sets rc, out (stdout), err (stderr)
  out="$("$BASH" "$scan" "$@" 2>"$TMP/stderr" </dev/null)"
  rc=$?
  err="$(cat "$TMP/stderr")"
}

check() { # <name> <want-exit> [<ere-pattern on stdout>] — one PASS/FAIL line
  local name="$1" want="$2" pattern="${3:-}" detail=""
  if [ "$rc" -ne "$want" ]; then
    detail="exit $rc want $want (stdout: $out) (stderr: $err)"
  elif [ -n "$pattern" ]; then
    printf '%s\n' "$out" | grep -qE -- "$pattern" || detail="no /$pattern/ on stdout: $out"
  fi
  if [ -z "$detail" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: $detail"
    fails=$((fails+1))
  fi
}

# --- token fragments (never a whole credential shape in the source) ---------

gh_tok="ghp_$(printf 'a%.0s' $(seq 36))"
jwt_tok="ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiJmaXh0dXJlIn0"
slack_tok="xox""b-EXAMPLE-NOT-A-REAL-TOKEN"
hex32="0123456789abcdef0123456789abcdef"
b64_40="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZQ"

# --- clean plan: exit 0, nothing on stdout ----------------------------------
# The scanner must stay quiet on the shape a real plan actually has, including
# a plans/-relative path and a bare (unquoted) mention of a plan-internal word.

mkfix clean <<'EOF'
# Plan: widget rollout

Spec: `plans/2026-08-19-widget.md`

## Task 1: add the widget

- Files: `src/widget.js`
- Verify: `npm test`
EOF
run "$f"
check "clean-plan-exits-0" 0
if [ -z "$out" ]; then echo "PASS clean-plan-prints-nothing"; else
  echo "FAIL clean-plan-prints-nothing: $out"; fails=$((fails+1)); fi

# --- one fixture per pattern class ------------------------------------------

mkfix begin <<'EOF'
# Plan

-----BEGIN CERTIFICATE-----
EOF
run "$f"
check "private-key-header-exits-1" 1 ':[0-9]+: private-key header'

mkfix aws <<'EOF'
# Plan

Deploy with AKIAIOSFODNN7EXAMPLE.
EOF
run "$f"
check "aws-access-key-exits-1" 1 ':[0-9]+: AWS access key id'

printf '# Plan\n\nUse %s to authenticate.\n' "$gh_tok" > "$TMP/gh.md"
run "$TMP/gh.md"
check "github-token-exits-1" 1 ':[0-9]+: GitHub personal access token'

printf '# Plan\n\nPost with %s here.\n' "$slack_tok" > "$TMP/slack.md"
run "$TMP/slack.md"
check "slack-token-exits-1" 1 ':[0-9]+: Slack token'

printf '# Plan\n\nBearer %s\n' "$jwt_tok" > "$TMP/jwt.md"
run "$TMP/jwt.md"
check "jwt-exits-1" 1 ':[0-9]+: JSON Web Token'

printf '# Plan\n\napi_key = "%s"\n' "$hex32" > "$TMP/assign-hex.md"
run "$TMP/assign-hex.md"
check "hex-value-assigned-to-a-key-name-exits-1" 1 \
  ':[0-9]+: secret-like value assigned to a key/token/secret/password name'

# The JSON/YAML spelling quotes the NAME too, so a closing quote sits between
# the name and the separator. It is the form a pasted config block actually has.
printf '# Plan\n\n{ "apiKey": "%s" }\n' "$hex32" > "$TMP/assign-json.md"
run "$TMP/assign-json.md"
check "quoted-name-json-assignment-exits-1" 1 \
  ':[0-9]+: secret-like value assigned to a key/token/secret/password name'

printf '# Plan\n\nSESSION_SECRET: %s\n' "$b64_40" > "$TMP/assign-b64.md"
run "$TMP/assign-b64.md"
check "base64-value-assigned-to-a-secret-name-exits-1" 1 \
  ':[0-9]+: secret-like value assigned to a key/token/secret/password name'

# Case-insensitivity of the NAME half is explicit in the contract.
printf '# Plan\n\nPassword=%s\n' "$hex32" > "$TMP/assign-case.md"
run "$TMP/assign-case.md"
check "name-half-is-case-insensitive" 1 \
  ':[0-9]+: secret-like value assigned to a key/token/secret/password name'

mkfix internal <<'EOF'
# Plan

Background: `.internal/specs/2026-08-19-thing.md`
EOF
run "$f"
check "quoted-internal-path-exits-1" 1 ':[0-9]+: quoted \.internal/ path'

# A shell-variable prefix is how a portable path to the same directory gets
# written; it must not be an escape hatch out of the rule.
mkfix internal-envvar <<'EOF'
# Plan

Background: `$HOME/.internal/specs/x.md`
EOF
run "$f"
check "quoted-internal-path-with-variable-prefix-exits-1" 1 ':[0-9]+: quoted \.internal/ path'

mkfix handoff <<'EOF'
# Plan

Inbound: `2026-08-19-beads-superpowers-handoff.md`
EOF
run "$f"
check "quoted-handoff-filename-exits-1" 1 ':[0-9]+: quoted hand-carried handoff filename'

# A handoff-shaped name UNDER plans/ is a tracked plan artifact, not a
# hand-carried file. Firing on it would make the tracked location unusable.
mkfix handoff-in-plans <<'EOF'
# Plan

Predecessor: `plans/2026-08-19-handoff-integration.md`
EOF
run "$f"
check "handoff-name-under-plans-is-clean" 0

# An unquoted word is not a reference the scanner is asked to flag; the
# contract says QUOTED references, and a plan that discusses the directory in
# prose must stay committable.
mkfix internal-unquoted <<'EOF'
# Plan

Working notes live in the internal scratch area, not in this plan.
EOF
run "$f"
check "unquoted-prose-is-clean" 0

# --- output shape: file:line, one line per finding, no redaction ------------

printf '# Plan\n\nok\nAKIAIOSFODNN7EXAMPLE\n' > "$TMP/lineno.md"
run "$TMP/lineno.md"
check "finding-names-the-file-and-the-right-line" 1 "^$TMP/lineno\.md:4: "

mkfix multi <<'EOF'
# Plan

-----BEGIN CERTIFICATE-----
AKIAIOSFODNN7EXAMPLE
Background: `.internal/specs/x.md`
EOF
run "$f"
n="$(printf '%s\n' "$out" | grep -c .)"
if [ "$rc" -eq 1 ] && [ "$n" -eq 3 ]; then
  echo "PASS three-findings-print-three-lines"
else
  echo "FAIL three-findings-print-three-lines: exit $rc, $n line(s): $out"
  fails=$((fails+1))
fi

before="$(cat "$f")"
run "$f"
if [ "$before" = "$(cat "$f")" ]; then
  echo "PASS scanner-never-redacts-the-file"
else
  echo "FAIL scanner-never-redacts-the-file: content changed"
  fails=$((fails+1))
fi

# --- exit 2: wrong arguments or an unreadable file --------------------------

run
check "no-argument-exits-2" 2

run "$TMP/clean.md" "$TMP/aws.md"
check "two-arguments-exit-2" 2

run "$TMP/does-not-exist.md"
check "missing-file-exits-2" 2

run "$TMP"
check "directory-argument-exits-2" 2

# An exit-2 diagnostic belongs on stderr: stdout carries findings only, and a
# caller that greps stdout must not read a usage line as a finding.
run
if [ -z "$out" ] && [ -n "$err" ]; then
  echo "PASS usage-diagnostic-goes-to-stderr"
else
  echo "FAIL usage-diagnostic-goes-to-stderr: stdout='$out' stderr='$err'"
  fails=$((fails+1))
fi

# --- hook level: pre-commit batches filenames onto one entry ----------------
# pre-commit appends every matched path to a SINGLE invocation of the hook's
# `entry`, so the entry — not the scanner — owns the multi-file case. The entry
# is read out of the config rather than restated here, so the test tracks the
# wiring the repo actually ships. A clean file alongside a dirty one must still
# surface the dirty file's finding and fail the commit.

entry="$(awk '
  /^      - id: scan-plan$/ { in_hook = 1; next }
  in_hook && /^        entry: / { sub(/^        entry: /, ""); print; exit }
' "$root/.pre-commit-config.yaml")"

if [ -z "$entry" ]; then
  echo "FAIL hook-entry-is-readable: no scan-plan entry in .pre-commit-config.yaml"
  fails=$((fails+1))
else
  hook=()
  eval "hook=($entry)"   # pre-commit shlex-splits `entry`; so does this.
  out="$(cd "$root" && "${hook[@]}" "$TMP/clean.md" "$TMP/aws.md" 2>"$TMP/stderr" </dev/null)"
  rc=$?
  err="$(cat "$TMP/stderr")"
  check "hook-entry-reports-the-dirty-file-of-two" 1 "^$TMP/aws\.md:[0-9]+: AWS access key id$"
fi

# --- summary ----------------------------------------------------------------

if [ "$fails" -ne 0 ]; then echo "FAIL: scan-plan ($fails failing)"; exit 1; fi
echo "PASS: scan-plan"
