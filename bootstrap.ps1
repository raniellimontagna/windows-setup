#
# bootstrap.ps1 — a PRIMEIRA coisa a rodar num Windows 11 recém-instalado.
# Deixa a máquina apta a rodar o resto do repo: execution policy, winget
# funcional, Git, PowerShell 7, este repositório clonado e o setup.ps1 chamado
# sob pwsh.
#
# Uso (num terminal COMUM, NÃO elevado — ver bloco ELEVAÇÃO abaixo):
#       powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
#       powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Ref <sha de 40 caracteres>
#       powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Ref v1.0.0 -ExpectedCommit <sha>
#       powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -SkipSetup
#
# Seguro rodar várias vezes (idempotente): cada etapa verifica o estado antes
# de agir. NÃO é destrutivo — não formata, não apaga, não toca em BIOS,
# Secure Boot nem BitLocker. Isso tudo é manual (ver README).
#
# ---------------------------------------------------------------------------
# POWERSHELL 5.1
# ---------------------------------------------------------------------------
# Este é o ÚNICO script do repo que precisa rodar em PowerShell 5.1. Um Windows
# recém-instalado não tem o PowerShell 7 — ele chega DEPOIS, pelo winget, que
# por sua vez depende deste script. Logo: nada de sintaxe de PS7 aqui (sem
# operador ternário, sem `??`, sem `&&`/`||`, sem `$IsWindows`, sem classes, sem
# `-Parallel`, sem Install-PSResource — este último seria circular).
#
# ENCODING: este arquivo é UTF-8 COM BOM de propósito. O PowerShell 5.1 assume
# ANSI (Windows-1252) em arquivo sem BOM e as mensagens em português sairiam
# como "InstalaÃ§Ã£o". Se seu editor remover o BOM, coloque de volta.
#
# ---------------------------------------------------------------------------
# QUEM INSTALA O POWERSHELL 7
# ---------------------------------------------------------------------------
# ESTE script, na seção 6, e só ele. Um dono por assunto:
#   - `Microsoft.PowerShell` NÃO entra em packages/*.json. Se entrasse, o
#     setup.ps1 dependeria de um pacote que ele mesmo instalaria depois de já
#     estar rodando sob pwsh — circular.
#   - depois de instalar, o bootstrap RE-INVOCA o setup.ps1 sob `pwsh.exe`.
#     Chamar o setup.ps1 a partir do 5.1 não funciona: ele usa sintaxe de PS7 e
#     morre com `exit`, que NÃO lança exceção nenhuma no chamador — era assim
#     que a versão anterior deste script imprimia "Bootstrap concluído" depois
#     de o setup ter falhado. Por isso a checagem aqui é do CÓDIGO DE SAÍDA.
#
# ---------------------------------------------------------------------------
# ELEVAÇÃO — NÃO abra como Administrador
# ---------------------------------------------------------------------------
# O provisionamento roda NA SUA CONTA, sem elevação. Rodar tudo elevado é um
# erro silencioso e caro:
#   - toda escrita em HKCU vai para o perfil do ADMINISTRADOR, não para o seu;
#   - pacote winget de escopo user instala na conta do admin, e alguns (o
#     Spotify.Spotify é o caso clássico, MSIX per-user) FALHAM em shell elevado;
#   - o $PROFILE, o clone do repo e o PATH que interessam são os do seu usuário.
# O UAC vai pedir confirmação por pacote machine-wide — isso é o esperado. O
# setup.ps1 se auto-eleva SÓ para o pedaço que escreve em HKLM.
#
# ---------------------------------------------------------------------------
# SEGURANÇA — leia antes de copiar comando de qualquer lugar
# ---------------------------------------------------------------------------
# NUNCA rode este (nem nenhum) script como `irm https://.../main | iex`.
# Motivos concretos:
#   1. `main` é um alvo móvel: o que você revisou ontem não é o que executa
#      hoje. Quem tiver push no repo (ou uma conta comprometida) executa
#      código como você, numa máquina recém-instalada e sem backup.
#   2. Script canalizado direto para `iex` NÃO recebe Mark-of-the-Web, então
#      SmartScreen e as regras de execution policy não têm o que inspecionar.
#      A Compass Security publicou (mar/2026) uma cadeia de initial access via
#      WinGet Desired State explorando exatamente isso.
#   3. A própria Microsoft recomenda revisar qualquer configuration file antes
#      de executar.
# O caminho certo: copie o arquivo do pendrive (ou baixe e LEIA), rode local,
# e passe `-Ref` com o SHA COMPLETO (40 caracteres) que você revisou. O default
# `main` existe só para conveniência de desenvolvimento e emite aviso.
# Tag e SHA abreviado NÃO são pin: quem tem push move a tag, ou cria uma tag
# cujo nome é o seu SHA curto. Por isso SHA abreviado é recusado, e uma tag só
# vale como pin junto com `-ExpectedCommit <sha completo>`.
#
# Nenhum segredo mora neste arquivo. Senha da conta local, tokens e chaves
# ficam FORA do repo (o repo é público) e são injetados em tempo de execução.
#

