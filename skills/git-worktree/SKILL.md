---
name: git-worktree
description: Use antes de criar, entrar ou remover um git worktree (git worktree add, EnterWorktree, subagente com isolation "worktree", worktree pedido por outra skill) e quando o usuário quiser listar os worktrees abertos ou saber quais pode apagar. Apresenta o plano e espera aprovação antes de criar, gera um relatório com veredito por worktree e propõe a limpeza ao final da tarefa.
---

# Git Worktree

Nenhum worktree nasce sem o usuário saber onde fica, de onde parte e como sai. Nenhum worktree é apagado sem o usuário pedir.

Esta skill tem precedência sobre outras skills que criam worktree (ex.: `superpowers:using-git-worktrees`) em três pontos: local, nome e aprovação. O resto do fluxo da outra skill continua valendo.

## Ferramentas por agente

| Ação | Claude Code | Codex |
|------|-------------|-------|
| Criar | `git worktree add` + `EnterWorktree(path: ...)` para mover a sessão | `git worktree add` e trabalhar com `git -C`/`workdir` no worktree |
| Subagente isolado | `Agent` com `isolation: "worktree"` (cria em `.claude/worktrees/`) | não se aplica |
| Sair | `ExitWorktree(action: "keep")` | voltar ao diretório original |
| Relatório | `pwsh -NoProfile -File "<pasta desta skill>/scripts/worktrees-report.ps1"` | igual |

`<pasta desta skill>` é o diretório onde está este `SKILL.md`. O script precisa de PowerShell 7+ (`pwsh`).

## 1. Antes de criar

1. Confira se você já está num worktree (`git rev-parse --git-dir` diferente de `git rev-parse --git-common-dir`, fora de submódulo). Se estiver, não crie outro sem o usuário pedir.
2. Rode o relatório nos repositórios envolvidos e guarde o resultado para o passo 4:
   ```
   pwsh -NoProfile -File "<pasta desta skill>/scripts/worktrees-report.ps1" -Path "<repo1>;<repo2>"
   ```
3. Monte o plano com os padrões abaixo e apresente um bloco por worktree:
   ```
   Plano de worktree
   - Repositório:     C:\repos\loja
   - Branch base:     origin/main @ 3f2a9c1 (git fetch feito agora)
   - Branch nova:     claude/feat-login-google
   - Nome:            feat-login-google
   - Local absoluto:  C:\repos\loja\.worktrees\feat-login-google
   - Local relativo:  .worktrees\feat-login-google
   - Como:            git -C "C:\repos\loja" worktree add "C:\repos\loja\.worktrees\feat-login-google" -b claude/feat-login-google origin/main
   - Remoção:         git -C "C:\repos\loja" worktree remove "C:\repos\loja\.worktrees\feat-login-google"
                      git -C "C:\repos\loja" branch -d claude/feat-login-google
   ```
   Se o repositório tiver submódulos (`.gitmodules`), avise no plano que a remoção vai precisar de `--force` e por quê.
4. Logo abaixo, mostre a tabela do relatório com os worktrees já abertos nesses repositórios (Worktree, Tamanho, Branch, O que eu perco). Se não houver nenhum, diga isso em uma linha.
5. **Espere o OK explícito do usuário.** Só então crie. No Claude Code, o hook do plugin pede uma confirmação extra na hora do comando. No Codex, a regra `codex/rules/git-worktree.rules` faz o mesmo para `git worktree add`.

Para vários subagentes em paralelo, apresente um único plano com todos os worktrees e peça um OK só.

### Padrões

- **Local:** `<raiz do repositório>/.worktrees/<nome>`, nos dois agentes. A exceção é o subagente do Claude Code com `isolation: "worktree"`, que sempre cria em `.claude/worktrees/`; nesse caso, informe esse caminho no plano.
- **Ignorar a pasta sem commit:** antes de criar, rode `git -C <repo> check-ignore -q .worktrees/x`. Se a pasta não estiver ignorada, adicione `.worktrees/` ao arquivo `info/exclude` do repositório (caminho em `git -C <repo> rev-parse --git-path info/exclude`). Esse arquivo é local e não gera commit. Avise que fez isso.
- **Nome:** `<tipo>-<descricao-curta>`, em kebab-case, com até 40 caracteres. Exemplos: `feat-login-google`, `fix-timeout-pagamento`.
- **Branch nova:** `<agente>/<nome>`, ou seja, `claude/feat-login-google` ou `codex/feat-login-google`. Se o repositório tiver convenção própria de branch (hook, CONTRIBUTING, histórico), siga a do repositório e diga qual é.
- **Base:** por padrão, a branch em que o usuário está no checkout principal. Use `origin/<branch padrão>` se a tarefa for independente dela. Rode `git fetch` antes e mostre o hash curto da base.

