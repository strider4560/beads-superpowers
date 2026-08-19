---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Production-Grade Doctrine:** every spec requirement MUST map to a task — a deliberate cut is surfaced as a tracked decision, never a silent omission. Never weaken, bypass, or remove a security control — a security regression is never acceptable.

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).

**Save plans to:** `.internal/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Stage Entry

Planning runs on the planning tier. Confirm that before reading the spec:

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

## Knowledge Check

Before proposing any design, query the knowledge store: `mex graph scope "<task summary>"` — then **read the routed pages, not just the envelope**: routed hits are pointers, not knowledge. Open every `.mex/` page that plausibly bears on this work in full (pages are distilled by design; reading them whole is sanctioned spend). 0 relevant pages does not mean none exist — re-angle the scope query once (different nouns, the component name instead of the feature name) before concluding none. Emit `mex retrieval: N pages routed, K read` (or `mex retrieval: none`) plus a one-line disposition per read page — folded in (what it changed) or ruled out (why). The check is complete when every plausibly-relevant page is dispositioned. If `.mex/context/decisions.md` or a `docs/decisions/` ADR already covers this, surface it rather than re-litigating. Where the code graph covers the project's language (JS/TS/Python verified; Rust upstream-claimed, unconfirmed), run `mex impact <symbol|file>` before modifying code that a grounded page cites and fold the affected pages into the check; on uncovered languages, pages/router/retrieval remain the working surface.

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Task Right-Sizing

A task is the smallest unit that carries its own test cycle and is worth a
fresh reviewer's gate. When drawing task boundaries: fold setup,
configuration, scaffolding, and documentation steps into the task whose
deliverable needs them; split only where a reviewer could meaningfully
reject one task while approving its neighbor. Each task ends with an
independently testable deliverable.

In beads terms, a right-sized task is one bead (`bd create -t task --parent <epic-id>`): claimable, verifiable, and closeable on its own.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Write for a Machine Reader (STE Rules)

Your plan's reader is a fresh subagent with no way to ask what you meant. Task text is
extracted verbatim into a brief (`scripts/task-brief`) and read cold; acceptance
criteria are copied verbatim into beads and re-read by reviewers and post-compaction
controllers. Every ambiguous sentence you write becomes some implementer's coin flip —
and a wrong flip costs a full fix round.

Apply these Simplified Technical English rules (adapted from ASD-STE100, the
controlled language aerospace uses to stop technicians misreading manuals) to all task
text, steps, Interfaces blocks, and acceptance criteria:

- **One name per concept, plan-wide.** The most important rule. If Task 2's "Produces"
  says `parse_config()`, Task 4's "Consumes" says `parse_config()` — never "the config
  loader". Parallel implementers see only their own task; consistent names are the only
  thing keeping their outputs compatible.
- **One instruction per sentence, ≤20 words, imperative, active voice.** "Run the test.
  Record the output." — not "The test should be run and its output recorded."
- **Acceptance criteria name observable outcomes.** "The command prints one progress
  line per 100 items" — not "progress reporting works correctly". A reviewer cannot
  verify "correctly", "properly", "robust", or "clean".
- **No phrasal verbs, no semicolons, no 4+-word noun stacks, no ellipsis.** "Start the
  server", not "spin up the server". Keep the subject and article even when it reads
  longer: "the files that are not committed", not "files not committed".
- **Keep hedges and exact values.** "May", "at most", version floors, and counts are
  content — copy them verbatim from the spec, never round or promote them.

Before saving the plan, scan every task for: synonym rotation, vague quality words,
run-on sentences, and criteria a reviewer could not test. The full rule set with a
per-surface checklist lives in
`../subagent-driven-development/references/ste-authoring.md`. Do not flatten
rationale prose ("Architecture", why-notes) into this style — strict rules apply to
text an agent must act on.

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** The bead graph for this plan already exists — an initiative epic, its child epics, and one task bead per Task below. **Do not** create task beads for these tasks: a second set forks the plan of record, and the reviewers and tier assignments live on the beads that are already there. Find the initiative id in `.mex/context/initiatives.md`, then claim a bead that exists (`bd ready --parent <initiative-id>`, then `bd update <id> --claim`). Implementation runs in a separate session through great_cto's `implementing-epics`. Steps within tasks use checkbox (`- [ ]`) syntax for human readability.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

## Global Constraints

[The spec's project-wide requirements — version floors, dependency limits,
naming and copy rules, platform requirements — one line each, with exact
values copied verbatim from the spec. Every task's requirements implicitly
include this section.]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Interfaces:**
- Consumes: [what this task uses from earlier tasks — exact signatures]
- Produces: [what later tasks rely on — exact function names, parameter
  and return types. A task's implementer sees only their own task; this
  block is how they learn the names and types neighboring tasks use.]

**Acceptance Criteria:**
- [Observable, testable outcomes — copied verbatim into the task bead's
  `## Acceptance Criteria` section at creation]

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