[CmdletBinding()]
param(
  # HTTPS, não SSH: numa máquina recém-instalada ainda não existe chave SSH
  # (ela vem do backup, ver Fase 1 do plano/README).
  #
  # ⚠️ Este default SÓ RESOLVE DEPOIS QUE O REPO FOR PUBLICADO. Enquanto o repo
  # não existir no GitHub, a URL devolve 404 — indistinguível de repo privado —
  # e o `git clone` falha na autenticação. A seção 7 detecta isso e diz o que
  # fazer, em vez de morrer com um erro de credencial sem contexto.
  [string] $RepoUrl = 'https://github.com/raniellimontagna/windows-setup.git',

  # SHA completo revisado (ou tag + -ExpectedCommit). Ver bloco SEGURANÇA acima.
  [string] $Ref = 'main',

  # Commit que o checkout de -Ref TEM de produzir. Obrigatório para tratar uma
  # tag como pin; com -Ref <sha completo> ele é redundante.
  [ValidatePattern('^[0-9a-fA-F]{40}$')]
  [string] $ExpectedCommit,

  [string] $TargetDir = (Join-Path $env:USERPROFILE 'Projetos\pessoal\windows-setup'),

  # Não chama o setup.ps1 no fim; só imprime o comando.
  [switch] $SkipSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- 1. Guardas, helpers e utilitários ---

# Sob Set-StrictMode, ler $LASTEXITCODE antes do primeiro comando nativo é erro.
$global:LASTEXITCODE = 0

function info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok($m)   { Write-Host "OK  $m"   -ForegroundColor Green }
function warn($m) { Write-Host "AVISO $m" -ForegroundColor Yellow }
function die($m)  { Write-Host "ERRO $m"  -ForegroundColor Red; exit 1 }

if ($PSVersionTable.PSVersion.Major -lt 5) {
  die "PowerShell 5.1 ou superior é necessário (encontrado $($PSVersionTable.PSVersion))."
}

# git e winget escrevem progresso no stderr. Com $ErrorActionPreference='Stop',
# em alguns hosts (ISE, saída redirecionada) isso vira exceção fatal e o script
# morre num "erro" que era só uma barra de progresso.
function Invoke-Exe {
  param(
    [Parameter(Mandatory = $true)][string] $File,
    [string[]] $Arguments = @()
  )
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $File @Arguments } finally { $ErrorActionPreference = $old }
}

# O winget escreve o PATH no registry, mas o processo atual só enxerga a cópia
# herdada quando a sessão abriu. Sem recarregar, `git` só apareceria num
# terminal novo — e o clone deste repo falharia logo depois de instalá-lo.
function Update-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# Procura o pwsh.exe DEPOIS de recarregar o PATH do registry: recém-instalado,
# ele existe no disco mas ainda não está no PATH herdado por esta sessão. Os
# caminhos fixos cobrem o caso do MSI (Program Files) e o do pacote de escopo
# user, quando o PATH ainda não propagou.
function Find-Pwsh {
  Update-PathFromRegistry
  # -First 1: com pwsh.exe em mais de um diretório do PATH, o Get-Command devolve
  # uma entrada por ocorrência — e $cmd.Source viraria um ARRAY, que quebraria o
  # `-File` mais adiante de um jeito difícil de ler.
  $cmd = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return [string] $cmd.Source }

  $candidates = New-Object System.Collections.ArrayList
  if ($env:ProgramFiles)  { [void] $candidates.Add((Join-Path $env:ProgramFiles  'PowerShell\7\pwsh.exe')) }
  if ($env:LOCALAPPDATA)  { [void] $candidates.Add((Join-Path $env:LOCALAPPDATA  'Microsoft\PowerShell\7\pwsh.exe')) }
  foreach ($c in $candidates) {
    if (Test-Path -Path $c) { return $c }
  }
  return $null
}

