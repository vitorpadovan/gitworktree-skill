# pwsh -NoProfile -File tests/worktrees-report.Tests.ps1
# Monta repositórios temporários com worktrees em cada situação e confere o veredito do relatório.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..' 'skills' 'git-worktree' 'scripts' 'worktrees-report.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "wt-report-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$failures = 0

function Invoke-TestGit { & git @args 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git $args falhou" } }

function Assert-Equal($actual, $expected, [string]$what) {
    if ($actual -ceq $expected) { Write-Output "ok   - $what" }
    else { Write-Output "FAIL - $what (esperado: $expected; obtido: $actual)"; $script:failures++ }
}

try {
    $remote = Join-Path $root 'remote.git'
    $repo = Join-Path $root 'repo'
    Invoke-TestGit init -q --bare -b main $remote
    Invoke-TestGit init -q -b main $repo
    Invoke-TestGit -C $repo config user.email 'teste@example.com'
    Invoke-TestGit -C $repo config user.name 'Teste'
    Set-Content (Join-Path $repo '.gitignore') "node_modules/`n.env"
    Invoke-TestGit -C $repo add .
    Invoke-TestGit -C $repo commit -q -m inicial
    Invoke-TestGit -C $repo remote add origin $remote
    Invoke-TestGit -C $repo push -q -u origin main
    Invoke-TestGit -C $repo remote set-head origin main

    $wts = Join-Path $repo '.worktrees'
    # Sem nada novo: tudo já está na branch atual.
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'limpo') -b limpo
    # Alteração sem commit.
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'sujo') -b sujo
    Set-Content (Join-Path $wts 'sujo' 'novo.txt') 'x'
    # Commit local que não está em lugar nenhum.
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'local') -b local
    Set-Content (Join-Path $wts 'local' 'a.txt') 'a'
    Invoke-TestGit -C (Join-Path $wts 'local') add .
    Invoke-TestGit -C (Join-Path $wts 'local') commit -q -m local
    # Commit já enviado ao remoto.
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'enviado') -b enviado
    Set-Content (Join-Path $wts 'enviado' 'b.txt') 'b'
    Invoke-TestGit -C (Join-Path $wts 'enviado') add .
    Invoke-TestGit -C (Join-Path $wts 'enviado') commit -q -m enviado
    Invoke-TestGit -C (Join-Path $wts 'enviado') push -q -u origin enviado
    # Só node_modules (recriável) e .env (perda real).
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'build') -b build
    New-Item -ItemType Directory (Join-Path $wts 'build' 'node_modules') | Out-Null
    Set-Content (Join-Path $wts 'build' 'node_modules' 'pkg.js') 'x'
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'segredo') -b segredo
    Set-Content (Join-Path $wts 'segredo' '.env') 'TOKEN=x'
    # Pasta apagada à mão.
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'orfao') -b orfao
    Remove-Item -Recurse -Force (Join-Path $wts 'orfao')
    # Submódulo inicializado: o "git worktree remove" só funciona com --force.
    $sub = Join-Path $root 'sub'
    Invoke-TestGit init -q -b main $sub
    Invoke-TestGit -C $sub config user.email 'teste@example.com'
    Invoke-TestGit -C $sub config user.name 'Teste'
    Set-Content (Join-Path $sub 'lib.txt') 'lib'
    Invoke-TestGit -C $sub add .
    Invoke-TestGit -C $sub commit -q -m lib
    Invoke-TestGit -C $repo -c protocol.file.allow=always submodule add -q $sub lib
    Invoke-TestGit -C $repo commit -q -m submodulo
    Invoke-TestGit -C $repo push -q
    Invoke-TestGit -C $repo worktree add -q (Join-Path $wts 'comsub') -b comsub
    Invoke-TestGit -C (Join-Path $wts 'comsub') -c protocol.file.allow=always submodule update -q --init

    # HOME temporário para os comandos de backup não escreverem na pasta do usuário.
    $realHome = $env:USERPROFILE
    $env:USERPROFILE = $root; $env:HOME = $root
    $report = & pwsh -NoProfile -File $script -Path $root -Json -SkipSize | ConvertFrom-Json
    $env:USERPROFILE = $realHome; $env:HOME = $realHome
    $byName = @{}
    foreach ($r in $report) { $byName[(Split-Path $r.Worktree -Leaf)] = $r }

    Assert-Equal $report.Count 8 'encontra os 8 worktrees vinculados'
    Assert-Equal $byName.limpo.Veredito 'PODE APAGAR' 'limpo pode ser apagado'
    Assert-Equal $byName.sujo.Veredito 'REVISAR' 'arquivo novo sem commit exige revisão'
    Assert-Equal $byName.sujo.NaoRastreados 1 'conta o arquivo não rastreado'
    Assert-Equal $byName.local.Veredito 'REVISAR' 'commit só local exige revisão'
    Assert-Equal $byName.local.AFrente 1 'commit local aparece à frente da branch atual'
    Assert-Equal $byName.local.ForaDoRemoto 1 'commit local aparece fora do remoto'
    Assert-Equal $byName.enviado.Veredito 'PODE APAGAR' 'commit já no remoto pode ser apagado'
    Assert-Equal $byName.build.Veredito 'PODE APAGAR' 'node_modules não conta como perda'
    Assert-Equal $byName.segredo.Veredito 'REVISAR' '.env ignorado conta como perda'
    Assert-Equal $byName.orfao.Veredito 'PRUNE' 'pasta apagada vira PRUNE'
    Assert-Equal $byName.limpo.Relativo (Join-Path '.worktrees' 'limpo') 'caminho relativo ao repositório'
    Assert-Equal $byName.limpo.BranchAtual 'main' 'compara com a branch atual do checkout principal'
    Assert-Equal $byName.limpo.OQueSePerde 'Nada' 'perda: nada quando está tudo salvo'
    Assert-Equal $byName.sujo.OQueSePerde '1 arquivo novo sem commit' 'perda: arquivo novo'
    Assert-Equal $byName.local.CommitsPerdidos 1 'conta o commit que só existe no worktree'
    Assert-Equal $byName.local.OQueSePerde '1 commit que só existe aqui' 'perda: commit só local'
    Assert-Equal $byName.enviado.OQueSePerde 'Nada' 'perda: commit no remoto não se perde'
    Assert-Equal $byName.build.OQueSePerde 'Nada' 'perda: node_modules não conta'
    Assert-Equal $byName.segredo.OQueSePerde 'ignorados pelo git: .env' 'perda: .env ignorado'
    Assert-Equal $byName.orfao.OQueSePerde 'Nada (a pasta já não existe; só sobrou o registro no git)' 'perda: registro órfão'

    Assert-Equal $byName.comsub.TemSubmodulos $true 'detecta submódulo inicializado'
    Assert-Equal $byName.comsub.OQueSePerde 'Nada' 'submódulo com tudo no remoto não é perda'
    $removeSub = $byName.comsub.ComandosRemocao | Where-Object { $_ -like '*worktree remove*' }
    Assert-Equal ($removeSub -like '*worktree remove --force*') $true 'usa --force quando há submódulo'
    Invoke-Expression $removeSub 2>&1 | Out-Null
    Assert-Equal (Test-Path (Join-Path $wts 'comsub')) $false 'o comando de remoção sugerido funciona com submódulo'

    $cmds = @($byName.segredo.ComandosRemocao)
    $copyAt = [array]::FindIndex($cmds, [Predicate[string]] { $args[0] -like 'Copy-Item*' })
    $removeAt = [array]::FindIndex($cmds, [Predicate[string]] { $args[0] -like '*worktree remove*' })
    Assert-Equal ($copyAt -ge 0 -and $copyAt -lt $removeAt) $true 'salva os ignorados antes de remover'
    foreach ($c in $cmds) { Invoke-Expression $c 2>&1 | Out-Null }
    Assert-Equal (Test-Path (Join-Path $root 'worktree-backup' 'repo' 'segredo' '.env')) $true 'o .env fica salvo no backup'
    Assert-Equal (Test-Path (Join-Path $wts 'segredo')) $false 'e o worktree é removido depois'

    $table = (& pwsh -NoProfile -File $script -Path $root -SkipSize) -join "`n"
    Assert-Equal ($table -match 'Worktree\s+Tamanho\s+Branch\s+O que eu perco') $true 'tabela tem as 4 colunas na ordem pedida'
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($failures) { Write-Output "$failures falha(s)"; exit 1 }
Write-Output 'Todos os testes passaram.'