**Beads integration:** This skill creates the bead graph — an epic bead for the plan and a child task bead for each Task N — and executing skills consume it. **Capture to Beads** below holds the commands. The `- [ ]` checkboxes remain in the markdown for human readability, but task-level tracking uses beads (`bd update --claim`, `bd close --reason`), and dependencies between tasks are wired at capture time.

**Required bead-body sections:** `bd lint` (Self-Review step 0) requires `## Success Criteria` in the epic bead's description and `## Acceptance Criteria` in each task bead's description. Include them at creation time — embed them in each bead's `description` in the import JSONL (or use the `acceptance_criteria` field). The epic's Success Criteria derive from the plan's **Goal**; each task's copy from its **Acceptance Criteria** block.

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**0. Deterministic checks — run these after Capture to Beads has created the graph, not now.** No bead exists at this point in the flow. **Capture to Beads** creates the graph once the user approves the plan, and it sends you back to these three commands at that point. Run them there and fix anything they flag before the Capture Complete Gate. The judgment checks below run now:

```bash
bd lint <epic-id>                                                    # required-section check on the epic
bd list --parent <epic-id> --json | jq -r '.[].id' | xargs -n1 bd lint   # same check on each child task
bd ready --parent <epic-id> --explain                                # confirm dependency ordering
```

**1. Spec coverage:** Skim each requirement in the spec. Every one MUST map to a task — point to it. A requirement with no task is either added as a task or surfaced to the user as an explicit, acknowledged cut. Silent omission is a plan failure.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## User Review Gate

After self-review passes, **open the plan file in the user's editor** so they can review it, then gate progression with your structured question tool (content below; shape shown in Claude Code schema — adapt to your tool):

**User's preferred editor:** !`echo ${VISUAL:-${EDITOR:-not-configured}}`

**⚠️ Run the open command as a standalone Bash call** — never chain it after `bd` commands in the same invocation (e.g., `bd close <id> && open file.md`). The combination hangs.

```bash
# Open in user's preferred editor, with platform fallbacks
if [ -n "$VISUAL" ]; then
  "$VISUAL" "<plan-file-path>"
elif [ -n "$EDITOR" ]; then
  "$EDITOR" "<plan-file-path>"
elif command -v open >/dev/null 2>&1; then
  open "<plan-file-path>"
else
  xdg-open "<plan-file-path>" 2>/dev/null
fi
# If none available: just report the path
```

Then immediately ask via your structured question tool (content below; shape shown in Claude Code schema — adapt to your tool):

<!-- Canonical 3-option stress-test gate — keep identical to brainstorming/SKILL.md -->

```json
{
  "questions": [{
    "question": "Plan opened in your editor at `<path>`. Review it and let me know how to proceed.",
    "header": "Plan review",
    "options": [
      {"label": "Approved + stress-test (Recommended)", "description": "Plan looks good — run an adversarial stress-test before execution"},
      {"label": "Approved", "description": "Plan looks good — skip stress-test and proceed to choose execution method"},
      {"label": "Needs changes", "description": "I want to revise the plan before proceeding"}
    ],
    "multiSelect": false
  }]
}
```

Route on the answer:
- **Approved + stress-test** → invoke the `stress-test` skill with the plan path (`.internal/plans/YYYY-MM-DD-<feature-name>.md`) as the Mode-A artifact; when it completes, proceed to **Capture to Beads**.
- **Approved** → proceed to **Capture to Beads** directly.
- **Needs changes** → make the requested changes and re-run the self-review. Only proceed once approved.

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

## Capture to Beads

