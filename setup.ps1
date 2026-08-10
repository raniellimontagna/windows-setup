#
# setup.ps1 — configura um Windows 11 novo para desenvolvimento e jogos.
#             Análogo direto do setup.sh do mac-setup.
#
# Uso:  pwsh -File setup.ps1 -Stage 1     # antes do reboot: Developer Mode, winget, features
#       pwsh -File setup.ps1 -Stage 2     # depois do reboot: pacotes, git, ssh, vscode
#       pwsh -File setup.ps1              # sem -Stage: decide sozinho pelo marker em disco
#
# Flags:
#   -WithWSL        habilita o WSL2. OFF por padrão de propósito: Virtual Machine Platform
#                   põe o Windows inteiro sob o hypervisor (2-5% de FPS) e "desabilite
#                   Hyper-V/VBS/WSL" é conselho de primeira linha no troubleshooting do
#                   anticheat do EA FC — que é o motivo desta máquina existir.
#   -WithDebloat    roda o Win11Debloat com o win11debloat.config.json do repo, no stage 1
#                   e ANTES de qualquer pacote. A ordem é obrigatória: a config remove o
#                   stub SpotifyAB.SpotifyMusic da Store, e rodar isso depois do winget
#                   desinstalaria o Spotify.Spotify recém-instalado.
#   -WithDefaults   chama windows-defaults.ps1 no fim. Por padrão NÃO chama, exatamente como
#                   o setup.sh não chama o macos-defaults.sh: ajuste de sistema é opt-in.
#   -SkipPackages   pula os `winget import` (útil para re-rodar só a parte de configuração).
#   -ElevatedTask   USO INTERNO. É como o script se auto-eleva para tocar HKLM/features.
#
# RODE SEM ELEVAÇÃO. O script pede UAC só nos trechos que precisam (HKLM, DISM, serviço,
# git --system, Win11Debloat). Rodar tudo elevado escreveria HKCU e pacotes per-user no
# perfil da conta elevada — o clássico "instalei e sumiu". Nenhum `winget import` roda
# elevado: ver a seção 9.
#
# Seguro rodar várias vezes (idempotente).
#
param(
  [ValidateSet('1', '2')]
  [string]$Stage,

  [switch]$WithWSL,
  [switch]$WithDebloat,
  [switch]$WithDefaults,
  [switch]$SkipPackages,

  [ValidateSet('devmode', 'wsl-features', 'git-system', 'ssh-agent')]
  [string]$ElevatedTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A partir do PowerShell 7.4 comandos nativos com exit code != 0 LANÇAM exceção quando
# $ErrorActionPreference = 'Stop'. Isso atropelaria o allowlist do winget (que retorna
# códigos != 0 em no-op) antes da gente conseguir olhar para o $LASTEXITCODE.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

# --- 0. Helpers de saída e de sistema ---

function info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok($m) { Write-Host "OK  $m" -ForegroundColor Green }
function warn($m) { Write-Host "AVISO $m" -ForegroundColor Yellow }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Recarrega o PATH do registry para a sessão atual. Necessário porque o winget acabou de
# instalar coisas (git, code, delta...) e o processo atual herdou o PATH de antes.
# Efeito colateral aceito: descarta acréscimos feitos só no processo.
function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# Mesma primitiva do windows-defaults.ps1: `New-ItemProperty -Force` NÃO cria a chave pai
# e lança exceção quando ela não existe — e várias chaves de policy não existem num
# Windows limpo. Sempre garanta a chave antes de escrever o valor.
function Set-Reg {
  param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
  Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
  ok "$Path\$Name = $Value"
}

# --- 0.1 Wrapper do winget (idempotência real) ---

# winget retorna código != 0 em no-op: sem allowlist, o segundo `setup.ps1` morre na
# primeira linha de "já instalado".
$WingetOkExit = @(0, -1978335135, -1978335189)   # 0x8A150061 ja instalado; 0x8A15002B nada a atualizar

# NÃO adicione -1978335212 (0x8A150014, "no packages found") a essa lista. Isso não é
# no-op: é erro de casing no -e/--exact, que é case-sensitive (Git.Git != git.git).
# Tratar como sucesso esconderia exatamente o bug que a gente mais quer ver — um ID
# escrito errado num Mac, descoberto só depois do wipe.

function Invoke-Winget {
  param(
    [Parameter(Mandatory)][string[]]$WingetArgs,
    [Parameter(Mandatory)][string]$What,
    [switch]$Tolerante   # avisa em vez de abortar (usado nos import, que são em lote)
  )
  # Out-Host explícito: sem isso a saída do winget vira valor de retorno da função e
  # some no `| Out-Null` de quem chama — você ficaria olhando para um terminal mudo
  # durante um import de 30 pacotes.
  & winget @WingetArgs | Out-Host
  if ($LASTEXITCODE -notin $WingetOkExit) {
    if ($Tolerante) {
      warn "winget falhou ($LASTEXITCODE) em $What — confira a saída acima."
      return $false
    }
    throw "winget falhou ($LASTEXITCODE) em $What"
  }
  ok $What
  return $true
}

function Import-WingetFile {
  param([Parameter(Mandatory)][string]$File)
  if (-not (Test-Path $File)) {
    warn "packages: $(Split-Path -Leaf $File) não existe — pulando."
    return
  }
  info "winget import: $(Split-Path -Leaf $File)"
  # `winget import` é ADITIVO: nunca remove nada, nunca converge. Não é `brew bundle --cleanup`.
  # E é uma passada serial, sem grafo de dependências e sem resume de reboot — por isso os stages.
  Invoke-Winget -Tolerante -What "import $(Split-Path -Leaf $File)" -WingetArgs @(
    'import', '--import-file', $File,
    '--accept-package-agreements', '--accept-source-agreements',
    '--disable-interactivity'
  ) | Out-Null
}

# O settings.json tem que aterrissar ANTES de qualquer bulk install, senão a preferência
# de scope nunca se aplica aos pacotes já instalados.
# Package family name do App Installer é fixo — não é caminho pessoal.
function Write-WingetSettings {
  $dir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'
  $file = Join-Path $dir 'settings.json'
  $json = @'
{
    "$schema": "https://aka.ms/winget-settings.schema.json",
    "installBehavior": {
        "preferences": {
            "scope": "user"
        }
    },
    "telemetry": {
        "disable": true
    }
}
'@
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  if (Test-Path $file) {
    $atual = Get-Content $file -Raw -ErrorAction SilentlyContinue
    if ($atual -and $atual.Trim() -eq $json.Trim()) { ok 'winget settings.json já está aplicado'; return }
    # Mesma cortesia do setup.sh com o .zshrc: guarda o antigo antes de sobrescrever.
    Copy-Item $file "$file.backup" -Force
    warn "settings.json anterior salvo em $file.backup"
  }
  Set-Content -Path $file -Value $json -Encoding utf8NoBOM
  ok "winget settings.json escrito (scope=user, telemetry off)"
}

# --- 0.2 Auto-elevação ---

# Relança ESTE script elevado rodando só uma tarefa (-ElevatedTask) e espera terminar.
# A janela elevada fecha sozinha, então a tarefa loga em $StateDir.
function Invoke-Elevated {
  param([Parameter(Mandatory)][string]$Task, [string]$Descricao = $Task)
  info "Precisa de UAC: $Descricao"
  $exe = (Get-Process -Id $PID).Path
  $cmdline = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ElevatedTask $Task"
  $p = Start-Process -FilePath $exe -ArgumentList $cmdline -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    warn "Tarefa elevada '$Task' terminou com $($p.ExitCode)."
    # O UAC pode ter elevado OUTRA conta — então um caminho derivado de %LOCALAPPDATA%
    # ou de %USERPROFILE% daqui apontaria para um log que não existe naquele perfil.
    # $StateDir mora em ProgramData justamente para o filho resolver o MESMO caminho,
    # seja qual for a conta. Ainda assim o arquivo só existe se o filho chegou a abrir
    # o transcript: falha antes disso (UAC negado, política, script bloqueado) não loga.
    warn "Log esperado (se o filho chegou a abrir o transcript): $(Join-Path $StateDir "elevated-$Task.log")"
    return $false
  }
  ok "Tarefa elevada '$Task' concluída"
  return $true
}

