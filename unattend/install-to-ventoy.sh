#!/usr/bin/env bash
#
# install-to-ventoy.sh — publica o answer file do Windows 11 25H2 e a configuração do plugin
#                        auto_install num pendrive Ventoy QUE JÁ EXISTE.
#
# Uso:  bash unattend/install-to-ventoy.sh --password-file "$HOME/.windows-setup-password"
#       bash unattend/install-to-ventoy.sh --password-file <arq> --ventoy /Volumes/Ventoy
#       bash unattend/install-to-ventoy.sh --password-file <arq> --dry-run
#       bash unattend/install-to-ventoy.sh --password-file <arq> --yes      # sem confirmação
#       WINSETUP_PASSWORD_FILE="$HOME/.windows-setup-password" bash unattend/install-to-ventoy.sh
#
# Opções:
#   --ventoy <mountpoint>   Partição 1 do Ventoy já montada. Padrão: /Volumes/Ventoy no macOS,
#                           autodetectada em /run/media, /media e /mnt no Linux.
#   --iso <arquivo>         ISO a conferir. Padrão: o ISO do 25H2 dentro do próprio pendrive.
#   --password-file <arq>   Arquivo com a senha da conta local, FORA do repo (ou
#                           $WINSETUP_PASSWORD_FILE). Uma linha, sem aspas.
#   --dry-run               Faz tudo (hash, geração, merge, diff) e não escreve no pendrive.
#   --yes                   Não pergunta antes de alterar o /ventoy/ventoy.json existente.
#
# RODA NO macOS E NO LINUX. Este script substituiu o build-usb.sh como caminho ativo porque a
# premissa dele deixou de valer: aqui o pendrive JÁ É um Ventoy, formatado em exFAT e montado
# read-write no Mac. Não existe mais nada para particionar, formatar ou dividir — o Ventoy
# boota o ISO direto do arquivo, então o limite de 4 GB do FAT32 (que era o motivo de precisar
# do wimlib e, portanto, do Linux) simplesmente não se aplica. O trabalho virou copiar dois
# arquivos de texto.
#
# NÃO É DESTRUTIVO: não formata, não escreve em block device, não apaga ISO nenhum, não mexe
#   na partição VTOYEFI. Só cria/atualiza dois arquivos dentro de /ventoy no pendrive.
#   O único arquivo pré-existente que ele pode alterar é o /ventoy/ventoy.json — e nesse caso
#   faz backup, faz MERGE (nunca clobber) e mostra o diff antes de escrever.
#
# Seguro rodar várias vezes (idempotente): o mesmo template + a mesma senha geram exatamente o
#   mesmo autounattend.xml, e o merge do ventoy.json substitui a entrada pela chave `image` em
#   vez de acumular duplicatas.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
TEMPLATE="$DIR/autounattend.template.xml"
HASH_FILE="$DIR/iso.sha256"
REPO_VENTOY_JSON="$REPO_ROOT/ventoy/ventoy.json"
PLACEHOLDER='@@LOCAL_ACCOUNT_PASSWORD@@'

