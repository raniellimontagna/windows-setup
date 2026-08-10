#
# windows-defaults.ps1 — ajustes de sistema opcionais (rode manualmente).
# NÃO é chamado pelo setup.ps1: rode só se concordar com as mudanças.
#
# Uso:  pwsh -File windows-defaults.ps1              # HKCU agora + eleva sozinho para o HKLM
#       pwsh -File windows-defaults.ps1 -Scope HKCU  # só as preferências do usuário
#       pwsh -File windows-defaults.ps1 -Scope HKLM  # só as chaves de máquina (precisa de admin)
#
# Seguro rodar várias vezes (idempotente): todo write passa pelo Set-Reg, que cria a chave pai
# quando ela não existe e reescreve o mesmo valor sem reclamar.
#
# Rode em PowerShell 7 (pwsh). O arquivo é UTF-8 e o powershell.exe 5.1 embaralha os acentos.
#
# ATENCAO — não abra este script num terminal JÁ elevado quando o escopo for All.
# Um shell "Executar como administrador" de outra conta escreve o HKCU no perfil daquela conta,
# e os seus ajustes de taskbar/tema simplesmente não aparecem. O fluxo correto é abrir um pwsh
# normal: a parte HKCU roda sem elevação e o script se re-abre elevado só para o bloco HKLM.
#
[CmdletBinding()]
param(
    [ValidateSet('All', 'HKCU', 'HKLM')]
    [string]$Scope = 'All',

    # Reinicia o explorer.exe no fim para aplicar taskbar/tema sem sair da conta.
    # Fecha todas as janelas do Explorer que estiverem abertas — por isso é opt-in.
    [switch]$RestartExplorer,

    # USO INTERNO. É como o script se auto-eleva: a janela elevada recebe o caminho do
    # transcript e escreve nele. Sem isso, a janela fecha sozinha e leva junto o erro.
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok($m)   { Write-Host "OK  $m" -ForegroundColor Green }
function warn($m) { Write-Host "AVISO $m" -ForegroundColor Yellow }

# Primitiva idempotente. New-ItemProperty -Force NÃO cria a chave pai, e várias das chaves de
# policy abaixo não existem num Windows limpo (...\Policies\Microsoft\Windows\Explorer,
# ...\Windows Search, ...\Dsh, ...\GameDVR). Sem o Test-Path a primeira execução morria na
# primeira policy — este helper é justamente o que impede esse crash de estreia.
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
    ok "$Path\$Name = $Value"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Onde mora o log da janela elevada. Fica FORA do repo (o repo e publico e isto e estado de
# maquina) e FORA do %LOCALAPPDATA%: sob UAC de outra conta admin o LOCALAPPDATA aponta para o
# perfil DAQUELA conta, e o processo pai procuraria o log num caminho que nao existe para ele.
# O pai calcula o caminho a partir do proprio %USERPROFILE% e passa pronto via -LogPath.
#
# Nota: o setup.ps1 resolve o MESMO risco de outro jeito, usando C:\ProgramData\windows-setup
# (identico para qualquer conta). As duas estrategias sao validas; a diferenca e de escopo.
# Aqui o log e um artefato descartavel de UMA execucao manual, entao ele acompanha o usuario que
# rodou o script. La o marcador de estagio precisa ser lido por processos de contas diferentes,
# entao tem que ser machine-wide. Nao unifique sem levar isso em conta.
$StateDir = Join-Path $env:USERPROFILE '.windows-setup'

# Impresso em todo caminho de saída — o análogo do "alguns ajustes só valem após sair e entrar
# na conta" do macos-defaults.sh, só que aqui a lista é maior e algumas coisas pedem reboot.
function Show-Notas {
    info "O que ainda não está valendo"
    Write-Host "  Reboot obrigatorio:"
    Write-Host "    - HwSchMode (HAGS)  -> confira em Settings > System > Display > Graphics"
    Write-Host "    - HVCI Enabled=0    -> confira em msinfo32: 'Virtualization-based security: Not enabled'"
    Write-Host "    - LongPathsEnabled  -> processos ja abertos continuam com o limite antigo"
    Write-Host "  Sair e entrar na conta (ou -RestartExplorer):"
    Write-Host "    - taskbar, tema escuro, caixa de busca, News and Interests, policies de Cortana/GameDVR"
    Write-Host "  Vale no proximo lancamento do app:"
    Write-Host "    - Game Mode/Game DVR, SwapEffectUpgrade (reabra o jogo)"
    Write-Host "  Depois de rebootar, rode windows-verify.ps1 NUM TERMINAL ELEVADO para conferir."
    Write-Host "    (sem elevacao ele pula Secure Boot, TPM, BitLocker e bcdedit)"
}

Write-Host "Aplicando ajustes do Windows... (escopo: $Scope)"

# ==============================================================================
#  HKCU — preferências do usuário. Nada aqui precisa de elevação.
# ==============================================================================

if ($Scope -ne 'HKLM') {

    if (Test-Admin) {
        warn "Este shell esta elevado. Se ele foi aberto como OUTRO usuario, o HKCU abaixo vai para"
        warn "o perfil daquele usuario e nao para o seu. Prefira: pwsh normal + self-elevate do HKLM."
    }

    # --- 1. Explorer e taskbar ---
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'HideFileExt'          0   # sempre mostra extensao (o analogo do AppleShowAllExtensions)
    Set-Reg $adv 'Hidden'               1   # mostra arquivos ocultos
    Set-Reg $adv 'LaunchTo'             1   # abre o Explorer em "This PC", nao em "Home"
    Set-Reg $adv 'TaskbarAl'            0   # icones alinhados a esquerda
    Set-Reg $adv 'ShowTaskViewButton'   0
    Set-Reg $adv 'TaskbarMn'            0   # botao de chat
    Set-Reg $adv 'ShowCopilotButton'    0

    # --- 2. Tema escuro ---
    $per = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-Reg $per 'AppsUseLightTheme'    0
    Set-Reg $per 'SystemUsesLightTheme' 0

    # --- 3. Busca: caixa vira icone, sem sugestao da web ---
    # SearchboxTaskbarMode: 0=oculto  1=icone  2=caixa
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
    # Esta e a chave ATUAL para tirar Bing/Cortana do menu Iniciar.
    # BingSearchEnabled (em ...\Search) e a antiga e hoje nao faz mais efeito sozinha.
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1

    # --- 4. Game Mode e Game DVR ---
    # Higiene barata, nao ganho de performance: o background recording ja vem desligado por padrao
    # e custa ~1-2% de FPS medio quando ligado. Escrevemos so para garantir que nada religue.
    # Isto NAO desinstala Game Bar nem Xbox: o overlay e usado por alguns launchers (ver o bloco
    # "Deliberadamente NAO feito aqui" no fim do arquivo).
    Set-Reg 'HKCU:\Software\Microsoft\GameBar'  'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\System\GameConfigStore'      'GameDVR_Enabled'     0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0

    # --- 5. Jogos em janela: VRR e Auto HDR ---
    # Habilita as "otimizacoes para jogos em janela" (windowed/borderless), que ligam VRR e
    # Auto HDR fora do fullscreen exclusivo. E o oposto do folclore de "desligar Fullscreen
    # Optimizations": no modelo flip do Win11 o caminho em janela e igual ou melhor.
    # DirectXUserGlobalSettings e uma string unica com pares "chave=valor;" — sobrescrever aqui
    # zera outros ajustes globais que estejam nessa mesma string. As preferencias POR JOGO ficam
    # em valores separados da mesma chave (um por caminho de .exe) e nao sao tocadas.
    Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' `
        'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\DirectX\GraphicsSettings' 'SwapEffectUpgradeCache' 1
}

# ==============================================================================
#  HKLM — chaves de máquina. Daqui para baixo precisa de admin.
# ==============================================================================

# --- 6. Ponte para o HKLM (self-elevate) ---
if ($Scope -eq 'HKCU') {
    Show-Notas
    return
}

if (-not (Test-Admin)) {
    info "Reabrindo elevado só para a parte HKLM (o UAC vai aparecer)..."
    # Reusa o MESMO host (pwsh.exe ou powershell.exe) que esta rodando agora.
    $psExe = (Get-Process -Id $PID).Path
    $logHklm = Join-Path $StateDir 'hklm.log'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Scope', 'HKLM',
        '-LogPath', "`"$logHklm`""
    )
    $proc = $null
    try {
        # -PassThru + -Wait sao o unico jeito de saber se o filho aplicou alguma coisa: a janela
        # elevada fecha sozinha, entao sem exit code + transcript o HAGS/BitLocker/HVCI podia
        # falhar inteiro e este script imprimir "concluido" mesmo assim.
        $proc = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait -PassThru
    } catch {
        # Cancelar o prompt do UAC lanca — nao e motivo para derrubar o que ja foi aplicado.
        warn "Elevacao recusada ou falhou: $($_.Exception.Message)"
        warn "Os ajustes HKCU acima continuam valendo. Rode depois: -Scope HKLM num shell admin."
        Show-Notas
        return
    }

    if ($null -eq $proc) {
        warn "Nao consegui acompanhar a janela elevada (sem processo). Trate o bloco HKLM como NAO aplicado."
        warn "Rode a mao num shell admin:  pwsh -File `"$PSCommandPath`" -Scope HKLM"
    }
    elseif ($proc.ExitCode -ne 0) {
        warn "O BLOCO HKLM FALHOU na janela elevada (exit $($proc.ExitCode))."
        warn "HAGS/HwSchMode, PreventDeviceEncryption e HVCI podem NAO estar aplicados — nao conte com eles."
        warn "Log da janela elevada: $logHklm"
        warn "Depois de corrigir, rode num shell admin:  pwsh -File `"$PSCommandPath`" -Scope HKLM"
    }
    else {
        ok "Bloco HKLM concluido na janela elevada (log: $logHklm)"
    }
    Show-Notas
    return
}

# --- 6.1 Transcript (só quando somos a janela elevada) ---
# A janela elevada fecha assim que termina e leva junto qualquer erro. O transcript e o que
# sobra para o processo pai apontar quando o exit code vier != 0.
if ($LogPath) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
    try { Start-Transcript -Path $LogPath -Force | Out-Null } catch { }
}

# --- 7. Filesystem: long paths ---
# Afeta SÓ apps com manifest longPathAware. O Git precisa do ajuste dele:
#   git config --system core.longpaths true
# node_modules sob %USERPROFILE% e um modo de falha real, nao teorico.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1

# --- 8. GPU: Hardware-Accelerated GPU Scheduling (HAGS) ---
# HwSchMode=2 e obrigatorio na 4060 Ti: sem HAGS o DLSS Frame Generation nao ativa, e e assim
# que uma placa de 8 GB continua jogavel. So 1=disabled e 2=enabled sao documentados;
# 0 e folclore de forum — nunca escreva 0 aqui. Efeito so apos reboot.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2

# --- 9. BitLocker: impedir a auto-encryption ---
# O item numero 1 de risco de perda de dados. Em clean install qualificado a Microsoft inicializa
# device encryption no drive do SO E em todos os fixed data drives, com clear key, INDEPENDENTE
# de conta local ou Microsoft account. Conta local muda so o escrow: o volume fica "encrypted but
# unprotected" e nenhuma recovery key existe em lugar nenhum. O 24H2 removeu os pre-requisitos de
# DMA/HSTI, entao esta maquina qualifica — e um device que ainda nao qualificava auto-habilita
# assim que passa a qualificar (por exemplo, ao ligar Secure Boot no BIOS).
# O lugar IDEAL desta chave e o autounattend.xml / o Shift+F10 durante o Setup. Aqui ela e rede de
# seguranca para o futuro. Se a criptografia JA rodou, isto nao decripta nada: rode
# windows-verify.ps1 (TERMINAL ELEVADO, senao o check de BitLocker so reporta SKIP) e capture a
# chave com  manage-bde -protectors -get C:  antes de mexer em VBS.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1

# --- 10. Memory Integrity (HVCI) desligado ---
# HVCI vem LIGADO por padrao em clean install deste hardware (Intel 8a gen+, 8 GB+, SSD 64 GB+,
# virtualizacao habilitada). Nao e "deixe desligado", e "desligue ativamente": o custo em FPS vem
# de colocar o Windows sob o hypervisor, o mesmo mecanismo que o WSL2 traz de volta.
# ATENCAO: se a auto-encryption da secao 9 ja tiver rodado, alternar VBS pode disparar prompt de
# recovery key no proximo boot. Capture a chave ANTES (manage-bde -protectors -get C:).
# Confirme depois do reboot em msinfo32: "Virtualization-based security: Not enabled".
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' `
    'Enabled' 0

# --- 11. Policies: News and Interests, Game DVR, Cortana ---
# AllowNewsAndInterests e documentado so para Pro/Enterprise/Education/IoT — anotado como "Pro+"
# porque este repo e publico: em Home a chave existe mas nao e honrada.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0          # Pro+
# Contraparte de maquina da secao 4 (a de usuario sozinha nao trava a captura).
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0

# --- 12. Windows Update: fora do "continuous innovation" ---
# Desmarca o "Get the latest updates as soon as they're available": a maquina fica na cadencia
# normal de rollout em vez de receber features assim que saem. Nao e pin de versao —
# pin/deferral sao decisao consciente e ficam de fora daqui (ver o bloco do fim).
Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsContinuousInnovationOptedIn' 0

# --- 13. Developer Mode: dono e o setup.ps1, NAO reintroduzir aqui ---
# AllowDevelopmentWithoutDevLicense e escrito pelo setup.ps1 (stage 1), que precisa dele cedo e
# ainda reconfere com um probe de symlink real. Um dono so por chave.

# --- 14. Fim ---
if ($RestartExplorer) {
    info "Reiniciando o explorer.exe (fecha as janelas abertas do Explorer)..."
    try {
        Stop-Process -Name explorer -Force
        ok "explorer.exe reiniciado"
    } catch {
        warn "Nao consegui reiniciar o explorer.exe: $($_.Exception.Message)"
    }
}

Show-Notas

# Janela elevada: fecha o transcript e devolve 0 EXPLICITO ao processo pai. Se qualquer Set-Reg
# acima tiver estourado ($ErrorActionPreference='Stop'), o script nunca chega aqui e o host sai
# com codigo != 0 — que e exatamente o sinal que o pai le para nao anunciar "concluido".
if ($LogPath) {
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# ==============================================================================
# --- Deliberadamente NÃO feito aqui ---
# ==============================================================================
# Documentação negativa: cada linha abaixo é uma coisa que o repo decidiu NÃO escrever.
# Ela vale tanto quanto o que está escrito acima — é o que impede a próxima versão deste arquivo
# de reintroduzir tweak de fórum numa máquina que precisa ficar estável com anticheat kernel.
#
# - Tweaks de "FPS boost": Win32PrioritySeparation, SystemResponsiveness, NetworkThrottlingIndex,
#   desabilitar Nagle, plano de energia "Ultimate Performance".
#   -> Placebo a nocivo no Windows 11 moderno, e exatamente a classe de mudanca que torna uma
#      maquina com anticheat kernel impossivel de diagnosticar depois.
#
# - Desabilitar Fullscreen Optimizations.
#   -> Conselho velho. O modelo flip do Win11 torna FSO igual ou melhor que fullscreen exclusivo,
#      e desabilitar quebra overlay, Auto HDR e VRR em alguns titulos. A secao 5 vai no sentido
#      OPOSTO: habilita as otimizacoes em janela.
#
# - HwSchMode=0.
#   -> So 1 e 2 sao documentados. O 0 e folclore de forum. Nunca escrever.
#
# - Remover pacotes Xbox / Game Bar em bloco.
#   -> Game Bar fornece o overlay e alguns launchers dependem de Xbox Identity / Gaming Services.
#      A secao 4 desabilita a CAPTURA (Game DVR), que e o que custa FPS. Desinstalar, nao.
#
# - DirectStorage.
#   -> Nao ha nada para configurar: e runtime por jogo. O que importa e o jogo estar no NVMe.
#
# - Settings da NVIDIA (G-Sync/VRR, image scaling, perfis por jogo).
#   -> O NVIDIA Control Panel foi aposentado (driver 610.47, mai/2026) e nao existe caminho de
#      registry suportado e versionavel para o NVIDIA app. Vai para o checklist manual do README.
#
# - Estado de BIOS, Secure Boot, TPM e VBS.
#   -> Decisoes one-time de firmware. Um script re-executavel que mexe nisso e ativamente
#      perigoso: alternar VBS depois que a auto-encryption rodou dispara prompt de recovery key.
#      windows-verify.ps1 LE esse estado; ninguem aqui escreve.
#
# - Debloat (remocao de apps provisionados, tweaks de privacidade em massa).
#   -> Fica no Win11Debloat com win11debloat.config.json (-Config -Silent), UMA ferramenta so.
#      Rodar duas ferramentas de debloat = escritas conflitantes. E ele NAO roda em pwsh: o modulo
#      Appx falha no PowerShell Core, o wrapper precisa chamar powershell.exe (5.1).
#
# - Pin de versao do Windows Update (TargetReleaseVersion, DeferFeatureUpdates/DeferQualityUpdates).
#   -> Pro-only, e a Microsoft e explicita que o deferral nao vale quando ha target version — nao
#      combine os dois. Alem disso NoAutoRebootWithLoggedOnUsers=1 sozinho e no-op no default do
#      Win11 (so vale com AUOptions=4 na mesma chave). Para "sem reboot no meio da partida", o
#      lever real e Active Hours na sua janela de jogo, ajustado a mao em Settings.
#
# - Exclusoes do Defender.
#   -> Exigem admin, podem ser bloqueadas em silencio pelo Tamper Protection (Add-MpPreference
#      "parece" funcionar sem fazer nada) e reduzem protecao no maior blob gravavel da maquina.
#      Decisao consciente, com verificacao explicita — nao efeito colateral de um script de tema.