The bead graph is the plan of record. This skill creates it; executing skills consume it. Create it once, after the user approves the plan — beads are durable and synced, so a graph built from a plan the user then rejects has to be purged.

Read `bd create --help`, `bd import --help`, and `bd batch --help` on first use this session, and round-trip one existing bead with `bd export <id>` to confirm the import field names. **Never** guess bd syntax here: a misspelled field imports quietly, and the failure surfaces later as a lint violation with no trace back to the typo.

**1. The initiative epic.** One epic bead, labeled `initiative`, whose body carries the plan's Goal as `## Success Criteria` plus pointers to the settled spec and to the mex declarations:

```bash
bd create "Initiative: <plan name>" -t epic -p 1 -l initiative -d "<the plan's Goal>

Spec: .internal/specs/YYYY-MM-DD-<topic>-design.md
Declarations: .mex/context/initiatives.md

## Success Criteria
- <measurable outcome from the Goal>"
```

Note the initiative id — every later step needs it. The graph lint checks the `initiative` label on this bead alone, so whether the label reaches any other bead does not matter.

**2. The epics, then the tasks.** Two import streams, in that order. A task's `parent-child` dependency names its epic's id, and the epic ids are assigned by the import that creates the epics.

```bash
# Epics — parent-child to the initiative; metadata.reviewers holds roster names.
cat <<'EOF' | bd import -
{"title":"Epic 1: <name>","issue_type":"epic","priority":2,"description":"<objective>\n\n## Success Criteria\n- <outcome>","metadata":{"reviewers":["architect","security-officer"]},"dependencies":[{"depends_on_id":"<initiative-id>","type":"parent-child"}]}
EOF

bd list --parent <initiative-id> --json | jq -r '.[].id'   # → the epic ids

# Tasks — parent-child to their epic, acceptance criteria copied verbatim.
cat <<'EOF' | bd import -
{"title":"Task 1: <name>","issue_type":"task","priority":2,"description":"<summary>\n\n## Acceptance Criteria\n- <observable outcome>","metadata":{"implementation_agent":"senior-dev","required_skills":["test-driven-development"],"tier":"implementation"},"dependencies":[{"depends_on_id":"<epic-id>","type":"parent-child"}]}
EOF
```

Omit `id` on every line — it is auto-assigned, and a supplied colliding id overwrites that bead. Confirm each import prints no `Skipped dependency`: a dependency to a missing target is skipped, not rolled back.

Three metadata values come from great_cto, and the graph lint rejects anything else:

| Field | Source of the value |
| --- | --- |
| `reviewers` (epics) | `REVIEW_AGENTS` in `$HOME/.agents/great_cto/scripts/agent-roster.mjs` |
| `implementation_agent` (tasks) | `IMPLEMENTATION_AGENTS` in the same file |
| `tier` (tasks) | a tier name from `$HOME/.agents/great_cto/shared/tier-map.json` |

`required_skills` (tasks) lists the skills the implementer loads before touching code — `test-driven-development` at minimum. Read the two great_cto files and copy the names out of them. **Never** invent an agent name or a tier name.

**3. Task ordering.** `parent-child` rides the import; `blocks` does not, because sibling ids do not exist while their own file is being read. Collect the ids per epic, then wire the ordering in one batch:

```bash
bd list --parent <epic-id> --json | jq -r '.[].id'
printf 'dep add <task-2-id> <task-1-id> blocks\n' | bd batch
```

Then run the Self-Review step 0 commands against the graph you just created — `bd lint` is the per-bead check. Go to **Capture to mex** next, then **Capture Complete Gate**, which is the whole-graph check.

## Capture to mex

The beads say what to build. `.mex/` says why, and both exist before this skill finishes.

This section is not the Capture gate. That gate asks whether the session left behind an ad-hoc durable, and **Skip** is its usual answer. The three decision lines and the distilled block below are mandatory on every plan, whatever was answered there.

**Scan first.** `.mex/` is committed and travels with the repo, so in a public repo these declarations are public. Scan every line before writing it and drop credentials, tokens, keys, PII, client names, and verbatim sensitive requirements. A durable that names an unmitigated risk, a security gap, or an unreleased plan belongs in `.mex/private/` (gitignored), **never** on a tracked page.

**Three decisions.** One line each for the finalized requirements, the design, and the plan rationale. Every line ends with the spec path and the initiative bead id:

