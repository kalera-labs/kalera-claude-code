# Changelog

All notable changes to **Kalera Claude Code** are documented here.

## [1.4.7] — 2026-09-17

### Changed
- **Hooks**: the `PreToolUse` Bash guard against git hook bypass now runs in-process (`scripts/hooks/pre-bash-block-no-verify.js` via `run-with-flags.js`, hook id `pre:bash:block-no-verify`, profiles `minimal,standard,strict`, `timeout: 10`) instead of `npx block-no-verify@1.1.2`. The npx form paid a full npm bootstrap plus a request to registry.npmjs.org on **every Bash tool call** (measured 1.1-1.4 CPU-s and ~1.8 s wall per call, two runaway instances at 100 % CPU on a loaded machine, and no timeout, so an offline network stalled every call for up to 60 s). The in-process hook measures ~0.03 s. The port keeps upstream's rules (`--no-verify` on commit/push/merge/cherry-pick/rebase/am, `-c core.hooksPath=`, `-n` for commit) and can now be switched off with `ECC_DISABLED_HOOKS` like every other hook.

### Fixed
- **Hooks**: the `-n` (short `--no-verify`) check is scoped to the shell segment that runs `git commit`, so `git commit -m "fix" && grep -n TODO src`, `head -n`, `tail -n`, or a heredoc commit body containing ` -n ` are no longer blocked as hook bypass. Covered by `tests/hooks/pre-bash-block-no-verify.test.js` (26 cases).

## [1.4.6] — 2026-09-10

### Fixed
- **MCP health check**: HTTP `401`/`403` from the anonymous pre-flight probe now count as healthy. OAuth-protected HTTP MCP servers reject that probe by design while the real tool call authenticates with the session's stored token, so the hook was blocking working servers. (Ported from a hot patch that had only lived in the installed plugin copy.)
- **Hooks**: `hooks/hooks.json` no longer carries `$schema` at the top level or `description`/`id` on hook groups. Claude Code 2.1.267 validates plugin hook files and logged `hooks.json: unknown keys "$schema", "description" in hooks.PreToolUse[0], ... and 56 more ignored` at every session start. Hook ids and descriptions moved to `hooks/hooks.meta.json`; `schemas/hooks.schema.json` now rejects those keys so they cannot come back.
- **Munin plugin**: dropped the dead top-level `configuration` block from `plugins/munin-claude-code/hooks/hooks.json` (same Claude Code warning; nothing read it). Mirrors `3d-era/munin-for-agents`.

### Changed
- Marketplace entry for `kalera-claude-code` now declares the real plugin version (was `2.1.0` while `plugin.json` said `1.4.5`; `claude plugin validate` flagged the mismatch).
- `CONTRIBUTING.md` (all locales) and `hooks/README.md` no longer show `description` on hook groups and now document `hooks/hooks.meta.json`.
- `scripts/ci/validate-hooks.js` mirrors Claude Code's top-level allow-list exactly (`description`, `hooks`, `modules`, `surface`) and also checks it when `hooks` is the legacy array form.

## [1.4.5] — 2026-09-05

### Removed
- **MCP**: `github`, `exa`, `sequential-thinking` no longer bundled in `.mcp.json` — `github` duplicates the `gh` CLI required by the toolkit rules, `exa`/`github` collided with user-scope servers (each one spawned twice), and `sequential-thinking` had no recorded usage. Add any of them back per machine with `claude mcp add`.

## [2.0.0-kalera] — 2026-04-04

### Added
- **Munin Memory Plugin** embedded at `plugins/munin-claude-code/` (agents, skills, hooks, MCP config)
- **`install.sh`** — One-command installer with conflict detection + auto-fix, SHA256 integrity verification
- **`README.vi.md`** — Vietnamese translation
- **`Dockerfile`** — Zero-to-install test container
- **Marketplace** `3d-era/kalera-claude-code` with two plugins: `kalera-claude-code` + `munin-claude-code`
- **`--yes` / `--dry-run` / `--verbose` / `--no-verify`** CLI flags for install.sh
- **`trap` cleanup** on EXIT/INT/TERM — prevents orphan temp directories on interrupt
- **Rules backup** — existing `~/.claude/rules/` files backed up as `.kalera.bak` before overwrite

### Removed (Conflicts resolved)
- **MCP**: `memory`, `omega-memory`, `context7`, `playwright` (duplicate — Pa has official versions)
- **Commands**: `tdd`, `plan`, `code-review`, `build-fix`, `e2e`, `skill-create`, `learn`, `sessions`, `save-session`, `resume-session`, and 14 more
- **Agents**: `planner`, `architect`, `chief-of-staff`, `tdd-guide`, `e2e-runner`, `harness-optimizer`, `loop-operator`
- **Skills**: `skill-create`, `eval-harness`, `verification-loop`
- **Hooks**: `session-start`, `pre-compact` (Munin handles these)

### Changed
- **Repo renamed**: `everything-claude-code` → `kalera-claude-code`
- **Upstream remote**: tracks `affaan-m/everything-claude-code` for future updates
- **README**: Rewritten with full credits, Quick Start in 3 steps (Munin account first)
- **CLAUDE.md**: Updated with unified architecture + credits
- **README.vi.md**: Vietnamese translation added
- **Plugin name in marketplace.json**: `everything-claude-code` → `kalera-claude-code`
- **`marketplace` name**: `kalera-cc` → `3d-era/kalera-claude-code` (GitHub repo path)

### Security
- SHA256 pinned integrity check for `curl | bash` install pattern — MITM mitigation
- `trap cleanup EXIT/INT/TERM` — prevents temp directory leaks on Ctrl+C or crash
- `chmod 700` on `mktemp -d` temp directories — explicit permission hardening
- Conflict detection: auto-fixes or warns about duplicate plugin/MCP installations
- E2EE memory: Munin supports end-to-end encrypted storage via Hash Key
- Plugin uninstall errors now captured and displayed (no silent `|| true` swallowing)
- `select` loop guard (max 10 attempts) — prevents infinite loops on invalid input

### Fixed (install.sh)
- Marketplace name: `3d-era/kalera-claude-code` → `kalera-claude-code` (format: `plugin@marketplace-alias`, not `owner/repo`)
- Plugin install name: `everything-claude-code` → `kalera-claude-code` (matches marketplace.json)
- Distinct error messages: rc=2 (not found) / rc=3 (already installed) / other (real failure)
- `git clone` and `mktemp -d` exit codes now validated with explicit error messages
- Munin install: fallback to `munin-claude-code@munin-ecosystem` marketplace if primary fails

---

<!-- upstream ECC changelog below -->

## [1.9.0] - 2026-03-20

### Highlights

- Selective install architecture with manifest-driven pipeline and SQLite state store.
- Language coverage expanded to 10+ ecosystems with 6 new agents and language-specific rules.
- Observer reliability hardened with memory throttling, sandbox fixes, and 5-layer loop guard.
- Self-improving skills foundation with skill evolution and session adapters.