# --- 1. Contexto: repo, estado, sanidade ---

$RepoDir = Split-Path -Parent $PSCommandPath
# O estado mora FORA do repo (o repo é público e isto é estado de máquina) e FORA de
# %LOCALAPPDATA%. Motivo: %LOCALAPPDATA% e %USERPROFILE% mudam quando o UAC eleva OUTRA
# conta. Um stage 1 rodado elevado por engano gravaria o marker num perfil que a sessão
# normal não enxerga — e o stage 1 rodaria inteiro de novo, em silêncio, com Developer
# Mode e settings.json do winget aparentemente "não aplicados". ProgramData é o mesmo
# caminho para toda conta da máquina, elevada ou não; é também o que faz o log da tarefa
# elevada ser encontrável (ver Invoke-Elevated).
$StateDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'windows-setup'
$Stage1Marker = Join-Path $StateDir 'stage1.done'
$MacSetupDir = Join-Path $env:USERPROFILE 'Projetos\pessoal\mac-setup'

if ($PSVersionTable.PSVersion.Major -lt 7) {
  warn "Este script exige PowerShell 7 (pwsh) — esta sessão é $($PSVersionTable.PSVersion)."
  warn 'Quem instala o PowerShell 7 é o bootstrap.ps1: ele roda no 5.1 (o único PowerShell'
  warn 'que um Windows recém-instalado tem), instala o pwsh e rechama este script sob ele.'
  Write-Host '  Se o bootstrap ainda não rodou:'
  Write-Host "    powershell -ExecutionPolicy Bypass -File `"$(Join-Path $RepoDir 'bootstrap.ps1')`""
  Write-Host '  Se já rodou, é só reabrir no pwsh (repetindo as flags que você usou):'
  Write-Host "    pwsh -File `"$PSCommandPath`""
  # throw, não `exit 1`: quem chama este script com & ou . só consegue capturar num
  # try/catch se o erro for terminante. `exit` encerraria o processo sem disparar catch
  # algum — e ainda por cima o bootstrap.ps1 chama daqui.
  throw 'setup.ps1 exige PowerShell 7 (pwsh).'
}

# --- 2. Modo elevado: executa SÓ a tarefa pedida e sai ---

