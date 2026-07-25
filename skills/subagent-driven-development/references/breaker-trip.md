# Fix Rounds and the Breaker — Rationale and Trip Procedure

Read this when the fix loop closes round five with findings still open, or when you
need the reasoning behind the fix-round rules in `SKILL.md`.

## Why fix rounds dispatch fresh

Resuming the previous implementer would be cheaper, but it requires the harness to
re-address a live subagent — not all harnesses can. Fresh dispatch behaves
identically everywhere. It also avoids the agent that wrote a defect defending it,
and it keeps verification anchored to an independent instance rather than the same
model judging its own reasoning.

## Why only the latest report section

The report file accumulates across rounds — that is the durable record. But a fix
round is handed only the most recent section. Passing the whole history grows
quadratically across rounds, and it feeds fresh eyes a long transcript of previous
wrong approaches, reintroducing the anchoring that fresh dispatch exists to avoid.
Earlier rounds remain on disk if a round genuinely needs them.

## Why a scoped re-review still needs the full suite

A re-reviewer sees only the fix diff. It structurally cannot detect an out-of-diff
regression — a changed contract breaking a distant caller, a removed guard making a
far-off test pass vacuously. So the reviewer answers "are these findings resolved"
and the test suite answers "did anything else break". Neither is asked to do the
other's job.

Rounds are also reviewed piecewise, so no task-level review ever sees several fixes
together. The final whole-branch review is the only place the composite is examined.

## What the breaker is and is not

It bounds **cost**, not **correctness**. A round cap does not stop a lenient
re-reviewer from closing the loop early on an unresolved finding. Correctness is
bounded by the full-suite gate and the composite final review. Do not treat a clean
breaker as evidence of a clean task.

## Trip procedure

1. **File every unresolved finding** as a child bead on the epic, stamped
   Severity / Confidence / Evidence per Agent-Filed Bead Discipline.
   **Preserve each finding's severity — never flatten it** (see below).
2. **Set the task bead `blocked`** and record the round count on it
   (`bd note <task-id> "fix rounds: N"`). Those counts are how the five-round cap
   gets calibrated later against real data instead of taste.
3. **Hold the task's branch unmerged.**
4. **Surface to the user and STOP.** Present **both** dispositions:
   - **Resolve** the open findings on the current branch, or
   - **Discard the fix rounds** and return to the round-0 state, preserved at the
     recorded per-task `BASE`. Round 0 passed its own full task review and failed
     only on the enumerated findings.

   Include the round-0 verdict and the round count so the choice is informed. After
   several rounds a branch can be *worse* than round 0 — sediment from successive
   narrow patches by agents that each saw only their own slice. That option must be
   visible or it will not be chosen.
5. **In a parallel batch:** let siblings run to completion, merge passing branches
   normally, hold the tripped task, leave dependents blocked through their existing
   `bd` deps, and surface everything together at batch end. Per-task worktrees exist
   so one task's failure cannot contaminate its siblings.

## Severity survives the breaker

The task reviewer's security floor states that a security regression is
automatically Critical / blocking regardless of size or stated rationale, is never
"Minor", and is never downgraded by a rationale.

Flattening every open finding into one "what do you want to do with these" list
silently converts a never-downgradable finding into an ordinary parking decision —
at the moment of maximum pressure, five rounds deep with the epic stalled.

So a security-classified open finding:

- blocks the **epic**, not just the task;
- is surfaced with its Critical classification and the floor's own language intact;
- is never included in a list of things that could be parked.

The user retains override authority. The obligation here is to make clear what is
being overridden.

## What the controller does not do

Findings are filed and surfaced; the user decides their disposition. Never close or
downgrade an open finding to make a task pass — file it and surface it instead.
