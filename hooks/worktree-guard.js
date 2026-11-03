#!/usr/bin/env node
// PreToolUse do Claude Code: pede confirmação antes de qualquer chamada que crie um git worktree.
// Cobre `git ... worktree add` em Bash/PowerShell, EnterWorktree com `name` (EnterWorktree com
// `path` só entra num worktree existente) e subagentes com isolation "worktree".

const WORKTREE_ADD = /\bgit\b[^\n;|&]*\bworktree\s+add\b/;

function reasonFor({ tool_name: tool, tool_input: input = {} }) {
  if ((tool === 'Bash' || tool === 'PowerShell') && WORKTREE_ADD.test(input.command ?? '')) {
    return 'O comando cria um git worktree.';
  }
  if (tool === 'EnterWorktree' && !input.path) return 'EnterWorktree vai criar um worktree novo.';
  if (tool === 'Agent' && input.isolation === 'worktree') {
    return 'O subagente roda num worktree novo (isolation "worktree").';
  }
  return null;
}

function main() {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => (raw += chunk));
  process.stdin.on('end', () => {
    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return;
    }
    const reason = reasonFor(payload);
    if (!reason) return;
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'ask',
          permissionDecisionReason: `${reason} Confira o plano da skill git-worktree (repositório, branch base, nome, local e remoção) antes de aprovar.`,
        },
      }),
    );
  });
}

if (require.main === module) main();

module.exports = { reasonFor };
