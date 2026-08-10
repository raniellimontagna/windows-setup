#!/usr/bin/env bash
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────┐
# │  ⚠️  ESTE NÃO É O CAMINHO ATIVO.                                                          │
# │                                                                                          │
# │  O caminho ativo é o `install-to-ventoy.sh`, neste mesmo diretório: o pendrive já é um    │
# │  Ventoy com 13 ISOs, e o answer file é entregue pelo plugin auto_install, sem formatar    │
# │  nada. Um pendrive só. Comece por lá — e pelo `README.md`.                                │
# │                                                                                          │
# │  Este script é a ALTERNATIVA DE PENDRIVE COMUM: ele apaga um dispositivo inteiro e        │
# │  constrói uma mídia dedicada só do Windows, com o autounattend.xml na raiz (a ordem de    │
# │  busca clássica do Setup). Ele continua aqui porque essa alternativa tem um uso real e    │
# │  específico, documentado na Fase 5 do README:                                             │
# │                                                                                          │
# │    - instalar com Secure Boot JÁ LIGADO. O bootloader do Windows é assinado pela          │
# │      Microsoft e boota com as chaves de fábrica; o do Ventoy usa CA própria e cairia no   │
# │      MOK manager pedindo enrollment — justamente no keystore que a Fase 5 acabou de       │
# │      limpar, numa máquina cujo motivo de existir é passar num anticheat kernel.           │
# │    - ou como plano B, se o Ventoy falhar na placa (a documentação dele admite que em      │
# │      algumas placas a solução simplesmente não funciona).                                 │
# │                                                                                          │
# │  Se você está seguindo o fluxo normal, NÃO rode este arquivo.                             │
# └──────────────────────────────────────────────────────────────────────────────────────────┘
#
# build-usb.sh — gera o autounattend.xml (senha vinda de fora do repo) e grava uma mídia
#                de instalação COMUM (não-Ventoy) do Windows 11 25H2 num pendrive.
#
# Uso:  sudo bash build-usb.sh --iso <arquivo.iso> --device /dev/sdX --password-file <arquivo>
#       bash build-usb.sh --inject <dir-ou-mountpoint> --password-file <arquivo>
#       bash build-usb.sh --dry-run --password-file <arquivo>
#
# NÃO RODA NO macOS — de propósito. Rode no CachyOS (enquanto ele ainda boota) ou numa VM
#   Linux do Proxmox com o pendrive passado por USB. Detalhes na seção 1.
#
# ⚠️ DESTRUTIVO no modo --device: apaga o pendrive INTEIRO, sem undo.
#    Exige confirmação digitada com o nome do dispositivo.
#
# Seguro rodar várias vezes (idempotente): reconstrói a mídia do zero a partir do ISO,
# e o autounattend.xml gerado é sempre o mesmo para o mesmo template + mesma senha.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
TEMPLATE="$DIR/autounattend.template.xml"
HASH_FILE="$DIR/iso.sha256"
PLACEHOLDER='@@LOCAL_ACCOUNT_PASSWORD@@'

