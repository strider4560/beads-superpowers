---
name: decisions
description: Key architectural and technical decisions with reasoning. Load when making design choices or understanding why something is built a certain way.
triggers:
  - "why do we"
  - "why is it"
  - "decision"
  - "alternative"
  - "we chose"
edges:
  - target: context/architecture.md
    condition: when a decision relates to system structure
  - target: context/stack.md
    condition: when a decision relates to technology choice
# Decisions usually ground sparsely; add only symbols that implement the decision.
# Entry shape: { node: "function:<tier-1-id>", fingerprint: "mh:64:<hex>" }
grounds_to: []
last_updated: [YYYY-MM-DD]
---

# Decisions

<!-- If a decision names its concrete implementation point, link it as below;
     do not anchor vague concepts:
```markdown
[`someFunction()`](mex://function:<tier-1-id>)
```
-->

<!-- HOW TO USE THIS FILE:
     Each decision follows the format below.
     When a decision changes: DO NOT delete the old entry.
     Mark it as superseded, add the new entry above it.
     The history must be preserved — this is the event clock. -->

## Decision Log

### No OSS "guided harness" to adopt — type-keyed authority builds on native harness primitives
**Date:** 2026-08-20
**Status:** Active (research conclusion; the full harness-redesign ADR is pending a planning session)
**Decision:** The harness redesign does not adopt any external OSS framework, agent library, or methodology; agent-type-keyed authority is expressed as our own small type→authority data table, compiled onto each harness's native enforcement primitives.
**Reasoning:** A five-lane survey (verified 2026-08-20) found: general multi-agent frameworks (CrewAI, LangGraph, Deep Agents, MAF, ADK) all own the agent loop — wrapping an external harness yields observability, not authority; Claude Code agent libraries (wshobson 39k★, VoltAgent, davila7) declare types but enforce only tool allowlists, with every finer boundary prose-only; SDD methodologies enforce nothing mechanically, and Agent OS shipped exactly this role registry (role → tools+model+standards+verifier) and retired it in v2.1.0 (2025-10-21) as "too complex… added no real benefit"; prompt-declared modes demonstrably leak (Cline issue #4387). Meanwhile the needed primitives exist natively: Claude Code delivers `agent_type` in every hook payload (PreToolUse included) and enforces per-agent `tools`/`disallowedTools`; OpenCode enforces per-agent model+variant+allow/ask/deny permission blocks in its runtime, fail-closed, with parent-deny inheritance to subagents.
**Alternatives considered:** Cupcake (eqtylab, OPA/Rego at the hook boundary, Apache-2.0) — the only OSS policy engine at the right boundary; kept as a spike-gated option (its `agent_type` input is undocumented, maintenance unverified since 2025-12), and our fail-closed shim is required regardless because Claude Code hooks fail open (only exit 2 blocks; exit 1 and command-hook timeouts proceed). MCP gateways — categorically disqualified: they cannot see local Bash/Write/Edit calls. Roo Code custom modes — archived 2026-05-15.
**Consequences:** The type vocabulary (planning / orchestration / implementation / review) is ours to define as data, fail-closed on unknown types; since no harness offers type inheritance, type→agent expansion is generated or guard-verified (convention-sync precedent). Enforcement lives in plugin `hooks.json` on Claude Code (plugin subagents ignore `permissionMode`/`hooks`/`mcpServers` frontmatter) and in generated agent `permission` blocks + the existing plugin hook on OpenCode. Authority binds to tools+hooks; per-type model/effort is cost economy only (subagent `model:` frontmatter has a history of being silently ignored).

<!-- Document key decisions using the format below.
     Include decisions that: are non-obvious, have important constraints,
     or where the reasoning prevents future mistakes.
     Do not document every decision — only ones where "why" matters.
     Minimum 3 decision entries during initial population. If you cannot identify 3,
     write placeholder entries with "[TO DETERMINE]" and explain what decision is pending.

     Format for each entry:

     ### [Decision Title]
     **Date:** YYYY-MM-DD (check git history for real dates when possible)
     **Status:** Active | Superseded by [title]
     **Decision:** [What was decided, in one sentence]
     **Reasoning:** [Why this was chosen]
     **Alternatives considered:** [What else was considered and why it was rejected]
     **Consequences:** [What this means for the codebase going forward]

     Example:

     ### Use PostgreSQL for all persistent storage
     **Date:** 2024-03-01
     **Status:** Active
     **Decision:** All persistent data lives in PostgreSQL, no secondary databases.
     **Reasoning:** Simplicity — one database to operate, backup, and reason about.
     **Alternatives considered:** Redis for sessions (rejected — adds operational complexity for minimal gain), MongoDB for user preferences (rejected — relational model fits our data).
     **Consequences:** No caching layer at database level. Application-level caching if needed.

     Example of a superseded entry:

     ### Use Redis for session storage
     **Date:** 2024-02-15
     **Status:** Superseded by "Use PostgreSQL for all persistent storage"
     **Decision:** Store user sessions in Redis.
     **Reasoning:** Fast read/write for session data.
     **Alternatives considered:** PostgreSQL (chosen later due to operational simplicity).
     **Consequences:** ~~Requires Redis infrastructure alongside PostgreSQL.~~
     **Superseded because:** Maintaining two data stores added operational complexity
     without meaningful performance benefit for our scale. -->
