#!/usr/bin/env node
// graph-lint.mjs — validate the bead plan graph rooted at an initiative epic.
// The bead graph is the plan of record, so it has to be well-formed before an
// implementation session consumes it. Exit 0 valid, 1 invalid (one line per
// violation on stderr, each naming the offending bead id and field), 2 usage.
//
// Field shapes are the captured `bd list --json` shapes, not guesses:
// `labels`, `metadata` and `dependencies` are omitted entirely when empty,
// issue-level `metadata` is an already-parsed object, and
// `dependencies[].depends_on_id` is the target of the edge — for a parent-child
// edge, the parent. See .internal/research/2026-08-19-bd-json-shape.md.
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const BSP_PIPELINE_VERSION = "0.19.0"; // synced by bump-version.sh

// The root this script was loaded from: the version file is read relative to
// it, so a copy under another root is judged against that root, not against
// wherever it was invoked. The manifest's hashed files are NOT read from here —
// they belong to the anchor's attested target (see the record block below).
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
// Fixed spellings, never through an env var: the installer, the hooks and the
// gates resolve their environment in four different process trees, and a
// writer/verifier divergence would read as record-absent — a hard deny (SEC-R4).
const ANCHOR = join(homedir(), ".agents", "beads-superpowers");
const RECORD_PATH = join(homedir(), ".local", "state", "beads-superpowers", "record.json");

const USAGE =
  "usage: graph-lint.mjs --initiative <bead-id> --state <file> [--roster <file>] [--tier-map <file>] [--require-stamps]";

function usage(message) {
  if (message) console.error(`ERROR: ${message}`);
  console.error(USAGE);
  process.exit(2);
}

// --- arguments --------------------------------------------------------------
// --roster and --tier-map default to the great_cto bundle root and exist so the
// test suite never needs a great_cto install.
const args = {
  initiative: null,
  state: null,
  roster: join(homedir(), ".agents", "great_cto", "scripts", "agent-roster.mjs"),
  "tier-map": join(homedir(), ".agents", "great_cto", "shared", "tier-map.json"),
  "require-stamps": false,
};
const BOOLEAN_FLAGS = new Set(["require-stamps"]);
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const flag = argv[i];
  const key = flag.startsWith("--") ? flag.slice(2) : "";
  if (!Object.prototype.hasOwnProperty.call(args, key)) usage(`unknown flag '${flag}'`);
  if (BOOLEAN_FLAGS.has(key)) {
    args[key] = true;
    continue;
  }
  const value = argv[++i];
  if (value === undefined) usage(`flag '${flag}' needs a value`);
  args[key] = value;
}
if (!args.initiative || !args.state) usage("--initiative and --state are both required");

// --- inputs -----------------------------------------------------------------

