/**
 * Tests for pre-bash-block-no-verify.js
 *
 * The hook replaces `npx block-no-verify@1.1.2` (which paid an npm bootstrap
 * plus a registry request on every Bash tool call). It must keep the same
 * blocking rules and fix the one known false positive: a `-n` that belongs
 * to another command in the same shell line (`grep -n`, `head -n`, ...).
 *
 * Run with: node tests/hooks/pre-bash-block-no-verify.test.js
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.join(__dirname, '..', '..');
const script = path.join(repoRoot, 'scripts', 'hooks', 'pre-bash-block-no-verify.js');
const runner = path.join(repoRoot, 'scripts', 'hooks', 'run-with-flags.js');
const hooksJsonPath = path.join(repoRoot, 'hooks', 'hooks.json');

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (err) {
    console.log(`  ✗ ${name}`);
    console.log(`    Error: ${err.message}`);
    failed++;
  }
}

function payload(command) {
  return JSON.stringify({ tool_name: 'Bash', tool_input: { command } });
}

function spawnHook(stdin, envOverrides = {}) {
  const result = spawnSync('node', [script], {
    encoding: 'utf8',
    input: stdin,
    timeout: 10000,
    env: { ...process.env, ...envOverrides },
  });
  return { code: result.status, stdout: result.stdout || '', stderr: result.stderr || '' };
}

function spawnViaRunner(command, envOverrides = {}) {
  const args = [
    runner,
    'pre:bash:block-no-verify',
    'scripts/hooks/pre-bash-block-no-verify.js',
    'minimal,standard,strict',
  ];
  const result = spawnSync('node', args, {
    encoding: 'utf8',
    input: payload(command),
    timeout: 10000,
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: repoRoot, ...envOverrides },
  });
  return { code: result.status, stdout: result.stdout || '', stderr: result.stderr || '' };
}

function loadRun() {
  delete require.cache[require.resolve(script)];
  return require(script).run;
}

function expectBlocked(run, command, mentions) {
  const result = run(payload(command));
  assert.strictEqual(result.exitCode, 2, `expected block for: ${command}`);
  assert.ok(/^BLOCKED:/.test(result.stderr || ''), `expected BLOCKED reason for: ${command}`);
  if (mentions) {
    assert.ok(result.stderr.includes(mentions), `expected reason to mention ${mentions}: ${result.stderr}`);
  }
}

function expectAllowed(run, command) {
  const result = run(payload(command));
  assert.strictEqual(result.exitCode, 0, `expected allow for: ${command} (${result.stderr || ''})`);
  assert.ok(!result.stderr, `expected no stderr for: ${command}`);
}

console.log('\n=== Testing pre-bash-block-no-verify.js ===\n');

console.log('  run() blocks hook bypass:');
test('blocks git commit --no-verify', () => {
  expectBlocked(loadRun(), 'git commit --no-verify -m "wip"', 'git commit');
});
test('blocks git commit -n (short form)', () => {
  expectBlocked(loadRun(), 'git commit -n -m "wip"', 'git commit');
});
test('blocks git commit -nm (combined short flags)', () => {
  expectBlocked(loadRun(), 'git commit -nm "wip"', 'git commit');
});
test('blocks -n placed after the message', () => {
  expectBlocked(loadRun(), 'git commit -m "wip" -n', 'git commit');
});
test('blocks --no-verify on push, merge, cherry-pick, rebase, am', () => {
  const run = loadRun();
  expectBlocked(run, 'git push --no-verify origin main', 'git push');
  expectBlocked(run, 'git merge --no-verify feature', 'git merge');
  expectBlocked(run, 'git cherry-pick --no-verify abc123', 'git cherry-pick');
  expectBlocked(run, 'git rebase --no-verify main', 'git rebase');
  expectBlocked(run, 'git am --no-verify patch.mbox', 'git am');
});
test('blocks core.hooksPath override', () => {
  const run = loadRun();
  expectBlocked(run, 'git -c core.hooksPath=/dev/null commit -m "wip"', 'core.hooksPath');
  expectBlocked(run, 'git -c "core.hooksPath=" commit -m "wip"', 'core.hooksPath');
});
test('blocks when git runs after cd or && in the same line', () => {
  const run = loadRun();
  expectBlocked(run, 'cd /tmp/repo && git commit --no-verify -m "wip"');
  expectBlocked(run, 'cd /tmp/repo; git commit -n -m "wip"');
});
test('blocks --no-verify smuggled through a variable', () => {
  expectBlocked(loadRun(), 'FLAGS="--no-verify"; git commit $FLAGS -m "wip"');
});
test('blocks git commit -n even when an earlier segment ran git push', () => {
  expectBlocked(loadRun(), 'git push origin main && git commit -n -m "wip"', 'git commit');
});
test('blocks on a truncated payload', () => {
  const result = loadRun()(payload('git status'), { truncated: true, maxStdin: 1024 });
  assert.strictEqual(result.exitCode, 2);
  assert.ok(/BLOCKED/.test(result.stderr));
});

console.log('\n  run() allows normal work:');
test('allows plain commands', () => {
  const run = loadRun();
  expectAllowed(run, 'echo hello');
  expectAllowed(run, 'git status');
  expectAllowed(run, 'git commit -m "feat: add thing"');
  expectAllowed(run, 'git push origin main');
});
test('allows -n where it is not --no-verify (push dry-run, merge no-commit)', () => {
  const run = loadRun();
  expectAllowed(run, 'git push -n origin main');
  expectAllowed(run, 'git merge -n feature');
});
test('allows -n that belongs to another command in the same line', () => {
  const run = loadRun();
  expectAllowed(run, 'git commit -m "fix" && grep -n TODO src/app.js');
  expectAllowed(run, 'head -n 5 CHANGELOG.md; git commit -m "docs"');
  expectAllowed(run, 'git commit -m "fix" 2>&1 | tail -n 3');
});
test('allows -n inside a heredoc body of a commit message', () => {
  const command = [
    'git commit -m "$(cat <<\'EOF\'',
    'fix: keep -n out of the guard',
    '',
    'See head -n 1 for context',
    'EOF',
    ')"',
  ].join('\n');
  expectAllowed(loadRun(), command);
});
test('allows commented-out bypass', () => {
  expectAllowed(loadRun(), 'git status # git commit --no-verify');
});
test('allows commands that only mention git in a word', () => {
  const run = loadRun();
  expectAllowed(run, 'digit commit --no-verify');
  expectAllowed(run, 'ls gitlab-runner');
});
test('allows empty or non-JSON input', () => {
  const run = loadRun();
  assert.strictEqual(run('').exitCode, 0);
  assert.strictEqual(run('   ').exitCode, 0);
  assert.strictEqual(run('not json at all').exitCode, 0);
  assert.strictEqual(run(JSON.stringify({ tool_input: {} })).exitCode, 0);
});
test('still scans raw text when JSON has no command field', () => {
  const result = loadRun()(JSON.stringify({ tool_input: { cmd: 'git commit --no-verify' } }));
  assert.strictEqual(result.exitCode, 2);
});

console.log('\n  stdin fallback (direct spawn):');
test('exit 2 with BLOCKED on stderr when blocked', () => {
  const result = spawnHook(payload('git commit --no-verify -m "wip"'));
  assert.strictEqual(result.code, 2);
  assert.ok(result.stderr.includes('BLOCKED'), `stderr: ${result.stderr}`);
});
test('exit 0 and passes the raw input through when allowed', () => {
  const raw = payload('git commit -m "ok"');
  const result = spawnHook(raw);
  assert.strictEqual(result.code, 0);
  assert.strictEqual(result.stdout, raw);
  assert.strictEqual(result.stderr, '');
});

console.log('\n  through run-with-flags.js:');
test('blocks in-process via the flag runner', () => {
  const result = spawnViaRunner('git commit --no-verify -m "wip"');
  assert.strictEqual(result.code, 2, `stderr: ${result.stderr}`);
  assert.ok(result.stderr.includes('BLOCKED'));
});
test('allows via the flag runner', () => {
  const result = spawnViaRunner('git commit -m "ok" && grep -n TODO app.js');
  assert.strictEqual(result.code, 0, `stderr: ${result.stderr}`);
});
test('can be switched off with ECC_DISABLED_HOOKS', () => {
  const result = spawnViaRunner('git commit --no-verify -m "wip"', {
    ECC_DISABLED_HOOKS: 'pre:bash:block-no-verify',
  });
  assert.strictEqual(result.code, 0);
});
test('stays on under the minimal profile', () => {
  const result = spawnViaRunner('git commit --no-verify -m "wip"', { ECC_HOOK_PROFILE: 'minimal' });
  assert.strictEqual(result.code, 2);
});

console.log('\n  hooks.json wiring:');
test('the Bash guard runs this script through run-with-flags with a timeout', () => {
  const hooks = JSON.parse(fs.readFileSync(hooksJsonPath, 'utf8'));
  const entries = hooks.hooks.PreToolUse
    .flatMap(group => (group.matcher === 'Bash' ? group.hooks : []))
    .filter(hook => hook.command.includes('block-no-verify'));
  assert.strictEqual(entries.length, 1, 'exactly one block-no-verify hook');
  const [hook] = entries;
  assert.ok(hook.command.startsWith('node "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-with-flags.js"'), hook.command);
  assert.ok(hook.command.includes('"scripts/hooks/pre-bash-block-no-verify.js"'), hook.command);
  assert.ok(Number.isInteger(hook.timeout) && hook.timeout > 0 && hook.timeout <= 15, 'timeout in seconds, small');
});
test('no plugin hook spawns npx or npm exec per tool call', () => {
  const hooks = JSON.parse(fs.readFileSync(hooksJsonPath, 'utf8'));
  for (const [event, groups] of Object.entries(hooks.hooks)) {
    for (const group of groups) {
      for (const hook of group.hooks) {
        if (hook.type !== 'command') continue;
        assert.ok(!/^\s*(npx|npm\s+exec)\b/.test(hook.command), `${event}: ${hook.command}`);
      }
    }
  }
});

console.log(`\n  Passed: ${passed}`);
console.log(`  Failed: ${failed}\n`);
process.exit(failed > 0 ? 1 : 0);
