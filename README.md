# git-worktree

Skill e plugin para **Claude Code** e **OpenAI Codex** que colocam regras no uso de `git worktree`. O objetivo é evitar worktrees esquecidos ocupando espaço em disco.

- **Antes de criar**, o agente apresenta um plano e espera o seu OK. O plano traz o repositório, a branch base (com hash), a branch nova, o nome, o local absoluto e relativo e os comandos de remoção.
- **Relatório** dos worktrees abertos, numa tabela com quatro colunas:

  | Worktree | Tamanho | Branch | O que eu perco |
  |----------|--------:|--------|----------------|
  | `C:\repos\loja\.worktrees\feat-login` | 241 MB | `claude/feat-login` | Nada |
  | `C:\repos\loja\.worktrees\fix-frete` | 399 MB | `codex/fix-frete` | 14 arquivos alterados e 3 novos sem commit |

  "O que eu perco" lista o que some ao apagar: arquivos sem commit, commits que só existem ali e arquivos ignorados pelo git, como `.env`. Pastas de build não contam. Com `-Json`, o relatório traz também commits à frente/atrás, status no remoto, data do último commit e os comandos de remoção.
- **Ao terminar a tarefa**, o agente propõe a remoção com os comandos prontos. Ele nunca apaga nada sem você pedir.

## Estrutura

```
.claude-plugin/plugin.json        manifesto do plugin (Claude Code)
.claude-plugin/marketplace.json   marketplace local (Claude Code)
.codex-plugin/plugin.json         manifesto do plugin (Codex)
.agents/plugins/marketplace.json  marketplace local (Codex)
skills/git-worktree/SKILL.md      as regras (mesma skill para os dois agentes)
skills/git-worktree/agents/openai.yaml           metadados da skill no Codex
skills/git-worktree/scripts/worktrees-report.ps1 relatório (somente leitura)
commands/worktrees.md             comando /git-worktree:worktrees (Claude Code)
hooks/                            hook que pede confirmação ao criar worktree (Claude Code)
codex/rules/git-worktree.rules    regra que pede aprovação ao criar worktree (Codex)
tests/                            testes do hook e do relatório
```

## Requisitos

- git 2.31 ou mais novo
- PowerShell 7+ (`pwsh`), usado pelo relatório
- Node.js 18+, usado só pelo hook do Claude Code

## Instalação

### Claude Code

```bash
claude plugin marketplace add C:\caminho\para\GitWorktree-Skill
claude plugin install git-worktree@gitworktree-skill
```

Se preferir instalar pelo GitHub: `claude plugin marketplace add vitorpadovan/gitworktree-skill`.

Depois, reinicie o Claude Code.

### Codex

```bash
codex plugin marketplace add C:\caminho\para\GitWorktree-Skill
codex plugin add git-worktree@gitworktree-skill
```

Para o Codex pedir aprovação antes de `git worktree add`, copie a regra:

```powershell
Copy-Item codex\rules\git-worktree.rules $HOME\.codex\rules\
```

## Uso

| Quero... | Claude Code | Codex |
|----------|-------------|-------|
| Ver quais worktrees posso apagar | `/git-worktree:worktrees C:\repos` | `$git-worktree liste meus worktrees em C:\repos` |
| Criar um worktree | Peça normalmente. A skill entra antes da criação | Igual |
| Rodar o relatório direto | `pwsh -NoProfile -File skills/git-worktree/scripts/worktrees-report.ps1 -Path C:\repos` | Igual |

Opções do relatório:

- `-Path "a;b"`: repositórios ou pastas raiz, separados por `;`.
- `-Json`: saída em JSON.
- `-SkipSize`: não calcula o tamanho em disco, para rodar mais rápido.
- `-Depth N`: profundidade da busca por repositórios (padrão: 6).

Sem `-Path`, o script usa a variável de ambiente `GIT_WORKTREE_ROOTS` ou, sem ela, o diretório atual.

### Atualizar

Os dois agentes copiam o plugin para um cache próprio. Depois de alterar o repositório, aumente `version` nos manifestos e rode `claude plugin update git-worktree@gitworktree-skill` e `codex plugin add git-worktree@gitworktree-skill`.

### Deixar a regra sempre ativa

A skill é carregada pela descrição. Para garantir que o agente a use sempre, adicione ao seu `CLAUDE.md` e ao `~/.codex/AGENTS.md`:

```markdown
## Worktrees
- Antes de criar, entrar ou remover um git worktree, seguir a skill `git-worktree`.
- Nunca criar sem apresentar o plano e receber meu OK. Nunca apagar sem eu pedir.
- Pasta raiz dos meus repositórios: C:\repos
```

## Padrões que a skill aplica

- **Local:** `<repo>/.worktrees/<nome>`. A pasta vai para `info/exclude`, que é local e não gera commit. A exceção é o subagente isolado do Claude Code, que sempre cria em `.claude/worktrees/`.
- **Nome:** `<tipo>-<descricao>`. A branch fica `claude/<nome>` ou `codex/<nome>`, a menos que o repositório tenha convenção própria.
- **Base:** a branch em que você está, depois de um `git fetch`, mostrando o hash.

## Proteções e limites

- **Hook do Claude Code:** pede confirmação em `git ... worktree add` (Bash e PowerShell), em `EnterWorktree` com `name` e em subagentes com `isolation: "worktree"`.
- **Regra do Codex:** só reconhece o comando simples `git worktree add ...`. Variações como `git -C <dir> worktree add` dependem da skill.
- **Comandos de remoção:** o relatório os gera na ordem certa. Arquivos ignorados que se perdem (ex.: `.env`) são copiados antes para `~/worktree-backup/<repo>/<worktree>`, e worktrees com submódulos recebem `--force`, que o git exige nesse caso. A skill manda o agente usar esses comandos em vez de escrevê-los de cabeça.
- **Merges por squash ou rebase** não são detectados pelo relatório e aparecem como `REVISAR`.
- **Economia de disco no Claude Code:** a configuração `worktree.symlinkDirectories` (ex.: `["node_modules"]`) cria links em vez de copiar essas pastas nos worktrees do `EnterWorktree` e dos subagentes isolados.

## Testes

```bash
node --test tests/worktree-guard.test.js
pwsh -NoProfile -File tests/worktrees-report.Tests.ps1
```