function Test-Winget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
  try {
    Invoke-Exe -File 'winget' -Arguments @('--version') | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

# Idempotência real do winget: ele retorna código NÃO-ZERO em no-ops.
#   0            sucesso
#   -1978335135  0x8A150061  pacote já instalado
#   -1978335189  0x8A15002B  nada a atualizar
# NÃO inclua -1978335212 (0x8A150014, "no packages found") aqui: isso é erro de
# casing no `-e` (que é case-sensitive), não no-op.
$WingetOk = @(0, -1978335135, -1978335189)

# Elevação importa aqui só para saber o que avisar. O modelo do repo é: rodar
# SEM elevação e deixar o setup.ps1 se auto-elevar apenas para o bloco HKLM.
# (No PS 5.1 o escopo default do Install-Module é AllUsers — daí os fallbacks
# para -Scope CurrentUser mais abaixo.)
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$Elevated = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# A PSGallery só aceita TLS 1.2 e o .NET Framework do PS 5.1 ainda negocia
# TLS 1.0 por padrão. Sem isto, Install-Module falha com um erro de conexão
# genérico que não menciona TLS em lugar nenhum.
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

info "windows-setup / bootstrap"
Write-Host "  PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "  Elevado    : $Elevated"
Write-Host "  Destino    : $TargetDir"
Write-Host "  Ref        : $Ref"
if ($Elevated) {
  warn "Esta sessão está ELEVADA — e NÃO deveria estar."
  Write-Host "      Rodar o provisionamento como Administrador quebra coisas em silêncio:"
  Write-Host "        - toda escrita em HKCU vai para o perfil do ADMIN, não para o seu;"
  Write-Host "        - pacote winget de escopo user instala na conta do admin, e alguns"
  Write-Host "          (Spotify.Spotify, MSIX per-user) FALHAM em shell elevado;"
  Write-Host '        - o $PROFILE, o clone do repo e o PATH que interessam são os do seu usuário.'
  Write-Host "      Feche este terminal, abra um COMUM e rode de novo."
  Write-Host "      O UAC pedindo confirmação por pacote machine-wide é o comportamento certo,"
  Write-Host "      e o setup.ps1 se auto-eleva sozinho só para a parte HKLM."
} else {
  ok "Sessão não elevada — é exatamente assim que tem que ser (ver bloco ELEVAÇÃO no topo)."
}

# --- 2. Execution policy e Mark-of-the-Web ---

info "Ajustando execution policy..."
# Windows 11 client vem 'Restricted': nenhum .ps1 roda. RemoteSigned no escopo
# CurrentUser não exige admin e é o mínimo que deixa o repo funcionar.
try {
  $current = Get-ExecutionPolicy -Scope CurrentUser
  if ($current -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    ok "ExecutionPolicy (CurrentUser) = RemoteSigned"
  } else {
    ok "ExecutionPolicy (CurrentUser) já é $current"
  }
} catch {
  # GPO/MDM pode travar o escopo. Não é fatal: dá para seguir com -ExecutionPolicy Bypass.
  warn "Não consegui ajustar a execution policy ($($_.Exception.Message)). Continue usando 'powershell -ExecutionPolicy Bypass -File ...'."
}

# Um .ps1 que veio de pendrive ou download carrega Mark-of-the-Web e continua
# bloqueado mesmo sob RemoteSigned. `git clone` NÃO marca — só arquivos baixados.
if ($PSScriptRoot) {
  try {
    Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -ErrorAction SilentlyContinue | Unblock-File
    ok "Mark-of-the-Web removido dos .ps1 em $PSScriptRoot"
  } catch {
    warn "Unblock-File falhou: $($_.Exception.Message)"
  }
}

# --- 3. winget: recuperação numa instalação limpa ---

info "Verificando o winget (App Installer)..."
if (Test-Winget) {
  ok "winget disponível"
} else {
  warn "winget indisponível. Isso é ESPERADO logo após uma instalação limpa: o App Installer se registra de forma assíncrona, via Store, depois do primeiro login (~15 min em alguns builds)."
  info "Aplicando o caminho de recuperação documentado (módulo Microsoft.WinGet.Client)..."

  # A CLI `winget` é NÃO SUPORTADA em contexto SYSTEM — lá só o módulo
  # PowerShell funciona. Por isso o caminho de recuperação é o módulo, e não
  # um instalador do msixbundle na mão.
  try {
    Install-PackageProvider -Name NuGet -Force | Out-Null
  } catch {
    # No PS 5.1 o escopo default é AllUsers e exige admin.
    warn "Install-PackageProvider falhou no escopo padrão; tentando CurrentUser..."
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
  }

  try {
    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
  } catch {
    warn "Install-Module falhou no escopo padrão; tentando CurrentUser..."
    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope CurrentUser | Out-Null
  }

  Import-Module Microsoft.WinGet.Client

  # -Latest pega a release mais nova do App Installer em vez da mínima.
  # (winget-cli #5826, que fazia desconfiar de -Latest, foi fechado em out/2025.)
  Repair-WinGetPackageManager -Force -Latest

  Update-PathFromRegistry
  if (Test-Winget) {
    ok "winget recuperado"
  } else {
    die "winget continua indisponível. Plano B offline (ver README/manual.md): instale Microsoft.DesktopAppInstaller_*.msixbundle MAIS o DesktopAppInstaller_Dependencies.zip (VCLibs Desktop + Microsoft.UI.Xaml). Sem as dependências o Add-AppxPackage falha."
  }
}

# --- 4. winget: App Installer e sources em dia ---

# Primeira ação de provisionamento, antes de qualquer pacote: um App Installer
# velho falha de formas criativas (manifests novos, schema novo) e a source
# desatualizada faz `-e` não achar ID que existe.
info "Atualizando o App Installer e as sources do winget..."

# Best-effort: qualquer código de saída aqui vira aviso, não morte. Se a source
# msstore estiver instável, não faz sentido travar o bootstrap inteiro.
Invoke-Exe -File 'winget' -Arguments @(
  'upgrade', 'Microsoft.AppInstaller',
  '--accept-package-agreements', '--accept-source-agreements',
  '--silent', '--disable-interactivity'
)
if ($LASTEXITCODE -in $WingetOk) {
  ok "App Installer em dia"
} else {
  warn "winget upgrade Microsoft.AppInstaller retornou $LASTEXITCODE (seguindo mesmo assim)"
}

Invoke-Exe -File 'winget' -Arguments @('source', 'update')
if ($LASTEXITCODE -eq 0) {
  ok "sources do winget atualizadas"
} else {
  warn "winget source update retornou $LASTEXITCODE (seguindo mesmo assim)"
}

# --- 5. Git ---

info "Instalando o Git..."
if (Get-Command git -ErrorAction SilentlyContinue) {
  ok "Git já instalado: $(Invoke-Exe -File 'git' -Arguments @('--version'))"
} else {
  # `-e/--exact` é CASE-SENSITIVE: Git.Git != git.git. Um ID com casing errado
  # retorna -1978335212 (no packages found), que de propósito NÃO está no
  # allowlist de no-op.
  Invoke-Exe -File 'winget' -Arguments @(
    'install', '--id', 'Git.Git', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements',
    '--silent', '--disable-interactivity', '--no-upgrade'
  )
  if ($LASTEXITCODE -notin $WingetOk) { die "winget falhou ($LASTEXITCODE) em Git.Git" }

  Update-PathFromRegistry
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    die "Git instalado mas fora do PATH desta sessão. Feche e reabra o terminal e rode o bootstrap de novo."
  }
  ok "Git instalado: $(Invoke-Exe -File 'git' -Arguments @('--version'))"
}