if ($ElevatedTask) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $log = Join-Path $StateDir "elevated-$ElevatedTask.log"
  try { Start-Transcript -Path $log -Force | Out-Null } catch { }
  $codigo = 0
  try {
    switch ($ElevatedTask) {

      'devmode' {
        # Developer Mode. Sem isso, `New-Item -ItemType SymbolicLink` exige
        # SeCreateSymbolicLinkPrivilege e metade de qualquer estratégia de dotfiles
        # falha em SILÊNCIO. Ligamos cedo e reconferimos depois (seção 4).
        # DONO ÚNICO: esta chave é escrita AQUI. O windows-defaults.ps1 deliberadamente
        # NÃO a duplica — o setup.ps1 precisa dela cedo, e dois escritores para a mesma
        # chave é como divergência começa.
        Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
          -Name 'AllowDevelopmentWithoutDevLicense' -Value 1
      }

      'wsl-features' {
        # `wsl --install --no-distribution` só é honrado se o WSL ainda NÃO estiver
        # instalado — chamar incondicionalmente vira no-op silencioso. Quem ramifica
        # é a seção 7, aqui a decisão já foi tomada.
        wsl --install --no-distribution
        if ($LASTEXITCODE -ne 0) { throw "wsl --install --no-distribution falhou ($LASTEXITCODE)" }
        ok 'WSL habilitado (Virtual Machine Platform). Exige reboot.'
      }

      'git-system' {
        # LongPathsEnabled=1 no registry só vale para apps com manifest longPathAware.
        # O git precisa do dele, e o --system fica em C:\Program Files\Git\etc\gitconfig.
        git config --system core.longpaths true
        if ($LASTEXITCODE -ne 0) { throw "git config --system falhou ($LASTEXITCODE)" }
        ok 'git: core.longpaths=true no escopo --system'
      }

      'ssh-agent' {
        $svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if (-not $svc) { throw 'Serviço ssh-agent não existe (OpenSSH Client não instalado?)' }
        Set-Service -Name ssh-agent -StartupType Automatic
        if ($svc.Status -ne 'Running') { Start-Service -Name ssh-agent }
        ok 'ssh-agent: Automatic + Running'
      }

      # NÃO existe tarefa elevada 'packages' aqui, de propósito — ver a seção 9.
    }
  }
  catch {
    warn "Falha na tarefa elevada '$ElevatedTask': $($_.Exception.Message)"
    $codigo = 1
  }
  finally {
    try { Stop-Transcript | Out-Null } catch { }
  }
  exit $codigo
}

# --- 3. Qual stage rodar ---

