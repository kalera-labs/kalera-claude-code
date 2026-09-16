#!/usr/bin/env node
/**
 * Block git hook bypass (PreToolUse: Bash)
 *
 * In-process port of the `block-no-verify` npm package (MIT, tupe12334).
 * The plugin used to run `npx block-no-verify@1.1.2` on every Bash tool
 * call, which cost about 1.3 CPU-seconds, 1.8 s of wall time and one
 * request to registry.npmjs.org per call. Running the same check here
 * through run-with-flags.js costs a few milliseconds and works offline.
 *
 * Rules (same as upstream):
 *   - a literal `--no-verify` anywhere in a command that invokes
 *     git commit | push | merge | cherry-pick | rebase | am is blocked
 *   - `-c core.hooksPath=...` on such a command is blocked
 *   - `-n` (short for --no-verify) is blocked for `git commit`
 *
 * One deliberate difference: the `-n` check only looks at the shell
 * segment (split on ; && || | newline &) that contains `git commit`, so
 * `grep -n`, `head -n`, `tail -n` elsewhere in the same line no longer
 * trip the guard.
 *
 * Exit codes: 0 = allow, 2 = block, 1 = internal error.
 */

'use strict';

const MAX_STDIN = 1024 * 1024;

const GIT_COMMANDS_WITH_NO_VERIFY = ['commit', 'push', 'merge', 'cherry-pick', 'rebase', 'am'];
const GENERIC_COMMAND_KEYS = ['command', 'cmd', 'input', 'shell', 'script'];
const VALID_BEFORE_GIT = ' \t\n\r;&|$`(<{!"\'/.~\\';
const SEGMENT_SEPARATOR = /\|\||&&|;|\||\n|&(?!&)/;
const NO_VERIFY_LONG = /--no-verify\b/;
const HOOKS_PATH_OVERRIDE = /-c\s+["']?core\.hooksPath\s*=/;
const COMMIT_SHORT_FLAG = /\s-n(?:\s|$)|\s-n[a-zA-Z]/;

function isInComment(input, idx) {
  const lineStart = input.lastIndexOf('\n', idx - 1) + 1;
  const before = input.slice(lineStart, idx);
  for (let i = 0; i < before.length; i++) {
    if (before.charAt(i) === '#') {
      const prev = i > 0 ? before.charAt(i - 1) : '';
      if (prev !== '$' && prev !== '\\') return true;
    }
  }
  return false;
}

function findGit(input, start) {
  let pos = start;
  while (pos < input.length) {
    const idx = input.indexOf('git', pos);
    if (idx === -1) return null;
    const isExe = input.slice(idx + 3, idx + 7).toLowerCase() === '.exe';
    const len = isExe ? 7 : 3;
    const after = input[idx + len] || ' ';
    if (!/[\s"']/.test(after)) {
      pos = idx + 1;
      continue;
    }
    const before = idx > 0 ? input[idx - 1] : ' ';
    if (VALID_BEFORE_GIT.includes(before)) return { idx, len };
    pos = idx + 1;
  }
  return null;
}

/**
 * Returns the first git subcommand (from GIT_COMMANDS_WITH_NO_VERIFY) that
 * the input invokes, or null. Ported unchanged from upstream.
 */
function detectGitCommand(input) {
  let start = 0;
  while (start < input.length) {
    const git = findGit(input, start);
    if (!git) return null;
    if (isInComment(input, git.idx)) {
      start = git.idx + git.len;
      continue;
    }
    for (const cmd of GIT_COMMANDS_WITH_NO_VERIFY) {
      const cmdIdx = input.indexOf(cmd, git.idx + git.len);
      if (cmdIdx === -1) continue;
      const before = cmdIdx > 0 ? input[cmdIdx - 1] : ' ';
      const after = input[cmdIdx + cmd.length] || ' ';
      if (!/\s/.test(before)) continue;
      if (!/[\s;&#|>)\]}"']/.test(after) && after !== '') continue;
      if (/[;|]/.test(input.slice(git.idx + git.len, cmdIdx))) continue;
      if (isInComment(input, cmdIdx)) continue;
      return cmd;
    }
    start = git.idx + git.len;
  }
  return null;
}

/**
 * `-n` means --no-verify only for `git commit`, and only when it sits in the
 * same shell segment as that commit (not in a piped `grep -n`, a heredoc
 * line, or a later command).
 */
function hasCommitShortFlag(input) {
  return input
    .split(SEGMENT_SEPARATOR)
    .some(segment => detectGitCommand(segment) === 'commit' && COMMIT_SHORT_FLAG.test(segment));
}

function checkCommand(command) {
  const gitCommand = detectGitCommand(command);
  if (!gitCommand) return { blocked: false };

  if (NO_VERIFY_LONG.test(command)) {
    return {
      blocked: true,
      gitCommand,
      reason: `BLOCKED: --no-verify flag is not allowed with git ${gitCommand}. Git hooks must not be bypassed.`,
    };
  }

  if (hasCommitShortFlag(command)) {
    return {
      blocked: true,
      gitCommand: 'commit',
      reason: 'BLOCKED: --no-verify flag is not allowed with git commit. Git hooks must not be bypassed.',
    };
  }

  if (HOOKS_PATH_OVERRIDE.test(command)) {
    return {
      blocked: true,
      gitCommand,
      reason: `BLOCKED: Overriding core.hooksPath is not allowed with git ${gitCommand}. Git hooks must not be bypassed.`,
    };
  }

  return { blocked: false, gitCommand };
}

function commandFromObject(obj) {
  if (!obj || typeof obj !== 'object') return null;
  const toolInput = obj.tool_input;
  if (toolInput && typeof toolInput === 'object' && typeof toolInput.command === 'string') {
    return toolInput.command;
  }
  for (const key of GENERIC_COMMAND_KEYS) {
    if (typeof obj[key] === 'string') return obj[key];
  }
  return null;
}

/**
 * Claude Code sends {"tool_input":{"command":"..."}}. Anything else is
 * scanned as plain text, which is what upstream did and keeps the guard
 * useful even if the payload shape ever changes.
 */
function extractCommand(inputOrRaw) {
  if (inputOrRaw && typeof inputOrRaw === 'object') {
    return commandFromObject(inputOrRaw) ?? '';
  }
  const raw = String(inputOrRaw ?? '');
  const trimmed = raw.trim();
  if (!trimmed) return '';
  if (!trimmed.startsWith('{')) return raw;

  let parsed;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return raw;
  }
  const command = commandFromObject(parsed);
  return command === null ? raw : command;
}

/**
 * Exportable run() for in-process execution via run-with-flags.js.
 */
function run(inputOrRaw, options = {}) {
  if (options.truncated) {
    return {
      exitCode: 2,
      stderr:
        `BLOCKED: Hook input exceeded ${options.maxStdin || MAX_STDIN} bytes; ` +
        'refusing to check a truncated command for git hook bypass. ' +
        'Split the command into smaller steps.',
    };
  }

  try {
    const result = checkCommand(extractCommand(inputOrRaw));
    return result.blocked ? { exitCode: 2, stderr: result.reason } : { exitCode: 0 };
  } catch (err) {
    return { exitCode: 1, stderr: `[Hook] block-no-verify error: ${err.message}` };
  }
}

module.exports = { run, checkCommand, detectGitCommand, extractCommand, GIT_COMMANDS_WITH_NO_VERIFY };

// Stdin fallback for direct execution (spawnSync path or manual runs).
if (require.main === module) {
  let raw = '';
  let truncated = /^(1|true|yes)$/i.test(String(process.env.ECC_HOOK_INPUT_TRUNCATED || ''));

  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    if (raw.length < MAX_STDIN) {
      const remaining = MAX_STDIN - raw.length;
      raw += chunk.substring(0, remaining);
      if (chunk.length > remaining) truncated = true;
    } else {
      truncated = true;
    }
  });

  process.stdin.on('end', () => {
    const result = run(raw, {
      truncated,
      maxStdin: Number(process.env.ECC_HOOK_INPUT_MAX_BYTES) || MAX_STDIN,
    });

    if (result.stderr) {
      process.stderr.write(result.stderr + '\n');
    }
    if (result.exitCode !== 0) {
      process.exit(result.exitCode);
    }
    process.stdout.write(raw);
  });
}
