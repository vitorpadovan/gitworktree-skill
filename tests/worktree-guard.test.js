// node --test tests/worktree-guard.test.js
const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { reasonFor } = require('../hooks/worktree-guard.js');

const bash = (command) => ({ tool_name: 'Bash', tool_input: { command } });

test('pede confirmação para git worktree add, inclusive com -C e encadeado', () => {
  assert.ok(reasonFor(bash('git worktree add .worktrees/x -b claude/x')));
  assert.ok(reasonFor(bash('git -C "C:\\repos\\loja" worktree add "C:\\repos\\loja\\.worktrees\\x" -b x main')));
  assert.ok(reasonFor(bash('git fetch && git worktree add ../x')));
  assert.ok(reasonFor({ tool_name: 'PowerShell', tool_input: { command: 'git worktree add .worktrees/x' } }));
});

test('não interfere em comandos de leitura ou remoção', () => {
  assert.equal(reasonFor(bash('git worktree list --porcelain')), null);
  assert.equal(reasonFor(bash('git worktree remove .worktrees/x')), null);
  assert.equal(reasonFor(bash('git status')), null);
  assert.equal(reasonFor(bash('echo worktree add')), null);
});

test('EnterWorktree só pede confirmação quando cria', () => {
  assert.ok(reasonFor({ tool_name: 'EnterWorktree', tool_input: { name: 'feat-x' } }));
  assert.ok(reasonFor({ tool_name: 'EnterWorktree', tool_input: {} }));
  assert.equal(reasonFor({ tool_name: 'EnterWorktree', tool_input: { path: 'C:\\repos\\loja\\.worktrees\\x' } }), null);
});

test('subagente só pede confirmação com isolation "worktree"', () => {
  assert.ok(reasonFor({ tool_name: 'Agent', tool_input: { prompt: 'x', isolation: 'worktree' } }));
  assert.equal(reasonFor({ tool_name: 'Agent', tool_input: { prompt: 'x' } }), null);
});

test('como processo, devolve permissionDecision "ask" ou nada', () => {
  const script = path.join(__dirname, '..', 'hooks', 'worktree-guard.js');
  const run = (payload) => execFileSync('node', [script], { input: JSON.stringify(payload), encoding: 'utf8' });

  const out = JSON.parse(run(bash('git worktree add x')));
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(out.hookSpecificOutput.permissionDecision, 'ask');

  assert.equal(run(bash('ls')), '');
  assert.equal(execFileSync('node', [script], { input: 'não é json', encoding: 'utf8' }), '');
});
