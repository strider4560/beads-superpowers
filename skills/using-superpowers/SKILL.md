---
name: using-superpowers
description: Use when starting any conversation - establishes how to find and use skills, requiring Skill tool invocation before ANY response including clarifying questions
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, ignore this skill.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## The Rule

**Invoke relevant or requested skills BEFORE any response or action** — including clarifying questions, exploring the codebase, or checking files. If it turns out wrong, you don't have to use it.

**Before entering plan mode:** if you haven't already brainstormed, invoke the brainstorming skill first.

Then announce "Using [skill] to [purpose]" and follow the skill exactly. If it has a checklist, track it with beads (see Beads below) — TodoWrite is forbidden.

## Skill Priority

Process skills come first — they set the approach, implementation skills carry it out. Implementation is **spec-backed**: it starts from an approved spec or plan, and you name that file before the first edit (typo-level fixes aside).

- "Let's build X" → planning session (planning tier): beads-superpowers:brainstorming → great_cto's planning-with-reviews → beads-superpowers:writing-plans.
- "Implement the ready epic" → implementation session: great_cto's `implementing-epics`.
- "Fix this bug" → beads-superpowers:systematic-debugging first, then domain skills.
- Design question mid-implementation → file a `needs-planning` bead. **Never** re-plan in-lane.
- A planning session drains open `needs-planning` beads first.

### Pipeline

Both sessions require the great_cto bundle root (`~/.agents/great_cto`). Without it the stage gates fail closed — stop and report, no override.

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "I need more context first" / "let me explore the codebase first" / "I can check git/files quickly" / "let me gather information first" / "I'll just do this one thing first" | Skills tell you HOW. Check BEFORE doing anything. |
| "This is just a simple question" / "this doesn't need a formal skill" / "this doesn't count as a task" / "the skill is overkill" | Action = task. If a skill exists, use it. Simple things become complex. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |
| "This bead is specified enough — I'll just implement it" | **Spec-backed**: name the spec/plan file, or brainstorm first. |

## Production-Grade Doctrine

Treat every project as a production system with real users, no matter how small it looks. You MUST NOT silently take a shortcut, descope a required behavior/edge-case, or accept a material-risk trade-off — surface it and let your human partner decide. You MUST NOT weaken, bypass, or remove a security control or introduce a vulnerability; a security regression is never acceptable, even for a deadline.

## Capturing Decisions

Log every settled decision — `mex log --type decision "<one-line>"`, unconditional; that line makes it retrievable. When a decision is hard to reverse, surprising without context, and a genuine trade-off, you MUST also offer an ADR in `docs/decisions/` (the user confirms; never auto-create). Bias toward offering; routine clarifications and scope questions don't qualify.

## Beads and mex

`bd` (beads) is the task tracker for ALL work — TodoWrite is forbidden, as are TaskCreate and markdown TODOs. Only the orchestrating agent manages beads — subagents never touch them. Include bead IDs in commit messages. If beads context wasn't injected this session, run `bd prime`. Initiative work is a graph: initiative → epics → tasks.

**bd tracks work; mex holds knowledge.** Durable notes (requirements, architecture, decisions, conventions, compliance, lessons) live in `.mex/` — never in beads. Only the orchestrating agent writes to `.mex/` or runs `mex log` — subagents read routed pages, never write. If mex context wasn't injected this session, read `.mex/ROUTER.md`. If a `mex` command errors, surface the error and stop the knowledge step — never improvise a workaround.

Session close = land the plane: `bd close` → `mex check` → `bd dolt push` → `git push`.

## Skill Name Resolution

Skills are referenced here as `beads-superpowers:<skill>`. Invoke whichever form
your skill list shows; if a reference errors as unknown, match it to the closest
name in your list and retry.

## Platform Adaptation

If your harness is codex, opencode, copilot, pi, antigravity, or gemini, read
`references/<harness>-tools.md` for special instructions.

## Asking the User

When a skill says to ask the user or present options: use your harness's structured question tool if it has one (multiple-choice with an "Other" escape); if it doesn't, print the options as a numbered list in plain text and STOP for the user's reply. If the tool errors, or an answer comes back skipped, dismissed, or auto-resolved (headless and auto modes do this), treat it as NO answer — never as consent: fall back to numbered plain text and stop. JSON question blocks in skills show Claude Code's schema — render the same content through your tool's shape.

## User Instructions

User instructions (CLAUDE.md, AGENTS.md, etc, direct requests) take precedence over skills, which in turn override default behavior. Only skip skill workflows or instructions when your human partner has explicitly told you to.