if (Test-Admin) {
  warn 'Esta sessão está ELEVADA. HKCU e pacotes per-user vão para o perfil da conta elevada.'
  warn 'O recomendado é fechar e rodar o setup.ps1 sem elevação — ele pede UAC sozinho.'
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# "Que stage é este?" é a decisão mais fácil de errar em silêncio do script inteiro —
# então ela é EXPLICADA em voz alta, com o caminho exato que foi consultado.
if ($Stage) {
  $StageToRun = [int]$Stage
  $MotivoStage = "-Stage $Stage foi passado explicitamente (o marker nem foi consultado)"
}
elseif (Test-Path $Stage1Marker) {
  $StageToRun = 2
  $carimbo = (Get-Content $Stage1Marker -Raw -ErrorAction SilentlyContinue)
  $carimbo = if ($carimbo) { $carimbo.Trim() } else { 'sem carimbo' }
  $MotivoStage = "o marker do stage 1 existe ($Stage1Marker, de $carimbo)"
}
else {
  $StageToRun = 1
  $MotivoStage = "não existe marker do stage 1 em $Stage1Marker"
}

Write-Host ''
Write-Host "windows-setup — stage $StageToRun" -ForegroundColor Magenta
Write-Host "repo:   $RepoDir"
Write-Host "state:  $StateDir"
Write-Host "porquê: $MotivoStage"

if ($StageToRun -eq 1) {

  # --- 4. Developer Mode (cedo, e RECONFERIDO) ---
  # Developer Mode é dono deste script e de mais ninguém: o windows-defaults.ps1 tinha
  # a mesma escrita e ela foi REMOVIDA de lá de propósito. Aqui ela precisa acontecer
  # cedo (symlink e Store sideload dependem dela); lá seria um segundo escritor para a
  # mesma chave, com a chance de divergir na próxima edição.
  info 'Habilitando Developer Mode...'
  $unlockKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
  function Get-DevMode {
    $p = Get-ItemProperty -Path $unlockKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
    if ($p) { return $p.AllowDevelopmentWithoutDevLicense }
    return $null
  }
  $devMode = Get-DevMode
  if ($devMode -ne 1) {
    Invoke-Elevated -Task 'devmode' -Descricao 'ligar Developer Mode (HKLM)' | Out-Null
    $devMode = Get-DevMode
  }
  if ($devMode -eq 1) { ok 'Developer Mode: AllowDevelopmentWithoutDevLicense=1' }
  else { warn 'Developer Mode NÃO ficou ligado. Ligue à mão em Settings > System > For developers.' }

  # Reconferência funcional: o registry pode dizer 1 e o privilégio ainda não valer nesta
  # sessão. Se este teste falhar, prefira as estratégias sem symlink (stub de dot-source
  # no $PROFILE, $env:STARSHIP_CONFIG) — que é o que este repo usa de qualquer forma.
  $probeDir = Join-Path $env:TEMP 'windows-setup-symlink-probe'
  try {
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $alvo = Join-Path $probeDir 'alvo.txt'
    $link = Join-Path $probeDir 'link.txt'
    Set-Content -Path $alvo -Value 'probe' -Encoding utf8NoBOM
    New-Item -ItemType SymbolicLink -Path $link -Target $alvo -ErrorAction Stop | Out-Null
    ok 'Symlink sem elevação: funciona'
  }
  catch {
    warn 'Symlink sem elevação AINDA não funciona (pode precisar de logoff/reboot).'
  }
  finally {
    Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # --- 4.1 Debloat (opt-in, e ANTES de qualquer pacote) ---
  # A ordem não é gosto pessoal, é a PEGADINHA 4 documentada no próprio
  # win11debloat.config.json: a lista remove o stub SpotifyAB.SpotifyMusic da Store.
  # Rodar o debloat DEPOIS do winget desinstalaria o Spotify.Spotify que o stage 2
  # acabou de instalar. Por isso ele vive aqui no stage 1, antes de qualquer import.
  if ($WithDebloat) {
    info 'Debloat pedido explicitamente (-WithDebloat).'
    $debloatCfg = Join-Path $RepoDir 'win11debloat.config.json'
    # O Win11Debloat é ferramenta de terceiro (Raphire/Win11Debloat) e NÃO é vendorizada
    # neste repo — procuramos nos lugares onde ela plausivelmente foi clonada.
    $debloatCandidatos = @(
      (Join-Path $env:USERPROFILE 'Projetos\pessoal\Win11Debloat\Win11Debloat.ps1'),
      (Join-Path $RepoDir 'Win11Debloat\Win11Debloat.ps1'),
      (Join-Path $env:USERPROFILE 'Downloads\Win11Debloat\Win11Debloat.ps1')
    )
    $debloatScript = $debloatCandidatos | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not (Test-Path $debloatCfg)) {
      warn 'win11debloat.config.json não existe no repo — debloat pulado.'
    }
    elseif (-not $debloatScript) {
      # Debloat é higiene, não pré-requisito de nada: avisa e segue.
      warn 'Win11Debloat não encontrado — debloat pulado (o resto do stage 1 continua).'
      warn 'Procurei em:'
      foreach ($c in $debloatCandidatos) { Write-Host "    $c" }
      Write-Host '  Para instalar e rodar o stage 1 de novo:'
      Write-Host "    git clone https://github.com/Raphire/Win11Debloat `"$(Join-Path $env:USERPROFILE 'Projetos\pessoal\Win11Debloat')`""
    }
    else {
      info "Rodando o Win11Debloat: $debloatScript"
      # powershell.exe (5.1) EXPLÍCITO, não pwsh: o módulo Appx falha no PowerShell 7 e
      # o Win11Debloat é inteiro construído em cima dele. Elevado porque a remoção
      # provisionada (AppRemovalScopeIndex 0 = AllUsers) e as chaves HKLM exigem admin.
      $debloatCmd = "-NoProfile -ExecutionPolicy Bypass -File `"$debloatScript`" -Config `"$debloatCfg`" -Silent"
      try {
        $pd = Start-Process -FilePath 'powershell.exe' -ArgumentList $debloatCmd -Verb RunAs -Wait -PassThru
        if ($pd.ExitCode -ne 0) {
          warn "Win11Debloat terminou com $($pd.ExitCode) — confira a saída da janela elevada."
          # Falha típica e inofensiva: XP9CXNGPPJ97XX (Copilot) sai via winget, e o App
          # Installer pode ainda estar se registrando na primeira passada. Rode de novo
          # depois; o tweak DisableCopilot já cobriu a policy.
        }
        else { ok 'Win11Debloat aplicado (config versionada do repo, -Silent)' }
      }
      catch {
        warn "Não consegui rodar o Win11Debloat ($($_.Exception.Message)) — seguindo sem debloat."
      }
    }
  }
  else {
    info 'Debloat: pulado (padrão). Use -WithDebloat para aplicar win11debloat.config.json.'
    Write-Host '  (tem que ser no stage 1: depois dos pacotes, ele desinstalaria o Spotify)'
  }

  # --- 5. winget usável ---
  # O App Installer registra de forma ASSÍNCRONA via Store depois do primeiro login
  # (~15 min em alguns builds). Numa instalação limpa o `winget` pode simplesmente
  # não responder ainda — esperar é normal, não é defeito.
  info 'Verificando se o winget já está usável...'
  $wingetOk = $false
  for ($i = 1; $i -le 10; $i++) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      & winget --version *> $null
      if ($LASTEXITCODE -eq 0) { $wingetOk = $true; break }
    }
    Write-Host "  winget ainda não responde (tentativa $i/10), esperando 30s..."
    Start-Sleep -Seconds 30
    Update-SessionPath
  }

  if (-not $wingetOk) {
    warn 'winget não subiu sozinho — tentando o caminho de reparo pelo módulo PowerShell.'
    # A CLI do winget não é suportada em contexto SYSTEM; só o módulo funciona lá.
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
    Repair-WinGetPackageManager -Force -Latest
    Update-SessionPath
    & winget --version *> $null
    $wingetOk = ($LASTEXITCODE -eq 0)
  }

  if (-not $wingetOk) {
    warn 'winget continua indisponível. Plano B offline está em packages/manual.md'
    warn '(msixbundle do App Installer + DesktopAppInstaller_Dependencies.zip).'
    exit 1
  }
  ok "winget disponível: $(& winget --version)"

  # Primeira ação de provisionamento, antes de qualquer bulk install.
  Invoke-Winget -Tolerante -What 'upgrade Microsoft.AppInstaller' -WingetArgs @(
    'upgrade', 'Microsoft.AppInstaller',
    '--accept-package-agreements', '--accept-source-agreements',
    '--silent', '--disable-interactivity'
  ) | Out-Null
  Invoke-Winget -Tolerante -What 'source update' -WingetArgs @('source', 'update') | Out-Null

  # --- 6. settings.json do winget (ANTES de qualquer instalação em lote) ---
  info 'Escrevendo o settings.json do winget...'
  Write-WingetSettings

  # --- 7. WSL: só as features (opt-in, exige reboot) ---
  if ($WithWSL) {
    info 'WSL2 pedido explicitamente (-WithWSL).'
    warn 'Lembre do custo: Virtual Machine Platform põe o Windows sob o hypervisor.'
    warn 'Válvula de escape para sessões competitivas (rode elevado, exige reboot):'
    warn '  bcdedit /set hypervisorlaunchtype off     # volta com: ... hypervisorlaunchtype auto'

    # .wslconfig ANTES de qualquer distro existir: sparseVhd só afeta VHDs NOVOS.
    $wslconfigSrc = Join-Path $RepoDir 'profile\wslconfig'
    if (Test-Path $wslconfigSrc) {
      Copy-Item $wslconfigSrc (Join-Path $env:USERPROFILE '.wslconfig') -Force
      ok '.wslconfig copiado para %USERPROFILE%'
    }
    else { warn 'profile/wslconfig não existe no repo — pulando.' }

    $env:WSL_UTF8 = '1'   # sem isso o wsl.exe emite UTF-16LE e a saída vira lixo no PowerShell
    $wslPresente = $false
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
      & wsl --version *> $null
      if ($LASTEXITCODE -eq 0) { $wslPresente = $true }
    }

    if ($wslPresente) { ok 'WSL já está instalado — nada a habilitar.' }
    else { Invoke-Elevated -Task 'wsl-features' -Descricao 'habilitar as features do WSL' | Out-Null }
  }
  else {
    info 'WSL2: pulado (padrão). Use -WithWSL se quiser mesmo assim.'
  }

  # --- 8. Marker + reboot ---
  # Um marker que já exista criado por OUTRA conta (stage 1 rodado elevado por engano)
  # pode não ser regravável por esta sessão. Isso não invalida nada — o marker continua
  # lá e continua sendo lido — então avisa em vez de abortar o stage inteiro no fim.
  try {
    Set-Content -Path $Stage1Marker -Value (Get-Date -Format 'o') -Encoding utf8NoBOM
    ok "Stage 1 concluído (marker em $Stage1Marker)"
  }
  catch {
    warn "Stage 1 concluído, mas não consegui gravar o marker em $Stage1Marker"
    warn "($($_.Exception.Message)). Rode o stage 2 com -Stage 2 explícito."
  }

  info 'REINICIE o computador e rode o stage 2:'
  Write-Host '    pwsh -File setup.ps1 -Stage 2'
  if ($WithWSL) {
    Write-Host '  (o reboot é obrigatório: as features do WSL só valem depois dele)'
  }
  else {
    Write-Host '  (o reboot é recomendado: garante PATH e privilégios novos na sessão)'
  }
  exit 0
}

