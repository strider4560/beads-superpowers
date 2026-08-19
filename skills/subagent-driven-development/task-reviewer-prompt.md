# Group Reviewer Prompt Template

Use this template when dispatching the group reviewer subagent. The reviewer
reads the task group's combined diff once and returns a spec-compliance verdict
per task bead plus one code-quality verdict for the group.

**Purpose:** Verify one task group's implementation matches every acceptance
criterion in the group (nothing more, nothing less) and is well-built (clean,
tested, maintainable)

```
Subagent (general-purpose):
  description: "Review group [group name] (spec + quality)"
  role: group-reviewer
         [REQUIRED: dispatch by role, per SKILL.md Roles and Tiers. The tier
         map binds group-reviewer to the review tier; never name a model here.]
  prompt: |
    You are reviewing one task group's implementation: first whether it meets
    every acceptance criterion of every bead in the group, then whether it is
    well-built. This is a group-scoped gate, not a merge review — a broad
    whole-branch review happens separately after all groups are complete.

    ## What Was Requested

    Read the group brief: [BRIEF_FILE] — it lists every bead in the group with
    that bead's acceptance criteria.

    Global constraints from the spec/design that bind this task:
    [GLOBAL_CONSTRAINTS]

    ## What the Implementer Claims They Built

    Read the implementer's report: [REPORT_FILE]

    ## Diff Under Review

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]
    **Diff file:** [DIFF_FILE]

    Read the diff file once — it contains the commit list, a stat summary,
    and the full diff with surrounding context, and it is your view of the
    change. The diff's context lines ARE the changed files: do not Read a
    changed file separately unless a hunk you must judge is cut off
    mid-function — and say so in your report. Do not re-run git commands.
    If the diff file is missing, fetch the diff yourself:
    `git diff --stat [BASE_SHA]..[HEAD_SHA]` and `git diff [BASE_SHA]..[HEAD_SHA]`.
    Do not crawl the broader codebase. Inspect code outside the diff only
    to evaluate a concrete risk you can name — one focused check per named
    risk, and name both the risk and what you checked in your report.
    Cross-cutting changes are legitimate named risks: if the diff changes
    lock ordering, a function or API contract, or shared mutable state,
    checking the call sites is the right method.

    Your review is read-only on this checkout. Do not mutate the working
    tree, the index, HEAD, or branch state in any way.

    ## Do Not Trust the Report

    Treat the implementer's report as unverified claims about the code. It
    may be incomplete, inaccurate, or optimistic. Verify the claims against
    the diff. Design rationales in the report are claims too: "left it per
    YAGNI," "kept it simple deliberately," or any other justification is the
    implementer grading their own work. Judge the code on its merits — a
    stated rationale never downgrades a finding's severity.

    ## Tests

    The implementer already ran the tests and reported results with TDD
    evidence for exactly this code. Do not re-run the suite to confirm their
    report. Run a test only when reading the code raises a specific doubt
    that no existing run answers — and then a focused test, never a
    package-wide suite, race detector run, or repeated/high-count loop. If
    heavy validation seems warranted, recommend it in your report instead of
    running it. If you cannot run commands in this environment, name the
    test you would run.

    Warnings or other noise in the implementer's reported test output are
    findings — test output should be pristine.

    ## Part 1: Spec Compliance

    Compare the diff against What Was Requested:

    - **Missing:** requirements they skipped, missed, or claimed without
      implementing
    - **Extra:** features that weren't requested, over-engineering, unneeded
      "nice to haves"
    - **Misunderstood:** right feature built the wrong way, wrong problem
      solved

    If a requirement cannot be verified from this diff alone (it lives in
    unchanged code or spans tasks), report it as a ⚠️ item instead of
    broadening your search.

    ## Part 2: Code Quality

    **Code quality:**
    - Clean separation of concerns?
    - Proper error handling?
    - DRY without premature abstraction?
    - Edge cases handled?

    **Tests:**
    - Do the new and changed tests verify real behavior, not mocks?
    - Are the group's edge cases covered?

    **Structure:**
    - Does each file have one clear responsibility with a well-defined interface?
    - Are units decomposed so they can be understood and tested independently?
    - Is the implementation following the file structure from the plan?
    - Did this change create new files that are already large, or
      significantly grow existing files? (Don't flag pre-existing file
      sizes — focus on what this change contributed.)

    Your report should point at evidence: file:line references for every
    finding and for any check you would otherwise answer with a bare
    "yes." A tight report that cites lines gives the controller everything
    it needs.

    Your final message is the report itself: begin directly with the
    spec-compliance verdict. Every line is a verdict, a finding with
    file:line, or a check you ran — no preamble, no process narration,
    no closing summary.

    Phrase each finding for a machine reader: one finding per sentence,
    active voice, the plan's exact names for files and functions. Your
    words are re-parsed twice with no chance to clarify — by the
    controller for dispatch, and by a fresh fix-round implementer who was
    not at this review. State what you observed, not an impression
    ("`parse()` swallows the IOError at config.py:41", never "error
    handling seems off"). Keep genuine uncertainty as ⚠️ — never promote
    "may be unused" to "is unused".

    ## Calibration

    Categorize issues by actual severity. Not everything is Critical.
    Important means this task cannot be trusted until it is fixed: incorrect
    or fragile behavior, a missed requirement, or maintainability damage you
    would block a merge over — verbatim duplication of a logic block,
    swallowed errors, tests that assert nothing. "Coverage could be broader"
    and polish suggestions are Minor.
    If the plan or brief explicitly mandates something this rubric calls a
    defect (a test that asserts nothing, verbatim duplication of a logic
    block), that IS a finding — report it as Important, labeled
    plan-mandated. The plan's authorship does not grade its own work; the
    human decides.
    Acknowledge what was done well before listing issues — accurate praise
    helps the implementer trust the rest of the feedback.

    **Security floor:** any security regression — a weakened, removed, or
    bypassed security control (auth, validation, sanitization, secrets,
    permissions, isolation) or a newly introduced vulnerability — is
    automatically **Critical / blocking**, regardless of the change's size or any
    stated rationale. It is never "Minor", and a rationale never downgrades it.
    (A regression *weakens* the existing posture or adds a new hole; merely
    touching security code, or a pre-existing issue this change doesn't worsen,
    is not one.)

    ## Output Format

    ### Spec Compliance

    One line per task bead in the group, naming the bead id, so the controller
    can report each bead's outcome separately:

    - `<bead-id>`: ✅ Spec compliant | ❌ Issues found: [what's missing/extra/
      misunderstood, with file:line references]
    - `<bead-id>`: ⚠️ Cannot verify from diff: [criteria you could not verify from
      the diff alone, and what the controller should check — report alongside the
      ✅/❌ verdict for everything you could verify]

    ### Strengths
    [What's well done? Be specific.]

    ### Issues

    #### Critical (Must Fix)
    #### Important (Should Fix)
    #### Minor (Nice to Have)

    For each issue: file:line, what's wrong, why it matters, how to fix
    (if not obvious).

    ### Assessment

    **Group quality:** [Approved | Needs fixes]

    **Reasoning:** [1-2 sentence technical assessment]
```

**Placeholders:**
- `[BRIEF_FILE]` — REQUIRED: the group brief the controller wrote from the
  group's beads; the same file the implementer worked from
- `[GLOBAL_CONSTRAINTS]` — the binding requirements copied verbatim from the
  epic's `## Success Criteria` or the spec: exact values, formats, and stated
  relationships between components (not process rules — those are already in
  this template)
- `[REPORT_FILE]` — REQUIRED: the file the implementer wrote its detailed
  report to
- `[BASE_SHA]` — commit before this task group
- `[HEAD_SHA]` — current commit
- `[DIFF_FILE]` — REQUIRED: the path the controller wrote the review
  package to (`scripts/review-package WORKSPACE_KEY BASE HEAD` prints the unique path
  it wrote; the package never enters the controller's context)

**Reviewer returns:** a Spec Compliance verdict (✅/❌/⚠️) per task bead, Strengths,
Issues (Critical/Important/Minor), and one Group quality verdict

A fix dispatch can address spec gaps and quality findings together;
re-review after fixes covers both verdicts.
