---
description: Lista os git worktrees abertos e diz quais podem ser apagados
argument-hint: "[pastas ou repositórios separados por ;]"
---

Use a skill `git-worktree` na seção "Relatório de worktrees" para estes caminhos: $ARGUMENTS

Se nenhum caminho foi passado, use a pasta raiz de repositórios definida nas instruções do usuário (CLAUDE.md). Se não houver, deixe o script decidir (variável `GIT_WORKTREE_ROOTS` ou diretório atual).

Não apague nada. Termine com os comandos de remoção prontos e pergunte quais o usuário quer executar.