info(){ printf "\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
ok(){   printf "\033[1;32m✔\033[0m %s\n" "$1"; }
warn(){ printf "\033[1;33m⚠\033[0m %s\n" "$1"; }
die(){  printf "\n\033[1;31m✖ ERRO:\033[0m %s\n\n" "$1" >&2; exit 1; }

# --- 1. Recusa de plataforma ---
# Esta recusa vale só para ESTE script (o caminho do pendrive comum), e não para o repo.
# Construir uma mídia COMUM do zero exige Linux:
#   - Rufus é Windows-only.
#   - O instalador do Ventoy não tem build para macOS (só Windows e Linux) — mas isso é
#     irrelevante aqui, porque no fluxo ativo o pendrive JÁ ESTÁ com o Ventoy instalado.
#   - O install.wim do ISO 25H2 passa de 4 GB, então um "dd do ISO" ou um pendrive FAT32
#     simples feito no Finder/Disk Utility não serve.
# A solução aqui é Linux puro: GPT + FAT32 + wimlib para dividir o install.wim em .swm,
# que é um formato que o Setup do Windows lê nativamente. Sem UEFI:NTFS, sem shim, sem Ventoy.
#
# ⚠️ NÃO conclua daqui que "não dá para preparar a mídia no Mac". Dá, e é o caminho ativo:
#    o `install-to-ventoy.sh` roda no macOS e só copia arquivos para a partição exFAT do
#    Ventoy já montada. Nada de formatar, nada de wimlib, nada de dividir .wim — o Ventoy
#    boota o ISO direto do arquivo, então o teto de 4 GB do FAT32 nem entra na conversa.
if [ "$(uname -s)" = "Darwin" ]; then
  cat >&2 <<'EOF'

✖ ERRO: este script não roda no macOS, e isso não é um descuido.

  ➜ Você provavelmente queria o caminho ATIVO, que roda no Mac sem problema nenhum:

        bash unattend/install-to-ventoy.sh --password-file "$HOME/.windows-setup-password"

    Ele entrega o answer file pelo plugin auto_install do Ventoy, no pendrive que você já
    tem. Não formata nada. Leia o unattend/README.md.

  Este script aqui é a ALTERNATIVA de pendrive COMUM (sem Ventoy), e essa sim precisa de
  Linux para ser construída:
    - Rufus é Windows-only.
    - O install.wim do ISO passa de 4 GB e não cabe num FAT32 sem ser dividido;
      dividir exige wimlib, que aqui é usado via wimlib-imagex.

  Se você realmente quer a mídia comum (ex.: instalar com Secure Boot já ligado):
    (a) Rode este script no CachyOS, ENQUANTO ELE AINDA BOOTA. Depois do wipe não dá mais.
    (b) Ou numa VM Linux no Proxmox, com o pendrive repassado por USB passthrough.

  Faça isto ANTES de mexer no disco. Ficar sem mídia no dia da instalação é ficar
  sem nenhum sistema operacional.

EOF
  exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
  die "Sistema não suportado ($(uname -s)). Este script foi escrito para Linux."
fi

# --- 2. Argumentos ---
ISO=""
DEVICE=""
INJECT_DIR=""
PW_FILE="${WINSETUP_PASSWORD_FILE:-}"   # também aceita a variável de ambiente
EXTRAS_DIR=""
DRY_RUN=0
ALLOW_FIXED=0

usage(){
  cat <<'EOF'
Uso:
  sudo bash build-usb.sh --iso <arquivo.iso> --device /dev/sdX --password-file <arquivo>
       Grava o pendrive do zero. ⚠️ APAGA O DISPOSITIVO INTEIRO.

  bash build-usb.sh --inject <dir> --password-file <arquivo>
       Só escreve o autounattend.xml na raiz de uma mídia que já existe (Ventoy, Rufus,
       pendrive antigo) ou num diretório qualquer. Não apaga nada, e não precisa de --iso.
       Útil também para montar a ISO de teste da VM do Proxmox (Fase 4).

  bash build-usb.sh --dry-run --password-file <arquivo>
       Só gera e valida o XML num diretório temporário. Não toca em disco nenhum.

Opções:
  --iso <arquivo>             ISO do Windows 11 25H2 x64 em Português (Brasil).
  --device /dev/sdX           Disco INTEIRO do pendrive (não uma partição: /dev/sdb, não sdb1).
  --inject <dir>              Escreve só o autounattend.xml no diretório/mídia indicado.
  --password-file <arquivo>   Arquivo de UMA linha com a senha da conta local.
                              TEM que estar fora do repo. Também lido de $WINSETUP_PASSWORD_FILE.
  --extras <dir>              Copia esta pasta para <mídia>/extras/ (drivers de rede, bootstrap).
  --allow-fixed-disk          Permite gravar num disco não removível. Cinto de segurança:
                              sem isso, o script recusa qualquer coisa que não seja removível.
  --dry-run                   Só gera e valida o XML.
  -h, --help                  Esta ajuda.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --iso)                ISO="${2:-}";        shift 2 ;;
    --device)             DEVICE="${2:-}";     shift 2 ;;
    --inject)             INJECT_DIR="${2:-}"; shift 2 ;;
    --password-file)      PW_FILE="${2:-}";    shift 2 ;;
    --extras)             EXTRAS_DIR="${2:-}"; shift 2 ;;
    --allow-fixed-disk)   ALLOW_FIXED=1;       shift ;;
    --dry-run)            DRY_RUN=1;           shift ;;
    -h|--help)            usage; exit 0 ;;
    *) usage >&2; die "Argumento desconhecido: $1" ;;
  esac
