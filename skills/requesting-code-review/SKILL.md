---
name: requesting-code-review
description: Use when completing tasks, implementing major features, or before merging to verify work meets requirements
---

# Requesting Code Review

Dispatch a code reviewer subagent to catch issues before they cascade. The reviewer gets precisely crafted context for evaluation — never your session's history.

**Core principle:** Review early, review often.

## When to Request Review

**Mandatory:**
- After each task in subagent-driven development
- After completing major feature
- Before merge to main

**Optional but valuable:**
- When stuck (fresh perspective)
- Before refactoring (baseline check)
- After fixing complex bug

## How to Request

**1. Get git SHAs:**
```bash
BASE_SHA=$(git rev-parse HEAD~1)  # or origin/main
HEAD_SHA=$(git rev-parse HEAD)
```

**2. Dispatch code reviewer subagent:**

Dispatch a `general-purpose` subagent, filling the template at [code-reviewer.md](code-reviewer.md)

**Placeholders:**
- `{DESCRIPTION}` - Brief summary of what you built
- `{PLAN_OR_REQUIREMENTS}` - What it should do
- `{BASE_SHA}` - Starting commit
- `{HEAD_SHA}` - Ending commit

**3. Act on feedback:**
- Fix Critical issues immediately
- Fix Important issues before proceeding
- Note Minor issues for later
- Push back if reviewer is wrong (with reasoning)

## Example

```
[Just completed Task 2: Add verification function]

You: Let me request code review before proceeding.

BASE_SHA=$(git log --oneline | grep "Task 1" | head -1 | awk '{print $1}')
HEAD_SHA=$(git rev-parse HEAD)

[Dispatch code reviewer subagent via code-reviewer.md template]
  WHAT_WAS_IMPLEMENTED: Verification and repair functions for conversation index
  PLAN_OR_REQUIREMENTS: Task 2 from .internal/plans/deployment-plan.md
  BASE_SHA: a7981ec
  HEAD_SHA: 3df7661
  DESCRIPTION: Added verifyIndex() and repairIndex() with 4 issue types

[Subagent returns]:
  Strengths: Clean architecture, real tests
  Issues:
    Important: Missing progress indicators
    Minor: Magic number (100) for reporting interval
  Assessment: Ready to proceed

You: [Fix progress indicators]
[Continue to Task 3]
```

## Integration

**Used by:**
- **subagent-driven-development** — review after EACH task; catch issues before they compound; fix before moving to next task
- **executing-plans** — review after each task or at natural checkpoints
- **Ad-hoc review** — before merge or when stuck

**Pairs with:**
- **receiving-code-review** — request/response pair; this skill dispatches the reviewer, receiving-code-review handles the feedback
- **verification-before-completion** — code review is pre-completion evidence

**Capture what you learned.** At close, record durable, evidence-backed insights (still true next month, tied to a file, test, or command) in `.mex/lessons.md`: one bullet per lesson, prefixed by kind (`lesson:` / `pattern:` / `root-cause:` / `correction:`), with the evidence named. Update an existing entry in place rather than adding a near-duplicate. The hot page is hard-capped at 2048 bytes — if an append would exceed it, demote the coldest entries to `.mex/lessons-archive.md` (retrievable via the router, not injected) until it fits. Decisions: `mex log "<one-line decision>"` always; add a full `docs/decisions/ADR-NNNN-<kebab>.md` (+ `INDEX.md`) only when the ADR bar is met (hard-to-reverse AND surprising-without-context AND genuine trade-off). Requirements, design rationale, and compliance durables: distill into the matching `.mex/` page. Durables that name an unmitigated risk, security gap, compliance exposure, or unreleased plan go to `.mex/private/` (gitignored), never to tracked pages. Never record guesses, one-offs, or secrets (tokens, keys, PII — the hot page is injected into all future sessions, and tracked `.mex/` pages are public in public repos); scan before writing.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "I'll just review the diff myself instead of dispatching a reviewer" | You're the coordinator — reviewing the diff inline burns the context window you need to keep driving the work. Dispatch a reviewer subagent: the diff and the evaluation live in its context, and only the findings come back to you. |
| "The reviewer needs my whole session history to understand the change" | Hand it precisely crafted context, never your session's history. That keeps the reviewer on the work product, not your thought process. |

## Red Flags

**Never:**
- Skip review because "it's simple"
- Ignore Critical issues
- Proceed with unfixed Important issues
- Argue with valid technical feedback

**If reviewer wrong:**
- Push back with technical reasoning
- Show code/tests that prove it works
- Request clarification

See template at: [code-reviewer.md](code-reviewer.md)
