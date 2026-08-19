---
name: research-driven-development
description: Use when the user asks a question about a topic, requests research, or when understanding something is needed before planning. Triggers on "research this", "what is X", "how does Y work", "compare A vs B", "investigate", "deep dive", "look into".
---

# Research-Driven Development

Dispatch parallel research agents, synthesize their findings, and write a persistent research document. Research is not complete until there is a written artifact — verbal answers without documents are prohibited.

**Announce at start:** "I'm using the research-driven-development skill to investigate this topic."

## When to Use

- User asks a question about a technology, concept, or approach
- User says "research this", "deep dive", "investigate", "look into"
- User asks "what is X", "how does Y work", "compare A vs B"
- Before planning a non-trivial task that requires understanding first
- When you need to understand something before making a decision

## When NOT to Use

- User asks about a specific file in the current codebase (just read it)
- The answer is a single fact you already know with certainty
- User explicitly asks for a quick verbal answer

## Iron Law

> **NO RESEARCH WITHOUT A DOCUMENT.**
> Every research task produces a written artifact. Verbal answers without persistent documents are prohibited. If you researched it, write it down.

## Grounding Rule

> **Every load-bearing claim must be grounded by the verify stage (Step 4) before the document is written.**

## Pipeline

```
Step 0: Scope check (conditional)
Step 1: Create bead + calibrate effort
Step 2: Check existing knowledge
Step 3: Decompose + dispatch parallel research agents
Step 4: Synthesize + verify findings
Step 4.5: Gap-closing round (if needed)
Step 5: Write document
Step 6: End-gate (top-level only) + close bead
```

## Step 0: Scope Check (conditional)

If the question is already specific, **skip this step**. Fire it **only when you cannot name the sources you'd search or the decision the answer informs** — e.g. "research databases" (too vague). Do NOT fire when scope is already present — e.g. "compare Postgres vs SQLite for our embedded Dolt use case". This is disambiguation, not a quality gate — mandatory scope-gating just duplicates what a capable model already does; the "When NOT to Use" list still applies.

When it fires, ask 2–3 clarifying questions via your structured question tool (scope · use-case · the decision it informs), then weave the answers into the research question before Step 1.

## Step 1: Create a Bead + Calibrate Effort

```bash
bd create "Research: <topic>" -t task -p 2
bd update <id> --claim
```

**Calibrate effort — the query tier picks the agent count (this is the throttle, not a vibe):**

| Tier | When | Agents | Searches |
|------|------|--------|----------|
| Simple fact-finding | one factual answer | 0–1 (no decomposition) | ~3–10 |
| Comparison / decision | weigh 2+ options | 2–4 sub-questions, one agent each | ~10–15 each |
| Complex / open-ended | broad or architectural | up to 10 sub-questions | as needed |

**Hard ceiling: at most 10 parallel agents per round.** `@explore` (Step 3), when dispatched, counts as one of the 10. Verifiers (Step 4) and gap-closing rounds (Step 4.5) are excluded from this cap — their own separate budget. **Concurrency reality:** the harness runs ~min(16, cores−2) agents concurrently, so main researchers + verifiers queue rather than all firing at once — 10 is the per-round design ceiling, not a concurrency promise. Scale effort to the question — do not over-dispatch.

## Step 2: Check Existing Knowledge

Before launching new research, search for existing coverage:

Before proposing any design, query the knowledge store: `mex graph scope "<task summary>"` — then **read the routed pages, not just the envelope**: routed hits are pointers, not knowledge. Open every `.mex/` page that plausibly bears on this work in full (pages are distilled by design; reading them whole is sanctioned spend). 0 relevant pages does not mean none exist — re-angle the scope query once (different nouns, the component name instead of the feature name) before concluding none. Emit `mex retrieval: N pages routed, K read` (or `mex retrieval: none`) plus a one-line disposition per read page — folded in (what it changed) or ruled out (why). The check is complete when every plausibly-relevant page is dispositioned. If `.mex/context/decisions.md` or a `docs/decisions/` ADR already covers this, surface it rather than re-litigating. Where the code graph covers the project's language (JS/TS/Python verified; Rust upstream-claimed, unconfirmed), run `mex impact <symbol|file>` before modifying code that a grounded page cites and fold the affected pages into the check; on uncovered languages, pages/router/retrieval remain the working surface.

Same lookup researchers run; see the "Search the knowledge base first" step in `./researcher-prompt.md`.

**If comprehensive coverage already exists:** Reference it, add any new findings as updates, and close the bead. Do not duplicate existing research.

## Step 3: Decompose + Dispatch Parallel Research Agents

**Decompose first** (skip for the Simple tier): break the topic into **3–6 complementary sub-questions** (for opinion/design topics, 2–3 perspectives) that collectively cover it. Assign **one researcher agent per sub-question** — never hand every agent the raw topic. Launch all agents in a **single message with multiple `Agent` tool calls** so they run concurrently. **Cap: 10 parallel agents (Step 1).**