# =============================== STAGE 2 ===============================

if (-not (Test-Path $Stage1Marker)) {
  warn 'Não achei o marker do stage 1. Developer Mode e o settings.json do winget podem'
  warn 'não estar aplicados. Se algo falhar, rode:  pwsh -File setup.ps1 -Stage 1'
}

# --- 9. Pacotes: winget import (tudo sem elevação) ---
if ($SkipPackages) {
  info 'Pacotes: pulados (-SkipPackages).'
}
else {
  info 'Instalando pacotes (winget import)...'

  # TODOS os imports rodam SEM ELEVAÇÃO, inclusive o packages-core.json. Isto já foi
  # feito errado aqui, então vale registrar o porquê:
  #   - o único pacote que "exige admin" é o DEVCOM.JetBrainsMonoNerdFont (fonte
  #     machine-wide), e o packages/manual.md registra o manifest dele como
  #     ElevationRequirement: elevatesSelf — o próprio instalador levanta o UAC quando
  #     precisa. Nunca foi necessário um shell elevado para ele;
  #   - em troca, o import elevado arrastava ~20 apps per-user (Warp, Discord, Obsidian,
  #     Telegram, VS Code, Bitwarden...) para o perfil da conta elevada: o clássico
  #     "instalei e sumiu";
  #   - e o Spotify.Spotify é elevationProhibited: falha de cara em shell elevado.
  # A separação em arquivos continua valendo como documentação e para o -SkipPackages,
  # mas a ordem aqui é só ordem de leitura, não ordem de elevação.
  Import-WingetFile -File (Join-Path $RepoDir 'packages\packages-core.json')
  Import-WingetFile -File (Join-Path $RepoDir 'packages\packages-gaming.json')
  Import-WingetFile -File (Join-Path $RepoDir 'packages\packages-user-scope.json')
  Import-WingetFile -File (Join-Path $RepoDir 'packages\packages-msstore.json')

  # packages-overlays.json (HWiNFO, RTSS, Afterburner) fica DELIBERADAMENTE de fora.
  # O manual.md manda validar o EA FC antes de empilhar overlay, e enquanto os três
  # estavam no packages-gaming.json esse aviso era inaplicável: instalavam junto com o
  # próprio EADesktop, na mesma passada. Separar é o que torna a ordem possível.
  # A falha típica do Javelin em instalação limpa não é Secure Boot — é conflito com
  # software kernel-level/overlay, e depurar isso com três deles já instalados é ruim.
  Write-Host ''
  warn 'Overlays (HWiNFO/RTSS/Afterburner) NÃO foram instalados — de propósito.'
  Write-Host '  Abra o EA FC, entre numa partida e confirme que o anticheat passa.'
  Write-Host '  Só depois disso, e num terminal comum:'
  Write-Host ''
  Write-Host "    winget import -i `"$(Join-Path $RepoDir 'packages\packages-overlays.json')`" ``"
  Write-Host '      --accept-package-agreements --accept-source-agreements --disable-interactivity'
  Write-Host ''
  Write-Host '  Instale um de cada vez e teste o jogo entre eles: é assim que você'
  Write-Host '  descobre QUAL deles brigou, em vez de perder a noite adivinhando.'

  Update-SessionPath
}

# --- 10. Git: identidade, defaults e aliases ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  warn 'git não está no PATH — pulando as seções de Git, SSH e VS Code.'
  warn 'Feche e reabra o terminal (ou rode o stage 2 de novo) depois do import de pacotes.'
}
else {
  info 'Configurando Git...'
  if (-not (git config --global user.name)) {
    $gitName = Read-Host '  Nome para os commits'
    $gitEmail = Read-Host '  Email para os commits'
    git config --global user.name $gitName
    git config --global user.email $gitEmail
  }
  git config --global init.defaultBranch main
  git config --global pull.rebase false
  git config --global push.autoSetupRemote true
  git config --global fetch.prune true
  git config --global core.editor "code --wait"
  git config --global color.ui auto
  git config --global rerere.enabled true

  # gitignore_global é compartilhado com o mac-setup e porta literalmente. Se o mac-setup
  # estiver clonado, aponta direto para lá — sem symlink, sem terceira cópia.
  $gitignoreCompartilhado = Join-Path $MacSetupDir 'gitignore_global'
  if (Test-Path $gitignoreCompartilhado) {
    git config --global core.excludesfile ($gitignoreCompartilhado -replace '\\', '/')
    ok "core.excludesfile -> $gitignoreCompartilhado"
  }
  else {
    $gitignoreLocal = Join-Path $env:USERPROFILE '.gitignore_global'
    git config --global core.excludesfile ($gitignoreLocal -replace '\\', '/')
    warn "mac-setup não clonado: core.excludesfile aponta para $gitignoreLocal (crie o arquivo)."
  }

  # --- 10.1 Bits que só existem no Windows ---
  # DONO ÚNICO: profile/gitconfig-windows. Este script NÃO escreve core.autocrlf,
  # core.longpaths nem core.symlinks direto — antes escrevia, e o arquivo dizia outra
  # coisa; dois escritores para a mesma chave é como divergência começa. Aqui só
  # apontamos a inclusão, e o arquivo versionado explica cada escolha.
  #
  # BARRA NORMAL no caminho: o git no Windows trata "\" como escape dentro de
  # include.path e a inclusão falha EM SILÊNCIO.
  # E `git config --global include.path <x>` SUBSTITUI o valor — nunca use --add aqui,
  # senão cada execução empilha uma inclusão duplicada.
  $gitconfigWindows = Join-Path $RepoDir 'profile\gitconfig-windows'
  if (Test-Path $gitconfigWindows) {
    git config --global include.path ($gitconfigWindows -replace '\\', '/')
    ok "git: include.path -> $gitconfigWindows"
    # Inclusão silenciosa exige conferência explícita: se o caminho estiver errado, o
    # git não reclama — as chaves simplesmente não existem.
    $origemLongpaths = git config --show-origin --get core.longpaths
    if ($origemLongpaths) { Write-Host "  core.longpaths veio de: $origemLongpaths" }
    else { warn 'A inclusão não trouxe core.longpaths — confira o profile/gitconfig-windows.' }
  }
  else {
    warn 'profile/gitconfig-windows não existe no repo: core.autocrlf, core.longpaths e'
    warn 'core.symlinks NÃO foram configurados (este script não os escreve mais direto).'
  }

  # O --global acima (via include.path) cobre este usuário; o --system precisa de admin e
  # é o que faz o longpaths valer também em serviços, runners e sessões de outra conta.
  # São complementares, não alternativos.
  Invoke-Elevated -Task 'git-system' -Descricao 'git config --system core.longpaths true' | Out-Null

  # Aliases úteis do git
  git config --global alias.st "status -sb"
  git config --global alias.co "checkout"
  git config --global alias.br "branch"
  git config --global alias.cm "commit -m"
  git config --global alias.lg "log --oneline --graph --decorate -20"
  git config --global alias.last "log -1 HEAD --stat"
  git config --global alias.unstage "reset HEAD --"

  # git-delta como pager (diffs bonitos), se instalado. No Windows o pacote é
  # dandavison.delta, mas o binário continua se chamando delta.
  if (Get-Command delta -ErrorAction SilentlyContinue) {
    git config --global core.pager delta
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate true
    git config --global merge.conflictStyle zdiff3
    ok 'git-delta configurado como pager'
  }

  # --- 11. Chave SSH para o GitHub ---
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  $sshKey = Join-Path $sshDir 'id_ed25519'
  $sshCfg = Join-Path $sshDir 'config'

  New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

  if (-not (Test-Path $sshCfg)) {
    # `IgnoreUnknown UseKeychain` PRECISA ser a primeira linha: o OpenSSH parseia linha a
    # linha e só ignora um keyword desconhecido se o IgnoreUnknown já tiver aparecido.
    # É isso que deixa UM arquivo servir macOS (UseKeychain) e Windows (não conhece o
    # keyword) sem manter duas versões.
    $sshConfigTexto = @'
IgnoreUnknown UseKeychain

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  AddKeysToAgent yes
  UseKeychain yes
'@
    Set-Content -Path $sshCfg -Value $sshConfigTexto -Encoding utf8NoBOM
    ok "~/.ssh/config criado"
  }

  if (-not (Test-Path $sshKey)) {
    info 'Gerando chave SSH (ed25519)...'
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
      warn 'ssh-keygen não encontrado (OpenSSH Client é feature opcional do Windows).'
    }
    else {
      $emailCommits = git config --global user.email
      # -N '' passa senha vazia. No PowerShell 7 a string vazia chega intacta ao ssh-keygen.
      ssh-keygen -t ed25519 -C $emailCommits -f $sshKey -N '' -q
      ok "chave gerada em $sshKey"
    }
  }

  if (Test-Path $sshKey) {
    # No Windows o agente é um SERVIÇO (não um `eval $(ssh-agent -s)`), e mexer nele
    # exige admin. Só eleva se realmente precisar.
    $agente = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if (-not $agente) {
      warn 'Serviço ssh-agent não existe — instale o OpenSSH Client em Settings > Optional features.'
    }
    else {
      if ($agente.Status -ne 'Running' -or $agente.StartType -ne 'Automatic') {
        Invoke-Elevated -Task 'ssh-agent' -Descricao 'ligar o serviço ssh-agent' | Out-Null
      }
      else { ok 'ssh-agent já está rodando' }

      # Sem --apple-use-keychain aqui: isso é macOS. No Windows o próprio agente persiste.
      if (Get-Command ssh-add -ErrorAction SilentlyContinue) {
        ssh-add $sshKey *> $null
        if ($LASTEXITCODE -ne 0) {
          warn 'ssh-add falhou. Se reclamar de permissão, ajuste as ACLs da pasta .ssh.'
        }
        else { ok 'chave adicionada ao ssh-agent' }
      }
    }

    # A .pub pode não existir se a chave veio de um backup só com a privada.
    if (Test-Path "$sshKey.pub") {
      Write-Host ''
      Write-Host '  >>> Adicione esta chave em https://github.com/settings/ssh/new :'
      Write-Host ''
      Get-Content "$sshKey.pub"
      Write-Host ''
    }
    else {
      warn "Não achei $sshKey.pub — recupere a pública com:  ssh-keygen -y -f $sshKey"
    }
  }

  # --- 12. Git: url.insteadOf (DEPOIS da chave SSH, nunca antes) ---
  # Isto reescreve toda URL https do GitHub para SSH — necessário para módulos Go privados.
  # ARMADILHA DE ORDEM: numa máquina sem chave SSH registrada, essa linha quebra clone
  # anônimo de repo público (inclusive o clone do próprio mac-setup) e o fetch de módulos
  # Go, com erro que não menciona insteadOf. Por isso só aplicamos depois da chave existir.
  if (Test-Path $sshKey) {
    # A chave inteira vai entre aspas simples de propósito: no PowerShell o `@` e o `:`
    # dentro de um token sem aspas são território de parser, e o equivalente literal do
    # setup.sh (url."git@github.com:".insteadOf) depende de concatenação implícita.
    git config --global 'url.git@github.com:.insteadOf' 'https://github.com/'
    ok 'git: url.insteadOf ssh configurado'
  }
  else {
    warn 'Sem chave SSH: url.insteadOf NÃO foi configurado (quebraria clone anônimo).'
    warn 'Rode o stage 2 de novo depois de gerar/restaurar a chave.'
  }
}

# --- 13. Estrutura de pastas ---
info 'Criando a estrutura de pastas...'
New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE 'Projetos\pessoal') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE 'Projetos\empresa') | Out-Null
ok '%USERPROFILE%\Projetos\{pessoal,empresa}'

# --- 14. Perfil do PowerShell (stub de dot-source, sem symlink) ---
# Symlink no Windows é privilegiado; o stub é a estratégia equivalente e sem UAC.
# $PROFILE NÃO tem caminho fixo: com MSA + OneDrive Known Folder Move o Documents é
# redirecionado e vira ...\OneDrive\Documents\PowerShell\... Sempre derive dele.
$perfilRepo = Join-Path $RepoDir 'profile\Microsoft.PowerShell_profile.ps1'
if (Test-Path $perfilRepo) {
  info 'Instalando o stub do $PROFILE...'
  $perfilDir = Split-Path -Parent $PROFILE
  New-Item -ItemType Directory -Force -Path $perfilDir | Out-Null
  if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
  $conteudo = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
  if (-not $conteudo -or $conteudo -notmatch [regex]::Escape($perfilRepo)) {
    Add-Content -Path $PROFILE -Value @(
      '',
      '# windows-setup: carrega o perfil versionado do repo (stub, sem symlink).',
      ". `"$perfilRepo`""
    )
    ok "stub adicionado em $PROFILE"
  }
  else { ok 'stub do $PROFILE já estava lá' }
  # Lembrete: PS 5.1 e PS 7 têm perfis SEPARADOS (WindowsPowerShell\ vs PowerShell\).
  # Este stub vale só para o pwsh, que é a shell canônica aqui.
}
else {
  warn 'profile/Microsoft.PowerShell_profile.ps1 não existe no repo — stub do $PROFILE pulado.'
}