# --- 6. PowerShell 7 ---

# O setup.ps1 e o windows-defaults.ps1 rodam sob pwsh, e um Windows recém-
# instalado só tem o 5.1. Quem fecha essa lacuna é ESTE ponto do bootstrap —
# não o setup.ps1 (que já precisaria do pwsh para rodar) e não packages/*.json
# (que é consumido pelo setup.ps1, depois). Um dono por assunto.
info "Instalando o PowerShell 7..."
$Pwsh = Find-Pwsh
if ($Pwsh) {
  ok "PowerShell 7 já instalado: $Pwsh"
} else {
  # --installer-type wix força o MSI. O MSIX (que o manifest também oferece)
  # instala como app empacotado e, nesse formato, o PowerShell não registra o
  # perfil AllUsers nem aceita `Set-ExecutionPolicy -Scope LocalMachine`.
  #
  # ⚠️ Isso vale enquanto o winget servir 7.6.x. A PARTIR DO 7.7.0 NÃO EXISTE
  # MSI no manifest do winget: quando a versão publicada passar disso, o
  # `--installer-type wix` deixa de casar e cai no fallback abaixo. O caminho
  # limpo, nesse dia, é baixar o MSI (ou o ZIP) do release do GitHub —
  # https://github.com/PowerShell/PowerShell/releases — conferir o hash e
  # instalar à mão. Este script não baixa binário de release por conta própria
  # de propósito: numa máquina recém-instalada, download não revisado é
  # exatamente o que o bloco SEGURANÇA do topo manda evitar.
  $pwshArgs = @(
    'install', '--id', 'Microsoft.PowerShell', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements',
    '--silent', '--disable-interactivity', '--no-upgrade'
  )
  Invoke-Exe -File 'winget' -Arguments ($pwshArgs + @('--installer-type', 'wix'))
  $pwshCode = $LASTEXITCODE

  if ($pwshCode -notin $WingetOk) {
    warn "winget falhou ($pwshCode) em Microsoft.PowerShell com --installer-type wix."
    warn "Causa provável: a versão publicada já é 7.7.0+, que não tem MSI no winget."
    info "Tentando de novo com o instalador default do manifest..."
    Invoke-Exe -File 'winget' -Arguments $pwshArgs
    if ($LASTEXITCODE -notin $WingetOk) {
      die "winget falhou ($LASTEXITCODE) em Microsoft.PowerShell. Instale o PowerShell 7 na mão pelo MSI do release (https://github.com/PowerShell/PowerShell/releases) e rode o bootstrap de novo."
    }
    warn "PowerShell 7 instalado com o instalador DEFAULT (provavelmente MSIX). Consequências: perfil AllUsers não é registrado e 'Set-ExecutionPolicy -Scope LocalMachine' não pega. Para o setup.ps1 isso basta, mas se atrapalhar, troque pelo MSI do release do GitHub."
  }

  $Pwsh = Find-Pwsh
  if (-not $Pwsh) {
    die "PowerShell 7 instalado, mas o pwsh.exe não apareceu no PATH nem nos caminhos conhecidos. Feche e reabra o terminal e rode o bootstrap de novo."
  }
  ok "PowerShell 7 instalado: $Pwsh"
}
Write-Host "  pwsh: $((Invoke-Exe -File $Pwsh -Arguments @('--version')) -join ' ')"