done

MODES=0
[ -n "$DEVICE" ]     && MODES=$((MODES + 1))
[ -n "$INJECT_DIR" ] && MODES=$((MODES + 1))
[ "$DRY_RUN" -eq 1 ] && MODES=$((MODES + 1))
[ "$MODES" -eq 1 ] || { usage >&2; die "Escolha exatamente um modo: --device, --inject ou --dry-run."; }

[ -f "$TEMPLATE" ] || die "Template não encontrado: $TEMPLATE"

# --- 3. Senha (mora fora do repo, igual ao ~/.secrets.zsh) ---
[ -n "$PW_FILE" ] || die "Faltou --password-file (ou a variável \$WINSETUP_PASSWORD_FILE)."
[ -f "$PW_FILE" ] || die "Arquivo de senha não existe: $PW_FILE"

PW_FILE_ABS="$(readlink -f "$PW_FILE")"
case "$PW_FILE_ABS" in
  "$REPO_ROOT"/*)
    die "O arquivo de senha está DENTRO do repo ($PW_FILE_ABS).
     O repo é público. Mova o arquivo para fora, por exemplo ~/.windows-setup-password,
     com permissão 600, e rode de novo." ;;
esac

PW_PERMS="$(stat -c '%a' "$PW_FILE_ABS")"
[ "$PW_PERMS" = "600" ] || warn "Permissão do arquivo de senha é $PW_PERMS. O ideal é 600 (chmod 600 '$PW_FILE_ABS')."

# read -r lê só a primeira linha e já descarta o \n final. O `tr -d '\r'` cuida do caso de um
# arquivo de senha salvo com CRLF: o \r invisível entraria na senha da conta e o resultado é
# não conseguir logar na máquina recém-formatada, com a senha "certa" na mão.
LOCAL_PASSWORD="$(head -n1 "$PW_FILE_ABS" | tr -d '\r')"
[ -n "${LOCAL_PASSWORD:-}" ] || die "O arquivo de senha está vazio: $PW_FILE_ABS"
ok "Senha lida de $PW_FILE_ABS (${#LOCAL_PASSWORD} caracteres, não será impressa)."

# --- 4. Área de trabalho temporária ---
WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
ISO_MNT="$WORKDIR/iso"
USB_MNT="$WORKDIR/usb"
GENERATED="$WORKDIR/autounattend.xml"

cleanup(){
  set +e
  mountpoint -q "$USB_MNT" 2>/dev/null && umount "$USB_MNT"
  mountpoint -q "$ISO_MNT" 2>/dev/null && umount "$ISO_MNT"
  # O XML gerado tem a senha em texto claro. Ele nunca sai deste diretório temporário
  # a não ser para a mídia; aqui ele morre junto com o diretório.
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# --- 5. Verificação do SHA-256 do ISO ---
# Feita ANTES de qualquer escrita. Um ISO truncado ou trocado só se manifesta no meio da
# instalação, com a máquina já formatada.
if [ -n "$ISO" ]; then
  [ -f "$ISO" ] || die "ISO não encontrado: $ISO"
  [ -f "$HASH_FILE" ] || die "Arquivo de hash não encontrado: $HASH_FILE"

  # O iso.sha256 tem comentários (linhas com #), então não dá para usar 'sha256sum -c'
  # direto. A primeira linha útil é '<hash>  <nome do arquivo>'.
  # Um awk só, e não um pipe de greps: com 'set -o pipefail', um grep que não casa nada
  # derrubaria o script com exit 1 e sem mensagem nenhuma.
  EXPECTED="$(awk '!/^[[:space:]]*#/ && NF { print tolower($1); exit }' "$HASH_FILE")"

  case "$EXPECTED" in
    ""|*@@*|0000000000000000000000000000000000000000000000000000000000000000)
      die "O $HASH_FILE ainda está com o placeholder.
     Preencha com o SHA-256 do ISO em Português (Brasil) que você baixou.
     A Microsoft publica uma tabela de hashes POR IDIOMA na própria página de download:
     o hash do en-US não bate com o do pt-BR. Copie o da linha em Português (Brasil)." ;;
  esac

  info "Conferindo o SHA-256 do ISO (leva alguns minutos)..."
  ACTUAL="$(sha256sum "$ISO" | awk '{print $1}' | tr 'A-F' 'a-f')"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    die "SHA-256 NÃO CONFERE. Nada foi escrito.
     esperado: $EXPECTED
     obtido:   $ACTUAL
     Baixe o ISO de novo, ou corrija o $HASH_FILE se o hash lá é que está errado."
  fi
  ok "SHA-256 confere: $ACTUAL"
elif [ "$DRY_RUN" -eq 0 ] && [ -z "$INJECT_DIR" ]; then
  die "Faltou --iso."
fi

# --- 6. Geração do autounattend.xml ---
# A substituição é feita em memória, com expansão de string do bash, e não com sed/awk:
# a senha nunca aparece na linha de comando de um processo (e portanto nunca em 'ps').
xml_escape(){
  local s="$1"
  s="${s//&/&amp;}"     # & primeiro, senão as outras substituições são reescapadas
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

info "Gerando o autounattend.xml a partir do template..."
TEMPLATE_CONTENT="$(cat "$TEMPLATE")"
case "$TEMPLATE_CONTENT" in
  *"$PLACEHOLDER"*) ;;
  *) die "O template não contém $PLACEHOLDER. Alguém já substituiu a senha lá dentro?
     Não grave essa mídia: confira o $TEMPLATE antes." ;;
esac

ESCAPED_PASSWORD="$(xml_escape "$LOCAL_PASSWORD")"
umask 077
printf '%s\n' "${TEMPLATE_CONTENT//"$PLACEHOLDER"/$ESCAPED_PASSWORD}" > "$GENERATED"

# Garantia de que a substituição realmente aconteceu (um placeholder sobrando vira uma
# senha literal "@@LOCAL_ACCOUNT_PASSWORD@@" na máquina instalada).
if grep -qF -- "$PLACEHOLDER" "$GENERATED"; then
  die "Sobrou placeholder no XML gerado. Abortado."
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$GENERATED" || die "O XML gerado está malformado. XML malformado = loop de reboot."
  ok "XML validado com xmllint (bem formado)."
else
  warn "xmllint não encontrado; pulei a validação do XML. Instale libxml2 para ter essa checagem."
fi
ok "autounattend.xml gerado ($(wc -c < "$GENERATED") bytes)."

if [ "$DRY_RUN" -eq 1 ]; then
  info "Modo --dry-run: nada foi escrito em disco."
  echo "  O XML foi gerado e validado num diretório temporário e será apagado agora."
  exit 0
fi

# --- 7. Modo --inject (não destrutivo) ---
# Escreve só o autounattend.xml na raiz de uma mídia que já existe.
#
# ⚠️ CONFLITO DE DONO DA CUSTOMIZAÇÃO — leia antes de usar isto com uma mídia feita no Rufus:
#   O Rufus, quando você deixa qualquer checkbox da tela WUE marcado (pular requisitos,
#   pular conta Microsoft, usuário local, desligar coleta de dados etc.), grava um answer
#   file PRÓPRIO na mídia. Esse arquivo vence a ordem de busca do Setup, e o seu
#   autounattend.xml passa a ser IGNORADO — sem erro, sem aviso, sem log óbvio. Você só
#   descobre quando a instalação termina em inglês, com conta Microsoft e ESP de 100 MB.
#   Ou o Rufus é o dono da customização, ou este repo é. Nunca os dois.
#   Se for usar Rufus: DESMARQUE TODOS os checkboxes da tela WUE.
#   Se for usar Ventoy: o Ventoy tem o próprio plugin de auto-install; não use os dois juntos.
if [ -n "$INJECT_DIR" ]; then
  [ -d "$INJECT_DIR" ] || die "Diretório de destino não existe: $INJECT_DIR"
  info "Injetando o autounattend.xml em $INJECT_DIR"

  # Um autounattend.xml de outra origem no mesmo lugar é exatamente o conflito descrito acima.
  if [ -f "$INJECT_DIR/autounattend.xml" ]; then
    warn "Já existe um autounattend.xml em $INJECT_DIR. Ele será SOBRESCRITO."
  fi
  for f in "$INJECT_DIR"/unattend.xml "$INJECT_DIR"/sources/unattend.xml "$INJECT_DIR"/autounattend/autounattend.xml; do
    if [ -e "$f" ]; then
      warn "Achei outro answer file na mídia: $f"
      warn "Ele pode vencer a ordem de busca do Setup e anular o seu. Remova-o antes de instalar."
    fi
  done

  cp "$GENERATED" "$INJECT_DIR/autounattend.xml"
  sync
  ok "autounattend.xml escrito em $INJECT_DIR/autounattend.xml"
  echo
  echo "  Lembre: o arquivo tem a senha da conta local em texto claro. Essa mídia agora é"
  echo "  um segredo físico. Não empreste o pendrive."
  exit 0
fi

# --- 8. Modo --device: dependências ---
[ "$(id -u)" -eq 0 ] || die "O modo --device precisa de root. Rode com sudo."

MISSING=()
need_cmd(){ command -v "$1" >/dev/null 2>&1 || MISSING+=("$1 (pacote: $2)"); }
need_cmd sgdisk        gptfdisk
need_cmd mkfs.vfat     dosfstools
need_cmd wimlib-imagex wimlib
need_cmd rsync         rsync
need_cmd lsblk         util-linux
need_cmd partprobe     parted
if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'Faltam ferramentas:\n' >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  die "No CachyOS/Arch: sudo pacman -S gptfdisk dosfstools wimlib rsync parted"
fi

[ -b "$DEVICE" ] || die "$DEVICE não é um dispositivo de bloco."
DEV_TYPE="$(lsblk -dnro TYPE "$DEVICE")"
[ "$DEV_TYPE" = "disk" ] || die "$DEVICE é do tipo '$DEV_TYPE'. Passe o DISCO inteiro (/dev/sdb), não uma partição (/dev/sdb1)."

DEV_NAME="$(basename "$DEVICE")"
REMOVABLE="$(cat "/sys/block/$DEV_NAME/removable" 2>/dev/null || echo 0)"
if [ "$REMOVABLE" != "1" ] && [ "$ALLOW_FIXED" -eq 0 ]; then
  die "$DEVICE NÃO está marcado como removível pelo kernel.
     Isto quase sempre significa que você apontou para um disco interno.
     Confira com: lsblk -o NAME,MODEL,SIZE,TRAN,RM
     Se tiver ABSOLUTA certeza, repita com --allow-fixed-disk."
fi

# Nunca escrever num disco que está segurando o sistema em execução.
while IFS= read -r MP; do
  case "$MP" in
    /|/boot|/boot/efi|/home|/var|/usr)
      die "$DEVICE tem uma partição montada em '$MP'. Este é o disco do sistema em execução. Abortado." ;;
  esac
done < <(lsblk -lnro MOUNTPOINT "$DEVICE" | grep -v '^$' || true)

# --- 9. Modo --device: confirmação DESTRUTIVA ---
echo
warn "=============================================================================="
warn " ATENÇÃO: OPERAÇÃO DESTRUTIVA E IRREVERSÍVEL"
warn "=============================================================================="
echo
echo "  Tudo o que estiver gravado no dispositivo abaixo será APAGADO PARA SEMPRE."
echo "  Não existe desfazer, não existe lixeira, não existe recuperação."
echo
lsblk -o NAME,MODEL,SIZE,TYPE,TRAN,RM,FSTYPE,LABEL,MOUNTPOINT "$DEVICE" || true
echo
echo "  Confira acima o MODELO e o TAMANHO. Se isso não for exatamente o pendrive que"
echo "  você quer apagar, cancele agora: qualquer resposta diferente da pedida abaixo"
echo "  cancela a operação e nada é escrito."
echo
printf "  Para continuar, digite exatamente o nome do dispositivo '%s' e pressione Enter: " "$DEVICE"
IFS= read -r CONFIRM || true
if [ "$CONFIRM" != "$DEVICE" ]; then
  die "Confirmação não conferiu (você digitou: '${CONFIRM:-<vazio>}'). Nada foi escrito."
fi
echo

# --- 10. Modo --device: particionar, formatar e copiar ---
info "Desmontando partições de $DEVICE, se houver..."
while IFS= read -r PART_PATH; do
  [ "$PART_PATH" = "$DEVICE" ] && continue
  umount "$PART_PATH" 2>/dev/null || true
done < <(lsblk -lnpo NAME "$DEVICE")

info "Criando a tabela GPT com uma única partição..."
# Uma partição só, FAT32, tipo 0700 (Microsoft basic data). O firmware UEFI de qualquer
# placa moderna boota um pendrive FAT32 direto, sem ESP separada.
wipefs --all "$DEVICE" >/dev/null
sgdisk --zap-all "$DEVICE" >/dev/null
sgdisk --new=1:0:0 --typecode=1:0700 --change-name=1:WIN11 "$DEVICE" >/dev/null
partprobe "$DEVICE"
command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 2

PART="$(lsblk -lnpo NAME "$DEVICE" | sed -n '2p')"
[ -b "$PART" ] || die "Não consegui identificar a partição criada em $DEVICE."
ok "Partição: $PART"

info "Formatando $PART como FAT32..."
mkfs.vfat -F 32 -n WIN11 "$PART" >/dev/null
ok "FAT32 pronto."

mkdir -p "$ISO_MNT" "$USB_MNT"
mount -o loop,ro "$ISO" "$ISO_MNT"
mount "$PART" "$USB_MNT"

# FAT32 não tem dono, permissão nem symlink: rsync com -rt, não -a (senão ele reclama sem parar).
# O install.wim fica de fora aqui e é tratado logo abaixo.
info "Copiando o conteúdo do ISO para a mídia (demora)..."
rsync -rt --no-perms --no-owner --no-group --modify-window=2 \
      --exclude='sources/install.wim' \
      "$ISO_MNT"/ "$USB_MNT"/
ok "Conteúdo copiado."

# O limite de tamanho de arquivo do FAT32 é 4 GiB menos 1 byte. O install.wim do 25H2
# passa disso. wimlib-imagex split gera install.swm + install2.swm..., que é um formato
# que o Setup do Windows lê nativamente — nada de UEFI:NTFS nem driver extra.
if [ -f "$ISO_MNT/sources/install.wim" ]; then
  WIM_SIZE="$(stat -c %s "$ISO_MNT/sources/install.wim")"
  if [ "$WIM_SIZE" -ge 4294967295 ]; then
    info "install.wim tem $((WIM_SIZE / 1024 / 1024)) MB e não cabe em FAT32. Dividindo em .swm..."
    wimlib-imagex split "$ISO_MNT/sources/install.wim" "$USB_MNT/sources/install.swm" 3800
    ok "install.wim dividido em partes de até 3800 MB."
  else
    info "install.wim cabe em FAT32; copiando inteiro..."
    cp "$ISO_MNT/sources/install.wim" "$USB_MNT/sources/install.wim"
    ok "install.wim copiado."
  fi
elif [ -f "$ISO_MNT/sources/install.esd" ]; then
  # ISO com install.esd (comprimido). Ele já foi copiado pelo rsync; só confirma o tamanho.
  ESD_SIZE="$(stat -c %s "$ISO_MNT/sources/install.esd")"
  if [ "$ESD_SIZE" -ge 4294967295 ]; then
    die "Este ISO usa install.esd de $((ESD_SIZE / 1024 / 1024)) MB, que não cabe em FAT32
     e não pode ser dividido com wimlib. Use o ISO oficial da Microsoft (que traz install.wim)."
  fi
  ok "install.esd copiado."
else
  die "Não achei sources/install.wim nem sources/install.esd no ISO. Este ISO é do Windows mesmo?"
fi

# O autounattend.xml TEM que ficar na raiz da mídia. É lá que o Setup procura.
info "Escrevendo o autounattend.xml na raiz da mídia..."
cp "$GENERATED" "$USB_MNT/autounattend.xml"
ok "autounattend.xml no lugar."

# --- 11. Extras (drivers, bootstrap) ---
# O item verdadeiramente crítico aqui é o DRIVER DE REDE da placa-mãe (Intel I225/I226 ou
# Realtek 2.5GbE). Sem NIC no primeiro boot, winget/scoop/choco morrem todos na largada e
# você fica numa máquina recém-formatada sem jeito de baixar nada.
if [ -n "$EXTRAS_DIR" ]; then
  [ -d "$EXTRAS_DIR" ] || die "Pasta de extras não existe: $EXTRAS_DIR"
  info "Copiando extras de $EXTRAS_DIR para a mídia..."
  mkdir -p "$USB_MNT/extras"
  rsync -rt --no-perms --no-owner --no-group --modify-window=2 "$EXTRAS_DIR"/ "$USB_MNT/extras"/
  ok "Extras copiados para <mídia>/extras/"
else
  warn "Nenhum --extras informado: a mídia vai sair SEM driver de rede embarcado."
fi

info "Sincronizando (não tire o pendrive ainda)..."
sync
umount "$USB_MNT"
umount "$ISO_MNT"
ok "Mídia desmontada com segurança. Pode remover o pendrive."

# --- 12. Resumo ---
info "Pronto. Antes do dia da instalação, confira:"
cat <<'EOF'
  [ ] Testar esta mídia numa VM do Proxmox (Fase 4 do README) — conta local criada,
      zero prompt de OOBE, teclado ABNT2, encryption off. XML malformado = loop de reboot.
  [ ] Driver de rede da placa-mãe copiado em <mídia>/extras/  (--extras)
  [ ] INF do chipset e, se o Intel VMD ficar ligado, o f6vmdflpy-x64
  [ ] Plano B do winget offline: Microsoft.DesktopAppInstaller_*.msixbundle
      + DesktopAppInstaller_Dependencies.zip
  [ ] Esta mídia contém a senha da conta local em texto claro no autounattend.xml.
      Guarde o pendrive como um segredo físico e troque a senha depois do primeiro boot.
EOF