# starship.toml é compartilhado com o mac-setup e porta sem alteração. Em vez de symlink,
# aponta a variável de ambiente do usuário para o arquivo dentro do clone do mac-setup.
$starshipCfg = Join-Path $MacSetupDir 'starship.toml'
if (Test-Path $starshipCfg) {
  if ([Environment]::GetEnvironmentVariable('STARSHIP_CONFIG', 'User') -ne $starshipCfg) {
    [Environment]::SetEnvironmentVariable('STARSHIP_CONFIG', $starshipCfg, 'User')
  }
  $env:STARSHIP_CONFIG = $starshipCfg
  ok "STARSHIP_CONFIG -> $starshipCfg"
}
else {
  warn "mac-setup não clonado em $MacSetupDir — STARSHIP_CONFIG não foi apontado."
}

# --- 15. Extensões do VS Code ---
$extFile = Join-Path $RepoDir 'vscode\extensions.txt'
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd -and (Test-Path $extFile)) {
  info 'Instalando extensões do VS Code...'
  foreach ($linha in Get-Content $extFile) {
    $ext = $linha.Trim()
    if (-not $ext -or $ext.StartsWith('#')) { continue }
    & $codeCmd.Source --install-extension $ext --force *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "  + $ext" }
    else { warn "  falhou: $ext" }
  }
}
elseif (-not $codeCmd) {
  # O `code` só entra no PATH pela opção "Add to PATH" do installer (marcada por padrão).
  warn '`code` não está no PATH — extensões do VS Code puladas. Reabra o terminal e rode de novo.'
}

