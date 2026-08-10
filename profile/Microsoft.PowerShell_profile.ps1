#
# Microsoft.PowerShell_profile.ps1 — perfil do PowerShell 7 (contraparte Windows do `zshrc`)
# Uso:  NÃO copie este arquivo para o $PROFILE. O setup.ps1 escreve um STUB de uma
#       linha no $PROFILE real que faz dot-source daqui:
#           . "$HOME\Projetos\pessoal\windows-setup\profile\Microsoft.PowerShell_profile.ps1"
#       Para recarregar sem fechar o terminal:  . $PROFILE
# Seguro carregar várias vezes (idempotente): tudo é guardado por Get-Command/Test-Path
# e o PATH nunca duplica (ver Add-ToPath).
#
# --- Por que stub e não symlink ----------------------------------------------
# Symlink no Windows exige SeCreateSymbolicLinkPrivilege (admin ou Developer Mode).
# O setup.ps1 liga o Developer Mode (ele é o dono desse ajuste), mas não dá para
# depender disso na primeira execução — e o Git for Windows tem core.symlinks=false
# por padrão, que este repo mantém em profile/gitconfig-windows, o que
# faria um clone materializar cada symlink como arquivo de texto com um caminho dentro.
# Dot-source de um stub não precisa de privilégio nenhum e sempre lê a versão do repo.
#
# --- $PROFILE não tem caminho fixo -------------------------------------------
# Com conta Microsoft + OneDrive Known Folder Move (padrão), Documents é redirecionado
# e o perfil vira ...\OneDrive\Documents\PowerShell\... Sempre use `Split-Path $PROFILE`
# para descobrir a pasta; nunca monte o caminho à mão.
#
# --- PS 5.1 e PS 7 são instalações separadas ---------------------------------
# Perfis:  Documents\WindowsPowerShell\  (PS 5.1)   vs  Documents\PowerShell\  (PS 7+)
# Módulos: $env:PSModulePath também é distinto entre os dois.
# Instalar um módulo em um NÃO o disponibiliza no outro. Este arquivo mira o PS 7.
# Ele é UTF-8 sem BOM: o PS 7 lê certo, mas o PS 5.1 leria na codepage ANSI e os
# acentos dos comentários sairiam tortos. Inofensivo (comentário e string não quebram
# o parser), mas é mais um motivo para o stub do PS 5.1 não apontar para cá.
#

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # análogo de `set -euo pipefail`; revertido no fim (seção 12)

# Helpers de saída (mesma forma do info/ok/warn do setup.sh). Durante a carga do
# perfil só `warn` é usado — um shell novo tem que abrir em silêncio. `info`/`ok`
# servem às funções de manutenção definidas aqui (ex.: Sync-WindowsTerminalSettings).
function info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok($m)   { Write-Host "OK  $m" -ForegroundColor Green }
function warn($m) { Write-Host "AVISO $m" -ForegroundColor Yellow }

# Raízes dos dois repos. $PSScriptRoot funciona porque este arquivo é dot-sourced;
# o fallback cobre o caso de alguém ter copiado o conteúdo em vez de usar o stub.
$WindowsSetupRoot = if ($PSScriptRoot) {
  Split-Path -Parent $PSScriptRoot
} else {
  Join-Path $HOME 'Projetos\pessoal\windows-setup'
}
$MacSetupRoot = Join-Path $HOME 'Projetos\pessoal\mac-setup'

# --- 1. Segredos locais (NÃO versionados) ------------------------------------
# Análogo exato do `[ -f ~/.secrets.zsh ] && source ~/.secrets.zsh` do zshrc.
# Este repo é PÚBLICO: tokens, IDs de conta AWS, nomes de org/usuário de trabalho e
# qualquer troca de conta por diretório moram AQUI, fora do repo. Se o arquivo não
# existir, o perfil carrega igual (source silencioso, como no zsh).
$SecretsFile = Join-Path $HOME '.secrets.ps1'
if (Test-Path $SecretsFile) {
  try { . $SecretsFile } catch { warn "falha ao carregar ~/.secrets.ps1: $($_.Exception.Message)" }
}

# --- 2. PATH -----------------------------------------------------------------
# Helper idempotente: recarregar o perfil (`. $PROFILE`) não pode inchar o PATH.
function Add-ToPath {
  param([string]$Dir, [switch]$Prepend)
  if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return }
  $Dir = (Resolve-Path -LiteralPath $Dir).Path
  $atual = @($env:PATH -split ';' | Where-Object { $_ })
  if ($atual -contains $Dir) { return }   # -contains é case-insensitive: certo para Windows
  $env:PATH = if ($Prepend) { "$Dir;$env:PATH" } else { "$env:PATH;$Dir" }
}