info(){ printf "\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
ok(){   printf "\033[1;32m✔\033[0m %s\n" "$1"; }
warn(){ printf "\033[1;33m⚠\033[0m %s\n" "$1"; }
die(){  printf "\n\033[1;31m✖ ERRO:\033[0m %s\n\n" "$1" >&2; exit 1; }

# Caminho absoluto com symlinks resolvidos — inclusive no ARQUIVO, não só no diretório.
# Resolver só o diretório deixava um buraco real: um symlink em $HOME apontando para dentro
# do repo passava pela recusa de "senha dentro do repo" da seção 6.
# macOS não garante `realpath` nem `readlink -f` no PATH; o python3 já é dependência.
abspath(){ python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# Escapa os cinco caracteres que quebram um documento XML. SEM ISSO, uma senha contendo
# & < > " ' gera um autounattend.xml malformado — e o Setup do Windows não avisa: ele entra
# em LOOP DE REBOOT, numa máquina que a essa altura já não tem mais sistema operacional.
# Senha forte com & ou " é comum, então isto não é caso de borda.
# A ordem importa: o & tem que ser substituído PRIMEIRO, senão ele reescreveria os &
# introduzidos pelas substituições seguintes.
xml_escape(){
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

VENTOY_MNT=""
ISO=""
PW_FILE="${WINSETUP_PASSWORD_FILE:-}"
DRY_RUN=0
ASSUME_YES=0

# --- 1. Argumentos ---
while [ $# -gt 0 ]; do
  case "$1" in
    --ventoy)        VENTOY_MNT="${2:-}"; shift 2 ;;
    --iso)           ISO="${2:-}";        shift 2 ;;
    --password-file) PW_FILE="${2:-}";    shift 2 ;;
    --dry-run)       DRY_RUN=1;           shift ;;
    --yes)           ASSUME_YES=1;        shift ;;
    -h|--help)       sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Argumento desconhecido: $1  (use --help)" ;;
  esac
done

# --- 2. Dependências e portabilidade ---
# Só duas: um utilitário de SHA-256 (nome diferente em cada SO) e o python3, usado
# exclusivamente para ler e reescrever JSON. Fazer merge de JSON com sed/awk é como se
# perde configuração alheia — e aqui o arquivo alvo pode conter plugins que não são nossos.
OS="$(uname -s)"
case "$OS" in
  Darwin) SHA_CMD=(shasum -a 256) ;;
  Linux)  SHA_CMD=(sha256sum) ;;
  *)      die "SO não suportado: $OS. Este script roda no macOS e no Linux." ;;
esac
command -v "${SHA_CMD[0]}" >/dev/null 2>&1 || die "'${SHA_CMD[0]}' não encontrado no PATH."
command -v python3 >/dev/null 2>&1 || die \
  "python3 não encontrado. É necessário para fazer MERGE do ventoy.json sem destruir
  configuração existente. No macOS: 'xcode-select --install'. No Linux: instale python3."

# --- 3. Localizar a partição do Ventoy ---
# O Ventoy tem duas partições: a primeira (grande, exFAT, com os ISOs) e a VTOYEFI (32 MB).
# Tudo aqui vai na PRIMEIRA. A documentação é explícita: "A ventoy.json file must be exist in
# /ventoy directory under the first partition (along with the iso files)."
if [ -z "$VENTOY_MNT" ]; then
  for cand in "/Volumes/Ventoy" "/run/media/$USER/Ventoy" "/media/$USER/Ventoy" "/media/Ventoy" "/mnt/Ventoy"; do
    if [ -d "$cand" ]; then VENTOY_MNT="$cand"; break; fi
  done
fi
[ -n "$VENTOY_MNT" ] || die \
  "Não achei a partição do Ventoy montada. Plugue o pendrive e passe --ventoy <mountpoint>."
[ -d "$VENTOY_MNT" ] || die "--ventoy '$VENTOY_MNT' não é um diretório."
VENTOY_MNT="$(abspath "$VENTOY_MNT")"
[ -w "$VENTOY_MNT" ] || die "Sem permissão de escrita em '$VENTOY_MNT'. Montado read-only?"