## 2. Relatório de worktrees

Use quando o usuário pedir para listar ou limpar worktrees e no passo 1.2 acima.

```
pwsh -NoProfile -File "<pasta desta skill>/scripts/worktrees-report.ps1" [-Path "<raiz ou repo>;..."] [-Json] [-SkipSize] [-Depth 6]
```

- Sem `-Path`, o script usa a variável `GIT_WORKTREE_ROOTS` ou, sem ela, o diretório atual. Se as instruções do usuário (CLAUDE.md, AGENTS.md) definirem uma pasta raiz de repositórios, passe essa pasta.
- O script é somente leitura. Ele encontra repositórios, submódulos e worktrees soltos fora da pasta do repositório.
- Use `-SkipSize` se o usuário quiser rapidez. Use `-Json` quando precisar dos detalhes (commits à frente/atrás, status no remoto, merge, data do último commit, veredito e comandos de remoção).

Mostre a tabela que o script imprime, com exatamente estas quatro colunas e nesta ordem:

| Coluna | Conteúdo |
|--------|----------|
| Worktree | Caminho absoluto |
| Tamanho | Espaço em disco |
| Branch | Branch do worktree, ou `(detached @ <hash>)` |
| O que eu perco | `Nada`, ou a lista do que some ao apagar: arquivos sem commit, commits que só existem ali, arquivos ignorados pelo git (ex.: `.env`). Pastas de build (`node_modules`, `bin`, `obj`...) não contam |

Não acrescente colunas. Detalhes vão abaixo da tabela, só quando ajudarem a decidir.

O que conta como perda:

- Arquivos alterados ou novos sem commit.
- Commits que não estão em nenhum remoto, nem na branch atual, nem na branch padrão.
- Arquivos ignorados que não são de build.
- Em submódulos inicializados: arquivos sem commit e commits que só existem neles.
- Um worktree travado (`git worktree lock`) aparece com `(travado...)` e não é apagado sem confirmação.
- Se a pasta já não existe, a coluna diz `Nada (a pasta já não existe...)`. Resolve com `git worktree prune`.
- Limitação: merges por squash ou rebase não são detectados, então esses commits aparecem como perda. Se o usuário disser que o PR já foi mergeado, confira no remoto.

Feche o relatório com o espaço que seria liberado apagando os que não perdem nada.

### Comandos de remoção

Quando o usuário pedir para apagar, ou pedir o comando, use o campo `ComandosRemocao` do `-Json`. Copie os comandos exatamente, na ordem e num bloco só. Não escreva os comandos de cabeça. O campo já resolve três armadilhas:

1. **Arquivos ignorados:** se houver arquivos ignorados que se perdem (ex.: `.env`, `.superpowers/`), os primeiros comandos os copiam para `~/worktree-backup/<repo>/<worktree>`. A cópia tem que vir antes da remoção: depois de remover, não há mais o que copiar.
2. **Submódulos:** se o worktree tiver submódulos inicializados, a remoção vem com `--force`, porque o git recusa `git worktree remove` sem ele. Antes de entregar esse comando, confirme na coluna "O que eu perco" que os submódulos não perdem nada, ou que o usuário aceitou a perda.
3. **Branch:** por último, `git branch -d` apaga a branch, que só sai se já estiver integrada.

Se você mesmo for executar, rode um comando por vez e pare no primeiro erro.

## 3. Ao terminar a tarefa

- Se o trabalho do worktree já foi integrado (mergeado ou enviado ao remoto), proponha a remoção com os comandos prontos.
- Se não foi, diga o que falta: commit, push, PR.
- No Claude Code, saia com `ExitWorktree(action: "keep")` e só remova pelo git depois do OK. `ExitWorktree(action: "remove")` só funciona para worktrees que o próprio `EnterWorktree` criou na sessão.

## Regras que não mudam

- Nunca apague worktree ou branch sem o usuário pedir. Apague um de cada vez e rode o relatório de novo no final.
- Nunca use `git branch -D` ou `ExitWorktree(discard_changes: true)` sem confirmação explícita para aquele worktree. `git worktree remove --force` só entra quando o worktree tem submódulos (veja "Comandos de remoção") e o usuário já viu o que se perde.
- Nunca crie um worktree sem ter apresentado o plano e recebido o OK.