# --- 7. Repositório (clone pinado, ou cópia manual do pendrive) ---

# Cópia manual: alguém trouxe o repo no pendrive (é o que a Fase 3 do plano
# manda estagiar) e não há remoto para clonar. Reconhecer isso deixa o bootstrap
# funcionar 100% offline — que é justamente o cenário "repo ainda não publicado".
$GitDir     = Join-Path $TargetDir '.git'
$ManualCopy = (-not (Test-Path $GitDir)) -and (Test-Path (Join-Path $TargetDir 'setup.ps1'))

if ($ManualCopy) {
  info "Usando a cópia local em $TargetDir"
  warn "$TargetDir tem um setup.ps1 mas NÃO é um repositório git (cópia manual do pendrive?). Pulando clone e checkout — nada é sobrescrito, e atualizações terão que ser copiadas na mão."
} else {
  $RefIsFullSha = $Ref -match '^[0-9a-fA-F]{40}$'
  if (-not $RefIsFullSha -and $Ref -match '^[0-9a-fA-F]{4,39}$') {
    die "-Ref '$Ref' parece um SHA abreviado. Uma tag com esse nome teria prioridade sobre o commit, então passe o SHA completo (40 caracteres): git rev-parse $Ref"
  }
  if ($Ref -eq 'main') {
    warn "Você está clonando o branch 'main'. Numa máquina recém-instalada prefira o SHA completo revisado: -Ref <sha> (ver bloco SEGURANÇA no topo)."
  }

  info "Clonando o repositório em $TargetDir..."
  # Sem `-c core.symlinks=true` de propósito. Symlink no Windows exige
  # SeCreateSymbolicLinkPrivilege (admin ou Developer Mode), e o Git for Windows
  # vem com core.symlinks=false por padrão. Este repo foi desenhado para NÃO
  # depender de symlink no lado Windows (stub que faz dot-source no $PROFILE,
  # $env:STARSHIP_CONFIG apontando para o clone). Ligar symlink aqui só criaria
  # uma falha silenciosa a mais.
  $parent = Split-Path -Parent $TargetDir
  if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  if (Test-Path $GitDir) {
    ok "Repositório já existe — atualizando"
    Invoke-Exe -File 'git' -Arguments @('-C', $TargetDir, 'fetch', '--tags', '--prune', 'origin')
    if ($LASTEXITCODE -ne 0) { warn "git fetch retornou $LASTEXITCODE" }
  } else {
    # `git clone` recusa destino não vazio. Diagnosticar isso ANTES evita
    # atribuir a falha à URL (que é o outro motivo provável, logo abaixo).
    if (Test-Path $TargetDir) {
      $existing = @(Get-ChildItem -Path $TargetDir -Force -ErrorAction SilentlyContinue)
      if ($existing.Count -gt 0) {
        die "$TargetDir já existe e não está vazio, mas não é um clone git nem tem um setup.ps1. Mova ou apague a pasta (ou passe -TargetDir <outro caminho>) e rode de novo."
      }
    }

    # Repo inexistente e repo privado são a MESMA resposta para o GitHub: 404.
    # O git reage a isso pedindo usuário/senha — e, com o Credential Manager do
    # Git for Windows, abrindo uma janela. Num terminal recém-aberto de máquina
    # nova isso vira um bootstrap travado esperando entrada que ninguém vai dar.
    # Este repo é público: desligamos prompt e credential helper só para o clone,
    # para que a falha seja RÁPIDA e diagnosticável em vez de silenciosa.
    $prevPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
      Invoke-Exe -File 'git' -Arguments @('-c', 'credential.helper=', 'clone', '--', $RepoUrl, $TargetDir)
      $cloneCode = $LASTEXITCODE
    } finally {
      if ($null -eq $prevPrompt) {
        Remove-Item -Path 'Env:GIT_TERMINAL_PROMPT' -ErrorAction SilentlyContinue
      } else {
        $env:GIT_TERMINAL_PROMPT = $prevPrompt
      }
    }

    if ($cloneCode -ne 0) {
      Write-Host ""
      warn "git clone falhou ($cloneCode) em $RepoUrl"
      if (-not $PSBoundParameters.ContainsKey('RepoUrl')) {
        # -RepoUrl não foi passado => esta é a URL default do script.
        Write-Host "  Causa mais provável: O REPOSITÓRIO AINDA NÃO FOI PUBLICADO."
        Write-Host "  Esta é a URL default do bootstrap e ela só passa a resolver depois que"
        Write-Host "  você criar o repo no GitHub e der push. Até lá o GitHub devolve 404"
        Write-Host "  (mesma resposta que daria para um repo privado) e o git falha na"
        Write-Host "  autenticação — não em 'repositório não encontrado'."
      } else {
        Write-Host "  Confira a URL, a rede e se você tem acesso ao remoto."
      }
      Write-Host ""
      Write-Host "  Saídas, em ordem de preferência:"
      Write-Host "    1. Publique o repo (git push) e rode o bootstrap de novo."
      Write-Host "    2. Aponte para o remoto certo:"
      Write-Host "         -RepoUrl https://github.com/<usuario>/<repo>.git"
      Write-Host "    3. Sem rede / sem repo publicado: copie a pasta do repo (do pendrive)"
      Write-Host "       para $TargetDir e rode o bootstrap de novo — ele detecta a cópia"
      Write-Host "       manual, pula o clone e segue direto para o setup.ps1."
      Write-Host ""
      die "Não foi possível obter o repositório."
    }
  }

  Invoke-Exe -File 'git' -Arguments @('-C', $TargetDir, 'checkout', $Ref)
  if ($LASTEXITCODE -ne 0) { die "git checkout '$Ref' falhou. Confira se a tag/SHA existe no remoto." }

  # O pin é o commit, não o nome: confere o que o checkout realmente trouxe.
  $Head = "$(Invoke-Exe -File 'git' -Arguments @('-C', $TargetDir, 'rev-parse', 'HEAD'))".Trim().ToLowerInvariant()
  $Wanted = if ($ExpectedCommit) { $ExpectedCommit.ToLowerInvariant() } elseif ($RefIsFullSha) { $Ref.ToLowerInvariant() } else { $null }
  if ($Wanted -and $Head -ne $Wanted) {
    die "O checkout de '$Ref' trouxe o commit $Head, não o $Wanted revisado. A tag pode ter sido movida — não rode este código."
  }
  if (-not $Wanted -and $Ref -ne 'main') {
    warn "'$Ref' resolveu para o commit $Head, mas uma tag pode ser movida por quem tem push. Para pinar de verdade use -Ref <sha completo> ou -ExpectedCommit <sha>."
  }

  # Se $Ref for um branch, alinha com o remoto. Se for tag ou SHA, o checkout
  # deixou o HEAD detached e o pull falha — o que é o comportamento desejado num
  # clone pinado, então é só aviso.
  Invoke-Exe -File 'git' -Arguments @('-C', $TargetDir, 'pull', '--ff-only')
  if ($LASTEXITCODE -ne 0) {
    ok "HEAD pinado em '$Ref' (sem pull — é isso que se espera de tag/SHA)"
  } else {
    ok "Branch '$Ref' alinhado com o remoto"
  }
}

