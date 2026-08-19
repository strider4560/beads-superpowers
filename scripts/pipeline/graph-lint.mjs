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
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const USAGE =
  "usage: graph-lint.mjs --initiative <bead-id> --state <file> [--roster <file>] [--tier-map <file>]";

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
};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const flag = argv[i];
  const key = flag.startsWith("--") ? flag.slice(2) : "";
  if (!Object.prototype.hasOwnProperty.call(args, key)) usage(`unknown flag '${flag}'`);
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