# ~/.local/bin PRIMEIRO, antes de qualquer `Get-Command`. No zshrc atual esse export
# está ~40 linhas ABAIXO do bloco de CLI modernas, o que faz os testes rodarem contra
# um PATH incompleto. Aqui a ordem está corrigida de propósito.
Add-ToPath (Join-Path $HOME '.local\bin') -Prepend

# pnpm — no Windows o diretório padrão é %LOCALAPPDATA%\pnpm, NÃO ~/Library/pnpm
# (esse caminho do zshrc é macOS-only e vira bug de verdade em qualquer outro SO).
if ($env:LOCALAPPDATA) {
  $env:PNPM_HOME = Join-Path $env:LOCALAPPDATA 'pnpm'
  Add-ToPath $env:PNPM_HOME -Prepend
}

# Go — o GOPATH/bin só entra se o go estiver instalado.
if (Get-Command go -ErrorAction SilentlyContinue) {
  try { Add-ToPath (Join-Path (go env GOPATH) 'bin') } catch { warn "não consegui ler o GOPATH" }
}

# LM Studio CLI (lms). Caminho equivalente ao do macOS (não verificado no Windows — se
# o `lms` não aparecer, confira onde o LM Studio instalou o CLI e ajuste aqui).
Add-ToPath (Join-Path $HOME '.lmstudio\bin')

# --- 3. Node: fnm -------------------------------------------------------------
# Forma PowerShell do hook. NÃO existe `eval` aqui: a saída do fnm é um script que
# precisa ser transformado em string e passado ao Invoke-Expression.
# `--shell powershell` é explícito de propósito — o próprio fnm recomenda passar o
# shell em vez de deixar ele inferir por process tree (mais rápido e sem surpresa).
if (Get-Command fnm -ErrorAction SilentlyContinue) {
  try { fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression }
  catch { warn "fnm env falhou: $($_.Exception.Message)" }
}
# corepack/pnpm NÃO são habilitados aqui: `corepack enable` escreve em disco e é
# tarefa de provisionamento (setup.ps1), não de abrir um shell.

# --- 4. Editor e variáveis de ambiente ---------------------------------------
$env:EDITOR = 'code --wait'
$env:BAT_THEME = 'ansi'

# Starship: em vez de symlink em ~/.config/starship.toml (privilegiado no Windows),
# apontamos a env var direto para o arquivo do repo mac-setup — o starship.toml é
# 100% portável, então os dois SOs leem o MESMO arquivo, sem cópia para divergir.
$StarshipToml = Join-Path $MacSetupRoot 'starship.toml'
if (Test-Path $StarshipToml) {
  $env:STARSHIP_CONFIG = $StarshipToml
} else {
  warn "starship.toml não encontrado em $MacSetupRoot - clone o repo mac-setup ali"
}

# --- 5. Histórico e PSReadLine -----------------------------------------------
# Equivalente do bloco HISTSIZE/SAVEHIST/HIST_IGNORE_ALL_DUPS do zshrc.
# Não existe análogo de SHARE_HISTORY: o PSReadLine grava num arquivo único e só
# recarrega o que já estava lá quando a sessão abriu.
$psrl = Get-Module PSReadLine
if (-not $psrl) {
  # -ListAvailable pode devolver várias versões lado a lado; a maior é a que vale.
  $psrl = Get-Module -ListAvailable -Name PSReadLine |
            Sort-Object Version -Descending | Select-Object -First 1
}
if ($psrl) {
  try {
    Set-PSReadLineOption -MaximumHistoryCount 50000
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    # Setas cima/baixo filtram pelo que já foi digitado (o comportamento que o zsh dá).
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete

    # Predictive IntelliSense = substituto nativo do zsh-autosuggestions (é por isso
    # que o lado Windows não instala plugin de zsh nenhum). Exige PSReadLine 2.2+; o
    # PS 5.1 sai de fábrica com a 2.0, daí o guard de versão.
    if ($psrl.Version -ge [version]'2.2.0') {
      Set-PSReadLineOption -PredictionSource History
      Set-PSReadLineOption -PredictionViewStyle InlineView   # sugestão cinza; aceita com ->
    }
  } catch { warn "PSReadLine: $($_.Exception.Message)" }
}

# fzf (Ctrl+R histórico, Ctrl+T arquivos). O binário vem do winget, mas os atalhos
# dependem do módulo PSFzf, que NÃO está na lista de pacotes do repo (não verificado):
#   Install-Module PSFzf -Scope CurrentUser
# Sem ele, o Ctrl+R padrão do PSReadLine continua funcionando.
if ((Get-Command fzf -ErrorAction SilentlyContinue) -and
    (Get-Module -ListAvailable -Name PSFzf)) {
  try {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
  } catch { warn "PSFzf: $($_.Exception.Message)" }
}

