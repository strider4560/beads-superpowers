---
name: executing-plans
description: DEPRECATED — use the pipeline (implementing-epics + subagent-driven-development). Retained only so existing references resolve
---

# Executing Plans (deprecated)

Plan execution runs through the pipeline now. `writing-plans` captures the plan as a bead graph and hands off to great_cto's `implementing-epics`, which forms task groups and invokes `beads-superpowers:subagent-driven-development` as the task engine. When the user directs execution inside the planning session instead, that same engine serves the in-session path, with the planning agent taking the caller's jobs.

**Do not** execute a plan from this skill. Route to `beads-superpowers:subagent-driven-development`.

The pre-deprecation body — the load-review-execute loop, the blocker taxonomy, and the epic/task creation walkthrough — is in git history at `git show 787c9f6:skills/executing-plans/SKILL.md`.
