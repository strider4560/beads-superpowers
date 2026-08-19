---
name: brainstorming
description: "You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior. Explores user intent, requirements and design before implementation."
---

# Brainstorming Ideas Into Designs

Help turn ideas into fully formed designs and specs through natural collaborative dialogue.

Start by understanding the current project context, then ask questions one at a time to refine the idea. Once you understand what you're building, present the design and get user approval.

The `stress-test` skill is no longer part of this path — the review deliberation stage that follows the spec gate covers adversarial scrutiny. It stays available standalone, on demand, whenever a design or decision needs grilling outside the pipeline.

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, or take any implementation action until you have presented a design and the user has approved it. This applies to EVERY project regardless of perceived simplicity.
</HARD-GATE>

**Production-Grade Doctrine** applies with full force here — trade-offs are *first chosen* in brainstorming: you MUST NOT simplify a design by quietly cutting a required behavior; surface every material trade-off and let the user decide. Never weaken, bypass, or remove a security control — a security regression is never acceptable.

## Stage Entry

Brainstorming runs on the planning tier. Confirm that before exploring the idea:

```bash
bash scripts/pipeline/tier-gate.sh --stage planning
```

Run it from the repo root — the gate reads session state from `./.internal/pipeline/`. Route on the exit code. "Stop on any nonzero" is wrong here:

| Exit | Meaning | What this skill does |
| --- | --- | --- |
| 0 | The tier is verified. | Proceed. |
| 1 | Fail-closed: wrong tier, missing bundle root, missing tier-map, unknown model, or no session data. | Stop and report the gate's message. There is no override. |
| 2 | Usage error — the command above is malformed. | Stop and report. The bug is in the command, not in the session. |
| 4 | Visible SKIP: this harness cannot expose the session model. | Report it, then ask the user. See below. |

Exit 4 leaves the tier unverified, and a SKIP is **NEVER** a pass, so never continue on it silently. Ask the user with your structured question tool (shape varies by harness — adapt to yours): tell them the tier could not be verified on this harness, then ask them to confirm this is a planning-tier session or to run `tier-gate.sh --assert <tier>` themselves. Continue only on an explicit confirmation. A denial is not consent, and neither is an answer that arrives skipped, dismissed, or auto-resolved — treat any of them as no answer and stop, per the **Asking the User** convention in `using-superpowers`.

When the gate reports that the session tier is unknown, it names the remedy: `tier-gate.sh --assert <tier>`. **Never** run `--assert` yourself. Ask the user to run it — anything that can write the tier assert file can grant itself any tier, so that command is the user's alone.

## Anti-Pattern: "This Is Too Simple To Need A Design"

Every project goes through this process. A todo list, a single-function utility, a config change — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but you MUST present it and get approval.

## Checklist

You MUST create the session bead + step children up front via `bd import`: first `bd create "Brainstorming: <topic>" -t task` (the permanent session bead — the audit trail; note its id), then author each checklist step as JSONL (one issue per line, `"issue_type":"chore"`, an explicit `"priority"`, `id` omitted, and a `parent-child` dep to the session id) and pipe to `bd import -`. Read `bd import --help` on first use; confirm the output shows no `Skipped dependency`. **Cleanup:** close each step bead as you complete it; if you abandon the brainstorm, close or `bd purge` the open steps (import children are permanent, not self-cleaning). Then complete the steps in order:

1. **Explore project context** — check files, docs, recent commits, and query the KB for prior decisions/research on the topic
2. **Offer the visual companion just-in-time** — NOT upfront. The first time a question would genuinely be clearer shown than described, offer it then (its own message); on approval its browser tab opens for you. If no visual question ever arises, never offer it. See the Visual Companion section below.
3. **Ask clarifying questions** — one at a time, understand purpose/constraints/success criteria
4. **Propose 2-3 approaches** — with trade-offs and your recommendation
5. **Present design** — in sections scaled to their complexity, get user approval after each section
6. **Write design doc** — save to `.internal/specs/YYYY-MM-DD-<topic>-design.md` and commit
7. **Spec self-review** — quick inline check for placeholders, contradictions, ambiguity, scope (see below)
8. **User reviews written spec** — ask user to review the spec file before proceeding
9. **Spec-review gate** — two options: Approved, or Needs changes (revise, then re-review)
10. **Hand off to review deliberation** — invoke `planning-with-reviews` with the approved spec

