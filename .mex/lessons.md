# Lessons

- lesson: A harness model id can carry a context-variant suffix (`claude-opus-5[1m]`). `shared/tier-map.json` lists only bare ids, so `resolve_session_tier` returns 1 (bundle-root.sh:191) and `pipeline-guard` hard-denies EVERY Bash/Write/Edit for the whole session (pipeline-guard:313). Evidence: this session, 2026-08-20.
- lesson: The `--assert` remedy the guard prints cannot clear an unmapped-model deny — `resolve_session_tier` reaches the `tier-assert` fallback only when `session.json` yields an EMPTY model, and a non-empty-but-unmapped model returns 1 first. Remedy is a tier-map edit (human-only under Rule D). Evidence: bundle-root.sh:175-207 read this session.
