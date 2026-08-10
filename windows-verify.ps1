#
# windows-verify.ps1 — auditoria SÓ LEITURA do estado da máquina.
# Confere o que nenhum outro script deste repo consegue conferir: firmware,
# TPM, VBS/HVCI, BitLocker, microcode do CPU, HAGS, TRIM, exclusões do
# Defender e a saúde do winget.
#
# Uso:  pwsh    -File .\windows-verify.ps1
#       powershell -File .\windows-verify.ps1     (funciona no 5.1 de fábrica)
#
# RODE NUM TERMINAL ELEVADO. Confirm-SecureBootUEFI, Get-Tpm, manage-bde e
# bcdedit exigem admin — sem elevação esses itens saem como SKIP, não como
# falha. Elevado só para LER: ver o bloco abaixo.
#
# ###########################################################################
# #                                                                         #
# #   ESTE SCRIPT NÃO MUDA NADA.                                            #
# #                                                                         #
# #   Nenhum Set-*, nenhum New-*, nenhuma escrita em registry, nenhum        #
# #   `manage-bde -on/-off`, nenhum `bcdedit /set`, nenhum `winget install`. #
# #   Só Get-*, `-get`, `query`, `/enum` e `--version`.                      #
# #                                                                         #
# #   Se você encontrar aqui um comando que ESCREVE, é BUG: remova.          #
# #   Estado de BIOS, Secure Boot, TPM e VBS são decisões one-time de        #
# #   firmware — um script re-executável que mexe nisso é ativamente         #
# #   perigoso (alternar VBS depois que a auto-encryption rodou dispara      #
# #   prompt de chave de recuperação).                                       #
# #                                                                         #
# ###########################################################################
#
# Seguro rodar várias vezes — idempotente por construção, já que só lê.
# Sai com código 1 se algum item ficar FAIL ou UNKNOWN; 0 caso contrário.
#
# UNKNOWN existe por causa da checagem de BitLocker (seção 5): num veredito que
# protege contra perder o acesso ao disco para sempre, "não consegui interpretar
# a resposta" NÃO pode virar PASS. Ver o comentário longo lá.
#
# ENCODING: UTF-8 COM BOM de propósito, para que as mensagens em português
# saiam corretas também no PowerShell 5.1 (que assume ANSI sem BOM).
#

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sob Set-StrictMode, ler $LASTEXITCODE antes do primeiro comando nativo é erro.
$global:LASTEXITCODE = 0

# --- 1. Helpers e tabela de resultados ---

function info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function ok($m)   { Write-Host "OK  $m"   -ForegroundColor Green }
function warn($m) { Write-Host "AVISO $m" -ForegroundColor Yellow }

$script:Results = New-Object System.Collections.ArrayList

# PASS     bate com o esperado
# FAIL     diverge do esperado (ou de um requisito duro, como Secure Boot)
# INFO     não existe "certo": é para registrar e comparar com o fabricante
# SKIP     não deu para medir, e a falta de medida é INÓCUA (falta elevação,
#          feature ausente)
# UNKNOWN  não deu para medir, e a falta de medida é PERIGOSA: a checagem existe
#          justamente para pegar um estado que causa perda de dados, então o
#          indeterminado conta como falha. Nunca use isto onde SKIP serve.
function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string] $Item,
    [Parameter(Mandatory = $true)][string] $Expected,
    [Parameter(Mandatory = $true)][string] $Actual,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'INFO', 'SKIP', 'UNKNOWN')][string] $Status
  )
  [void] $script:Results.Add([PSCustomObject]@{
    Item     = $Item
    Esperado = $Expected
    Atual    = $Actual
    Status   = $Status
  })
  $color = 'Gray'
  if ($Status -eq 'PASS')    { $color = 'Green'   }
  if ($Status -eq 'FAIL')    { $color = 'Red'     }
  if ($Status -eq 'INFO')    { $color = 'Cyan'    }
  if ($Status -eq 'SKIP')    { $color = 'Yellow'  }
  if ($Status -eq 'UNKNOWN') { $color = 'Magenta' }
  Write-Host ("    [{0}] {1}: {2}" -f $Status, $Item, $Actual) -ForegroundColor $color
}

