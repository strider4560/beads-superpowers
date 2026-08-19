---
name: mex-curator
description: Use at session close when the session produced durable knowledge, or on demand when the `.mex/` store needs a sweep. Triggers on "curate the wiki", "distill this session", "mex sweep", "clean up .mex".
---

# mex Curator

Distill a session's durable knowledge into the repo-local `.mex/` wiki: route each durable to
its page, keep the hot page under its cap, supersede what it replaces. Input is text already in
context plus the `mex` CLI. No runtime, no embeddings.

**Announce at start:** "I'm using the mex-curator skill to distill this session's durables into `.mex/`."

## When to Use
- **Session-close** — the session produced durable knowledge (a lesson, a decision, a requirement,
  a design rationale). Offered, never automatic — see `finishing-a-development-branch` Step 7.
- **On-demand** — a full-store sweep: `Skill(beads-superpowers:mex-curator)`.

## When NOT to Use
- Sessions that produced nothing durable — the common case. Skip is the default.
- Mid-task — run at a clean stopping point, not while work is in flight.

## Runtime posture: fail loudly
Every `mex` call here is load-bearing. If one errors, surface the exact command and its output, and
stop the sweep. **Never** substitute a hand-written stand-in for a failed command — appending a
decision line to a page because `mex log` failed produces a store that looks current and is not.
Two commands lie by default; treat both as named below:
- `mex check` exits 0 **with** warnings (a stock scaffold scores 79/100). Gate on the exit code, never
  on a warning-free report.
- `mex sync` exits 0 having repaired nothing when errors are present and stdin is closed. Its exit
  code proves nothing; only a second `mex check` does.

`.mex/lessons.md`, `.mex/lessons-archive.md`, and `.mex/private/` are this product's pages —
mex 0.7.1 neither creates nor reads them. `project-init` seeds `.mex/lessons.md` and creates
`.mex/private/`; `.mex/lessons-archive.md` is created by this skill on the first demotion. If
`.mex/lessons.md` or `.mex/private/` is missing, run `project-init`. Do not improvise a different layout.

## Routing table
**The destination is the routing decision.** Classify each durable once; the row sets where it is
written and by what.

| Session durable | Destination | Written by |
|---|---|---|
| requirement / PRD statement | `.mex/requirements.md` | file edit |
| design rationale | `.mex/architecture.md` | file edit |
| convention (how this repo does a thing) | `.mex/conventions.md` | file edit |
| reusable code pattern | `.mex/patterns/<name>.md` | file edit |
| compliance durable | `.mex/compliance.md` | file edit |
| sensitive class — unmitigated risk, security gap, compliance exposure, unreleased plan | `.mex/private/` | file edit |
| decision | `mex log --type decision` ± ADR, per the capture contract | `mex log` |
| lesson / pattern / root-cause / correction | `.mex/lessons.md` (the hot page) | file edit |
| procedural how-to (steps an agent follows) | **banned from the store** — it belongs in a skill | — |

- **Sensitive class trade-off:** `.mex/private/` is gitignored and local-only. It never syncs, never
  reaches a teammate, and dies with the clone. That cost is accepted deliberately: the sensitive class
  must not land on a tracked page in a public repo. When others need the durable, write a sanitized
  version to the tracked page and leave the sensitive detail private — never move the sensitive detail
  out to buy sync.
- **Decisions:** `mex log --type decision "<one-line decision>"` — bare `mex log` records kind `note`,
  not a decision. The log file is `.mex/events/decisions.jsonl`, created lazily by the first `mex log`.
  The prose page is `.mex/context/decisions.md` (not `.mex/decisions.md`).
- If a durable fits no row, ask — don't invent a page. If an extracted "durable" is really procedural,
  flag it for a skill; don't store it.

## Hot-page management
`.mex/lessons.md` is the **hot page** — the only page injected at session start. It is hard-capped
at **2048 bytes**.

- One bullet per lesson, prefixed by kind (`lesson:` / `pattern:` / `root-cause:` / `correction:`),
  with the evidence named. Update an existing entry in place rather than adding a near-duplicate.
- Check the size before appending (`wc -c .mex/lessons.md`). If an append would exceed 2048 bytes,
  **demote** the coldest entries — oldest, least-referenced — to `.mex/lessons-archive.md` until it
  fits. Demote, never delete: the archive stays retrievable through the router, it is just not injected.
- Promotion: **twice-burned promotes: a routed lesson whose miss cost a session moves to the hot page.**
  One session's miss is not enough; two is the bar.

## Supersession
**Never delete first — write, verify, then remove.** A removal that runs before its successor exists
loses the durable outright, and nothing in `.mex/` warns you.

1. Write the new entry at its routed destination.
2. Verify it — re-read the file and confirm the entry is there, in full.
3. Only then remove the superseded entry.

For decisions, the forward-pointer is part of the supersession. A superseding ADR's log line reads
`supersedes ADR-NNNN`; find them with `grep 'supersedes ADR-' .mex/events/decisions.jsonl` and, for
each, make the stale entry in `.mex/context/decisions.md` point forward to the superseding ADR. Add
the pointer to the stale entry — do not rewrite or delete its text; a decision record that no longer
shows what was decided is worse than a stale one.

## Iron rule: propose, then apply
This mutates the knowledge layer read by every future session — the hot page is injected at session
start, and the rest is routed by `mex graph scope`. A bad run corrupts that layer invisibly. So:

- Emit the full planned change list — every page edit (ADD / UPDATE / DEMOTE / PROMOTE / SUPERSEDE,
  naming the target page) and every `mex log --type decision` line, each with a one-line reason — and
  get the user's approval before applying ANY of it. The on-demand sweep is dry-run-first, always.