# --- 6. CLI modernas ----------------------------------------------------------
# eza (ls moderno). No PowerShell `ls` é um ALIAS, e alias tem precedência sobre função
# na resolução de comandos — por isso o alias precisa ser removido antes.
if (Get-Command eza -ErrorAction SilentlyContinue) {
  Remove-Item -Path Alias:ls -Force -ErrorAction SilentlyContinue
  function ls { eza --icons --group-directories-first @args }
  function ll { eza -lah --icons --git --group-directories-first @args }
  function lt { eza --tree --level=2 --icons @args }
} else {
  function ll { Get-ChildItem -Force @args }
}
# bat: no Windows o binário chama `bat` mesmo. O rename para `batcat` é coisa do
# pacote Debian/Ubuntu — só importa dentro do WSL.

# zoxide (cd inteligente: use `z <parte-do-nome>`)
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
  try { Invoke-Expression (& { (zoxide init powershell | Out-String) }) }
  catch { warn "zoxide init falhou: $($_.Exception.Message)" }
}

# --- 7. Aliases ---------------------------------------------------------------
# ATENÇÃO: gc, gp e gl já são aliases nativos (Get-Content, Get-ItemProperty,
# Get-Location). Sobrescrever é intencional — são os mesmos atalhos do zshrc e a
# memória muscular vale mais aqui. Os cmdlets continuam acessíveis pelo nome completo,
# e `cat`/`pwd` seguem apontando para Get-Content/Get-Location.
Remove-Item -Path Alias:gc, Alias:gp, Alias:gl -Force -ErrorAction SilentlyContinue

function lg  { lazygit @args }
function gs  { git status @args }
function gc  { git commit @args }
function gco { git checkout @args }
function gp  { git push @args }
function gl  { git pull @args }
function gd  { git diff @args }
function gb  { git branch @args }
function projetos { Set-Location (Join-Path $HOME 'Projetos') }
# Os aliases `ios`/`ios-list` do zshrc não portam: Simulator e xcrun são do macOS.

# --- 8. Prompt: Starship ------------------------------------------------------
# Forma exata da documentação do starship. Como o $env:STARSHIP_CONFIG da seção 4 já
# aponta para o starship.toml do mac-setup, o prompt sai idêntico ao do Mac.
if (Get-Command starship -ErrorAction SilentlyContinue) {
  try { Invoke-Expression (&starship init powershell) }
  catch { warn "starship init falhou: $($_.Exception.Message)" }
}