# Binários externos (manage-bde, fsutil, bcdedit, reg, winget) escrevem no
# stderr com frequência. Com $ErrorActionPreference='Stop' isso viraria exceção
# em alguns hosts. Aqui capturamos tudo como texto e olhamos o $LASTEXITCODE.
function Invoke-Exe {
  param(
    [Parameter(Mandatory = $true)][string] $File,
    [string[]] $Arguments = @()
  )
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $File @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return , @($out)
  } catch {
    return , @("erro ao executar ${File}: $($_.Exception.Message)")
  } finally {
    $ErrorActionPreference = $old
  }
}

# Retorna $null se a chave OU o valor não existirem. Várias das chaves abaixo
# simplesmente não existem num Windows limpo — ausência é um resultado válido,
# não uma exceção.
function Get-RegValue {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Name
  )
  try {
    if (-not (Test-Path -Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
    return $item.$Name
  } catch {
    return $null
  }
}

function Show-Value($v) {
  if ($null -eq $v) { return '(ausente)' }
  return [string]$v
}

# Elevação é só para LER: Confirm-SecureBootUEFI, Get-Tpm, manage-bde e bcdedit
# exigem admin. Sem ela, esses itens viram SKIP em vez de FAIL falso.
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$Elevated = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

info "windows-verify — auditoria só leitura"
Write-Host "  Máquina    : $env:COMPUTERNAME"
Write-Host "  PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "  Elevado    : $Elevated"
Write-Host "  Data       : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
if (-not $Elevated) {
  warn "Sem elevação: Secure Boot, TPM, BitLocker e bcdedit vão sair como SKIP. Reabra como Administrador para uma auditoria completa."
}

# --- 2. Firmware — Secure Boot ---

info "Firmware — Secure Boot"
# O EA FC (anticheat Javelin) exige Secure Boot E TPM 2.0 de forma INDEPENDENTE.
# Secure Boot é feature de firmware UEFI e não depende do TPM — a EA conflaciona
# os dois porque o Javelin checa cada um separadamente. Por isso aqui também são
# dois itens distintos. Se este falhar, nada mais no repo importa: é o motivo
# inteiro da migração.
try {
  $secureBoot = Confirm-SecureBootUEFI
  if ($secureBoot) {
    Add-Check 'Secure Boot' 'True' 'True' 'PASS'
  } else {
    Add-Check 'Secure Boot' 'True' 'False' 'FAIL'
  }
} catch {
  # Duas causas comuns e bem diferentes:
  #   "Cmdlet not supported on this platform" -> a máquina bootou em BIOS/CSM
  #      (CSM tem que estar OFF, boot UEFI only)
  #   acesso negado -> só falta elevação
  $msg = $_.Exception.Message
  if ($Elevated) {
    Add-Check 'Secure Boot' 'True' "erro: $msg" 'FAIL'
  } else {
    Add-Check 'Secure Boot' 'True' 'precisa de elevação' 'SKIP'
  }
}

# --- 3. TPM ---

info "TPM"
try {
  $tpm = Get-Tpm
  if ($tpm.TpmPresent) {
    Add-Check 'TPM presente' 'True' ([string]$tpm.TpmPresent) 'PASS'
  } else {
    # Numa placa Intel de varejo isso normalmente é o Intel PTT desligado na BIOS.
    Add-Check 'TPM presente' 'True' ([string]$tpm.TpmPresent) 'FAIL'
  }
  if ($tpm.TpmReady) {
    Add-Check 'TPM pronto' 'True' ([string]$tpm.TpmReady) 'PASS'
  } else {
    Add-Check 'TPM pronto' 'True' ([string]$tpm.TpmReady) 'FAIL'
  }
} catch {
  if ($Elevated) {
    Add-Check 'TPM' 'TpmPresent/TpmReady = True' "erro: $($_.Exception.Message)" 'FAIL'
  } else {
    Add-Check 'TPM' 'TpmPresent/TpmReady = True' 'precisa de elevação' 'SKIP'
  }
}
# Get-Tpm não expõe a Specification Version. O 2.0 exigido pelo Javelin se
# confere no olho em tpm.msc (ver seção de verificações manuais no fim).

# --- 4. VBS / HVCI / hypervisor ---

info "VBS, HVCI (Memory Integrity) e hypervisor"
# Memory Integrity vem LIGADO por padrão em clean install neste hardware
# (Intel 8ª gen+, 8 GB+, SSD 64 GB+, virtualização habilitada). Não é "deixe
# desligado", é "desligue ativamente" — e custa frames em jogo. Esta seção é o
# equivalente scriptável da linha "Virtualization-based security" do msinfo32.
try {
  $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard'

  # 0 = não habilitado | 1 = habilitado, não rodando | 2 = habilitado e rodando
  $vbs = [int]$dg.VirtualizationBasedSecurityStatus
  if ($vbs -eq 0) {
    Add-Check 'VBS (status)' '0 = Not enabled' '0 = Not enabled' 'PASS'
  } else {
    Add-Check 'VBS (status)' '0 = Not enabled' "$vbs = habilitado" 'FAIL'
  }

  # SecurityServicesRunning: 2 = HVCI / Memory Integrity em execução.
  $running = @()
  if ($null -ne $dg.SecurityServicesRunning) { $running = @($dg.SecurityServicesRunning) }
  if ($running -contains 2) {
    Add-Check 'HVCI em execução' 'não' 'sim (Memory Integrity ligado)' 'FAIL'
  } else {
    Add-Check 'HVCI em execução' 'não' 'não' 'PASS'
  }
} catch {
  Add-Check 'VBS / HVCI' '0 = Not enabled' "erro: $($_.Exception.Message)" 'SKIP'
}

# A chave de policy correspondente. Ela pode não existir num Windows limpo —
# ausente NÃO significa desligado, significa "sem override": por isso ausente
# vira INFO e quem manda no veredito é o Win32_DeviceGuard acima.
$hvciKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
$hvciEnabled = Get-RegValue -Path $hvciKey -Name 'Enabled'
if ($null -eq $hvciEnabled) {
  Add-Check 'HVCI (registry Enabled)' '0' '(ausente — sem override)' 'INFO'
} elseif ([int]$hvciEnabled -eq 0) {
  Add-Check 'HVCI (registry Enabled)' '0' '0' 'PASS'
} else {
  Add-Check 'HVCI (registry Enabled)' '0' ([string]$hvciEnabled) 'FAIL'
}

# hypervisorlaunchtype é a válvula de escape para sessões competitivas quando o
# WSL2 está instalado (Virtual Machine Platform coloca o Windows inteiro sob o
# hypervisor). 'off' = hypervisor desligado; 'auto' = ligado. Sem WSL, o normal
# é a linha nem aparecer. Informativo: os dois valores são escolhas válidas.
if ($Elevated) {
  $bcd = Invoke-Exe -File 'bcdedit' -Arguments @('/enum', '{current}')
  $hv = ($bcd | Select-String -Pattern 'hypervisorlaunchtype\s+(\S+)' | Select-Object -First 1)
  if ($hv) {
    Add-Check 'hypervisorlaunchtype' 'off p/ jogar, auto p/ WSL2' $hv.Matches[0].Groups[1].Value 'INFO'
  } else {
    Add-Check 'hypervisorlaunchtype' 'off p/ jogar, auto p/ WSL2' '(não definido — default)' 'INFO'
  }
} else {
  Add-Check 'hypervisorlaunchtype' 'off p/ jogar, auto p/ WSL2' 'precisa de elevação' 'SKIP'
}

# --- 5. BitLocker e device encryption ---

info "BitLocker / device encryption"
# O item de risco nº 1 do plano. Em clean install qualificado, o Windows
# inicializa device encryption no drive do SO E em todos os fixed data drives,
# com clear key, INDEPENDENTEMENTE de conta local ou MSA. Com conta local o
# volume fica "encrypted but unprotected" e NENHUMA chave de recuperação existe
# em lugar nenhum. Pior: um device que não qualificava auto-habilita assim que
# passa a qualificar — por exemplo ao LIGAR SECURE BOOT, que é justamente o que
# este repo manda fazer na BIOS.
$preventEnc = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name 'PreventDeviceEncryption'
if ($null -ne $preventEnc -and [int]$preventEnc -eq 1) {
  Add-Check 'PreventDeviceEncryption' '1' '1' 'PASS'
} else {
  Add-Check 'PreventDeviceEncryption' '1' (Show-Value $preventEnc) 'FAIL'
}

# ---------------------------------------------------------------------------
# POR QUE ESTA CHECAGEM É PARANOICA
# ---------------------------------------------------------------------------
# Este é o veredito mais importante do repo. Ele separa "o disco está limpo" de
# "o disco está criptografado e NÃO EXISTE chave de recuperação em lugar nenhum"
# — estado do qual não se sai: um reset de TPM, um flash de BIOS ou um toggle de
# Secure Boot depois disso e a máquina pede uma chave que nunca existiu.
#
# A versão anterior desta seção decidia o veredito pelo $LASTEXITCODE do
# manage-bde: QUALQUER código não-zero virava PASS "nenhum protector". Só que
# manage-bde devolve não-zero por meia dúzia de motivos completamente
# diferentes — volume inexistente, volume bloqueado, serviço do BitLocker
# parado, privilégio faltando, letra de drive errada — e todos eles eram
# reportados como "limpo" num volume que podia estar criptografado. Falso PASS
# no único item onde falso PASS custa o disco inteiro.
#
# A regra agora é: olhar o CONTEÚDO, e na dúvida NUNCA dizer PASS.
#   1. fonte primária: Get-BitLockerVolume — objeto tipado (KeyProtector,
#      VolumeStatus, ProtectionStatus), independente de idioma;
#   2. fallback: texto do manage-bde, casando SÓ marcadores que não são
#      traduzidos (GUID do protector, senha numérica de 48 dígitos, código
#      0x........). A máquina é pt-BR: casar frase em inglês não serve de nada;
#   3. o que não cair claramente num dos dois lados vira UNKNOWN, que conta como
#      falha e imprime o que rodar na mão.
# ---------------------------------------------------------------------------

# Imprime o bloco de alerta da chave de recuperação. Só LÊ e escreve na tela —
# de propósito nada vai para arquivo: o repo é público.
function Write-BitLockerRecoveryNotice {
  param(
    [Parameter(Mandatory = $true)][string] $Drive,
    [string] $Password
  )
  Write-Host ""
  if ($Password) {
    Write-Host "      >>> CHAVE DE RECUPERAÇÃO ($Drive): $Password" -ForegroundColor Magenta
    Write-Host "      >>> Copie AGORA para o Bitwarden. Ela não vai para arquivo nenhum" -ForegroundColor Magenta
    Write-Host "      >>> (este script não escreve nada) e o repo é PÚBLICO." -ForegroundColor Magenta
  } else {
    warn "      Nenhuma senha numérica de recuperação listada para $Drive. Se o volume estiver criptografado, ele está 'encrypted but unprotected' (clear key) — não existe chave de recuperação em lugar nenhum. Rode 'manage-bde -status $Drive' e trate como urgente."
  }
  Write-Host ""
}

if (-not $Elevated) {
  # Sem elevação nem Get-BitLockerVolume nem manage-bde conseguem ler o estado.
  # SKIP e não UNKNOWN porque a causa é conhecida, trivial e dita no cabeçalho.
  Add-Check 'BitLocker protectors' 'nenhum protector' 'precisa de elevação' 'SKIP'
} else {
  $drives = @()
  $drivesPartial = $false
  try {
    # Todos os volumes fixos, não só o C: — um drive de jogos NTFS anexado pode
    # ter sido criptografado junto pela auto-encryption.
    $drives = @(Get-Volume |
      Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
      ForEach-Object { "$($_.DriveLetter):" })
  } catch {
    $drives = @()
  }
  if ($drives.Count -eq 0) {
    $drives = @('C:')
    $drivesPartial = $true
  }
  if ($drivesPartial) {
    warn "Não consegui enumerar os volumes fixos (Get-Volume). Só o C: foi verificado — confira os outros drives na mão com 'manage-bde -status <letra>:'."
  }

  # Fonte primária. Em máquina sem o módulo BitLocker (algumas edições/imagens
  # enxutas) o cmdlet não existe e caímos direto no manage-bde.
  $blCmdlet = Get-Command 'Get-BitLockerVolume' -ErrorAction SilentlyContinue

  foreach ($d in $drives) {
    # 'CLEAN' | 'PROTECTED' | 'ENCRYPTED_NO_PROTECTOR' | 'UNKNOWN'
    $verdict  = ''
    $detail   = ''
    $recovery = ''
    $source   = 'nenhuma fonte disponível'

    if ($blCmdlet) {
      try {
        $vol = Get-BitLockerVolume -MountPoint $d -ErrorAction Stop
        $source = 'Get-BitLockerVolume'
        # Cmdlet que não erra e não devolve nada também é resposta inutilizável:
        # joga para o fallback em vez de virar um "sem protector" fabricado.
        if ($null -eq $vol) { throw 'o cmdlet não devolveu volume nenhum' }

        $protectors = @()
        if ($null -ne $vol.KeyProtector) {
          $protectors = @($vol.KeyProtector | Where-Object { $null -ne $_ })
        }
        $volStatus  = [string] $vol.VolumeStatus
        $protStatus = [string] $vol.ProtectionStatus

        foreach ($p in $protectors) {
          if ($p.RecoveryPassword) { $recovery = [string] $p.RecoveryPassword }
        }

        if ($protectors.Count -gt 0) {
          $types = (@($protectors | ForEach-Object { [string] $_.KeyProtectorType }) -join ', ')
          $verdict = 'PROTECTED'
          $detail  = "$($protectors.Count) protector(es): $types (VolumeStatus=$volStatus, ProtectionStatus=$protStatus)"
        } elseif ([string]::IsNullOrWhiteSpace($volStatus)) {
          $verdict = 'UNKNOWN'
          $detail  = 'o cmdlet respondeu sem VolumeStatus'
        } elseif ($volStatus -eq 'FullyDecrypted') {
          $verdict = 'CLEAN'
          $detail  = "sem protector, volume não criptografado (VolumeStatus=$volStatus)"
        } else {
          # Criptografado (total ou parcialmente) e sem protector nenhum: este É
          # o estado "encrypted but unprotected" da auto-encryption com conta
          # local. O código antigo chamava exatamente isto de PASS.
          $verdict = 'ENCRYPTED_NO_PROTECTOR'
          $detail  = "CRIPTOGRAFADO e SEM protector (VolumeStatus=$volStatus, ProtectionStatus=$protStatus)"
        }
      } catch {
        $verdict = ''
        $detail  = "Get-BitLockerVolume falhou: $($_.Exception.Message)"
      }
    }

    if (-not $verdict) {
      $fallbackNote = $detail
      if (Get-Command 'manage-bde' -ErrorAction SilentlyContinue) {
        $out  = Invoke-Exe -File 'manage-bde' -Arguments @('-protectors', '-get', $d)
        $code = $LASTEXITCODE
        $text = ($out -join "`n")
        $source = 'manage-bde'

        # Marcadores INDEPENDENTES DE IDIOMA:
        #   - todo protector é impresso com um GUID entre chaves;
        #   - a senha numérica são 48 dígitos em 8 grupos de 6;
        #   - erro do BitLocker vem acompanhado de um código 0x........
        $hasProtectorId = ($text -match '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}')
        $numMatch = [regex]::Match($text, '\d{6}(-\d{6}){7}')
        if ($numMatch.Success) { $recovery = $numMatch.Value }
        $errMatch = [regex]::Match($text, '0x[0-9A-Fa-f]{8}')
        $errCode = ''
        if ($errMatch.Success) { $errCode = $errMatch.Value.ToLower() }

        if ($hasProtectorId -or $numMatch.Success) {
          $verdict = 'PROTECTED'
          $detail  = "manage-bde listou protector (saída $code)"
        } elseif ($code -eq 0) {
          # Sucesso sem listar protector nenhum não é um estado documentado.
          # Pode ser saída vazia por redirecionamento, pode ser volume com só
          # clear key. Não dá para chamar de limpo.
          $verdict = 'UNKNOWN'
          $detail  = 'manage-bde terminou com sucesso mas não listou protector nenhum'
        } elseif ($errCode -eq '0x80310001' -or $errCode -eq '0x80310008') {
          # 0x80310001 FVE_E_NOT_ENCRYPTED e 0x80310008 FVE_E_NOT_ACTIVATED são
          # os DOIS únicos códigos que significam, sem ambiguidade, "este volume
          # não está sob BitLocker". Qualquer outro (inclusive 0x80310000,
          # volume bloqueado) é indeterminado — e volume bloqueado é justamente
          # um volume criptografado.
          $verdict = 'CLEAN'
          $detail  = "volume fora do BitLocker ($errCode)"
        } else {
          $verdict = 'UNKNOWN'
          $detail  = "manage-bde saiu com $code"
          if ($errCode) { $detail = "$detail, código $errCode" }
          $detail = "$detail — não dá para afirmar que não há protector"
        }
      } else {
        $verdict = 'UNKNOWN'
        $detail  = 'nem Get-BitLockerVolume nem manage-bde disponíveis'
      }
      if ($fallbackNote) { $detail = "$detail (após: $fallbackNote)" }
    }

    if ($verdict -eq 'CLEAN') {
      Add-Check "BitLocker $d" 'nenhum protector' "$detail [$source]" 'PASS'
    } elseif ($verdict -eq 'PROTECTED') {
      Add-Check "BitLocker $d" 'nenhum protector' "$detail [$source]" 'FAIL'
      Write-Host ""
      warn "O volume $d TEM protectors do BitLocker."
      Write-Host "      Se você ligou o BitLocker de propósito, este FAIL só quer dizer"
      Write-Host "      'difere do baseline do repo'. Se NÃO ligou, a auto-encryption do"
      Write-Host "      Windows pegou este volume — e é agora que a chave tem que sair daqui."
      Write-BitLockerRecoveryNotice -Drive $d -Password $recovery
    } elseif ($verdict -eq 'ENCRYPTED_NO_PROTECTOR') {
      Add-Check "BitLocker $d" 'nenhum protector' "$detail [$source]" 'FAIL'
      Write-Host ""
      warn "URGENTE: o volume $d está CRIPTOGRAFADO e SEM NENHUM PROTECTOR."
      Write-Host "      É o pior estado possível: 'encrypted but unprotected' (clear key)."
      Write-Host "      Não existe chave de recuperação — nem aqui, nem na conta Microsoft,"
      Write-Host "      nem no Active Directory. Um reset de TPM, um flash de BIOS ou um"
      Write-Host "      toggle de Secure Boot a partir daqui deixa o disco inacessível."
      Write-Host "      Decida AGORA entre decriptar o volume ou ligar o BitLocker de"
      Write-Host "      verdade e guardar a chave no Bitwarden. Este script não faz nem um"
      Write-Host "      nem outro — ele só lê."
      Write-Host ""
    } else {
      Add-Check "BitLocker $d" 'nenhum protector' "INDETERMINADO: $detail [$source]" 'UNKNOWN'
      Write-Host ""
      warn "Não deu para determinar o estado do BitLocker em $d — e indeterminado NÃO é aprovado."
      Write-Host "      Este item existe para impedir que você perca o acesso ao disco, então"
      Write-Host "      ele nunca chuta 'está tudo bem'. Confira na mão, nesta ordem:"
      Write-Host "        Get-BitLockerVolume -MountPoint $d | Format-List *"
      Write-Host "        manage-bde -status $d"
      Write-Host "        manage-bde -protectors -get $d"
      Write-Host "      Se aparecer qualquer protector, copie a chave de recuperação para o"
      Write-Host "      Bitwarden antes de mexer em BIOS, TPM ou Secure Boot."
      Write-Host ""
    }
  }
}

# --- 6. CPU — microcode ---

info "CPU — microcode"
# Raptor Lake: o que importa é ter a BIOS MAIS NOVA que o fabricante oferece,
# pelo fix de Vmin Shift. 0x12F (mai/2025) foi o mais recente que o plano
# conseguiu verificar e supera 0x129/0x12B — mas NÃO trate 0x12F como alvo:
# anote a revisão e compare com a página de suporte da placa. Por isso INFO,
# nunca PASS/FAIL. (Intel estendeu a garantia para 5 anos nas peças afetadas.)
# Equivalente em cmd:
#   reg query HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 /v "Update Revision"
$cpuKey  = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
$cpuName = Get-RegValue -Path $cpuKey -Name 'ProcessorNameString'
$rev     = Get-RegValue -Path $cpuKey -Name 'Update Revision'

if ($null -ne $cpuName) {
  Add-Check 'CPU' '(informativo)' ([string]$cpuName).Trim() 'INFO'
}
if ($rev -is [byte[]] -and $rev.Length -ge 8) {
  # REG_BINARY de 8 bytes; a revisão são os 4 bytes altos, little-endian.
  $revHex = '0x{0:X}' -f [BitConverter]::ToUInt32($rev, 4)
  $raw    = ($rev | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
  Add-Check 'Microcode (Update Revision)' 'a mais nova do fabricante' "$revHex (raw: $raw)" 'INFO'
} else {
  Add-Check 'Microcode (Update Revision)' 'a mais nova do fabricante' (Show-Value $rev) 'INFO'
}

# --- 7. GPU — HAGS ---

info "GPU — HAGS (Hardware-Accelerated GPU Scheduling)"
# HwSchMode tem que ser 2 na 4060 Ti: o DLSS Frame Generation não ativa com HAGS
# off, e é assim que uma placa de 8 GB continua jogável. Só 1 (disabled) e
# 2 (enabled) são documentados — 0 é folclore de fórum, nunca escreva.
# Efeito só depois de reboot: um 2 aqui logo após a escrita ainda não está valendo.
$hwSch = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
if ($null -ne $hwSch -and [int]$hwSch -eq 2) {
  Add-Check 'HwSchMode (HAGS)' '2' '2' 'PASS'
} else {
  Add-Check 'HwSchMode (HAGS)' '2' (Show-Value $hwSch) 'FAIL'
}

# --- 8. Armazenamento — TRIM ---

info "Armazenamento — TRIM"
# DisableDeleteNotify = 0 significa TRIM LIGADO (a chave é negativa).
$trimOut = Invoke-Exe -File 'fsutil' -Arguments @('behavior', 'query', 'DisableDeleteNotify')
# Builds recentes imprimem uma linha por filesystem (NTFS e ReFS); builds antigos
# imprimem uma linha só. A que importa para o SSD do sistema é a do NTFS.
# O texto ao redor é LOCALIZADO (esta máquina é pt-BR), então não dá para casar
# uma frase inteira: filtramos por palavra-chave e pegamos só o dígito do '='.
$trimLines = @($trimOut | Where-Object { $_ -match 'DisableDeleteNotify' })
$ntfsLine = $trimLines | Where-Object { $_ -match 'NTFS' } | Select-Object -First 1
if (-not $ntfsLine) { $ntfsLine = $trimLines | Select-Object -First 1 }

if ($ntfsLine -and ($ntfsLine -match '=\s*(\d)')) {
  $trimVal = $Matches[1]
  if ($trimVal -eq '0') {
    Add-Check 'TRIM (DisableDeleteNotify)' '0 = TRIM ligado' '0' 'PASS'
  } else {
    Add-Check 'TRIM (DisableDeleteNotify)' '0 = TRIM ligado' $trimVal 'FAIL'
  }
} else {
  Add-Check 'TRIM (DisableDeleteNotify)' '0 = TRIM ligado' (($trimOut -join ' ').Trim()) 'SKIP'
}

# --- 9. Defender — exclusões ---

info "Defender — exclusões de caminho"
# Só faz sentido esperar exclusões se você instalou WSL/Docker. E há uma
# pegadinha: Add-MpPreference pode PARECER ter funcionado e não ter feito nada,
# porque Tamper Protection bloqueia em silêncio. Esta lista é a única prova.
# Honestidade: exclusão reduz proteção no maior blob gravável da máquina.
try {
  $exclusions = @()
  $pref = Get-MpPreference
  if ($null -ne $pref.ExclusionPath) { $exclusions = @($pref.ExclusionPath) }

  if ($exclusions.Count -eq 0) {
    Add-Check 'Defender ExclusionPath' '(depende do WSL)' 'nenhuma exclusão' 'INFO'
  } else {
    Add-Check 'Defender ExclusionPath' '(depende do WSL)' "$($exclusions.Count) caminho(s)" 'INFO'
    foreach ($e in $exclusions) { Write-Host "        - $e" }
  }
} catch {
  Add-Check 'Defender ExclusionPath' '(depende do WSL)' "erro: $($_.Exception.Message)" 'SKIP'
}

# --- 10. winget — saúde ---

info "winget"
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $wv = Invoke-Exe -File 'winget' -Arguments @('--version')
  if ($LASTEXITCODE -eq 0) {
    Add-Check 'winget' 'responde a --version' (($wv -join ' ').Trim()) 'PASS'
  } else {
    Add-Check 'winget' 'responde a --version' "saída $LASTEXITCODE" 'FAIL'
  }
} else {
  # Numa instalação limpa isso é esperado por um tempo: o App Installer se
  # registra de forma assíncrona depois do primeiro login. O bootstrap.ps1 tem
  # o caminho de recuperação (Repair-WinGetPackageManager).
  Add-Check 'winget' 'responde a --version' 'comando não encontrado' 'FAIL'
}

# O módulo é o caminho de recuperação do bootstrap — e o único que funciona em
# contexto SYSTEM, onde a CLI winget é não suportada.
if (Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -ErrorAction SilentlyContinue) {
  Add-Check 'Módulo Microsoft.WinGet.Client' '(opcional)' 'instalado' 'INFO'
} else {
  Add-Check 'Módulo Microsoft.WinGet.Client' '(opcional)' 'ausente' 'INFO'
}

# --- 11. Resumo PASS/FAIL ---

function Format-Cell {
  param([string] $Text, [int] $Width)
  if ($null -eq $Text) { $Text = '' }
  $Text = ($Text -replace '\s+', ' ').Trim()
  if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + '~' }
  return $Text.PadRight($Width)
}