# Sanidade: se não houver nenhum .iso na raiz, provavelmente não é o pendrive certo. Escrever
# um /ventoy/ dentro do diretório errado é inofensivo, mas silenciosamente inútil — e "achei
# que tinha injetado" é exatamente o modo de falha que este script existe para evitar.
if ! ls "$VENTOY_MNT"/*.iso >/dev/null 2>&1; then
  warn "Nenhum arquivo .iso na raiz de '$VENTOY_MNT'. Confira se é mesmo a partição do Ventoy."
fi
ok "Partição do Ventoy: $VENTOY_MNT"

# --- 4. Ler a configuração do repo (fonte da verdade das chaves) ---
# O script NÃO redigita nome de chave nenhum: tudo (image, template, autosel, control) vem do
# ventoy/ventoy.json versionado. Assim existe um único lugar para editar a configuração, e o
# script não pode divergir dela.
[ -f "$REPO_VENTOY_JSON" ] || die "Não encontrei '$REPO_VENTOY_JSON'."

# Uma chave por LINHA, e leitura linha a linha. Separar por espaço quebrava com nome de ISO
# que tem espaço — e 4 dos 13 ISOs deste pendrive têm ("tiny10 x64 23h2.iso",
# "Windows 7 Lite.iso"...). Falharia ruidosamente, mas falharia.
CFG_OUT="$(python3 - "$REPO_VENTOY_JSON" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
ai = cfg.get("auto_install")
if not isinstance(ai, list) or len(ai) != 1:
    sys.exit("ventoy.json do repo deve ter exatamente 1 entrada em auto_install.")
e = ai[0]
img, tpl = e.get("image"), e.get("template")
if not isinstance(img, str) or not img.startswith("/"):
    sys.exit("chave 'image' ausente ou nao e um caminho absoluto.")
if not isinstance(tpl, str) or not tpl.startswith("/ventoy/"):
    sys.exit("chave 'template' deve ser uma string comecando por /ventoy/.")
print(img)
print(tpl)
PY
)"
IMAGE_PATH="$(printf '%s\n' "$CFG_OUT" | sed -n '1p')"
TEMPLATE_PATH="$(printf '%s\n' "$CFG_OUT" | sed -n '2p')"
[ -n "${IMAGE_PATH:-}" ] && [ -n "${TEMPLATE_PATH:-}" ] || die "Falha ao ler $REPO_VENTOY_JSON."
ok "Config do repo: image=$IMAGE_PATH  template=$TEMPLATE_PATH"

# `image` é o caminho do ISO como o Ventoy o enxerga (raiz = partição 1). Traduzimos para o
# caminho real no host para conferir o hash.
[ -n "$ISO" ] || ISO="$VENTOY_MNT$IMAGE_PATH"

# --- 5. Senha (mora FORA do repo, mesma regra do ~/.secrets.zsh) ---
# Validada ANTES do hash de propósito: conferir 7,6 GiB via USB leva minutos, e descobrir
# só depois disso que faltou --password-file é o tipo de espera que faz a pessoa começar a
# pular etapas. Tudo que é barato de checar vem primeiro.
# O repo é público. A senha nunca entra nele, nem versionada nem por descuido de um `git add`.
[ -n "$PW_FILE" ] || die \
  "Faltou a senha da conta local. Passe --password-file <arq> ou defina \$WINSETUP_PASSWORD_FILE.
  Exemplo:
    printf '%s\\n' 'SuaSenhaAqui' > \"\$HOME/.windows-setup-password\"
    chmod 600 \"\$HOME/.windows-setup-password\""
[ -f "$PW_FILE" ] || die "Arquivo de senha não encontrado: $PW_FILE"
PW_FILE_ABS="$(abspath "$PW_FILE")"

# Recusa explícita: arquivo de senha dentro do repo. Um `git add -A` distraído publicaria a
# senha da máquina no GitHub, e o histórico do git não esquece.
# O abspath resolve symlinks no arquivo, então um link fora do repo apontando para dentro
# dele também é pego.
case "$PW_FILE_ABS/" in
  "$REPO_ROOT"/*) die \
    "O arquivo de senha está DENTRO do repo ($PW_FILE_ABS).
  Isso é recusado de propósito: este repo é público e um 'git add -A' publicaria a senha.
  Mova para fora, por exemplo \$HOME/.windows-setup-password, e rode de novo." ;;
esac

# Permissão: aviso, não erro. `stat` tem sintaxe diferente no BSD e no GNU.
case "$OS" in
  Darwin) PW_MODE="$(stat -f '%OLp' "$PW_FILE_ABS" 2>/dev/null || echo '')" ;;
  Linux)  PW_MODE="$(stat -c '%a'   "$PW_FILE_ABS" 2>/dev/null || echo '')" ;;
esac
if [ -n "$PW_MODE" ] && [ "$PW_MODE" != "600" ]; then
  warn "O arquivo de senha está com permissão $PW_MODE (o ideal é 600):  chmod 600 '$PW_FILE_ABS'"
fi

# tr -d '\r': um arquivo de senha salvo no Windows, ou vindo de um editor configurado com
# CRLF, carrega um \r invisível no fim da linha. Ele entraria na senha da conta, e o
# resultado é não conseguir logar na máquina recém-formatada — com a senha "certa" na mão.
LOCAL_PASSWORD="$(head -n1 "$PW_FILE_ABS" | tr -d '\r')"
[ -n "$LOCAL_PASSWORD" ] || die "O arquivo de senha '$PW_FILE_ABS' está vazio."
ok "Senha lida de $PW_FILE_ABS (${#LOCAL_PASSWORD} caracteres, não será impressa)."

# --- 6. Verificação do SHA-256 do ISO ---
# Um answer file perfeito colado num ISO errado (idioma en-US, download truncado, mídia
# adulterada) produz exatamente o desastre que este diretório inteiro tenta evitar — uma
# instalação irreversível, errada, numa máquina que já não tem mais sistema operacional
# para voltar atrás.
info "Conferindo o SHA-256 do ISO (pode levar alguns minutos: são ~7,6 GiB via USB)..."
[ -f "$ISO" ] || die "ISO não encontrado: $ISO"
[ -f "$HASH_FILE" ] || die "Não encontrei '$HASH_FILE'."

EXPECTED_SHA="$(grep -Eo '^[0-9a-fA-F]{64}' "$HASH_FILE" | head -n1 | tr 'A-F' 'a-f')"
[ -n "$EXPECTED_SHA" ] || die "Nenhum hash SHA-256 válido em '$HASH_FILE'."
case "$EXPECTED_SHA" in
  0000000000000000000000000000000000000000000000000000000000000000)
    die "O hash em '$HASH_FILE' ainda é o placeholder de zeros. Preencha antes de continuar." ;;
esac

ACTUAL_SHA="$("${SHA_CMD[@]}" "$ISO" | awk '{print $1}' | tr 'A-F' 'a-f')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  die "SHA-256 NÃO confere — pare e não instale com esta mídia.
  arquivo:   $ISO
  esperado:  $EXPECTED_SHA
  obtido:    $ACTUAL_SHA
  Hipótese nº 1: você baixou o ISO de outro idioma (o hash é POR IDIOMA). Hipótese nº 2:
  download truncado. Em qualquer dos casos, baixe de novo da página oficial."
fi
ok "SHA-256 confere: $ACTUAL_SHA"

# --- 7. Geração do autounattend.xml em área temporária ---
# A substituição é feita com expansão de parâmetro do bash, não com sed: a senha pode conter
# &, /, \ e outros caracteres que o sed interpretaria. Também não passamos a senha por argv
# de processo nenhum — argv é visível no `ps` para qualquer usuário da máquina.
[ -f "$TEMPLATE" ] || die "Template não encontrado: $TEMPLATE"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup(){ rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

info "Gerando o autounattend.xml a partir do template..."
TEMPLATE_CONTENT="$(cat "$TEMPLATE")"
grep -q "$PLACEHOLDER" "$TEMPLATE" || die \
  "O template '$TEMPLATE' não contém o placeholder $PLACEHOLDER.
  Ou ele já foi editado à mão (e talvez tenha uma senha dentro), ou é o arquivo errado."

# A senha vai ESCAPADA para XML. O valor original é que vale para o login do Windows — o
# parser do Setup desfaz o escape ao ler o arquivo.
ESCAPED_PASSWORD="$(xml_escape "$LOCAL_PASSWORD")"
GENERATED_XML="${TEMPLATE_CONTENT//"$PLACEHOLDER"/$ESCAPED_PASSWORD}"
GENERATED="$WORKDIR/autounattend.xml"
printf '%s\n' "$GENERATED_XML" > "$GENERATED"

# Asserção dura: se sobrou placeholder, o Windows tentaria criar a conta com a senha literal
# "@@LOCAL_ACCOUNT_PASSWORD@@" — e o pior é que isso *funcionaria*, deixando a máquina com uma
# senha que está escrita em texto claro num repo público.
if grep -q "$PLACEHOLDER" "$GENERATED"; then
  die "Sobrou placeholder $PLACEHOLDER no XML gerado. Abortando sem escrever nada."
fi

# Validação de XML bem-formado. É a rede de segurança final: um answer file malformado não
# produz erro visível no Setup — produz LOOP DE REBOOT, numa máquina sem sistema operacional.
# O xmllint vem com o macOS e com a maioria das distros; se faltar, cai no python3, que já é
# dependência. Um dos dois SEMPRE roda — não existe caminho que escreva XML sem validar.
info "Validando o XML gerado..."
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$GENERATED" 2>"$WORKDIR/xmllint.err" || die \
    "O autounattend.xml gerado NÃO é XML válido. Nada foi escrito no pendrive.
$(sed 's/^/    /' "$WORKDIR/xmllint.err")
  Causa quase certa: a senha contém caractere especial e o escape falhou. Reporte isto —
  não instale com esta mídia."
  ok "XML válido (xmllint)."
else
  python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' "$GENERATED" || die \
    "O autounattend.xml gerado NÃO é XML válido (verificado com python3). Nada foi escrito."
  ok "XML válido (python3)."
fi
ok "autounattend.xml gerado ($(wc -c < "$GENERATED" | tr -d ' ') bytes)."

# --- 8. Merge do /ventoy/ventoy.json (nunca clobber) ---
# O pendrive tem 13 ISOs e é a caixa de ferramentas dele. Se já existir um ventoy.json com
# outros plugins (theme, menu_alias, persistence...), sobrescrever destruiria tudo isso sem
# aviso. A regra aqui é: preservar todo o resto, e mexer só na entrada de auto_install cuja
# `image` seja a nossa, e nas chaves de `control` que declaramos. Se não der para fazer isso
# com segurança, o script PARA em vez de adivinhar.
DEST_JSON="$VENTOY_MNT/ventoy/ventoy.json"
PROPOSED="$WORKDIR/ventoy.json.proposed"

cat > "$WORKDIR/merge.py" <<'PY'
# Faz o merge conservador do ventoy.json. Sai com codigo 3 quando nao consegue garantir
# que o merge preserva a configuracao existente — nesse caso o bash aborta sem escrever.
import json, sys

repo_path, existing_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def bail(msg):
    print(msg, file=sys.stderr)
    sys.exit(3)

with open(repo_path, encoding="utf-8") as f:
    ours = json.load(f)

try:
    with open(existing_path, encoding="utf-8") as f:
        raw = f.read().strip()
    existing = json.loads(raw) if raw else {}
except FileNotFoundError:
    existing = None
except json.JSONDecodeError as e:
    bail("O /ventoy/ventoy.json existente nao e JSON valido (%s).\n"
         "  Nao vou sobrescrever um arquivo que nao consigo entender: corrija ou mova\n"
         "  o arquivo a mao e rode de novo." % e)

changes = []

if existing is None:
    merged = ours
    changes.append("CRIAR /ventoy/ventoy.json (nao existia)")
else:
    if not isinstance(existing, dict):
        bail("O /ventoy/ventoy.json existente nao tem um objeto {...} na raiz. Abortando.")
    merged = dict(existing)  # preserva ordem e TODAS as chaves de plugin que nao sao nossas

    # --- auto_install: substitui a entrada com a mesma `image`, preserva as demais ---
    our_entry = ours["auto_install"][0]
    our_image = our_entry["image"]
    cur = existing.get("auto_install", [])
    if not isinstance(cur, list):
        bail("A chave 'auto_install' existente nao e uma lista. Abortando.")
    kept = []
    for e in cur:
        if not isinstance(e, dict):
            bail("Ha uma entrada nao-objeto dentro de 'auto_install'. Abortando.")
        if e.get("image") == our_image:
            if e != our_entry:
                changes.append("SUBSTITUIR entrada auto_install de %s" % our_image)
            continue
        if "parent" in e:
            # `parent` aplica um template a TODOS os ISOs de um diretorio. Se ele cobrir o
            # diretorio do nosso ISO, as duas regras casam com o mesmo arquivo — e a doc do
            # Ventoy NAO define precedencia entre `image` e `parent`, nem se a ordem no array
            # importa. Confiar na ordem seria palpite, e o modo de falha e silencioso: a
            # instalacao simplesmente usa o template errado, ou nenhum.
            # Antes isto era so um aviso no meio de outras dez linhas de relatorio. Sob --yes
            # ninguem le um aviso. Agora PARA.
            our_dir = our_image.rsplit("/", 1)[0] or "/"
            parent = e.get("parent")
            if isinstance(parent, str) and (parent.rstrip("/") or "/") in (our_dir, "/"):
                bail("Existe uma entrada 'auto_install' com \"parent\": %r, que cobre o\n"
                     "  diretorio do nosso ISO (%s). As duas regras casariam com o mesmo\n"
                     "  arquivo e o Ventoy nao documenta qual vence.\n"
                     "  Resolva a mao no /ventoy/ventoy.json do pendrive (remova a regra\n"
                     "  'parent', ou restrinja-a a outro diretorio) e rode de novo.\n"
                     "  Nada foi alterado." % (parent, our_dir))
            changes.append("PRESERVAR entrada auto_install com 'parent': %r "
                           "(nao cobre o nosso ISO)" % parent)
        kept.append(e)
    if not any(e.get("image") == our_image for e in cur):
        changes.append("ADICIONAR entrada auto_install para %s" % our_image)
    for e in kept:
        changes.append("PRESERVAR entrada auto_install existente: %s"
                       % (e.get("image") or e.get("parent")))
    merged["auto_install"] = kept + [our_entry]

    # --- control: substitui so as chaves que declaramos, preserva as outras na ordem ---
    our_ctrl = {}
    for item in ours.get("control", []):
        our_ctrl.update(item)
    cur_ctrl = existing.get("control", [])
    if not isinstance(cur_ctrl, list):
        bail("A chave 'control' existente nao e uma lista. Abortando.")
    out_ctrl, seen = [], set()
    for item in cur_ctrl:
        if not isinstance(item, dict) or len(item) != 1:
            bail("Entrada de 'control' fora do formato { \"CHAVE\": \"valor\" }. Abortando.")
        (k, v), = item.items()
        if k in our_ctrl:
            seen.add(k)
            if v != our_ctrl[k]:
                changes.append("SUBSTITUIR control %s: %r -> %r" % (k, v, our_ctrl[k]))
            out_ctrl.append({k: our_ctrl[k]})
        else:
            changes.append("PRESERVAR control %s" % k)
            out_ctrl.append(item)
    for k, v in our_ctrl.items():
        if k not in seen:
            changes.append("ADICIONAR control %s = %r" % (k, v))
            out_ctrl.append({k: v})
    if out_ctrl:
        merged["control"] = out_ctrl

    for k in existing:
        if k not in ("auto_install", "control"):
            changes.append("PRESERVAR plugin '%s' (intocado)" % k)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=4, ensure_ascii=False)
    f.write("\n")

for c in changes:
    print(c)
PY

info "Calculando o merge do /ventoy/ventoy.json..."
if ! MERGE_REPORT="$(python3 "$WORKDIR/merge.py" "$REPO_VENTOY_JSON" "$DEST_JSON" "$PROPOSED" 2>&1)"; then
  die "Não consigo fazer o merge com segurança, então não vou escrever nada:

$MERGE_REPORT

  Nada foi alterado no pendrive."
fi

# Idempotência: se o arquivo proposto for byte a byte igual ao que já está no pendrive, não
# há o que alterar. Nesse caso não faz backup (encheria o pendrive de .bak idênticos) e não
# pergunta nada — perguntar quando não há risco só treina o dedo a apertar 's' no automático.
JSON_UNCHANGED=0
if [ -f "$DEST_JSON" ] && cmp -s "$DEST_JSON" "$PROPOSED"; then
  JSON_UNCHANGED=1
fi

# Mesmo tratamento para o answer file. Antes este arquivo era sobrescrito direto, sem teste
# de existência, sem backup e sem uma linha na saída — o que tornava falsa a promessa do
# cabeçalho ("o único arquivo pré-existente que ele pode alterar é o ventoy.json"). Cenário
# real: um autounattend.xml copiado à mão antes, com ajustes, sumindo sem aviso.
DEST_XML="$VENTOY_MNT$TEMPLATE_PATH"
XML_UNCHANGED=0
XML_EXISTS=0
if [ -f "$DEST_XML" ]; then
  XML_EXISTS=1
  cmp -s "$DEST_XML" "$GENERATED" && XML_UNCHANGED=1
fi

printf '\n\033[1mO que será alterado em %s:\033[0m\n' "$DEST_XML"
if [ "$XML_EXISTS" -eq 0 ]; then
  printf '    CRIAR (não existia)\n'
elif [ "$XML_UNCHANGED" -eq 1 ]; then
  printf '    (nada — o answer file do pendrive já é idêntico ao que seria gerado)\n'
else
  printf '    \033[1;33mSOBRESCREVER um autounattend.xml que já existe.\033[0m\n'
  printf '    Backup datado será criado antes.\n'
  # O diff NÃO é impresso: as duas versões contêm a senha da conta local em texto claro,
  # e isso iria parar no scrollback do terminal e em qualquer log de sessão.
  printf '    (diff omitido de propósito: o arquivo contém a senha em texto claro)\n'
fi

printf '\n\033[1mO que será alterado em %s:\033[0m\n' "$DEST_JSON"
if [ "$JSON_UNCHANGED" -eq 1 ]; then
  printf '    (nada — o ventoy.json do pendrive já está exatamente como deveria)\n'
else
  printf '%s\n' "$MERGE_REPORT" | sed 's/^/    /'
  if [ -f "$DEST_JSON" ]; then
    printf '\n\033[1mDiff (atual -> proposto):\033[0m\n'
    diff -u "$DEST_JSON" "$PROPOSED" | sed 's/^/    /' || true
  else
    printf '\n\033[1mConteúdo do novo arquivo:\033[0m\n'
    sed 's/^/    /' "$PROPOSED"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n'
  warn "--dry-run: nada foi escrito no pendrive."
  ok "Ensaio concluído: ISO íntegro, XML gerado sem placeholder, merge do ventoy.json viável."
  exit 0
fi

# Confirmação quando existe QUALQUER arquivo alheio em risco — ventoy.json OU answer file.
# A condição antiga olhava só o ventoy.json: se ele não existisse mas o XML sim, não havia
# prompt nenhum e o XML alheio era destruído em silêncio.
# Criar arquivo do zero não destrói nada, então aí não se pergunta — perguntar quando não há
# risco só treina o dedo a apertar 's' no automático.
NEEDS_CONFIRM=0
[ -f "$DEST_JSON" ] && [ "$JSON_UNCHANGED" -eq 0 ] && NEEDS_CONFIRM=1
[ "$XML_EXISTS" -eq 1 ] && [ "$XML_UNCHANGED" -eq 0 ] && NEEDS_CONFIRM=1

if [ "$NEEDS_CONFIRM" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  # Sem tty não dá para pedir confirmação de verdade: um `read` com stdin vindo de pipe
  # consome qualquer coisa e vira um "sim" acidental.
  [ -t 0 ] || die \
    "Há arquivos existentes para sobrescrever e não existe terminal interativo para confirmar.
  Rode num terminal, ou passe --yes se tem certeza do que vai ser alterado."
  printf '\n'
  read -r -p "Aplicar as alterações acima? [s/N] " answer
  case "$answer" in
    s|S|sim|Sim|y|Y|yes) ;;
    *) die "Cancelado pelo usuário. Nada foi alterado." ;;
  esac
fi

# --- 9. Escrita no pendrive ---
info "Escrevendo no pendrive..."
mkdir -p "$VENTOY_MNT/ventoy/script"

# Backup do ventoy.json antes de tocar nele. Datado, para poder rodar várias vezes sem
# sobrescrever o backup anterior.
if [ -f "$DEST_JSON" ] && [ "$JSON_UNCHANGED" -eq 0 ]; then
  BACKUP="$DEST_JSON.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$DEST_JSON" "$BACKUP"
  ok "Backup: $BACKUP"
fi

# Backup do answer file, pelo mesmo motivo do ventoy.json.
if [ "$XML_EXISTS" -eq 1 ] && [ "$XML_UNCHANGED" -eq 0 ]; then
  XML_BACKUP="$DEST_XML.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$DEST_XML" "$XML_BACKUP"
  ok "Backup: $XML_BACKUP"
  warn "Esse backup contém a senha antiga em texto claro. Apague o pendrive quando não precisar mais."
fi

# Escrita por redirecionamento, não por `cp`: no macOS o `cp` pode carregar extended
# attributes para o exFAT e criar arquivos AppleDouble '._nome'. O Ventoy tem até uma opção
# (VTOY_FILT_DOT_UNDERSCORE_FILE) para esconder essa sujeira do menu — melhor não gerar.
mkdir -p "$(dirname "$DEST_XML")"
cat "$GENERATED"  > "$DEST_XML"
cat "$PROPOSED"   > "$DEST_JSON"
ok "Answer file:  $DEST_XML"
ok "Config Ventoy: $DEST_JSON"

# Remove AppleDouble deixado por cópias anteriores feitas no Finder, se houver.
if [ "$OS" = "Darwin" ] && command -v dot_clean >/dev/null 2>&1; then
  dot_clean -m "$VENTOY_MNT/ventoy" 2>/dev/null || true
fi

sync

# --- 10. Resumo e verificação ---
info "Pronto. Antes de apagar a máquina, VERIFIQUE que a injeção funcionou:"
cat <<EOF

  1. Ejete o pendrive com segurança (no macOS: 'diskutil eject $VENTOY_MNT').

  2. Boote o pendrive numa VM (Proxmox, ou UTM no Mac) com um disco virtual descartável,
     com Secure Boot DESLIGADO — o Ventoy assina o bootloader com CA própria e pediria
     enrollment de MOK.

  3. No menu do Ventoy, pressione F5 (Tools) e confira, nesta ordem:
       - "Check plugin json configuration (ventoy.json)"
       - "Check auto install plugin configuration"
       - "Check global control plugin configuration"
     Erro de sintaxe ou caminho errado aparece AQUI, de graça. É o teste mais barato que existe.

  4. Selecione o ISO do Windows. Com "autosel" e sem "timeout", o Ventoy NÃO deve mostrar
     nenhum menu de escolha de template — se aparecer, a configuração não está valendo.

  5. Deixe a instalação na VM ir até o fim e confirme: zero prompt de OOBE, conta local
     'ranielli', UI e teclado em pt-BR (ABNT2), ESP de 1 GB, partição de recovery no fim
     do disco, device encryption desligada.

  ⚠️  O pendrive agora contém a senha da conta local EM TEXTO CLARO, em
      $TEMPLATE_PATH. exFAT não tem permissão de arquivo: trate o pendrive
      como segredo físico e troque a senha depois do primeiro boot.

EOF
ok "Concluído."
