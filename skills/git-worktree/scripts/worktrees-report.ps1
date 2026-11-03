<#
.SYNOPSIS
  Lista os git worktrees de um ou mais repositórios e indica quais podem ser apagados.

.DESCRIPTION
  Para cada worktree vinculado (o checkout principal fica de fora) mostra o caminho, o tamanho
  em disco, a branch e o que se perde ao apagá-lo: alterações sem commit, commits que não estão
  em nenhum remoto nem na branch atual/padrão e arquivos ignorados que não são de build.
  Com -Json inclui também commits à frente/atrás, status no remoto, merge na branch padrão,
  data do último commit, veredito e comandos de remoção. Não altera nada.

  Requer PowerShell 7+ e git no PATH.

.PARAMETER Path
  Repositórios ou pastas raiz para varrer. Aceita vários separados por ";".
  Padrão: a variável de ambiente GIT_WORKTREE_ROOTS ou, sem ela, o diretório atual.

.PARAMETER Depth
  Profundidade máxima da busca por repositórios dentro das pastas raiz.

.PARAMETER SkipSize
  Não calcula o tamanho em disco (mais rápido em worktrees com node_modules grandes).

.PARAMETER Json
  Emite o resultado em JSON em vez de tabela.

.EXAMPLE
  pwsh -NoProfile -File worktrees-report.ps1 -Path C:\repos
  pwsh -NoProfile -File worktrees-report.ps1 -Path "C:\repos\projeto-a;C:\repos\projeto-b" -Json
#>
param(
    [string[]]$Path = @(),
    [int]$Depth = 6,
    [switch]$SkipSize,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $Path = if ($env:GIT_WORKTREE_ROOTS) { @($env:GIT_WORKTREE_ROOTS) } else { @((Get-Location).Path) }
}

# Pastas geradas por build/instalação: ignoradas pelo git, mas recriáveis, então não contam como perda.
$RegenerableDirs = '^(node_modules|bin|obj|dist|build|out|target|coverage|__pycache__|\.venv|venv|\.next|\.nuxt|\.expo|\.angular|\.svelte-kit|\.parcel-cache|\.turbo|\.cache|\.pytest_cache|\.ruff_cache|\.mypy_cache|\.gradle|\.idea|\.vs|\.terraform)$'

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $out = & git -C $Dir @GitArgs 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out) }
}

function Get-NormalizedPath([string]$p) {
    $full = [IO.Path]::GetFullPath($p)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) {
        $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $full
}

function Format-Count([int]$n, [string]$singular, [string]$plural) {
    if ($n -eq 1) { "1 $singular" } else { "$n $plural" }
}

# Texto da coluna "O que eu perco": tudo que deixa de existir se o worktree for apagado.
function Get-LossText($info) {
    $parts = @()
    $changed = [int]$info.NaoCommitados; $new = [int]$info.NaoRastreados
    if ($changed -and $new) { $parts += "$(Format-Count $changed 'arquivo alterado' 'arquivos alterados') e $(Format-Count $new 'novo' 'novos') sem commit" }
    elseif ($changed) { $parts += "$(Format-Count $changed 'arquivo alterado' 'arquivos alterados') sem commit" }
    elseif ($new) { $parts += "$(Format-Count $new 'arquivo novo' 'arquivos novos') sem commit" }
    if ($info.CommitsPerdidos) { $parts += Format-Count $info.CommitsPerdidos 'commit que só existe aqui' 'commits que só existem aqui' }
    $ignored = @($info.IgnoradosPerdidos)
    if ($ignored.Count) {
        $names = ($ignored | Select-Object -First 3) -join ', '
        if ($ignored.Count -gt 3) { $names += " e mais $($ignored.Count - 3)" }
        $parts += "ignorados pelo git: $names"
    }
    $parts += @($info.SubmodulosComPerda)
    $text = if ($parts) { $parts -join '; ' } else { 'Nada' }
    if ($info.Travado) { $text += ' (travado com git worktree lock)' }
    $text
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
}

