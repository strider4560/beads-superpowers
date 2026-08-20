# Manual verification — what install-shape can NOT prove

`just shape` proves artifacts land where each harness expects. It does NOT prove hooks
fire. These checks are manual, by design (auth-gated or interactive):

| Check | Harness | How |
|---|---|---|
| SessionStart fires + `bd prime` injects | Claude Code | new session in a bd repo → context shows "Beads Workflow Context" |
| SessionStart fires (needs `codex_hooks = true`) | Codex | new session → bootstrap injected |
| Plugin bootstrap + compaction re-injection | OpenCode | new session; then compact → re-injection |
| Native plugin install works at all | Antigravity, Droid | auth-gated — run the hint command from a logged-in CLI |
| Native install hints are still correct | all Tier B | run the printed command against the live harness |
| Windows polyglot hook (`hooks/run-hook.cmd`) | Claude Code on Windows | out of suite scope — see `.internal/windows/` |
| Install-root posture on the plugin channel | Claude Code | both cases below |

## Plugin-channel install root and posture (spec D3)

On the scripted tiers `install.sh` populates `~/.agents/beads-superpowers` and writes the
ownership record, and `just shape claude` asserts all of it. On the Claude Code plugin
channel no installer ever runs: `hooks/session-start` maintains the anchor, and it can only
do so from inside a real harness session. That is why these two checks are manual.

The posture is **declared, never inferred**, and the discriminator is the plugin root's
canonical path: under `~/.claude/plugins/` (either `cache/` or `marketplaces/`) it is
`manifest-backed`; anywhere else it is `dev-clone-advisory`. Read it the same way in both
cases:

```bash
jq -r '.posture, .target' ~/.local/state/beads-superpowers/record.json
readlink ~/.agents/beads-superpowers
```

**Case 1 — stock marketplace install.** `claude plugin marketplace add strider4560/beads-superpowers`,
`claude plugin install beads-superpowers@beads-superpowers-marketplace`, then start a new
session. Expected: the anchor is a symlink into `~/.claude/plugins/…`, and the record reads
posture `manifest-backed` with `target` equal to that path. A stock marketplace install is
itself a git clone, so "is a git working tree" is NOT the discriminator — if this prints
`dev-clone-advisory`, the managed-directory prefix set has drifted.

**Case 2 — cache symlinked to a development clone.** Point the plugin cache entry at a local
checkout (the maintainer host setup), then start a new session. Expected: posture
`dev-clone-advisory`, and the pipeline gates say so on stderr — "advisory (unpinned root) by
declared posture" — rather than verifying a manifest. An unpinned root that reports
`manifest-backed` means the record is attesting hashes nobody re-writes when the clone moves.

Both cases also expect a real directory at the anchor to be left alone: if `~/.agents/beads-superpowers`
is a directory (a scripted install), the hook stands down and neither the anchor nor the
record changes.
