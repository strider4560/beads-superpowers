// Fixture roster for tests/pipeline/test-graph-lint.sh (controller decision D11).
// Deliberately the plan's short lists, NOT the real great_cto roster, so the
// suite never depends on a great_cto install. Shape mirrors the real
// <bundle-root>/scripts/agent-roster.mjs: two frozen exported arrays.
export const REVIEW_AGENTS = Object.freeze([
  "architect",
  "code-reviewer",
  "qa-engineer",
  "security-officer",
]);
export const IMPLEMENTATION_AGENTS = Object.freeze(["senior-dev"]);