## Process Flow

```dot
digraph brainstorming {
    "Explore project context" [shape=box];
    "Ask clarifying questions" [shape=box];
    "Propose 2-3 approaches" [shape=box];
    "Present design sections" [shape=box];
    "User approves design?" [shape=diamond];
    "Write design doc" [shape=box];
    "Spec self-review\n(fix inline)" [shape=box];
    "User reviews spec?" [shape=diamond];
    "Invoke planning-with-reviews" [shape=doublecircle];

    "Explore project context" -> "Ask clarifying questions";
    "Ask clarifying questions" -> "Propose 2-3 approaches";
    "Propose 2-3 approaches" -> "Present design sections";
    "Present design sections" -> "User approves design?";
    "User approves design?" -> "Present design sections" [label="no, revise"];
    "User approves design?" -> "Write design doc" [label="yes"];
    "Write design doc" -> "Spec self-review\n(fix inline)";
    "Spec self-review\n(fix inline)" -> "User reviews spec?";
    "User reviews spec?" -> "Write design doc" [label="changes requested"];
    "User reviews spec?" -> "Invoke planning-with-reviews" [label="approved"];
}
```

**The terminal state is planning-with-reviews.** Do NOT invoke frontend-design, mcp-builder, or any other implementation skill.

## The Process

**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits)
- Before proposing any design, query the knowledge store: `mex graph scope "<task summary>"` — then **read the routed pages, not just the envelope**: routed hits are pointers, not knowledge. Open every `.mex/` page that plausibly bears on this work in full (pages are distilled by design; reading them whole is sanctioned spend). 0 relevant pages does not mean none exist — re-angle the scope query once (different nouns, the component name instead of the feature name) before concluding none. Emit `mex retrieval: N pages routed, K read` (or `mex retrieval: none`) plus a one-line disposition per read page — folded in (what it changed) or ruled out (why). The check is complete when every plausibly-relevant page is dispositioned. If `.mex/context/decisions.md` or a `docs/decisions/` ADR already covers this, surface it rather than re-litigating. Where the code graph covers the project's language (JS/TS/Python verified; Rust upstream-claimed, unconfirmed), run `mex impact <symbol|file>` before modifying code that a grounded page cites and fold the affected pages into the check; on uncovered languages, pages/router/retrieval remain the working surface.
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
- If the project is too large for a single spec, help the user decompose into sub-projects: what are the independent pieces, how do they relate, what order should they be built? Then brainstorm the first sub-project through the normal design flow. Each sub-project gets its own spec → plan → implementation cycle.
- For appropriately-scoped projects, ask questions one at a time to refine the idea
- Prefer multiple choice questions when possible — **use your structured question tool** for these (structured options are faster to answer than reading text and typing a response). Open-ended questions that don't have clear discrete options can remain as text.
- Only one question per message - if a topic needs more exploration, break it into multiple questions
- Focus on understanding: purpose, constraints, success criteria

**Exploring approaches:**

- Propose 2-3 different approaches with trade-offs
- **Use your structured question tool** to present the approaches as structured options. Put your recommended option first with "(Recommended)" in the label. Use the `description` field for trade-offs and reasoning. This is more efficient than text blocks that require the user to read and type a response.
- If approaches need detailed explanation beyond what fits in option descriptions, present the analysis as text first, THEN follow up with a structured question for the actual selection
- **YAGNI ruthlessly** - Remove unnecessary *speculative* features from all designs (never drop a required behavior, edge case, or security control — that is descoping, not YAGNI)

**Presenting the design:**

- Once you believe you understand what you're building, present the design
- Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced
- After presenting each section, **use your structured question tool** to check approval (content below; shape shown in Claude Code schema — adapt to your tool):
  ```json
  {
    "questions": [{
      "question": "Does the <section-name> section look right?",
      "header": "Design",
      "options": [
        {"label": "Looks good", "description": "Approve this section and move to the next one"},
        {"label": "Needs changes", "description": "I have feedback or revisions for this section"}
      ],
      "multiSelect": false
    }]
  }
  ```