# Busca em largura por pastas com ".git" (diretório ou arquivo, para pegar submódulos e worktrees
# soltos), sem descer em pastas de build nem seguir links.
function Find-GitDirs([string]$root, [int]$maxDepth) {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Dir = [IO.DirectoryInfo]::new($root); Level = 0 })
    while ($queue.Count) {
        $item = $queue.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $item.Dir.FullName '.git')) { $item.Dir.FullName }
        if ($item.Level -ge $maxDepth) { continue }
        try { $children = $item.Dir.EnumerateDirectories() } catch { continue }
        foreach ($child in $children) {
            if ($child.Name -eq '.git' -or $child.Name -match $RegenerableDirs) { continue }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue([pscustomobject]@{ Dir = $child; Level = $item.Level + 1 })
        }
    }
}

# Checkout principal de um repositório a partir do git-common-dir. Submódulos guardam o
# caminho em core.worktree; repositórios bare não têm checkout principal.
function Get-MainPath([string]$commonDir) {
    $cw = & git --git-dir=$commonDir config --get core.worktree 2>$null
    if ($LASTEXITCODE -eq 0 -and $cw) { return Get-NormalizedPath ([IO.Path]::GetFullPath($cw, $commonDir)) }
    if ((Split-Path $commonDir -Leaf) -eq '.git') { return Split-Path $commonDir -Parent }
    $null
}

function Find-Repos([string[]]$roots, [int]$depth) {
    $found = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { Write-Warning "Caminho não encontrado: $root"; continue }
        $dirs = if ((Invoke-Git $root @('rev-parse', '--git-dir')).Ok) { @($root) } else { Find-GitDirs (Get-NormalizedPath $root) $depth }
        foreach ($dir in $dirs) {
            $common = Invoke-Git $dir @('rev-parse', '--path-format=absolute', '--git-common-dir')
            if (-not $common.Ok) { continue }
            $commonDir = Get-NormalizedPath $common.Out[0]
            if ($found.ContainsKey($commonDir)) { continue }
            $main = Get-MainPath $commonDir
            if ($main) { $found[$commonDir] = [pscustomobject]@{ Main = $main; CommonDir = $commonDir } }
        }
    }
    $found.Values | Sort-Object Main
}

function Get-Worktrees([string]$main) {
    $list = Invoke-Git $main @('worktree', 'list', '--porcelain')
    if (-not $list.Ok) { return @() }
    $items = @()
    $cur = $null
    foreach ($line in $list.Out + '') {
        if ($line -eq '') { if ($cur) { $items += [pscustomobject]$cur }; $cur = $null; continue }
        $key, $value = $line -split ' ', 2
        switch ($key) {
            'worktree' { $cur = @{ Path = (Get-NormalizedPath $value); Head = $null; Branch = $null; Bare = $false; Detached = $false; Locked = $false; Prunable = $false } }
            'HEAD' { $cur.Head = $value }
            'branch' { $cur.Branch = $value -replace '^refs/heads/', '' }
            'bare' { $cur.Bare = $true }
            'detached' { $cur.Detached = $true }
            'locked' { $cur.Locked = $true }
            'prunable' { $cur.Prunable = $true }
        }
    }
    $items
}

function Get-DefaultRef([string]$main) {
    $r = Invoke-Git $main @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if ($r.Ok -and $r.Out[0]) { return $r.Out[0] }
    foreach ($b in 'main', 'master', 'develop') {
        if ((Invoke-Git $main @('rev-parse', '--verify', '--quiet', "refs/heads/$b")).Ok) { return $b }
    }
    $null
}

$roots = $Path | ForEach-Object { $_ -split ';' } | Where-Object { $_ } | ForEach-Object { $_.Trim() }
$repos = Find-Repos $roots $Depth
$results = @()