function readJson(path, label) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    usage(`cannot read ${label} '${path}': ${e.code ?? e.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    usage(`${label} '${path}' is not valid JSON: ${e.message}`);
  }
}

const state = readJson(args.state, "state file");
if (!Array.isArray(state)) {
  usage(`state file '${args.state}' is not a JSON array — capture it with 'bd list --all -n 0 --json'`);
}

let roster;
try {
  roster = await import(pathToFileURL(args.roster).href);
} catch (e) {
  usage(`cannot load roster '${args.roster}': ${e.code ?? e.message}`);
}
const REVIEW_AGENTS = roster.REVIEW_AGENTS;
const IMPLEMENTATION_AGENTS = roster.IMPLEMENTATION_AGENTS;
if (!Array.isArray(REVIEW_AGENTS) || !Array.isArray(IMPLEMENTATION_AGENTS)) {
  usage(`roster '${args.roster}' must export REVIEW_AGENTS and IMPLEMENTATION_AGENTS arrays`);
}

const tierMap = readJson(args["tier-map"], "tier-map");
const TIERS = Object.keys(tierMap?.tiers ?? {});
if (TIERS.length === 0) usage(`tier-map '${args["tier-map"]}' has no 'tiers' object`);

// --- violations -------------------------------------------------------------
// Collected, never thrown: a lint that stops at the first violation makes the
// reader run it once per defect.

const violations = [];
const violation = (id, field, message) => violations.push(`${id}: ${field}: ${message}`);
function report(ok) {
  if (violations.length > 0) {
    for (const line of violations) console.error(line);
    process.exit(1);
  }
  console.log(ok);
  process.exit(0);
}

// --- self-checks: version pin and integrity record ---------------------------
// Both run before any graph check, because the initiative-not-found path
// reports and exits: a lint whose own root is skewed or unpinned must say so
// whatever the graph looks like. There is no warning channel — every failure
// here is a violation, so every failure is exit 1.

let rootVersion = null;
try {
  rootVersion = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).version;
} catch {
  // An unreadable version file reads as a mismatch: it cannot prove the pin.
}
if (rootVersion !== BSP_PIPELINE_VERSION) {
  violation(
    "graph-lint",
    "version",
    `script pins ${BSP_PIPELINE_VERSION} but root '${ROOT}' reports '${rootVersion ?? "(unreadable)"}'`,
  );
}

// D3 record-binding semantics, identical to the bash `verify_record`:
//   1. presence is lstat on the anchor entry itself — a dangling symlink is
//      PRESENT, so its record check applies and fails closed on the missing
//      target rather than silently skipping;
//   2. the record is selected by anchor path, and the anchor's canonical target
//      must equal record.target — a mismatch is a repoint, reported as one;
//   3. hashes are verified over the files under record.target, the attested
//      root, never under this script's own root;
//   4. a root outside record.target is a repo-relative/dev invocation —
//      supported, not denied — and says so on stderr while still doing 1-3.
// No anchor at all means no anchor claim to verify: a dev clone run in place,
// which is this repo's own case.

const canonical = (path) => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};
const anchorPresent = () => {
  try {
    lstatSync(ANCHOR);
    return true;
  } catch {
    return false;
  }
};
const inside = (path, root) => path === root || path.startsWith(root + sep);

if (anchorPresent()) {
  let record = null;
  try {
    record = JSON.parse(readFileSync(RECORD_PATH, "utf8"));
  } catch (e) {
    violation(
      "graph-lint",
      "record",
      `anchor '${ANCHOR}' exists but its integrity record '${RECORD_PATH}' is absent or unreadable: ${e.code ?? e.message}`,
    );
  }
  // The target the record attests, canonicalised where it resolves so the two
  // sides of the comparison are spelled the same way.
  const declared = typeof record?.target === "string" && record.target !== "" ? record.target : null;
  const target = declared === null ? null : (canonical(declared) ?? declared);
  const anchorTarget = canonical(ANCHOR);
  // The record is selected BY ANCHOR PATH (semantics 2), so a record naming a
  // different anchor describes some other install and attests nothing about
  // this one: unreadable, which is the same deny as absent. Checked first and
  // reported as itself, exactly as the bash verify_record does — a record the
  // hook rejects must not be one the lint accepts.
  const recordedAnchor = typeof record?.anchor === "string" ? record.anchor : null;
  if (record && recordedAnchor !== ANCHOR) {
    violation(
      "graph-lint",
      "record",
      `record '${RECORD_PATH}' does not describe anchor '${ANCHOR}' (it records anchor '${recordedAnchor ?? "(unset)"}') — treat it as unreadable`,
    );
  } else if (record && anchorTarget === null) {
    violation(
      "graph-lint",
      "record",
      `anchor '${ANCHOR}' does not resolve — the record attests '${declared ?? "(unset)"}', which is unreachable`,
    );
  } else if (record && target === null) {
    violation("graph-lint", "record", `record '${RECORD_PATH}' names no 'target' for anchor '${ANCHOR}'`);
  } else if (record && anchorTarget !== target) {
    violation(
      "graph-lint",
      "record",
      `anchor '${ANCHOR}' resolves to '${anchorTarget}' but the record attests '${target}' — the anchor was repointed`,
    );
  } else if (record) {
    // The anchor and the record agree, so the attested root is known and the
    // remaining checks read from it.
    if (!inside(canonical(ROOT) ?? ROOT, target)) {
      console.error(
        `graph-lint: record: running unpinned copy (not the anchored install) — root '${ROOT}' is outside the attested target '${target}'`,
      );
    }
    const posture = record.posture;
    if (posture === "manifest-backed") {
      const hashes = record.hashes;
      if (hashes === null || typeof hashes !== "object" || Object.keys(hashes).length === 0) {
        violation("graph-lint", "record", `manifest-backed record '${RECORD_PATH}' carries no 'hashes' map`);
      } else {
        for (const [relative, want] of Object.entries(hashes)) {
          let got = null;
          try {
            got = createHash("sha256").update(readFileSync(join(target, relative))).digest("hex");
          } catch {
            // An unreadable gate file cannot match its recorded hash.
          }
          if (got !== want) {
            violation(
              "graph-lint",
              "record",
              `hash mismatch for '${relative}' under target '${target}': recorded ${want}, found ${got ?? "(unreadable)"}`,
            );
          }
        }
      }
    } else if (posture === "dev-clone-advisory") {
      console.error(
        `graph-lint: record: advisory (unpinned root) — posture 'dev-clone-advisory' for anchor '${ANCHOR}'`,
      );
    } else {
      violation(
        "graph-lint",
        "record",
        `record '${RECORD_PATH}' declares neither posture: found '${posture ?? "(unset)"}'`,
      );
    }
  }
}

// --- the initiative bead (check 1) ------------------------------------------

const byId = new Map(state.map((issue) => [issue.id, issue]));
const initiative = byId.get(args.initiative);
if (!initiative) {
  violation(args.initiative, "id", `initiative bead not found in state file '${args.state}'`);
  report();
}
if (initiative.issue_type !== "epic") {
  violation(initiative.id, "issue_type", `the initiative bead must be an epic, found '${initiative.issue_type}'`);
}
// D4: the label is asserted on the named bead only. `bd create` inherits labels
// from the parent, so descendants may legitimately carry it too — do not add a
// uniqueness check here.
if (!(initiative.labels ?? []).includes("initiative")) {
  violation(initiative.id, "labels", "the initiative bead must carry the 'initiative' label");
}

// D6 under --require-stamps: the initiative sits outside the member walk below,
// so its stamp is checked here, against it directly. The contract's cwd
// precondition is the repo root, so the plan resolves against the cwd —
// existence and in-repo resolution, not merely a '.md' suffix (R2-005).
if (args["require-stamps"]) {
  const planPath = (initiative.metadata ?? {}).plan_path;
  const field = "metadata.plan_path";
  const resolved = typeof planPath === "string" ? resolve(process.cwd(), planPath) : null;
  if (typeof planPath !== "string" || planPath === "") {
    violation(initiative.id, field, "--require-stamps: the initiative bead carries no plan_path");
  } else if (!planPath.endsWith(".md")) {
    violation(initiative.id, field, `--require-stamps: '${planPath}' does not name a markdown file`);
  } else if (!resolved.startsWith(process.cwd() + sep)) {
    violation(initiative.id, field, `--require-stamps: '${planPath}' resolves outside '${process.cwd()}'`);
  } else if (!existsSync(resolved)) {
    violation(initiative.id, field, `--require-stamps: '${planPath}' does not exist under '${process.cwd()}'`);
  }
}

// --- the graph rooted at the initiative -------------------------------------

const parentsOf = (issue) =>
  (issue.dependencies ?? []).filter((d) => d.type === "parent-child").map((d) => d.depends_on_id);

const childrenOf = new Map();
for (const issue of state) {
  for (const parent of parentsOf(issue)) {
    if (!childrenOf.has(parent)) childrenOf.set(parent, []);
    childrenOf.get(parent).push(issue.id);
  }
}

// Transitive descendants of the initiative over parent-child edges. Beads
// outside this set belong to other initiatives and are not judged.
const members = new Set();
const queue = [initiative.id];
const seen = new Set([initiative.id]);
while (queue.length > 0) {
  for (const child of childrenOf.get(queue.shift()) ?? []) {
    if (seen.has(child)) continue;
    seen.add(child);
    members.add(child);
    queue.push(child);
  }
}
const memberIssues = [...members].map((id) => byId.get(id));
const epics = memberIssues.filter((i) => i.issue_type === "epic");
const tasks = memberIssues.filter((i) => i.issue_type === "task");
const epicIds = new Set(epics.map((i) => i.id));

// --- epics (checks 2 and 3) -------------------------------------------------

for (const epic of epics) {
  if (!/^## Success Criteria\s*$/m.test(epic.description ?? "")) {
    violation(epic.id, "description", "epic description has no '## Success Criteria' heading");
  }
  const reviewers = (epic.metadata ?? {}).reviewers;
  if (!Array.isArray(reviewers) || reviewers.length === 0) {
    violation(epic.id, "metadata.reviewers", "epic has no reviewers — expected a non-empty array of REVIEW_AGENTS members");
    continue;
  }
  for (const reviewer of reviewers) {
    if (!REVIEW_AGENTS.includes(reviewer)) {
      violation(epic.id, "metadata.reviewers", `'${reviewer}' is not a member of REVIEW_AGENTS`);
    }
  }
}

// --- D5 canonical metadata.paths ---------------------------------------------
// The rejection rules are the contract text shared with great_cto, implemented
// here byte-exact: no normalization pass, because a path the planner cannot
// spell canonically is a defect to fix at the plan, not something for the lint
// to repair. Duplicate detection belongs to the caller — it needs the whole
// array. Overlap (two claims overlap when either is a path-component prefix of
// the other, directory claims ending in '/') is the consumer's grouping rule,
// not a rejection rule, so it is not checked here.

function canonicalPathViolation(entry) {
  if (typeof entry !== "string" || entry === "") return "is not a non-empty string";
  if (entry.includes("\\")) return "uses a backslash — forward slashes only";
  if (entry.startsWith("/")) return "is not repository-relative (leading '/')";
  if (entry.startsWith("./")) return "is not repository-relative (leading './')";
  const segments = entry.split("/");
  const directoryClaim = segments[segments.length - 1] === "";
  if (directoryClaim) segments.pop();
  if (segments.includes("")) return "has an empty path segment";
  if (segments.includes("..")) return "has a '..' segment";
  if (segments.includes(".")) return "has a '.' segment";
  // The trailing slash is the directory claim, so where the entry already
  // exists the filesystem decides the 'if and only if'. A path the task will
  // create does not exist yet and cannot be judged either way.
  let stats = null;
  try {
    stats = statSync(resolve(process.cwd(), entry));
  } catch {
    return null;
  }
  if (stats.isDirectory() && !directoryClaim) return "names an existing directory but has no trailing '/'";
  if (!stats.isDirectory() && directoryClaim) return "has a trailing '/' but does not name a directory";
  return null;
}

// --- tasks (checks 4, 5, 6 and the parent half of 7) ------------------------

for (const task of tasks) {
  if (!/^## Acceptance Criteria\s*$/m.test(task.description ?? "")) {
    violation(task.id, "description", "task description has no '## Acceptance Criteria' heading");
  }
  const metadata = task.metadata ?? {};
  if (!IMPLEMENTATION_AGENTS.includes(metadata.implementation_agent)) {
    violation(
      task.id,
      "metadata.implementation_agent",
      `'${metadata.implementation_agent ?? "(unset)"}' is not a member of IMPLEMENTATION_AGENTS`,
    );
  }
  if (!TIERS.includes(metadata.tier)) {
    violation(task.id, "metadata.tier", `'${metadata.tier ?? "(unset)"}' is not a tier of the tier-map`);
  }
  for (const parent of parentsOf(task)) {
    if (!epicIds.has(parent)) {
      violation(task.id, "parent", `'${parent}' is not an epic of initiative ${initiative.id}`);
    }
  }
  if (!args["require-stamps"]) continue;
  const paths = metadata.paths;
  if (!Array.isArray(paths) || paths.length === 0) {
    violation(task.id, "metadata.paths", "--require-stamps: task carries no paths — expected a non-empty array");
    continue;
  }
  const seen = new Set();
  for (const entry of paths) {
    const reason = canonicalPathViolation(entry);
    if (reason) {
      violation(task.id, "metadata.paths", `--require-stamps: '${entry}' ${reason}`);
    } else if (seen.has(entry)) {
      violation(task.id, "metadata.paths", `--require-stamps: '${entry}' is a duplicate entry`);
    } else {
      seen.add(entry);
    }
  }
}

// --- no dependency cycle (check 7) ------------------------------------------
// blocks edges only: parent-child edges are a tree by construction and are not
// cycle candidates. Edges leaving the initiative's graph are out of scope.

const blocksOut = new Map(
  memberIssues.map((i) => [
    i.id,
    (i.dependencies ?? [])
      .filter((d) => d.type === "blocks" && members.has(d.depends_on_id))
      .map((d) => d.depends_on_id),
  ]),
);
const WHITE = 0, GRAY = 1, BLACK = 2;
const colour = new Map(memberIssues.map((i) => [i.id, WHITE]));
const stack = [];
const cycles = [];
function walk(id) {
  colour.set(id, GRAY);
  stack.push(id);
  for (const next of blocksOut.get(id) ?? []) {
    if (colour.get(next) === GRAY) {
      // Record the back edge and keep walking. Stopping at the first cycle
      // would report one defect per run and hide the rest.
      cycles.push({ at: id, loop: [...stack.slice(stack.indexOf(next)), next] });
    } else if (colour.get(next) === WHITE) {
      walk(next);
    }
  }
  stack.pop();
  colour.set(id, BLACK);
}
for (const issue of memberIssues) {
  if (colour.get(issue.id) === WHITE) walk(issue.id);
}
// One line per cycle, not per bead: naming every bead in a loop would repeat a
// single defect. Every cycle contains at least one back edge, so every cycle is
// reported.
for (const cycle of cycles) {
  violation(cycle.at, "dependencies", `blocks dependency cycle: ${cycle.loop.join(" -> ")}`);
}

report(`graph-lint OK: ${initiative.id} (${epics.length} epics, ${tasks.length} tasks)`);