# --- 16. WSL: distro + cloud-init (opt-in) ---
if ($WithWSL -and -not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  warn 'wsl.exe não está no PATH — rode o stage 1 com -WithWSL e reinicie antes do stage 2.'
}
elseif ($WithWSL) {
  info 'Provisionando a distro do WSL...'
  $env:WSL_UTF8 = '1'   # sem isso o wsl.exe emite UTF-16LE e a saída vira lixo no PowerShell

  # cloud-init é o caminho suportado pela Canonical e roda SÓ no primeiro boot da distro:
  # o user-data tem que estar no lugar ANTES do `wsl --install`.
  # Distro fixada em Ubuntu-24.04: `Ubuntu` é alvo móvel.
  $cloudInitSrc = Join-Path $RepoDir 'wsl\cloud-init.user-data'
  if (Test-Path $cloudInitSrc) {
    $cloudInitDir = Join-Path $env:USERPROFILE '.cloud-init'
    New-Item -ItemType Directory -Force -Path $cloudInitDir | Out-Null
    Copy-Item $cloudInitSrc (Join-Path $cloudInitDir 'Ubuntu-24.04.user-data') -Force
    ok 'cloud-init user-data em %USERPROFILE%\.cloud-init\Ubuntu-24.04.user-data'
  }
  else { warn 'wsl/cloud-init.user-data não existe no repo — a distro vai subir pelo OOBE.' }

  $distros = (& wsl --list --quiet) -replace "`0", ''
  if ($LASTEXITCODE -eq 0 -and ($distros -join "`n") -match 'Ubuntu-24\.04') {
    ok 'Ubuntu-24.04 já existe — cloud-init NÃO reprovisiona instância já configurada.'
  }
  else {
    # --no-launch é obrigatório: se a distro abrir o OOBE, o cloud-init não roda.
    & wsl --install -d Ubuntu-24.04 --no-launch
    if ($LASTEXITCODE -ne 0) { warn "wsl --install -d Ubuntu-24.04 falhou ($LASTEXITCODE)" }
    else { ok 'Ubuntu-24.04 instalado (sem launch).' }
  }

  # Passos 4 e 5 da sequência do wsl/README.md. Nenhum dos dois pode rodar daqui: o
  # cloud-init só dispara no PRIMEIRO boot da distro, e o provision.sh roda DENTRO do
  # Ubuntu — é ele que restaura/gera a chave SSH, clona o mac-setup, instala o
  # zshrc.linux e conserta as quatro quebras do zshrc sob WSL (plugins do zsh, PNPM_HOME,
  # fzf --zsh, batcat/fdfind). Sem esse passo o WSL sobe pelado.
  Write-Host ''
  Write-Host '  Falta o que só roda de dentro do Ubuntu (wsl/README.md, passos 4 e 5):'
  Write-Host '    4. wsl -d Ubuntu-24.04       # primeiro boot: o cloud-init roda AQUI'
  Write-Host "    5. cd `"`$(wslpath -a '$RepoDir')/wsl`" && bash provision.sh"
  Write-Host '       (aceita SSH_BACKUP_DIR, GIT_NAME e GIT_EMAIL; nenhum é obrigatório)'
  Write-Host '    Depois:  wsl --shutdown      # regra dos 8s: config só vale com a VM parada'
}