foreach ($repo in $repos) {
    $main = $repo.Main
    # Em submódulos o git lista o checkout principal pelo caminho do git-common-dir.
    $linked = Get-Worktrees $main | Where-Object { $_.Path -ne $main -and $_.Path -ne $repo.CommonDir -and -not $_.Bare }
    if (-not $linked) { continue }

    $currentBranch = (Invoke-Git $main @('branch', '--show-current')).Out[0]
    $currentRef = if ($currentBranch) { $currentBranch } else { 'HEAD' }
    $defaultRef = Get-DefaultRef $main
    $hasRemote = [bool]((Invoke-Git $main @('remote')).Out | Where-Object { $_ })

    foreach ($wt in $linked) {
        $exists = Test-Path -LiteralPath $wt.Path
        $info = [ordered]@{
            Repo              = $main
            Worktree          = $wt.Path
            Relativo          = [IO.Path]::GetRelativePath($main, $wt.Path)
            Branch            = if ($wt.Branch) { $wt.Branch } elseif ($wt.Head) { "(detached @ $($wt.Head.Substring(0, 7)))" } else { '(detached)' }
            BranchAtual       = if ($currentBranch) { $currentBranch } else { '(detached)' }
            BranchPadrao      = $defaultRef
            NaoCommitados     = $null
            NaoRastreados     = $null
            AFrente           = $null
            Atras             = $null
            ForaDoRemoto      = $null
            MergeadoNoPadrao  = $null
            CommitsPerdidos   = $null
            IgnoradosPerdidos = @()
            TemSubmodulos     = $false
            SubmodulosComPerda = @()
            OQueSePerde       = $null
            UltimoCommit      = $null
            Tamanho           = $null
            TamanhoBytes      = $null
            Travado           = $wt.Locked
            Orfao             = ($wt.Prunable -or -not $exists)
            Veredito          = $null
            Motivo            = $null
            ComandosRemocao   = @()
        }

        if ($info.Orfao) {
            $info.Veredito = 'PRUNE'
            $info.Motivo = 'A pasta não existe mais; só sobrou o registro no git.'
            $info.OQueSePerde = 'Nada (a pasta já não existe; só sobrou o registro no git)'
            $info.ComandosRemocao = @("git -C `"$main`" worktree prune")
            $results += [pscustomobject]$info
            continue
        }

        $status = (Invoke-Git $wt.Path @('status', '--porcelain')).Out | Where-Object { $_ }
        $info.NaoRastreados = @($status | Where-Object { $_ -like '`?`?*' }).Count
        $info.NaoCommitados = @($status).Count - $info.NaoRastreados

        $ignored = (Invoke-Git $wt.Path @('ls-files', '--others', '--ignored', '--exclude-standard', '--directory')).Out | Where-Object { $_ }
        $info.IgnoradosPerdidos = @($ignored | Where-Object {
                $parts = $_.TrimEnd('/') -split '/'
                -not ($parts | Where-Object { $_ -match $RegenerableDirs })
            })

        # Submódulos inicializados (linhas sem "-" no início) impedem o "git worktree remove" sem --force,
        # e o --force apaga junto o que só existe neles.
        $subs = (Invoke-Git $wt.Path @('submodule', 'status', '--recursive')).Out | Where-Object { $_ -and $_ -notmatch '^-' }
        foreach ($line in $subs) {
            $info.TemSubmodulos = $true
            $subPath = ($line.Substring(1).Trim() -split '\s+')[1]
            $subDir = Join-Path $wt.Path $subPath
            $subDirty = @((Invoke-Git $subDir @('status', '--porcelain')).Out | Where-Object { $_ }).Count
            $subCommits = [int](Invoke-Git $subDir @('rev-list', '--count', 'HEAD', '--not', '--remotes')).Out[0]
            $subParts = @()
            if ($subDirty) { $subParts += "$(Format-Count $subDirty 'arquivo' 'arquivos') sem commit" }
            if ($subCommits) { $subParts += Format-Count $subCommits 'commit que só existe aqui' 'commits que só existem aqui' }
            if ($subParts) { $info.SubmodulosComPerda += "submódulo ${subPath}: $($subParts -join ', ')" }
        }

        if ($wt.Head) {
            $lr = Invoke-Git $main @('rev-list', '--left-right', '--count', "$currentRef...$($wt.Head)")
            if ($lr.Ok) { $info.Atras, $info.AFrente = [int[]]($lr.Out[0] -split '\s+') }
            if ($hasRemote) {
                $info.ForaDoRemoto = [int](Invoke-Git $main @('rev-list', '--count', $wt.Head, '--not', '--remotes')).Out[0]
            }
            if ($defaultRef) {
                $info.MergeadoNoPadrao = (Invoke-Git $main @('merge-base', '--is-ancestor', $wt.Head, $defaultRef)).Ok
            }
            # Commits que não estão em nenhum remoto, nem na branch atual, nem na branch padrão.
            $keep = @('--remotes', $currentRef) + @($defaultRef | Where-Object { $_ })
            $info.CommitsPerdidos = [int](Invoke-Git $main (@('rev-list', '--count', $wt.Head, '--not') + $keep)).Out[0]
            $info.UltimoCommit = (Invoke-Git $main @('log', '-1', '--format=%cs', $wt.Head)).Out[0]
        }

        if (-not $SkipSize) {
            $bytes = (Get-ChildItem -LiteralPath $wt.Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $info.TamanhoBytes = [long]$bytes
            $info.Tamanho = Format-Size ([long]$bytes)
        }

        $info.OQueSePerde = Get-LossText $info
        if ($wt.Locked -or $info.OQueSePerde -ne 'Nada') {
            $info.Veredito = 'REVISAR'; $info.Motivo = $info.OQueSePerde
        }
        else {
            $info.Veredito = 'PODE APAGAR'
            $info.Motivo = if ($info.AFrente -eq 0) { 'Tudo já está na branch atual.' }
            elseif ($info.MergeadoNoPadrao) { "Já mergeado em $defaultRef." }
            else { 'Todos os commits já estão no remoto.' }
        }

        # Em ordem: primeiro salvar os ignorados (a remoção os apaga), depois remover e apagar a branch.
        $commands = @()
        if ($info.IgnoradosPerdidos.Count) {
            $backup = Join-Path $HOME 'worktree-backup' (Split-Path $main -Leaf) (Split-Path $wt.Path -Leaf)
            $commands += "New-Item -ItemType Directory -Force `"$backup`" | Out-Null"
            foreach ($entry in $info.IgnoradosPerdidos) {
                $commands += "Copy-Item -Recurse -LiteralPath `"$(Join-Path $wt.Path $entry.TrimEnd('/'))`" -Destination `"$backup`""
            }
        }
        $force = if ($info.TemSubmodulos) { ' --force' } else { '' }
        $commands += "git -C `"$main`" worktree remove$force `"$($wt.Path)`""
        if ($wt.Branch) { $commands += "git -C `"$main`" branch -d $($wt.Branch)" }
        $info.ComandosRemocao = $commands
        $results += [pscustomobject]$info
    }
}

if ($Json) {
    ConvertTo-Json -InputObject @($results) -Depth 4
    return
}

if (-not $results) {
    Write-Output "Nenhum worktree vinculado encontrado em $(@($repos).Count) repositório(s)."
    return
}

$results | Sort-Object Worktree | Format-Table -AutoSize -Wrap @(
    @{ Label = 'Worktree'; Expression = { $_.Worktree } },
    @{ Label = 'Tamanho'; Expression = { if ($_.Tamanho) { $_.Tamanho } else { '-' } }; Alignment = 'Right' },
    @{ Label = 'Branch'; Expression = { $_.Branch } },
    @{ Label = 'O que eu perco'; Expression = { $_.OQueSePerde } }
) | Out-String -Width 250 | Write-Output

$deletable = $results | Where-Object { $_.Veredito -in 'PODE APAGAR', 'PRUNE' }
$recoverable = ($deletable | Measure-Object -Property TamanhoBytes -Sum).Sum
$freed = if ($recoverable) { " (liberam ~$(Format-Size ([long]$recoverable)))" } else { '' }
Write-Output "$($results.Count) worktree(s): $(@($deletable).Count) sem perda$freed; $($results.Count - @($deletable).Count) com algo a perder."
