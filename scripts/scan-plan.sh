#!/usr/bin/env bash
# scan-plan.sh — secret/PII scan for a plan file before it is committed to the
# tracked plans/ directory (spec D6). Reports only — a hit is a stop plus human
# review, never an auto-redaction, so this script never writes to the file.
#   exit 0  clean
#   exit 1  findings — one `file:line: reason` line each, on stdout
#   exit 2  wrong arguments, or a file that cannot be read
# Limitation: pattern matching sees shapes, not meaning. A credential with no
# recognisable shape passes; a long identifier next to a `key`-ish name is
# reported. Both are findings for a human, not reasons to widen the patterns.
set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: scan-plan.sh <plan-file>" >&2
  exit 2
fi
file="$1"
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "scan-plan.sh: not a readable file: $file" >&2
  exit 2
fi

found=0
report() { # <line> <reason>
  printf '%s:%s: %s\n' "$file" "$1" "$2"
  found=1
}

scan() { # <grep-flags> <ere> <reason> — one finding per matching line
  local flags="$1" ere="$2" reason="$3" lineno
  while IFS=: read -r lineno _; do
    [ -n "$lineno" ] && report "$lineno" "$reason"
  done < <(grep -n"$flags"E -- "$ere" "$file")
}

# A quote or backtick. A reference is "quoted" when the path starts right after
# one of these: `"the spec" and .internal/x` is prose, `.internal/x` is a path.
q="[\"'\`]"
p='[A-Za-z0-9._/~$-]'

scan '' -----BEGIN                       'private-key header'
scan '' 'AKIA[0-9A-Z]{16}'               'AWS access key id'
scan '' 'ghp_[A-Za-z0-9]{36}'            'GitHub personal access token'
scan '' 'xox[baprs]-'                    'Slack token'
scan '' 'eyJ[A-Za-z0-9_-]{10,}\.eyJ'     'JSON Web Token'
scan 'i' "(key|token|secret|password)[A-Za-z0-9_-]*${q}?[[:space:]]*[:=][[:space:]]*${q}?[A-Za-z0-9+/=_-]{32,}" \
  'secret-like value assigned to a key/token/secret/password name'
scan '' "${q}${p}*\.internal/"           'quoted .internal/ path'

# Hand-carried handoff filenames. `plans/…-handoff….md` is a tracked plan
# artifact, so the exclusion is on the quoted path itself, not on the line —
# which is why this one reads each match rather than each matching line.
while IFS=: read -r lineno match; do
  [ -n "$lineno" ] || continue
  case "$match" in
    ?plans/*) continue ;;
  esac
  report "$lineno" 'quoted hand-carried handoff filename'
done < <(grep -noE -- "${q}${p}*-handoff${p}*\.md" "$file")

exit "$found"
