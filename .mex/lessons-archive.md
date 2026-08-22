# Lessons — archive

Demoted from the hot page (`.mex/lessons.md`) when it reached its 2 KB cap.
Still true; retrievable via the router, not injected into every session.

- lesson: Claude Code hook payloads carry `agent_type` (= subagent frontmatter `name`) + `agent_id` on every event incl. PreToolUse, but NEVER `model` outside SessionStart — key guards on agent_type, not session model. Hooks fail open: only exit 2 blocks; exit 1 and command-hook timeouts proceed. Evidence: code.claude.com/docs/en/hooks, verified 2026-08-20.
- lesson: Plugin-distributed subagents IGNORE `permissionMode`/`hooks`/`mcpServers` frontmatter; `tools`/`disallowedTools` still apply. Plugin enforcement must live in plugin hooks.json. Evidence: code.claude.com/docs/en/sub-agents, verified 2026-08-20.
- lesson: pipeline-guard's install-skew deny exempts a git checkout (`.git` beside the hook's tree): CLAUDE.md has maintainers symlink the plugin cache at the dev repo, so it is meant to run ahead of the installed root. Evidence: test case skew-a-git-checkout-is-expected-to-run-ahead-and-is-not-denied.