# --- 8. Handoff para o setup.ps1 (sob pwsh, não sob 5.1) ---

$Setup = Join-Path $TargetDir 'setup.ps1'
$HandoffCmd = "`"$Pwsh`" -NoLogo -NoProfile -File `"$Setup`" -Stage 1"

if (-not (Test-Path $Setup)) {
  warn "setup.ps1 não encontrado em $TargetDir (o clone trouxe a ref '$Ref')."
  info "Bootstrap concluído. Rode o setup manualmente quando o arquivo existir."
} elseif ($SkipSetup) {
  info "Handoff pulado (-SkipSetup). Próximo passo, manualmente:"
  Write-Host "    $HandoffCmd"
} else {
  info "Chamando o setup.ps1 (estágio 1) sob o PowerShell 7..."
  # -NoProfile: o $PROFILE é escrito pelo PRÓPRIO setup.ps1. Carregar um perfil
  # meio-escrito (ou herdado de outra máquina) aqui só cria falha aleatória.
  #
  # A checagem é do CÓDIGO DE SAÍDA, não de try/catch. Um script que termina com
  # `exit 1` — ou que só imprime erro e volta — NÃO lança exceção nenhuma no
  # chamador: o catch nunca dispararia e o bootstrap seguiria imprimindo
  # "Bootstrap concluído" em cima de um setup que morreu. Foi exatamente esse o
  # bug da versão anterior.
  Invoke-Exe -File $Pwsh -Arguments @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $Setup, '-Stage', '1'
  )
  $SetupCode = $LASTEXITCODE
  if ($SetupCode -ne 0) {
    Write-Host ""
    Write-Host "  O estágio 1 do setup.ps1 NÃO terminou bem. Nada aqui foi 'concluído'."
    Write-Host "  Leia a saída acima, corrija, e rode de novo (é idempotente):"
    Write-Host "    $HandoffCmd"
    die "setup.ps1 -Stage 1 saiu com código $SetupCode."
  }
  ok "setup.ps1 (estágio 1) concluído (código 0)"
}

info "Bootstrap concluído."
Write-Host "  Repositório : $TargetDir"
Write-Host "  PowerShell 7: $Pwsh"
Write-Host "  Depois      : reinicie, rode o estágio 2 do setup.ps1, e então"
Write-Host "                (num terminal ELEVADO, o verify só lê)"
Write-Host "                `"$Pwsh`" -File `"$(Join-Path $TargetDir 'windows-verify.ps1')`""
Write-Host ""
Write-Host "  Lembre: BIOS, Secure Boot, TPM e a chave de recuperação do BitLocker"
Write-Host "  NÃO são feitos por script nenhum daqui. Ver README."
