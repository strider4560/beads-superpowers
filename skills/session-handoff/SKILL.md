---
name: session-handoff
description: A human-invoked utility that writes a grounded session-handoff document (plus a continuation pointer on the mex hot page) so a fresh agent can resume in-progress work. Not auto-invoked; a human runs it deliberately.
disable-model-invocation: true
---

# Session Handoff

Write a grounded handoff document — and a one-line continuation pointer on the mex hot
page — so a fresh session can resume exactly where this one left off.

**Announce at start:** "I'm using the session-handoff skill to write a session handoff."

> **Human-invoked only.** A human fires this skill directly (slash command or explicit
> ask) — before `/clear`, `/compact`, a context limit, or a teammate handoff. It stays
> off every agent-trigger surface by design.

## When a human uses this

- Before `/clear` or `/compact`, mid-task, when context is about to be lost.
- End of a working session, to seed the next one.
- Handing work to a teammate or another agent.

Optional argument: a short description of what the next session will focus on — used to
tailor Work In Progress / Loose Threads / Suggested Skills.

## Pipeline

1. **Gather (read-only, run the commands — do not recall):**
   `git status -sb`, `git log --oneline -15`, `git diff --stat`, branch + ahead/behind;
   `bd ready`, `bd blocked`, `bd count --by-status`, in-progress beads; list the
   spec, plan, and architecture-decision-record files touched this session.
   Done when: every listed command has run and its output is captured.
2. **Synthesize** into the bundled template (`handoff-template.md`). **Reference
   artifacts by path — never paste their bodies** (commits, ADRs, specs, plans, diffs).
   Duplicating bloats the doc and goes stale.
   **Write for the machine reader:** the consumer is a fresh agent with no way to ask
   what you meant. Short active sentences, one fact per line, one name per artifact
   used consistently, no pronouns whose referent lives in this dead session ("the fix
   we discussed"). "Exact next action" is an instruction: imperative, one action, ≤20
   words. Keep honest hedges ("push may have failed") — never promote them to facts.
   (Full rules: `../subagent-driven-development/references/ste-authoring.md`.)
   Done when: every section maps to a captured fact, referenced by path.
3. **Write the doc** — Default: `.internal/handoff/YYYY-MM-DD[-HHMMSS]-<topic>-handoff.md`
   (`-HHMMSS` only if a same-day handoff exists).
   (The same-day check globs the inbox `.internal/handoff/*.md` only; archived docs under `archive/` are out of scope and do not affect same-day naming.)
   If the human names another location,
   write there. `mkdir -p` the target first.
   Done when: the doc exists at the target path.
4. **Write the continuation pointer** — append one entry to `.mex/lessons.md` per the
   capture contract (`mex-curator` owns the store; this skill only appends):
   `lesson: continuation — <one-line pointer to doc path + headline state>; see .internal/handoff/<file>`
   One entry per handoff, named for its doc (`continuation-<date>-<topic>`), so
   `getting-up-to-speed` can prune superseded ones by the `lesson: continuation`
   line prefix.
   **Cap-aware:** the hot page is hard-capped at 2048 bytes. Check first
   (`wc -c .mex/lessons.md`); if the append would exceed the cap, demote the coldest
   entries to `.mex/lessons-archive.md` until it fits — demote, never delete.
   No `.mex/` directory → say so and skip this step; the doc still stands on its own.
   Done when: the entry is in `.mex/lessons.md` and the page is ≤ 2048 bytes.
5. **Verification (externally anchored — output the result block):**
   - Cross-check each state line against the **captured Phase-1 command output**.
   - **Gitignore safety:** `git check-ignore <output-path>`; if NOT ignored, warn the
     human ("⚠️ <dir> is not gitignored; a handoff can contain sensitive session
     state") and offer to add it to `.gitignore` **before** writing.
   - `ls <path>` confirms the doc exists; `grep -n 'continuation' .mex/lessons.md` plus
     `wc -c .mex/lessons.md` confirm the entry landed and the page is within its cap.
   - **Secret-scan grep** over the doc (`sk-`, `ghp_`, `AKIA`, `-----BEGIN`,
     `password=`) — a backstop, not a guarantee.
   - The narrative synthesis is the author's recollection — not externally verified;
     that is why it references artifacts by path.
   Done when: the confirmation block is output — doc path · continuation entry +
   hot-page byte count · gitignore-safety result · secret-scan result.

## Doctrine

- **Redact secrets** (keys, tokens, passwords, PII) — the doc lands on disk and may be
  shared, and the continuation entry lands on a hot page injected into every future
  session. This is a hard rule; never weaken it.
- **Reference, don't duplicate** — point at commits/ADRs/specs by path.
- **Ground every fact** — run the gather commands; never invent state. If a command
  fails (not a git repo, `bd` absent), degrade gracefully and note the gap.

## Red Flags (low-independence backstop — not the primary guard)

| Rationalization | Reality |
|---|---|
| "I'll write it from memory" | Run the gather commands — recollection drifts. |
| "I'll add it to the skill index so the agent finds it" | Forbidden — human-invoked only. |
| "The output dir is probably gitignored" | Run `git check-ignore` — secrets to a tracked path is a leak. |

## Integration

**Standalone.** Human-invoked only, with no skill, hook, or agent-routing surface
pointing to it. Read-side counterpart: `getting-up-to-speed` reads the latest
`.internal/handoff/` doc (no skill-to-skill call) and archives it to
`.internal/handoff/archive/` on close — `.internal/handoff/` is an unread inbox, so a
stale doc is never re-read as the last session.
