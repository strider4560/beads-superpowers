# Session Handoff — <YYYY-MM-DD> — <topic>

> **Read this FIRST on resume.** The session hook already injected beads context automatically;
> if no `<beads-context>` block is visible, run `bd prime`. This file + the continuation
> entry on the mex hot page give full orientation. Gitignored (`.internal/`), local-only.

## Current State (TL;DR)
- Repo / branch @ <sha>, sync status, working tree, version, backlog counts.

## Work In Progress
> *Primary content for a mid-work handoff. Empty if the session ended cleanly.*
- Current task + bead: <id>
- Uncommitted changes: <git diff --stat summary>
- **Exact next action:** <one concrete step>
- Dead-ends already ruled out: <so the next session doesn't repeat them>

## What Shipped This Session
- <commit sha> — <subject> (<bead id>). Reference by path; don't paste diffs.

## Architectural Decisions
- <ADR path> — <one-line rationale>.

## Key File Paths
| Artifact | Path |
|---|---|
| Spec | <path> |
| Plan | <path> |
| This handoff | <path> |

## Loose Threads
- Uncommitted/unpushed, in-flight, deferred, separate-repo notes.

## How to Resume
1. Beads context already injected by the session hook (if missing, run `bd prime`). 2. Read this file. 3. `bd ready`. 4. <next>.

## Suggested Skills
- <skill the next session should invoke and why>.

## Continuation Pointer
- `continuation-<date>-<topic>` — one-line pointer appended to `.mex/lessons.md` as
  `lesson: continuation — <one line>; see .internal/handoff/<file>` (cap-aware: demote
  coldest entries to `.mex/lessons-archive.md` if the 2048-byte cap would be exceeded).
