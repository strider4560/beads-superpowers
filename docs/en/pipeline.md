---
sidebar:
  order: 10
description: The five-stage pipeline that runs a change from idea to reviewed epic across two sessions, the authority each participant holds, and the gates that fail closed when something is off.
---

<!-- Role: the contract between beads-superpowers and great_cto - stages, session roles, tier vocabulary, gates, and the plan of record. Does NOT belong here: per-skill reference detail (skills.md), or the router-style walkthrough of the older single-session flow (workflow.md). -->

# The Pipeline

[Example Workflow](workflow.md) describes the single-session flow this pipeline replaced; read it for how the individual skills route to each other, and read this page for the stage and authority contract that now sits over them.

Work travels through five stages split across two sessions: a planning session that ends with a bead graph, and an implementation session that reads that graph and builds against it. Nothing is handed between them in prose. The plan of record is the bead graph plus the `.mex/` knowledge store, so the implementation session never parses a document the planning session wrote.

The pipeline spans two repositories. beads-superpowers owns the process mechanics - stage contracts, the bead and mex schema, and the scripts under `scripts/pipeline/`. [great_cto](https://github.com/strider4560/great_cto) owns the deployment bindings - the agent roster, the review contracts, the agent prompts, and the map from capability tier to concrete model. beads-superpowers resolves that bundle at `~/.agents/great_cto/` and refuses to run without it:

```bash
git clone https://github.com/strider4560/great_cto ~/Develop/great_cto && ~/Develop/great_cto/scripts/install.sh --host all
```

## The five stages

| Stage | Skill | Input to output |
|-------|-------|-----------------|
| 1. Brainstorm | `brainstorming` (this repo) | An idea becomes approved requirements and a design spec under `.internal/specs/` |
| 2. Review deliberation | `planning-with-reviews` (great_cto) | The approved spec is put to selected domain reviewers, read-only, and comes back settled with immutable review artifacts |
| 3. Capture | `writing-plans` (this repo) | The settled spec becomes a Markdown plan, a bead graph, and the mex declarations behind it |
| 4. Implement one epic | `implementing-epics` (great_cto) | Epic selection, task grouping, worktrees and branches; each task group goes to the task engine in this repo |
| 5. Epic review | `reviewing-epics` (great_cto) | The built epic goes to the mandatory reviewers plus whichever the plan declared, read-only, in rounds with a breaker |

Each stage's terminal action is invoking the next stage's skill, so the sequence holds without a supervising state machine. A trivial fix - one line, no design question - skips the stages but not the guard rules below, which apply to every session and every subagent regardless of which stage they think they are in.

## Two session roles

The **planning session** runs stages 1 through 3 at the planning tier in one continuous sitting, at session effort `high`, and ends by landing the plane. Its reviewer dispatches run at the planning tier with effort `xhigh` and read-only tools; the mechanical fan-out in the capture stage runs at effort `low`.

The **implementation session** runs stages 4 and 5 at the implementation-orchestration tier, one fresh session per epic. It groups ready tasks whose declared implementation agent matches and whose paths do not overlap, gives each group one worktree and one branch, and dispatches one implementer per group at the implementation tier under test-driven development. A completed group gets a single `senior-dev` review of the group's combined diff against every acceptance criterion in it, at the review tier with effort `high` and a five-round breaker. The bead ledger stays per task: the orchestrator closes each task bead individually with evidence drawn from the group's verification.

When an implementation session hits a genuine design question, it files a `needs-planning` bead that blocks the affected task and stops that task. The epic carries on with the tasks that do not depend on it. Re-planning happens in the next planning session, which drains `needs-planning` beads first, and never in-lane.

## Capability tiers

Skills in this repo name four tiers and nothing else:

- **planning tier** - the planning session and its reviewers
- **implementation-orchestration tier** - the session that runs an epic
- **implementation tier** - task implementers, which a plan may raise for an individual task
- **review tier** - epic reviewers and the per-group task review

Tiers are dispatch-time economy, not enforcement: since the agent-authority rework (2026-08-21) no gate reads the session's model, and which model a session or a dispatch runs on is a human choice the tier map describes. Model identifiers and default effort levels appear only in great_cto's tier map. The harnesses this repo ships to name their models differently or not at all, so a guard rejects a model name in harness-neutral content. If you need to know which model a tier resolves to, read the tier map, not a skill.

## What fails closed

Four gates, all of them tooling rather than prose. None of them asks the agent to police itself.

**The hard-dependency check.** `install.sh` verifies the bundle root before it detects tools or touches anything. `--uninstall` is the single exemption, because removing beads-superpowers must never require the dependency beads-superpowers needs to run. In the pipeline scripts the bundle root is resolved after the gate's own version handshake and integrity check, ahead of everything else. A missing bundle root prints the install command above and exits nonzero. The session-start hook reports bundle-root presence too, by directory existence alone, because that hook only ever reads files.

**The preflight gate.** Stage skills call `scripts/pipeline/tier-gate.sh --stage planning|implementing|reviewing` at stage entry (the filename is historical). The gate verifies the install: the version handshake between the gate and its own root, the integrity record, and the great_cto bundle at the required floor. It reads nothing about the session - no model, no effort, no session id - so no harness or model spelling can brick a stage.

The same script carries the pipeline's orientation mode: `tier-gate.sh --phase` is agent-run, read-only, and advisory - it reads the bead graph (and, with nothing in flight, the planning artifacts under `.internal/`) and prints the current phase plus a one-line `next:` recommendation. The orchestrating agent fires it when you say "continue" or "where are we" and routes from its answer; you never run pipeline scripts yourself. Only the `phase:` and `next:` prefixes are contract.

**The PreToolUse backstop.** Where hooks exist, two rule families apply once a project is armed, with no ask-or-confirm middle ground. Rule D: the pipeline's own state directory and the installed gate surface are not agent-writable, for any caller - anything that can rewrite the control judging it has self-authorized. Rule S: a subagent - detected mechanically by the `agent_id` the harness stamps on every subagent tool call, never by name - cannot mutate beads (reads and `bd note` on its own task bead stay open), write mex, or edit the plan of record (`plans/`, `.internal/plans/`, `.internal/specs/`); those belong to the orchestrating session that dispatched it, and the deny message tells the subagent to report the need instead. The orchestrating session itself is unrestricted by Rule S. The hook denies on internal error rather than allowing, and it does not depend on the agent choosing to call the gate.

The session-model tier wall that used to sit here - rules keyed on which model the session ran - was removed in the agent-authority rework: it bricked whole sessions whenever a harness spelled a model id in a way the tier map did not list, and the enforcement point never receives a model on PreToolUse anyway. Guard rails now attach to what is mechanically observable: subagent identity.

**graph-lint.** `scripts/pipeline/graph-lint.mjs` reads `bd list --json` and checks that every task's implementation agent and every epic's reviewers exist in the bundle root's roster, that the dependency graph is acyclic, that tier values exist in the tier map, that required body sections are present, and that the initiative-to-epic-to-task structure is intact. The capture stage cannot complete until it passes, and the implementation session reruns it before selecting an epic. A failure means fixing the beads and rerunning; hand-editing around it defeats the point.

## Beads and mex are the plan of record

There is no handoff file. Nothing is exported, imported, or re-parsed at the stage-3 to stage-4 boundary.

The **bead graph** carries the what. Capture creates it atomically: `bd create` for the initiative, then `bd import -` for the epics and tasks as JSONL, then `bd batch` for the inter-task `blocks` dependencies. One epic-type bead labeled `initiative` holds the plan's goal and success criteria along with pointers to the mex declarations and the settled spec. Implementation epics are its parent-child children, so bd keeps the initiative open until the last epic closes. Task beads sit under their epic, carry their acceptance criteria verbatim in the body, and carry `implementation_agent`, `required_skills`, and `tier` in metadata. Effort is not a task field: harnesses expose per-call model but not per-call effort, so effort is pinned per agent role in great_cto's definitions instead.

The **mex store** carries the why. Capture records a decision entry for the finalized requirements, one for the design, and one for the plan rationale, then distills an initiative page into `.mex/context/` under the usual routing and size conventions. Beads cite the mex entries and the mex entries cite the bead IDs, so either half leads to the other. Because `.mex/` is committed and travels with the repository, the capture step runs a secret and PII scan before every write and keeps the declarations distilled - pointers and rationale, never credentials, client names, or verbatim sensitive requirements. The full prose spec and the review artifacts stay in `.internal/`, which is gitignored and session-local.

Graph creation is resumable rather than transactional. If it fails partway, rerun the capture step - `bd import` upserts idempotently - until graph-lint passes. Never hand-delete a half-built graph.

An implementation session therefore starts from three reads: `bd ready` for its epic's tasks, the initiative and epic bead bodies for objective and criteria, and mex retrieval for the reasoning. It depends on none of the planning session's context.

## Cross-repo contract

great_cto reaches into this repo through three absolute paths. Their spellings, the directory they have to run from, and the exit codes they promise are the interface between the two bundles, so they move only in a coordinated release of both.

```bash
# All three MUST be run with the working project's repo root as the cwd —
# session state, --state dumps, plan files and git state are cwd-relative.
bash "$HOME/.agents/beads-superpowers/scripts/pipeline/tier-gate.sh" --stage <stage>
node "$HOME/.agents/beads-superpowers/scripts/pipeline/graph-lint.mjs" --initiative <id> --state <dump>
"$HOME/.agents/beads-superpowers/skills/subagent-driven-development/scripts/review-package" <plan-path> <MERGE_BASE> HEAD
# Exit contract: 0/1/2 as documented per script. Any other exit — including
# 127 (missing file) — is fail-closed: stop and report. This row is also added
# to the exit tables in skills/brainstorming and skills/writing-plans.
```

`review-package`'s first argument is a plan file that has to exist on disk; the plan path is what identifies the workspace. `${CLAUDE_PLUGIN_ROOT}` is rejected for great_cto's calls; the absolute paths above are the only accepted spelling.

### Where the pipeline is supported

Two channels: an `install.sh` scripted-tier install (local, tarball, or git), and the Claude Code plugin channel. Everything else this project ships to - npx, the seven best-effort harness plugin installs, OpenCode's git-plugin install, and any harness whose plugin channel does not execute our hooks - is pipeline-unavailable. The gates there fail closed rather than running in a reduced mode, so a call that should have been checked stops instead of passing unchecked.

### Version pairs and rollback

The two bundles are pinned to each other in pairs. great_cto 3.0.x goes with beads-superpowers 0.17.x, great_cto 3.1.0 goes with beads-superpowers 0.18.0, and great_cto 3.2.0 goes with beads-superpowers 0.19.0. The 0.17.x half is defined as "no anchor present", so which half a host is on is checkable rather than a matter of memory: `$HOME/.agents/beads-superpowers` exists on 0.18.0 and later, and does not exist on 0.17.x.

Rolling back runs in this order, and the first step is the one that is easy to get wrong:

1. Run **the installed release's own** `install.sh --uninstall` first — 0.19.0's, if you are on the current pair — before installing anything older. The installer that removes an artifact has to be the one that created it, and 0.17.x's installer knows nothing about the anchor directory or the integrity record, so it will leave both behind. This step removes `$HOME/.agents/beads-superpowers` and the record under `$HOME/.local/state/beads-superpowers/`.
2. Check out the great_cto tag for the pair you are returning to — `v3.1.0` for 0.18.0, `v3.0.0` for 0.17.x — and re-run its installer.
3. Install that pair's beads-superpowers release.

The `paths` and `plan_path` stamps a plan leaves on its beads need no undoing. They are additive metadata that the 0.17.x toolchain ignores, so rollback is forward-fix only. To reset pipeline session state, delete `.internal/pipeline/`.

### Declaring the files a task touches

Every task bead carries `metadata.paths`: repository-relative path strings covering the files that task edits or creates. The implementation session groups tasks by them, so two tasks whose paths overlap never run in parallel against the same worktree. Both repos implement the same comparison, and graph-lint rejects anything that is not canonical:

entries are repository-relative; no leading `./` or `/`; no `..`, no interior `.` segments (`src/./a.ts`), and no empty segments (`src//a.ts`); forward slashes only; no duplicate entries; comparison is byte-exact; trailing `/` if and only if the entry is a directory claim (enforceable where the entry already exists on disk — for a not-yet-created path the claim's spelling is taken as declared). Overlap: two claims overlap when either is a path-component prefix of the other (`src/` overlaps `src/a.ts`; `src/ab.ts` does not overlap `src/a.ts`).

### When a gate stops you

Two failures have a remedy you can act on directly. Both deny rather than warn, and neither has an agent-side fix, which is the point.

| What the gate reports | What clears it |
|-----------------------|----------------|
| The integrity record is missing or unreadable, or a file `does not match its recorded hash` | Re-run `install.sh`. The record is written by its channel's maintainer - `install.sh` on the scripted tiers, session-start on the plugin channel - and only that maintainer can rewrite it; on the plugin channel, that means starting a fresh session so the hook re-attests the root. |
| `is running against beads-superpowers root`, naming a version that is not the gate's own | Re-run `install.sh`, or refresh the plugin, so the gates and the installed root are the same version. |
| `install skew`, naming this hook's version and a different attested root version | Refresh whichever channel is behind, so both are the same release: `claude plugin update beads-superpowers` on the plugin channel, or re-run `install.sh` on a scripted install. The hook and the library it sources are two halves of one contract, and the deny is what stops a mismatch from surfacing later as an undefined shell function with nothing to act on. |

Accepted risks and residuals for this contract are recorded privately, in the decision record's amendment and in `.mex/private/`, not on this page.