- Cover: architecture, components, data flow, error handling, security, testing
- Be ready to go back and clarify if something doesn't make sense

**Design for isolation and clarity:**

- Break the system into smaller units that each have one clear purpose, communicate through well-defined interfaces, and can be understood and tested independently
- For each unit, you should be able to answer: what does it do, how do you use it, and what does it depend on?
- Can someone understand what a unit does without reading its internals? Can you change the internals without breaking consumers? If not, the boundaries need work.
- Smaller, well-bounded units are also easier for you to work with - you reason better about code you can hold in context at once, and your edits are more reliable when files are focused. When a file grows large, that's often a signal that it's doing too much.

**Working in existing codebases:**

- Explore the current structure before proposing changes. Follow existing patterns.
- Where existing code has problems that affect the work (e.g., a file that's grown too large, unclear boundaries, tangled responsibilities), include targeted improvements as part of the design - the way a good developer improves code they're working in.
- Don't propose unrelated refactoring. Stay focused on what serves the current goal.

## After the Design

**Documentation:**

- Write the validated design (spec) to `.internal/specs/YYYY-MM-DD-<topic>-design.md`
  - (User preferences for spec location override this default)
- Commit the design document to git

> When filing a bead for discovered/follow-up work, stamp it per **Agent-Filed Bead Discipline** (`verification-before-completion`).

After the work is settled, present the Capture gate — mandatory every time; Skip is the default (most work leaves nothing worth keeping):

```json
{
  "questions": [{
    "question": "Worth keeping anything from this?",
    "header": "Capture",
    "options": [
      {"label": "Skip", "description": "Nothing here outlasts the work itself (usually the case)"},
      {"label": "Record the decision", "description": "Pick this if the choice is hard to undo, non-obvious in hindsight, and had real trade-offs — so future-you knows why"},
      {"label": "Remember the lesson", "description": "A specific, evidence-backed lesson worth reusing in later sessions"},
      {"label": "Both", "description": "A lasting decision and a lesson worth reusing"}
    ],
    "multiSelect": false
  }]
}
```

Route on the answer. **Record the decision / Both** → this writes an ADR, so first confirm it clears the bar (hard-to-reverse AND surprising-without-context AND genuine trade-off); if it doesn't, say so and capture it via `mex log --type decision` alone (the lighter record) — unless the user confirms they want the full ADR. Write the ADR (`docs/decisions/ADR-NNNN-<kebab>.md`, sections Context/Decision/Rationale/Consequences, update `docs/decisions/INDEX.md`), then run `mex log --type decision "<one-line summary> — see docs/decisions/ADR-NNNN-<kebab>.md"` (run the secret/PII scan on the summary first). A superseding ADR's log line must read `supersedes ADR-NNNN`, and `mex-curator` updates `.mex/context/decisions.md` so the stale entry points forward. **Remember the lesson / Both** → append to `.mex/lessons.md` per the capture contract. **Skip** → nothing.

**Spec Self-Review:**
After writing the spec document, look at it with fresh eyes:

1. **Placeholder scan:** Any "TBD", "TODO", incomplete sections, or vague requirements? Fix them.
2. **Internal consistency:** Do any sections contradict each other? Does the architecture match the feature descriptions?
3. **Scope check:** Is this focused enough for a single implementation plan, or does it need decomposition?
4. **Ambiguity check:** Could any requirement be interpreted two different ways? If so, pick one and make it explicit. The spec's next readers are writing-plans and, transitively, subagents who cannot ask you what you meant — so also scan requirements (not rationale prose) for machine-reader hazards: synonym rotation (one name per entity, used every time), vague quality words ("robust", "properly" — name the observable behavior instead), and multi-clause requirement sentences (split them; one requirement per sentence). Full rules: `../subagent-driven-development/references/ste-authoring.md`.

Fix any issues inline. No need to re-review — just fix and move on.

**User Review Gate:**
After the spec review loop passes, **open the spec file in the user's editor** so they can review it, then gate progression with your structured question tool (content below; shape shown in Claude Code schema — adapt to your tool):

**User's preferred editor:** !`echo ${VISUAL:-${EDITOR:-not-configured}}`

**⚠️ Run the open command as a standalone Bash call** — never chain it after `bd` commands in the same invocation (e.g., `bd close <id> && open file.md`). The combination hangs.

```bash
# Open in user's preferred editor, with platform fallbacks
if [ -n "$VISUAL" ]; then
  "$VISUAL" "<spec-file-path>"
elif [ -n "$EDITOR" ]; then
  "$EDITOR" "<spec-file-path>"
elif command -v open >/dev/null 2>&1; then
  open "<spec-file-path>"
else
  xdg-open "<spec-file-path>" 2>/dev/null
fi
# If none available: just report the path
```

Then immediately ask via your structured question tool (content below; shape shown in Claude Code schema — adapt to your tool):

<!-- Canonical 2-option review gate — keep identical to writing-plans/SKILL.md -->

```json
{
  "questions": [{
    "question": "Spec opened in your editor at `<path>`. Review it and let me know how to proceed.",
    "header": "Spec review",
    "options": [
      {"label": "Approved", "description": "Spec looks good — hand it to planning-with-reviews for review deliberation"},
      {"label": "Needs changes", "description": "I want to revise the spec before proceeding"}
    ],
    "multiSelect": false
  }]
}
```

Route on the answer:
- **Approved** → invoke great_cto's `planning-with-reviews` with the spec path (`.internal/specs/YYYY-MM-DD-<topic>-design.md`). That stage settles the spec against its reviewers and hands to `writing-plans`.
- **Needs changes** → make the requested changes and re-run the spec review loop. Only proceed once approved.

**Handoff:**

- Invoke `planning-with-reviews` with the approved spec. It runs the reviewer fan-out, settles the spec, and hands to writing-plans for plan and bead-graph capture.
- Do NOT invoke any other skill from here, and do not write the plan yourself.
- Pass the brainstorming bead context forward: the epic bead created during plan execution should reference the brainstorming session bead via `bd dep add <epic-id> <brainstorming-bead-id> --type discovered-from`

## Visual Companion

A browser-based companion for showing mockups, diagrams, and visual options during brainstorming. Available as a tool — not a mode. Accepting the companion means it's available for questions that benefit from visual treatment; it does NOT mean every question goes through the browser.

**Offering the companion (just-in-time):** Do NOT offer it upfront. Wait until a question would genuinely be clearer shown than told — a real mockup / layout / diagram question, not merely a UI *topic*. The first time that happens, offer it then for consent using your structured question tool. **This offer MUST be its own message.** Do not combine it with clarifying questions, context summaries, or any other content. If they decline, continue text-only and don't offer again unless they raise it.

```json
{
  "questions": [{
    "question": "This next part might be easier to show than describe. I can put together mockups, diagrams, and comparisons in a web browser as we go. This feature is still new and can be token-intensive. Want me to? (Requires opening a local URL)",
    "header": "Visual",
    "options": [
      {"label": "Yes, use visuals", "description": "Open a browser companion for mockups and diagrams during brainstorming"},
      {"label": "No, text only", "description": "Continue with text-based brainstorming in the terminal"}
    ],
    "multiSelect": false
  }]
}
```

Wait for the user's response before continuing. If they decline, proceed with text-only brainstorming.

**Per-question decision:** Even after the user accepts, decide FOR EACH QUESTION whether to use the browser or the terminal. The test: **would the user understand this better by seeing it than reading it?**

- **Use the browser** for content that IS visual — mockups, wireframes, layout comparisons, architecture diagrams, side-by-side visual designs
- **Use the terminal** for content that is text — requirements questions, conceptual choices, tradeoff lists, A/B/C/D text options, scope decisions

A question about a UI topic is not automatically a visual question. "What does personality mean in this context?" is a conceptual question — use the terminal. "Which wizard layout works better?" is a visual question — use the browser.

If they agree to the companion, read the detailed guide before proceeding:
`skills/brainstorming/visual-companion.md`

## Integration

**Invokes:**
- **planning-with-reviews** — terminal state (great_cto). It settles the spec and hands to writing-plans; brainstorming invokes nothing else.