- Surface the rollback path with the proposal: tracked `.mex/` pages roll back through git, so name
  the pre-sweep commit. `.mex/private/` is gitignored and has **no** rollback — say so when the plan
  touches it.
- No removal without a written-and-verified successor, an exact-duplicate match, or a cited reason.

## Secrets
**Never persist secrets, credentials, tokens, keys, or PII** — the hot page is injected into every
future session, tracked `.mex/` pages are public in a public repo, and git history outlives any later
removal. Scan every candidate before writing it. A secret found in a candidate is **flagged for
removal, never relocated** — not into `.mex/private/` either.

## The sweep
One pass. Input: the session (in context) plus the current `.mex/` pages. Output: a **reviewed** change
list, applied only after approval.

1. **Extract** — pull the session's durable, self-contained claims. Store a claim ONLY if it carries
   checkable evidence (cited `file:line`, passing test, command output, closed bead) — the same bar as
   Agent-Filed Bead Discipline in `verification-before-completion`. No evidence → drop it.
   Done when: every extracted claim is evidence-backed, dropped, or flagged for a skill.
2. **Route** — assign each claim a destination from the routing table; run the secret scan on it.
   Done when: every surviving claim names exactly one destination.
3. **Reconcile** — for each destination, decide ADD, UPDATE-in-place, or SUPERSEDE against what the page
   already holds. Merging keeps the MOST information; never silently shrink an entry.
   Done when: every routed claim is an ADD, an UPDATE, a SUPERSEDE, or a skip with a reason.
4. **Propose and apply** — emit the change list per the iron rule, get approval, then apply it: file
   edits first, `mex log --type decision` lines after. Hot-page demotions run as part of the same
   approved list.
   Done when: every approved change is applied and verified by re-reading its target.
5. **Close** — run the check below.

## Close with `mex check`
```bash
mex check    # gate on the EXIT CODE — warnings at exit 0 are the stock baseline, not a failure
```

- **Exit 0** — done. Report the score line as-is; do not call warnings a failure, and do not chase
  them into scope creep.
- **Exit non-zero, errors scoped to pages this session touched** — run `mex sync` **once**, then run
  `mex check` a **second** time and gate on *that* exit code. `mex sync`'s own exit code is not
  evidence: it exits 0 having repaired nothing when stdin is closed.
- **Exit non-zero after the second check, or drift broader than this session's pages** — do not sweep
  the repo. File one bead — `bd create "chore: mex sync backlog — <pages>" -t chore`, stamped per
  Agent-Filed Bead Discipline (`verification-before-completion`) — then land anyway, stating the dirty
  state and the bead id explicitly in the close summary. A dirty store that is disclosed is fine; a
  dirty store that is not is a false green.

## Capture contract
The contract every other skill captures under — the curator is its enforcement pass:

**Capture what you learned.** At close, record durable, evidence-backed insights (still true next month, tied to a file, test, or command) in `.mex/lessons.md`: one bullet per lesson, prefixed by kind (`lesson:` / `pattern:` / `root-cause:` / `correction:`), with the evidence named. Update an existing entry in place rather than adding a near-duplicate. The hot page is hard-capped at 2048 bytes — if an append would exceed it, demote the coldest entries to `.mex/lessons-archive.md` (retrievable via the router, not injected) until it fits. Decisions: `mex log --type decision "<one-line decision>"` always (bare `mex log` records kind "note", not a decision); add a full `docs/decisions/ADR-NNNN-<kebab>.md` (+ `INDEX.md`) only when the ADR bar is met (hard-to-reverse AND surprising-without-context AND genuine trade-off). Requirements, design rationale, and compliance durables: distill into the matching `.mex/` page. Durables that name an unmitigated risk, security gap, compliance exposure, or unreleased plan go to `.mex/private/` (gitignored), never to tracked pages. Never record guesses, one-offs, or secrets (tokens, keys, PII — the hot page is injected into all future sessions, and tracked `.mex/` pages are public in public repos); scan before writing.

## Red Flags
| Thought | Reality |
|---------|---------|
| "I'll just apply the edits" | Propose the list; the user approves first — never mutate `.mex/` silently. |
| "This is probably worth keeping" | No cited evidence → it doesn't meet the bar. Drop it. |
| "There might be a token in here, but it's internal" | Redact or drop. Never persist secrets/PII — not into `.mex/private/` either. |
| "`mex sync` exited 0, so the store is repaired" | It exits 0 having repaired nothing with stdin closed. Only a second `mex check` proves repair. |
| "`mex check` printed warnings, so it failed" | 79/100 with warnings at exit 0 is the stock baseline. Gate on the exit code. |
| "The old entry is obviously replaced — delete it now" | Never delete first. Write, verify, then remove. |
| "This how-to would be useful in the wiki" | Procedural how-to belongs in a skill. It is banned from the store. |

## Beads Integration
```bash
bd create "mex curation: <session/sweep>" -t chore
# after the user approved + you applied:
bd close <id> --reason "Distilled: <N pages updated, M demoted, K superseded, J decisions logged>; mex check exit <code>"
```
Run this as the session/ledger-owning agent; a dispatched single-task subagent does not.

## Integration
**Invoked at:** session-close (offered when the session produced durable knowledge — see
`finishing-a-development-branch` Step 7), by the human-invoked handoff skill, and on-demand by
the user.
**Pairs with:** `verification-before-completion` (supplies the evidence bar) and `getting-up-to-speed`
(reads `.mex/` at session start; this skill owns what is there to read).

Durables arrive unrouted from other skills; the curator assigns the destination on contact. Do not add
routing logic to other skills — capture-then-curate is the intended split.