### The delegation contract (every dispatch)

Each agent's brief MUST state all four parts (Anthropic's delegation contract — vague briefs cause duplicated and missed work):

1. **Objective** — the specific sub-question, not the whole topic.
2. **Output format** — structured findings, and a **verbatim supporting quote for every load-bearing claim** (the grounding verifier re-fetches independently; this quote is only the fallback if that re-fetch is inconclusive).
3. **Tools / sources** — which to prefer (official docs over blogs).
4. **Boundaries** — what this agent owns vs. its neighbours, so sub-questions don't overlap.

Add to every brief: **start wide, then narrow** — open with a SHORT broad query, see what's available, then narrow. Never lead with a long, hyper-specific query.

### Agent A: Researchers (web + documentation)

Dispatch via the `Agent` tool:

1. `Read` the prompt template at `./researcher-prompt.md`
2. Use its content as the `prompt` parameter, appending the sub-question + the four contract parts above + bead context (bead ID, what decision this informs, prior knowledge from the `.mex/` pages you read in Step 2)
3. Use `subagent_type: "general-purpose"` (do NOT use `"researcher"` — that built-in agent's system prompt overrides the template)

### Agent B: @explore (codebase) — one agent, conditional

Dispatch **exactly one** `@explore` agent (`subagent_type: "Explore"`) **only when the topic has codebase relevance** ("how does X work *here*", "should we adopt Y"). It counts as one of the 10 and is **not decomposed** (it's already a broad codebase sweep), but gets the same 4-part contract:

> Objective: find existing implementations, patterns, config, tests, and docs related to [topic] in this repo. Output: what exists, where (`file:line`), and how it relates. Boundaries: codebase only — no web. Report concisely.

**Pure codebase question**: dispatch only `@explore`.

## Step 4: Synthesize + Verify Findings

After the agents return, you synthesize.

1. **Merge findings** — combine the sub-question results + codebase findings; merge semantic duplicates.
2. **Verify grounding (dispatch the 3-layer stage below)** — every load-bearing claim must clear layer 1 + layer 2 (escalating to layer 3 on doubt) before being kept. Tag each surviving load-bearing claim inline with its verified source (`[S1]`).
3. **Assign confidence per finding** — **high** (multiple primary sources agree) / **medium** (secondary or split) / **low** (single source / blog / contested), with a one-line rationale.
4. **Resolve contradictions, keep the verdict** — when sources conflict, determine which is authoritative and recommend. When the conflict is load-bearing, also record both positions in an optional **Disagreements** note — but never silently average, and never abdicate the call.
5. **Identify gaps** — list load-bearing claims that rest on a single source or are unresolved (feeds Step 4.5).
6. **Extract actionable items** — note recommended beads.

### Grounding Verify Stage

The verifier's job is narrow — **citation soundness, not truth-judgment**: does the cited source actually contain a span that entails this claim? It never judges whether the claim is true in some absolute sense, only whether the cited source backs it up. This stage is **universal — every tier, including Simple** (one cheap verifier for a single-fact claim closes the grounding gap without a special case).

**Load-bearing heuristic:** a claim is load-bearing if a recommendation, decision, or comparison in the document rests on it. Non-load-bearing color/context claims are not verified.

Dedup semantically-equivalent claims first, then verify the **top-K** load-bearing claims; if more exist, **log which were not independently verified** — a visible note, never a silent truncation.

**Layer 1 — deterministic pre-filter (no LLM, always runs, all tiers):**
- Every load-bearing claim carries a source tag → else flag ungrounded.
- The cited URL resolves (HTTP check, e.g. `WebFetch` or a HEAD request) → else flag as a possibly-fabricated source.

**Layer 2 — blinded verifier (fast/cheap model; entailment only; default 1 verifier per claim):** for each load-bearing claim that passed layer 1, dispatch one fresh-context verifier:
1. `Read` the prompt template at `./verifier-prompt.md`.
2. Fill in only the claim text and the cited URL — no author, no framing that this is "our" research (the blinding kills self-preference bias).
3. Dispatch via the `Agent` tool: `subagent_type: "general-purpose"`, using a fast/cheap model.
4. Collect its three-way verdict: `{ verdict: SUPPORTED | UNSUPPORTED | INCONCLUSIVE, supporting_span, confidence, reason }`.

**Layer 3 — escalate on doubt (not always-on):** a clean SUPPORTED verdict with a verbatim span is accepted immediately — no escalation. **Only** on UNSUPPORTED / INCONCLUSIVE / low-confidence, escalate that single claim: first to a **3-way fast/cheap-model ensemble** (majority verdict, same `./verifier-prompt.md` template); if still split, to **one fresh blinded stronger-model verifier** (same template, same blinding/re-fetch contract) whose verdict is final — keeping the grounding chain independent of the author model end-to-end. Verifiers and escalations are **excluded from the 10-cap** — their own budget, separate from the main research fan-out (~1 verifier per load-bearing claim; 3-way only when contested).

**Verdict handling:**
- **SUPPORTED** → keep the claim, tagged with its verified span/source.
- **UNSUPPORTED** → the source doesn't actually support the claim → feeds Step 4.5.
- **INCONCLUSIVE** → never drop the claim for a fetch failure. Retry once / follow one redirect / fall back to the researcher's original quote; if still unreadable, keep the claim but flag it "source unverifiable" with lowered confidence, and feed it to Step 4.5 for a better source.

## Step 4.5: Gap-Closing Round (if needed)

If Step 4 surfaced load-bearing claims resting on a single source, unresolved, or **UNSUPPORTED / unresolved-INCONCLUSIVE from the grounding verify stage**, **dispatch one narrow follow-up round of 1–2 targeted agents** aimed only at those gaps (not a second full fan-out) to find a legitimate supporting source, then re-synthesize and re-verify. **Cap: 1–2 rounds total.** Record each: `bd note <id> "reflection round N: chasing <gaps>"`. If a claim still can't be grounded after this round, **remove it from the findings and revise any recommendation resting on it** — never leave it dangling; record the drop in the document's Refuted / Discarded Claims section with the reason. If no gaps, skip.

## Step 5: Write the Document

Research documents are written to **`.internal/research/`** — the project-local, gitignored knowledge base. Not configurable.

Filename: `YYYY-MM-DD-<topic-slug>.md`

Write the document using the structure in **`./document-template.md`** (read it now).

### Distill the Document into `.mex/`

Distilling is part of this step, not a separate one — it happens the moment the document is written, never deferred to later. The full document stays in `.internal/research/` (gitignored scratch); only the distillate is durable.

**Write authority is yours alone.** Only the orchestrating agent writes to `.mex/` or runs `mex log`. Researcher subagents return *recommended* page edits and decision lines in their reports — review each one, then apply it yourself.

**Secret/PII scan first:** scan the distillate before writing. A secret, token, key, or credential value, or PII, is never written into ANY store — not a tracked `.mex/` page, not `.mex/private/`, not a `mex log` line, not the research document. `.mex/private/` is gitignored, not a vault: it is NOT where secrets go. If the distillate carries one, flag it for removal and stop that entry — write the surrounding conclusion only after the secret is out, referring to the credential by name and location, never by value. Tracked pages are public in a public repo and ride git history, which outlives a later edit. Separately, and for sensitivity rather than secrets: durables that name an unmitigated risk, security gap, compliance exposure, or unreleased plan go to `.mex/private/` (gitignored), never to a tracked page.

1. **Distill into the matching pages** — requirements the research settled into `.mex/requirements.md`, design rationale and architectural conclusions into `.mex/architecture.md`, repo conventions into `.mex/conventions.md`, reusable patterns into `.mex/patterns/<name>.md`, compliance durables into `.mex/compliance.md`. Update an existing entry in place rather than adding a near-duplicate. Each entry must be actionable on its own — a reader acts on it without opening the document. **Never cite an `.internal/` path from a `.mex/` page:** `.mex/` is tracked and shared, `.internal/research/` is gitignored scratch that no other clone has, so such a pointer is dead on arrival for every other reader. State the conclusion in full instead.
2. **Log every load-bearing conclusion** — `mex log --type decision "<one-line conclusion>"`. The line must stand alone: no `.internal/` path in it either, for the same reason. Bare `mex log` records kind `note`, not a decision; the decision prose page is `.mex/context/decisions.md`.

### Quality Checklist

Before writing — and again as a self-grade before closing, running one Step-4.5 round if any axis fails — verify your document passes these checks:

- [ ] **Summary exists** and is 2-3 sentences (not a paragraph)
- [ ] **Every finding has evidence and citation soundness** — no unsourced claims, and each load-bearing claim's source actually supports it, confirmed by the grounding verify stage's independent re-fetch (Step 4) — the Step 3 quote is only the fallback
- [ ] **Factual accuracy** — claims match their sources
- [ ] **Sources section has 3+ entries** with URLs (not "various sources"), including ≥1 primary/official source for each load-bearing claim
- [ ] **Dates and versions noted** for time-sensitive information
- [ ] **Contradictions resolved** — if sources disagreed, which is right and why
- [ ] **Codebase context included** — what exists now, not just what the web says
- [ ] **Completeness** — every sub-question answered
- [ ] **Recommendations are actionable** — "do X" not "consider doing X"
- [ ] **Effort efficiency** — agent count matched the query tier (no over-dispatch)

## Step 6: End-Gate + Close the Bead

You are **top-level** unless the caller passed a `nested` marker — that's caller-declared, and the default is top-level (the no-signal case is a direct user research request).

**Nested mode:** skip the end-gate — return your findings to the caller.

**Top-level mode:** present the end-gate using your structured question tool. Three options:

1. **Start brainstorming** — invoke `Skill(beads-superpowers:brainstorming)`, passing the research document path as design input.
2. **Do further research** — run another round (Step 3 fan-out or a Step 4.5 gap-closing round).
3. **Accept & close the bead** — continue below.

**Capture what you learned.** At close, record durable, evidence-backed insights (still true next month, tied to a file, test, or command) in `.mex/lessons.md`: one bullet per lesson, prefixed by kind (`lesson:` / `pattern:` / `root-cause:` / `correction:`), with the evidence named. Update an existing entry in place rather than adding a near-duplicate. The hot page is hard-capped at 2048 bytes — if an append would exceed it, demote the coldest entries to `.mex/lessons-archive.md` (retrievable via the router, not injected) until it fits. Decisions: `mex log --type decision "<one-line decision>"` always (bare `mex log` records kind "note", not a decision); add a full `docs/decisions/ADR-NNNN-<kebab>.md` (+ `INDEX.md`) only when the ADR bar is met (hard-to-reverse AND surprising-without-context AND genuine trade-off). Requirements, design rationale, and compliance durables: distill into the matching `.mex/` page. Durables that name an unmitigated risk, security gap, compliance exposure, or unreleased plan go to `.mex/private/` (gitignored), never to tracked pages. Never record guesses, one-offs, or secrets (tokens, keys, PII — the hot page is injected into all future sessions, and tracked `.mex/` pages are public in public repos); scan before writing.

```bash
bd close <id> --reason "Research complete: <1-line summary of finding>"
```

If research revealed follow-up work, create the recommended beads — stamp each per **Agent-Filed Bead Discipline** (`beads-superpowers:verification-before-completion`):

```bash
bd create "Follow-up: <title>" -t task -p <priority> --notes "Severity: <Critical|Important|Minor>
Confidence: <Confirmed|Speculative>
Evidence: <file:line / source / repro | none>"
```

## Red Flags / Anti-Rationalization

| Thought | Reality |
|---------|---------|
| "I already know the answer" | You might be wrong. Check sources. The document is for future sessions too. |
| "This is a simple question, I'll just answer verbally" | Iron Law: NO RESEARCH WITHOUT A DOCUMENT. Write it down. |
| "I'll skip the codebase search — this is a general topic" | The codebase might already have an implementation. Always check. |
| "I'll write the document later" | You won't. Write it now while the research is fresh. |
| "One source is enough" | Cross-reference across 3+ independent sources. Single-source findings get flagged. |
| "I'll skip the knowledge base check" | You might duplicate existing research. Always search first. |
| "The first pass answered it" | First passes miss the non-obvious. Run the Step-4 gap check. |
| "The source is about the right topic" | Topical ≠ supporting. The verify stage re-fetches the source independently and checks for a verbatim entailing span — don't rely on topical similarity. |
| "I'll hand the agents the whole topic" | Decompose. Give each agent one bounded sub-question + the 4-part contract. |
| "This needs 20 agents" | Cap at 10. Scale effort to the query tier. |
| "The cheaper recommendation is fine to default to" | Any recommendation that advises a shortcut, descope, material-risk trade-off, or security regression must be flagged as such — never the default path (Production-Grade Doctrine). |

## Example

User asks: "How does Dolt handle merge conflicts?"

```
1. bd create "Research: Dolt merge conflict handling" -t task -p 2
2. mex graph scope "dolt merge conflict handling" → read the routed .mex/ pages in full
3. Dispatch researcher (via ./researcher-prompt.md): "Research Dolt merge conflict resolution..."
   Dispatch @explore: "Search codebase for Dolt merge, conflict..."
4. Synthesize: researcher found cell-level merge docs, explore found bd dolt pull usage
5. Write to .internal/research/2026-05-01-dolt-merge-conflict-handling.md
5a. Secret/PII scan the distillate, then distill into .mex/ and log the conclusion:
    → append to .mex/architecture.md: "Dolt merges SQL tables cell-level (3-way), so conflicts are
      detected per cell and there are no textual conflict markers; this repo exercises the merge path
      via bd dolt pull/push."          # no .internal/ pointer — the full write-up is local-only
    mex log --type decision "Dolt uses cell-level 3-way merge on SQL tables (no textual conflict markers)"
6. bd close <id> --reason "Research complete: Dolt uses cell-level merge on SQL tables"
```

## Integration

**Invoked by:** User on-demand, or during the research phase before planning. No other skill invokes this directly.

**Invokes:** `brainstorming` (via the top-level end-gate). Also dispatches @researcher and @explore agents in parallel internally.
