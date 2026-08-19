/**
 * beads-superpowers plugin for OpenCode.ai
 *
 * Upstream-parity base: obra/superpowers .opencode/plugins/superpowers.js (v6.1.1)
 * — bootstrap injected via message transform into the first user message
 * (upstream #750/#894), module-level caching (#1202), skills auto-registered via
 * the config hook. Install is the git-backed package spec in opencode.json
 * (see ../INSTALL.md); everything resolves repo-relative — no fallback roots.
 *
 * Fork delta (minimal, policy-free): bootstrap content comes from the canonical
 * composer `hooks/session-start --emit-plain` (using-superpowers bootstrap +
 * composed <beads-context>); on failure it falls back to a minimal pointer plus
 * the durable-knowledge (mex) hot page — NEVER the full bd prime dump. Plus a
 * compaction re-injection hook. All selection/degradation policy lives in
 * hooks/session-start; the anti-fork guard is
 * tests/hooks/test-opencode-injection.mjs.
 */

import path from 'path';
import { execSync } from 'child_process';
import { existsSync, readFileSync } from 'fs';
import { fileURLToPath } from 'url';

// Byte cap on the injected .mex/lessons.md hot page — the product-wide constant,
// mirroring BSP_MEX_CEILING in hooks/session-start. Everything past the cap stays
// reachable through the router, so clipping is lossless at the store level, but
// never silent: a clipped page carries the truncation marker below.
const MEX_CEILING = 2048;

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Module-level cache for bootstrap content (upstream #1202 pattern).
// undefined = not yet loaded; a string = cached payload (composed or pointer).
let _bootstrapCache = undefined;

export const BeadsSuperpowersPlugin = async ({ client, directory }) => {
  const packageRoot = path.resolve(__dirname, '../..');
  const skillsDir = path.join(packageRoot, 'skills');

  // Exec the canonical composer. Returns null on failure OR on the composer's
  // event-dedup yielding an empty rapid re-run — a real payload always carries
  // the <EXTREMELY_IMPORTANT> injection marker.
  const composeBootstrap = () => {
    try {
      const text = execSync(
        `"${path.join(packageRoot, 'hooks/session-start')}" --emit-plain 2>/dev/null`,
        { encoding: 'utf8', timeout: 10000 }
      ).trim();
      return text.includes('EXTREMELY_IMPORTANT') ? text : null;
    } catch {
      return null;
    }
  };

  // Durable knowledge (mex) for the fallback payload — the JS mirror of
  // bsp_compose_mex in hooks/session-start. File reads only: routing and ranking
  // are the agent's job at retrieval time, not session-start policy. Independent
  // of bd — .mex/ is a store on disk, not a beads feature.
  const composeMex = () => {
    const mexDir = path.join(directory ?? process.cwd(), '.mex');
    if (!existsSync(mexDir)) {
      // In-context (not stderr): the agent is the actor who can fix this.
      return 'No .mex/ found — run the project-init skill to set up mex.';
    }
    const lines = [
      '## Durable Knowledge (mex)',
      '',
      'Router: read .mex/ROUTER.md for task-scoped pages. Retrieval: mex graph scope "<task>".',
    ];
    let page;
    try {
      // Buffer, not string — a UTF-8 page must clip on the BYTE cap.
      page = readFileSync(path.join(mexDir, 'lessons.md'));
    } catch {
      return lines.join('\n'); // no hot page: router pointer only
    }
    if (page.length === 0) return lines.join('\n'); // empty page: no empty block
    lines.push('', page.subarray(0, MEX_CEILING).toString('utf8'));
    // The marker is the loss disclosure — a clipped page must never look complete.
    if (page.length > MEX_CEILING) {
      lines.push('[truncated — lessons.md exceeds the 2 KB hot-page cap; run mex-curator]');
    }
    return lines.join('\n');
  };

  const getBootstrapContent = () => {
    if (_bootstrapCache !== undefined) return _bootstrapCache;

    const composed = composeBootstrap();
    if (composed) {
      _bootstrapCache = composed;
      return _bootstrapCache;
    }

    // Policy-free pointer fallback (composer missing/failed). Wrapped in the
    // marker so the transform guard below stays idempotent.
    _bootstrapCache = [
      '<EXTREMELY_IMPORTANT>',
      'beads-superpowers: session composer unavailable in this environment.',
      'Load skills via the skill tool (start: using-superpowers).',
      composeMex(),
      '</EXTREMELY_IMPORTANT>',
    ].filter(Boolean).join('\n');
    return _bootstrapCache;
  };

  return {
    // Upstream: inject the skills path into live config so OpenCode discovers
    // the bundled skills without symlinks or config edits.
    config: async (config) => {
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(skillsDir)) {
        config.skills.paths.push(skillsDir);
      }
    },

    // Upstream: inject bootstrap into the first user message of each session.
    // Fires on every agent step; the cache + marker guard keep it idempotent.
    'experimental.chat.messages.transform': async (_input, output) => {
      const bootstrap = getBootstrapContent();
      if (!bootstrap || !output.messages.length) return;
      const firstUser = output.messages.find(m => m.info.role === 'user');
      if (!firstUser || !firstUser.parts.length) return;
      if (firstUser.parts.some(p => p.type === 'text' && p.text.includes('EXTREMELY_IMPORTANT'))) return;
      const ref = firstUser.parts[0];
      firstUser.parts.unshift({ ...ref, type: 'text', text: bootstrap });
    },

    // Fork delta: compaction resilience — re-compose fresh beads context after
    // context-window compaction (beads state has moved on; a stale cache is
    // also promoted here if the composer was briefly unavailable at startup).
    'experimental.session.compacting': async (_input, output) => {
      const fresh = composeBootstrap();
      if (fresh) _bootstrapCache = fresh;
      output.context.push(fresh || 'beads-superpowers is installed. Run skills via the skill tool.');
    },
  };
};