function Get-ColumnWidth {
  param([string[]] $Values, [int] $Cap, [int] $Min)
  $w = $Min
  foreach ($v in $Values) {
    $len = ($v -replace '\s+', ' ').Trim().Length
    if ($len -gt $w) { $w = $len }
  }
  if ($w -gt $Cap) { $w = $Cap }
  return $w
}

info "Resumo"
$wItem = Get-ColumnWidth -Values @($script:Results | ForEach-Object { $_.Item })     -Cap 34 -Min 12
$wExp  = Get-ColumnWidth -Values @($script:Results | ForEach-Object { $_.Esperado }) -Cap 28 -Min 8
$wAct  = Get-ColumnWidth -Values @($script:Results | ForEach-Object { $_.Atual })    -Cap 36 -Min 8

$header = "{0}  {1}  {2}  {3}" -f (Format-Cell 'VERIFICAÇÃO' $wItem),
                                  (Format-Cell 'ESPERADO'    $wExp),
                                  (Format-Cell 'ATUAL'       $wAct),
                                  'STATUS'
Write-Host $header
Write-Host ('-' * ($wItem + $wExp + $wAct + 12))

foreach ($r in $script:Results) {
  $line = "{0}  {1}  {2}  {3}" -f (Format-Cell $r.Item     $wItem),
                                  (Format-Cell $r.Esperado $wExp),
                                  (Format-Cell $r.Atual    $wAct),
                                  $r.Status
  $color = 'Gray'
  if ($r.Status -eq 'PASS')    { $color = 'Green'   }
  if ($r.Status -eq 'FAIL')    { $color = 'Red'     }
  if ($r.Status -eq 'INFO')    { $color = 'Cyan'    }
  if ($r.Status -eq 'SKIP')    { $color = 'Yellow'  }
  if ($r.Status -eq 'UNKNOWN') { $color = 'Magenta' }
  Write-Host $line -ForegroundColor $color
}

