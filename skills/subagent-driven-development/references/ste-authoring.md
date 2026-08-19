# STE Authoring — Writing Bead Text for Machine Readers

Every bead description, task brief, review finding, close reason, and handoff line in
this workflow is parsed by an agent that cannot ask you what you meant. A fresh
implementer subagent reads its task brief cold. A scoped re-reviewer reads findings
cold. A post-compaction controller reads close reasons cold. If a sentence has two
possible readings, some agent will eventually take the wrong one — and in this
workflow that costs a fix round, a re-dispatched task, or a silently wrong close.

This reference adapts ASD-STE100 (Simplified Technical English), the controlled
language the aerospace industry built to stop maintenance technicians from misreading
instructions. The same discipline works on subagents: remove words with more than one
meaning, and sentences with more than one possible structure.

> Derived from [danyuchn/asd-ste100-skill](https://github.com/danyuchn/asd-ste100-skill)
> (MIT), which encodes the rule categories of ASD-STE100 Issue 9. This file keeps the
> structural rules, which are checkable without ASD's ~900-word dictionary, and drops
> dictionary lookups. It is a clarity tool inspired by STE, not certified STE.

## Structural Rules (apply everywhere)

| Rule | Do | Don't |
|---|---|---|
| Active voice, named actor | "The controller closes the bead." | "The bead is closed." — closed by whom? Subagents assign work by actor. |
| One instruction per sentence | "Open the file. Read line 3." | "Open the file and read line 3, then check it matches." |
| Sentence length | ≤20 words for instructions, ≤25 for descriptions | Compound sentences with subordinate clauses |
| Imperative for steps | "Run the test. Record the output." | "The test should be run and its output recorded." |
| No phrasal verbs | "Start the job." "Remove the flag." | "Spin up the job." "Take out the flag." — two-word verbs have meanings the parts do not predict |
| No semicolons | Split into two sentences | Any semicolon — it hides a second instruction inside the first |
| Noun clusters ≤3 words | "the task-queue handler" | "the agent task queue priority handler config" |
| No ellipsis | "The files that are not committed will be lost." | "Files not committed will be lost." — which files? Keep subject, verb, article. |
| Keep modality | "The cache **may be** stale." stays "may be" | Promoting a hedge to a fact. A hedge is content — dropping it changes the claim. |
| Lists for sequences | Numbered list for 3+ steps or conditions | A sequence buried in one prose sentence |

## One Name Per Concept (the highest-value rule here)

Rotating synonyms is the single most damaging habit in multi-agent text. If the plan
says "the user record", the acceptance criteria say "the account object", and the
Interfaces block says "the profile" — a parallel implementer cannot tell whether that
is one thing or three, and two parallel implementers may resolve it differently
(divergence no worktree can isolate).

Pick one name for each entity, function, file, and state. Use it verbatim in the spec,
the plan, every task's Files/Interfaces/Acceptance Criteria blocks, every bead
description, and every prompt. When a name is long, keep it long — a consistent long
name beats a rotating short one.

## Scan Checklist (before you commit any bead text)

1. **Synonym rotation** — one thing, several names. Fix: one name, every time.
2. **Hedge stacking** — "it may potentially help to improve". Fix: state the claim or delete it. (Distinct from a single honest hedge, which you keep.)
3. **Nominalization** — "perform validation of". Fix: "validate".
4. **Vague quality words** — "robust", "clean", "appropriate", "properly". A reviewer cannot verify "handles errors properly". Fix: name the observable behavior ("returns exit code 2 and logs the path").
5. **Run-on sentences** — ideas chained with semicolons, "and then", em dashes. Fix: one idea per sentence.
6. **Soft phrasal verbs** — spin up, reach out, kick off, dig into. Fix: start, contact, begin, read.

## Per-Surface Guidance

**Acceptance criteria** (writing-plans → bead description → task brief): strictest
surface. Each criterion is one testable sentence with an observable outcome. Bad:
"Progress reporting works correctly." Good: "The command prints one progress line per
100 items processed."

**Scene-setting context and answers to subagent questions** (SDD controller): ≤25-word
sentences, named actors, one name per concept — the implementer acts on your exact
words with no follow-up round unless it stops to ask.

**Review findings** (task review, re-review): one finding per sentence, with file:line.
The finding text is re-parsed twice: by the controller for dispatch, and by a fresh
fix-round implementer who was not present at the review. Keep genuine uncertainty as
⚠️ — never promote "may be unused" to "is unused".

**Close reasons and `.mex/lessons.md` entries** (durable ledger): parsed after compaction by an
agent with no other context. State what was done, the commit range, and the evidence.
No pronouns whose referent lives in the dead conversation ("fixed it as discussed").

**Handoffs and specs**: apply the structural rules in full; treat word-choice rules as
advisory. Specs need some prose range — do not flatten rationale sections into
robot-speak. The "Exact next action" line in a handoff is an instruction: imperative,
one action, ≤20 words.

## What This Discipline Is Not

- **Not compression.** Stop when the sentence is unambiguous, not when it is shortest.
  If a rewrite would drop a safety condition, a scope qualifier, or a number, keep the
  longer phrasing.
- **Not certainty laundering.** Never upgrade "may have failed" to "failed". Never add
  a cause, frequency, or mechanism the source did not state.
- **Not a style for everything.** Rationale, design discussion, and README prose keep
  their voice. Apply strict rules only to text an agent must act on.
