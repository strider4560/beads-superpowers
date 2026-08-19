#!/usr/bin/env node
// test-opencode-injection.mjs — hermetic plugin test (ADR-0039 + bead beads-superpowers-avji.3).
//
// The plugin (.opencode/plugins/beads-superpowers.js) resolves everything
// repo-relative to its own file location (packageRoot = two dirs up from
// __dirname) — no HOME, no env overrides, no fallback roots (upstream
// parity). To test it hermetically, each scenario below builds a standalone
// fixture directory with its own copy of the plugin file plus a
// hooks/session-start stub and a skills/using-superpowers/SKILL.md stub, then
// dynamically imports the fixture's copy. A fresh file path per scenario
// forces a fresh ES module instance (and a fresh module-level bootstrap
// cache) — importing the SAME path twice would reuse the cached module.
//
// Run with: node tests/hooks/test-opencode-injection.mjs (plain JS — no
// TypeScript loader / tsx required now that the plugin ships as .js).

import assert from "node:assert"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"

const __dirname = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(__dirname, "../..")
const realPluginPath = join(repoRoot, ".opencode/plugins/beads-superpowers.js")
const pluginSrc = readFileSync(realPluginPath, "utf-8")

// Test 0a: exec-target — composeBootstrap execs the canonical composer, not a
// reimplementation. Exactly one execSync call targets hooks/session-start
// --emit-plain (one source of truth; a bd-prime-style dump must not be
// reimplemented here). Matches across the multi-line template literal.
const execTargetRe = /execSync\(\s*`[^`]*hooks\/session-start[^`]*--emit-plain[^`]*`/g
const execTargetMatches = pluginSrc.match(execTargetRe) || []
assert.strictEqual(execTargetMatches.length, 1, "exactly one execSync call targets hooks/session-start --emit-plain")
assert.ok(!pluginSrc.includes("bdPrime"), "bdPrime() must not exist — composeBootstrap replaces it")
console.log("PASS: exec-target — single execSync call to the canonical hook with --emit-plain")

// Test 0b: anti-fork guard — the plugin must contain ZERO selection policy. Composer/selection
// logic (salience parsing, recall loops, ceiling logic) lives ONLY in hooks/session-start.
assert.ok(
  !/salience|@type=|BSP_MEM_CEILING/i.test(pluginSrc),
  "plugin source must not reimplement selection policy (salience / @type= / BSP_MEM_CEILING)"
)
assert.ok(!pluginSrc.includes("bd memories --json"), "plugin source must not reimplement memory selection (bd memories --json)")
console.log("PASS: anti-fork guard — no selection policy in plugin source")

// Test 0c: legacy bd-memory surface is gone — durable knowledge is .mex/, and the
// plugin must not shell out to the retired bd memory commands.
assert.ok(
  !/bd (remember|memories|forget|recall)\b/.test(pluginSrc),
  "plugin source must not reference bd remember/memories/forget/recall"
)
console.log("PASS: no legacy bd-memory references in plugin source")

// buildFixture(withHook, mex) — a standalone fixture dir with its own copy of the plugin
// file (fresh module identity), a skills/using-superpowers/SKILL.md stub, and
// optionally a hooks/session-start stub that echoes a canned composer payload.
// mex: null → no .mex/ at all; { lessons } → .mex/ with that lessons.md body;
// {} → .mex/ present but no lessons.md.
const stubPayload = [
  "<EXTREMELY_IMPORTANT>",
  "stub bootstrap body",
  "</EXTREMELY_IMPORTANT>",
  "",
  "<beads-context>",
  "stub beads body",
  "</beads-context>",
].join("\n")

function buildFixture(withHook, mex = null) {
  const root = mkdtempSync(join(tmpdir(), "bsp-oc-test-"))
  const pluginDir = join(root, ".opencode/plugins")
  mkdirSync(pluginDir, { recursive: true })
  const pluginPath = join(pluginDir, "beads-superpowers.js")
  writeFileSync(pluginPath, pluginSrc)

  const skillDir = join(root, "skills/using-superpowers")
  mkdirSync(skillDir, { recursive: true })
  writeFileSync(join(skillDir, "SKILL.md"), "# fixture skill\nEXTREMELY_IMPORTANT fixture body\n")

  if (withHook) {
    const hooksDir = join(root, "hooks")
    mkdirSync(hooksDir, { recursive: true })
    // /bin/sh + a heredoc only: no external binaries needed.
    writeFileSync(
      join(hooksDir, "session-start"),
      "#!/bin/sh\ncat <<'STUBEOF'\n" + stubPayload + "\nSTUBEOF\n",
      { mode: 0o755 }
    )
  }

  if (mex) {
    const mexDir = join(root, ".mex")
    mkdirSync(mexDir, { recursive: true })
    if (mex.lessons !== undefined) writeFileSync(join(mexDir, "lessons.md"), mex.lessons)
  }

  return { root, pluginPath }
}

// Fallback payload for a fixture — the composer is absent, so getBootstrapContent
// takes the pointer + mex path.
async function fallbackText(fixture) {
  const { BeadsSuperpowersPlugin } = await import(fixture.pluginPath)
  const hooks = await BeadsSuperpowersPlugin({ client: {}, directory: fixture.root })
  const out = { messages: [{ info: { role: "user" }, parts: [{ type: "text", text: "hi" }] }] }
  await hooks["experimental.chat.messages.transform"]({}, out)
  return out.messages[0].parts[0].text
}

// --- Scenario A: hook present — primary composer path ---
const fixtureA = buildFixture(true)
const { BeadsSuperpowersPlugin: PluginA } = await import(fixtureA.pluginPath)
assert.strictEqual(typeof PluginA, "function", "BeadsSuperpowersPlugin is exported as a function")
const hooksA = await PluginA({ client: {}, directory: fixtureA.root })

// Test 1: config hook appends the fixture's skills dir, and is idempotent.
const config = {}
await hooksA.config(config)
assert.deepStrictEqual(config.skills.paths, [join(fixtureA.root, "skills")], "config hook appends fixture skills dir")
await hooksA.config(config)
assert.strictEqual(config.skills.paths.length, 1, "config hook is idempotent on a second call")
console.log("PASS: config hook — skills path appended once")

// Test 2: transform injects the composer payload into the first user message once;
// a second call does not double-inject (marker guard). Injected text matches the
// composer output as-is — no prepended bootstrap, no re-wrap.
const output = { messages: [{ info: { role: "user" }, parts: [{ type: "text", text: "hi" }] }] }
await hooksA["experimental.chat.messages.transform"]({}, output)
const firstUserParts = output.messages[0].parts
assert.strictEqual(firstUserParts.length, 2, "transform injects exactly one part")
assert.strictEqual(firstUserParts[0].text, stubPayload, "injected text is the composer output as-is")

await hooksA["experimental.chat.messages.transform"]({}, output)
assert.strictEqual(output.messages[0].parts.length, 2, "second transform call does not double-inject")
console.log("PASS: transform — inject once, marker guard prevents double-injection")

// Test 3 (part 1): compaction hook pushes composer output into output.context.
const compactionOutput = { context: [] }
await hooksA["experimental.session.compacting"]({}, compactionOutput)
assert.strictEqual(compactionOutput.context.length, 1, "compaction pushes exactly one context entry")
assert.strictEqual(compactionOutput.context[0], stubPayload, "compaction pushes composer output as-is")
console.log("PASS: compaction — composer output pushed to context (primary path)")

rmSync(fixtureA.root, { recursive: true, force: true })

// --- Scenario B: hook absent, no .mex/ — policy-free pointer + mex nudge ---
const fixtureB = buildFixture(false, null)
const textB = await fallbackText(fixtureB)
assert.ok(textB.includes("session composer unavailable"), "fallback pointer present when the composer is unreachable")
assert.ok(textB.includes("skill tool"), "fallback still points at the skill tool")
assert.ok(
  !/salience|@type=|BSP_MEM_CEILING/i.test(textB),
  "fallback pointer must not carry memory-selection policy strings"
)
assert.ok(
  textB.includes("No .mex/ found — run the project-init skill to set up mex."),
  "absent .mex/ injects the project-init nudge (bsp_compose_mex parity)"
)
assert.ok(!textB.includes("Durable Knowledge (mex)"), "no mex section header when .mex/ is absent")
console.log("PASS: fallback — pointer + '.mex/ absent' nudge")

rmSync(fixtureB.root, { recursive: true, force: true })

// --- Scenario C: .mex/ present, lessons.md under the cap — header + router + page ---
const lessonsC = "# Lessons\n\n- fixture lesson body\n"
const fixtureC = buildFixture(false, { lessons: lessonsC })
const textC = await fallbackText(fixtureC)
assert.ok(textC.includes("## Durable Knowledge (mex)"), "present .mex/ injects the section header")
assert.ok(
  textC.includes('Router: read .mex/ROUTER.md for task-scoped pages. Retrieval: mex graph scope "<task>".'),
  "present .mex/ injects the router line verbatim"
)
assert.ok(textC.includes(lessonsC.trim()), "lessons.md content is injected")
assert.ok(!textC.includes("No .mex/ found"), "no absent-nudge when .mex/ exists")
assert.ok(!textC.includes("[truncated"), "an under-cap page carries no truncation marker")
console.log("PASS: mex present — header + router line + lessons hot page")

rmSync(fixtureC.root, { recursive: true, force: true })

// --- Scenario D: lessons.md over the 2 KB cap — byte prefix + truncation marker ---
const CAP = 2048
const lessonsD = "x".repeat(CAP + 500) // ASCII: bytes == chars, so the prefix is checkable
const fixtureD = buildFixture(false, { lessons: lessonsD })
const textD = await fallbackText(fixtureD)
assert.ok(
  textD.includes("[truncated — lessons.md exceeds the 2 KB hot-page cap; run mex-curator]"),
  "an over-cap page carries the truncation marker (loss is disclosed, never silent)"
)
assert.ok(textD.includes("x".repeat(CAP)), "the first 2048 bytes of lessons.md are injected")
assert.ok(!textD.includes("x".repeat(CAP + 1)), "nothing past the 2048-byte cap is injected")
console.log("PASS: mex over-cap — 2048-byte prefix plus truncation marker")

rmSync(fixtureD.root, { recursive: true, force: true })

// --- Scenario E: .mex/ present but no lessons.md — router pointer only ---
const fixtureE = buildFixture(false, {})
const textE = await fallbackText(fixtureE)
assert.ok(textE.includes("## Durable Knowledge (mex)"), "header present without a hot page")
assert.ok(textE.includes(".mex/ROUTER.md"), "router pointer present without a hot page")
assert.ok(!textE.includes("No .mex/ found"), "an existing .mex/ never emits the absent-nudge")
console.log("PASS: mex present, no lessons.md — router pointer only")

rmSync(fixtureE.root, { recursive: true, force: true })

console.log("PASS: opencode plugin — config idempotent, inject-once, compaction OK, mex fallback OK")