$nPass    = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$nFail    = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$nInfo    = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
$nSkip    = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count
$nUnknown = @($script:Results | Where-Object { $_.Status -eq 'UNKNOWN' }).Count

Write-Host ""
Write-Host ("  PASS $nPass   FAIL $nFail   UNKNOWN $nUnknown   INFO $nInfo   SKIP $nSkip")

# --- 12. Verificações que só dá para fazer no olho ---

info "Ainda no olho (nenhuma delas é scriptável de forma confiável)"
Write-Host "  msinfo32          BIOS Mode = UEFI · Secure Boot State = On ·"
Write-Host "                    Virtualization-based security = Not enabled"
Write-Host "  tpm.msc           Specification Version = 2.0 (o Get-Tpm não expõe isso)"
Write-Host "  Windows Security  Device security > Secure boot certificate status —"
Write-Host "                    os certificados 2023 chegam por Windows Update, e o"
Write-Host "                    'Restore Factory Keys' da BIOS descarta o que houver."
Write-Host "  BIOS              Intel Default Settings = tier Performance (o i5 não tem"
Write-Host "                    Extreme) · Multi-Core Enhancement OFF · XMP ON ·"
Write-Host "                    Resizable BAR + Above 4G ON · CSM OFF · VT-x/VT-d ON"
Write-Host "  NVIDIA app        G-Sync/VRR — o Control Panel foi aposentado e não existe"
Write-Host "                    caminho de registry versionável para isso."
Write-Host ""

if ($nUnknown -gt 0) {
  warn "$nUnknown item(ns) INDETERMINADO(s) — trate como falha até verificar na mão (ver as instruções impressas acima). Um indeterminado no BitLocker é a diferença entre um disco acessível e um disco perdido."
}
if ($nFail -gt 0) {
  warn "$nFail item(ns) divergindo do esperado. Nada foi alterado — corrija na BIOS ou pelo windows-defaults.ps1."
}
if ($nFail -gt 0 -or $nUnknown -gt 0) {
  exit 1
}
ok "Nenhuma divergência. Nada foi alterado por este script."
exit 0