# --- 9. Perfis multi-conta (Claude Code / Codex CLI) --------------------------
# O zsh resolve isso com `VAR=valor comando` dentro de um alias. O PowerShell não tem
# prefixo de env var por comando: variável de ambiente é do PROCESSO inteiro. Por isso
# a função gerada salva o valor anterior e restaura no finally — sem isso, rodar
# `claude-<perfil>` uma vez contaminaria a sessão toda.
function New-CliProfile {
  param(
    [Parameter(Mandatory)][string]$Nome,          # sufixo do comando gerado
    [Parameter(Mandatory)][string]$Comando,       # 'claude', 'codex', ...
    [Parameter(Mandatory)][string]$VarAmbiente,   # 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', ...
    [Parameter(Mandatory)][string]$Dir
  )
  $corpo = @"
`$anterior = `$env:$VarAmbiente
`$env:$VarAmbiente = '$Dir'
try { $Comando @args } finally { `$env:$VarAmbiente = `$anterior }
"@
  Set-Item -Path "Function:global:$Comando-$Nome" -Value ([scriptblock]::Create($corpo)) -Force
}

# `claude`/`codex` puros = perfil pessoal. Sem estes exports o Claude Code cairia no
# ~/.claude.json da raiz do home — uma TERCEIRA configuração, separada dos perfis.
$env:CLAUDE_CONFIG_DIR = Join-Path $HOME '.claude'
$env:CODEX_HOME        = Join-Path $HOME '.codex'
New-CliProfile -Nome 'pessoal' -Comando 'claude' -VarAmbiente 'CLAUDE_CONFIG_DIR' -Dir $env:CLAUDE_CONFIG_DIR
New-CliProfile -Nome 'pessoal' -Comando 'codex'  -VarAmbiente 'CODEX_HOME'        -Dir $env:CODEX_HOME

# Perfis adicionais (trabalho, cliente, sócio...) NÃO entram aqui — este repo é
# público. Coloque em ~/.secrets.ps1, que já foi carregado lá na seção 1:
#
#   New-CliProfile -Nome 'trabalho' -Comando 'claude' `
#                  -VarAmbiente 'CLAUDE_CONFIG_DIR' -Dir "$HOME\.claude-trabalho"
#
# Mesma regra para trocar a conta do gh por diretório. Esboço GENÉRICO, deixado
# comentado de propósito — a versão real (com org e usuários de verdade) vive em
# ~/.secrets.ps1, nunca aqui:
#
#   function gh {
#     $orgTrabalho  = '<org>'             # placeholder
#     $userTrabalho = '<usuario-work>'    # placeholder
#     $userPessoal  = '<usuario-pessoal>' # placeholder
#     $remote = (git remote get-url origin 2>$null)
#     $conta  = if ($PWD.Path -like "$HOME\Projetos\empresa\$orgTrabalho*" -or
#                   $remote -like "*$orgTrabalho/*") { $userTrabalho } else { $userPessoal }
#     & (Get-Command gh.exe) auth switch -u $conta *> $null
#     & (Get-Command gh.exe) @args
#   }

# --- 10. Windows Terminal: sync do settings.json ------------------------------
function Sync-WindowsTerminalSettings {
  <#
    .SYNOPSIS
      Copia profile/windows-terminal-settings.json do repo para o settings.json ativo
      do Windows Terminal. Idempotente: se o conteúdo já for idêntico, não escreve.
    .DESCRIPTION
      COPIA, não symlink — e isso é de propósito. O Windows Terminal reescreve o
      settings.json inteiro sempre que você mexe em algo pela UI (e sozinho, ao migrar
      schema). Ao fazer isso ele grava um arquivo NOVO por cima: o symlink é destruído
      e as suas edições seguintes no repo param de chegar em lugar nenhum, sem erro
      nenhum. Com cópia o fluxo fica explícito: edite o JSON do repo -> rode
      Sync-WindowsTerminalSettings -> reinicie o Terminal. Se você mexer pela UI, a
      mudança fica só no destino até ser trazida de volta para o repo à mão.
  #>
  [CmdletBinding()]
  param()

  $origem = Join-Path $WindowsSetupRoot 'profile\windows-terminal-settings.json'
  if (-not (Test-Path -LiteralPath $origem)) { warn "não achei $origem"; return }

  # Caminhos do settings.json por tipo de instalação (não verificado no plano —
  # confirme com `Get-AppxPackage Microsoft.WindowsTerminal` se nenhum casar).
  $candidatos = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
  )
  $destino = $candidatos | Where-Object { Test-Path -LiteralPath (Split-Path -Parent $_) } | Select-Object -First 1
  if (-not $destino) {
    warn "o Windows Terminal ainda não criou a pasta de settings. Abra ele uma vez e rode de novo."
    return
  }

  if ((Test-Path -LiteralPath $destino) -and
      ((Get-FileHash -LiteralPath $origem).Hash -eq (Get-FileHash -LiteralPath $destino).Hash)) {
    ok "settings.json já está em dia"
    return
  }

  info "Sincronizando settings.json do Windows Terminal..."
  if (Test-Path -LiteralPath $destino) {
    # Backup único, sobrescrito a cada sync — o objetivo é poder desfazer a ÚLTIMA
    # cópia, não acumular histórico (isso é trabalho do git, do lado do repo).
    Copy-Item -LiteralPath $destino -Destination "$destino.bak" -Force
    ok "backup em $destino.bak"
  }
  Copy-Item -LiteralPath $origem -Destination $destino -Force
  ok "$destino"
  warn "reinicie o Windows Terminal para aplicar"
}

# --- 11. Autocompletion -------------------------------------------------------
# Não há análogo do `compinit` aqui: o PowerShell já completa cmdlets, parâmetros e
# caminhos nativamente, sem cache para reconstruir.
#
# Completers de ferramentas externas (gh, winget) são gerados chamando o próprio
# binário, o que custa ~100-200 ms em TODO shell novo. Não valem o preço no caminho
# quente. Se quiser um, adicione à mão no ~/.secrets.ps1 — e consulte a documentação
# da ferramenta na hora, em vez de fixar a flag aqui.

# --- 12. Volta às preferências interativas ------------------------------------
# StrictMode/EAP=Stop protegem a CARGA do perfil, mas mantidos na sessão eles tornam o
# shell hostil: qualquer variável não inicializada, ou um .exe que escreve em stderr,
# viraria erro terminante no meio de um one-liner. Aqui a sessão volta ao normal.
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