# --- 17. windows-defaults.ps1 (só com -WithDefaults) ---
$defaultsScript = Join-Path $RepoDir 'windows-defaults.ps1'
if ($WithDefaults) {
  if (Test-Path $defaultsScript) {
    info 'Aplicando windows-defaults.ps1...'
    & $defaultsScript
  }
  else { warn 'windows-defaults.ps1 não existe no repo.' }
}
else {
  info 'windows-defaults.ps1: NÃO foi chamado (padrão, igual ao macos-defaults.sh).'
  Write-Host '  Leia antes de rodar:  pwsh -File windows-defaults.ps1'
}

# --- 18. Próximos passos ---
Write-Host ''
info 'Concluído! O que ainda é manual:'
Write-Host '  1. packages/manual.md — driver NVIDIA, rtk e grok-build não existem no winget.'
Write-Host '  2. windows-verify.ps1 — confere Secure Boot, TPM, VBS/HVCI, HAGS, BitLocker e'
Write-Host '     microcode. Rode ANTES de abrir o EA FC pela primeira vez, e num terminal'
Write-Host '     ELEVADO: sem admin, Secure Boot, TPM, BitLocker e bcdedit saem como SKIP —'
Write-Host '     justamente os que importam. Ele só LÊ, não escreve nada.'
Write-Host '       # abra o Terminal como Administrador e rode:'
Write-Host "       pwsh -File `"$(Join-Path $RepoDir 'windows-verify.ps1')`""
Write-Host '  3. Memory Integrity (HVCI) vem LIGADA em instalação limpa deste hardware:'
Write-Host '     desligue ativamente em Windows Security > Device security > Core isolation.'
Write-Host '  4. Adicione a chave SSH no GitHub e teste:  ssh -T git@github.com'
Write-Host '  5. Instale e valide o EA FC ANTES de empilhar overlays e utilitários de tuning.'
Write-Host '  6. Feche e reabra o terminal (PATH, $PROFILE e STARSHIP_CONFIG novos).'
Write-Host ''