```bash
mex log --type decision "requirements: <one line> — .internal/specs/YYYY-MM-DD-<topic>-design.md, initiative <initiative-id>"
mex log --type decision "design: <one line> — .internal/specs/YYYY-MM-DD-<topic>-design.md, initiative <initiative-id>"
mex log --type decision "plan rationale: <one line> — .internal/specs/YYYY-MM-DD-<topic>-design.md, initiative <initiative-id>"
```

`--type decision` is required: a bare `mex log` records kind `note`, and a note is not a decision. If a `mex` call fails, surface the exact command and its output and stop. **Never** hand-write the entry into a page instead — that leaves a store that looks current and is not.

**One distilled block.** Append this initiative's section to `.mex/context/initiatives.md`, creating the file if it is absent: a heading naming the initiative id and the plan, then the requirements summary, the design summary, and the rationale, two or three sentences each. Pointers and rationale only — the prose spec and the review artifacts stay in `.internal/`.

The appended block is capped at 2.5 KB (2560 bytes). Write it to a file, measure it, and append only once it fits:

```bash
block="$(mktemp)"                       # write the distilled block here
wc -c "$block"                          # must be <= 2560
cat "$block" >> .mex/context/initiatives.md
```

If it does not fit, cut summary prose. **Never** cut the spec path or the bead ids — they are what a later session follows back.

## Capture Complete Gate

The plan is not captured until the graph lint passes:

```bash
state="$(mktemp)"
bd list --all -n 0 --json > "$state" && node scripts/pipeline/graph-lint.mjs --initiative <initiative-id> --state "$state"
```

Exit 0 is the only pass. On exit 1 the lint prints one line per violation, each naming the bead id and the field, so fix those beads and run it again.

Read the success line as well: `graph-lint OK: <id> (N epics, M tasks)`. N and M MUST match the counts you just captured. Every lint check is quantified over the initiative's children, so an initiative with none passes them all — an import that silently landed nothing reads as a clean graph, and the counts are what catch it.

## Execution Handoff

**Initiative work hands off through the graph, not through this session.** The plan is captured and the lint is green, so execution belongs to a separate implementation session running great_cto's `implementing-epics` against the initiative. Report the initiative id, the epic and task counts, and the spec path, then ask the user to start that session. **Never** decide on your own to carry on into implementation here — a planning-tier session that implements is the tier wall failing open.

**Every plan this skill produces is initiative work.** Capture to Beads is mandatory and has already run, so an initiative epic exists and you hold its id. Hand off, then stop.

**The one exception, and the test for it.** Once you have presented the plan and the handoff, the user may direct you to execute it here instead. Only a direction given then, against the handoff, opens the in-session path; a standing instruction from the top of the session, such as "plan this and then build it", was given before the plan existed and is not one. The test is a single question: after seeing the handoff, did the user tell you, in words, to execute now? Plan size, task count, an absent great_cto install, and a Stage Entry SKIP are **NEVER** substitutes for it. If the answer is no, hand off and stop. If it is yes, ask which in-session method they want:

```json
{
  "questions": [{
    "question": "Plan complete and saved. How would you like to execute it?",
    "header": "Execution",
    "options": [
      {
        "label": "Subagent-Driven (Recommended)",
        "description": "Fresh subagent per task with a single task review between tasks — fast iteration, high quality"
      },
      {
        "label": "Inline Execution",
        "description": "Execute tasks in this session using executing-plans — batch execution with checkpoints"
      }
    ],
    "multiSelect": false
  }]
}
```

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use beads-superpowers:subagent-driven-development
- Fresh subagent per task + single task review (spec + quality verdicts)

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use beads-superpowers:executing-plans
- Batch execution with checkpoints for review

## Integration

**Called by:** **brainstorming** — this is brainstorming's terminal state. After design approval, brainstorming invokes writing-plans.

**Hands off to:** **great_cto `implementing-epics`** — the default for every plan. A separate implementation session consumes the captured bead graph.

**Invokes:**
- **subagent-driven-development** — in-session execution, only when the user directs it (see Execution Handoff).
- **executing-plans** — in-session execution, only when the user directs it.

**Pairs with:** **stress-test** — offered at the plan-review gate every time (the "Approved + stress-test" option), before execution.
