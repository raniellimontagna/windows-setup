#!/usr/bin/env bash
#
# provision.sh — provisiona o Ubuntu do WSL2 reusando a metade Linux-safe do mac-setup.
# Uso:  bash provision.sh            (DENTRO da distro Ubuntu, como usuário normal)
# Seguro rodar várias vezes (idempotente).
#
# NÃO roda no Windows (é bash + apt) e NÃO roda como root (precisa do seu $HOME).
#
# O que ele reusa do mac-setup/setup.sh, seção por seção:
#   1-3 Xcode CLT / Homebrew / Brewfile ....... descartado (apt no lugar; ver README)
#   4   git config ............................ reusado, com a ordem invertida (ver §4/§6)
#   5   chave SSH ............................. reusado, sem --apple-use-keychain
#   6   zshrc + starship ...................... reusado via stub + symlink
#   7   Node LTS via fnm + pnpm ............... reusado se o fnm existir
#   8   extensões do VS Code .................. descartado (o VS Code é o do Windows)
#   9   estrutura de pastas ................... reusado
#
# Variáveis de ambiente aceitas (nenhuma obrigatória):
#   MAC_SETUP_REPO   URL do repo mac-setup (default: clone anônimo por https)
#   SSH_BACKUP_DIR   pasta com id_ed25519 resgatado do CachyOS (default: ~/ssh-restore)
#   GIT_NAME / GIT_EMAIL   preenchem a identidade do git sem prompt
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ printf "\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
ok(){   printf "\033[1;32m✔\033[0m %s\n" "$1"; }
warn(){ printf "\033[1;33m⚠\033[0m %s\n" "$1"; }

MACSETUP="$HOME/Projetos/pessoal/mac-setup"
MAC_SETUP_REPO="${MAC_SETUP_REPO:-https://github.com/raniellimontagna/mac-setup.git}"
SSH_BACKUP_DIR="${SSH_BACKUP_DIR:-$HOME/ssh-restore}"
ME="$(id -un)"

# --- 1. Sanity checks ---
info "Conferindo o ambiente..."

if [ "$(id -u)" -eq 0 ]; then
  echo "Não rode como root: o script escreve em \$HOME e faz sudo onde precisa."
  exit 1
fi

# Não é fatal (dá para usar em qualquer Ubuntu), mas se não for WSL vários
# avisos deste script não fazem sentido.
if [ -z "${WSL_DISTRO_NAME:-}" ] && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then
  warn "Isto não parece ser WSL. Seguindo mesmo assim."
fi

# CRLF: um .sh com CRLF morre com `$'\r': command not found` e o erro não diz
# nada sobre line ending. O .gitattributes cobre *.sh/*.conf/user-data, mas
# `zshrc.linux` cai no `* text=auto` — num clone feito do lado Windows com
# core.autocrlf=true ele chega aqui com CRLF. Detectamos e sanitizamos.
FRAG_CRLF=0
if grep -q $'\r' "$DIR/zshrc.linux" 2>/dev/null; then
  FRAG_CRLF=1
  warn "zshrc.linux está com CRLF (clone feito no Windows?) — será copiado sanitizado."
fi

# Repo em /mnt/c é lido pelo drvfs a cada abertura de shell (lento) e não
# aceita symlink de volta para o Windows de forma confiável.
case "$DIR" in
  /mnt/*) ON_DRVFS=1 ;;
  *)      ON_DRVFS=0 ;;
esac
[ "$ON_DRVFS" = 1 ] && warn "Rodando a partir de $DIR (/mnt = disco do Windows). O fragmento do zsh será COPIADO, não symlinkado."

ok "Ambiente OK ($ME @ ${WSL_DISTRO_NAME:-desconhecida})"

# --- 2. Pacotes do apt ---
# O cloud-init já instala esta lista no primeiro boot; repetimos porque o
# provision.sh também tem que funcionar numa distro criada pelo OOBE normal.
# apt-get (não apt) é o certo para script: interface estável, sem barra de
# progresso interativa.
info "Instalando pacotes base (apt)..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  zsh zsh-autosuggestions zsh-syntax-highlighting \
  git curl wget ca-certificates unzip build-essential \
  jq ripgrep fd-find bat fzf >/dev/null
ok "Pacotes base instalados"

# Opcionais: podem não existir no noble (nao verificado, por pacote). Falha de
# um não pode derrubar o script — daí o laço tolerante em vez de uma linha só.
info "Instalando opcionais (tolerante a falha)..."
for pkg in eza zoxide git-delta lazygit btop; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg (já instalado)"
  elif sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
    ok "$pkg"
  else
    warn "$pkg não está no repositório do Ubuntu 24.04 (ou falhou) — instale por outro canal se quiser"
  fi
done
# starship e fnm não são empacotados pelo Ubuntu. NÃO instalamos por
# `curl ... | sh`: a mesma regra que vale para `irm | iex` no lado Windows vale
# aqui. Veja o README para o caminho manual.

# --- 3. /etc/wsl.conf ---
# Usa o wsl.conf do repo como fonte da verdade e só troca o usuário padrão pelo
# seu (o arquivo versionado traz `default = dev`, que é placeholder).
if [ -f "$DIR/wsl.conf" ]; then
  info "Instalando /etc/wsl.conf..."
  TMP_WSLCONF="$(mktemp)"
  sed "s/^default *=.*/default = $ME/" "$DIR/wsl.conf" > "$TMP_WSLCONF"
  if cmp -s "$TMP_WSLCONF" /etc/wsl.conf 2>/dev/null; then
    ok "/etc/wsl.conf já está atualizado"
  else
    sudo cp "$TMP_WSLCONF" /etc/wsl.conf
    sudo chmod 644 /etc/wsl.conf
    ok "/etc/wsl.conf escrito (systemd=true, default=$ME)"
    warn "Regra dos 8 s: rode 'wsl --shutdown' no Windows para valer."
  fi
  rm -f "$TMP_WSLCONF"
fi

# --- 4. Chave SSH (ANTES do git config — ver §6) ---
info "Configurando chave SSH..."
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [ -f "$HOME/.ssh/id_ed25519" ]; then
  ok "Chave já existe em ~/.ssh/id_ed25519"
elif [ -f "$SSH_BACKUP_DIR/id_ed25519" ]; then
  # Caminho preferido: a chave resgatada do CachyOS antes do wipe. Copiar de
  # /mnt/c preserva o conteúdo mas não as permissões — o chmod não é opcional,
  # o ssh recusa chave com permissão frouxa.
  cp "$SSH_BACKUP_DIR/id_ed25519" "$HOME/.ssh/id_ed25519"
  [ -f "$SSH_BACKUP_DIR/id_ed25519.pub" ] && cp "$SSH_BACKUP_DIR/id_ed25519.pub" "$HOME/.ssh/id_ed25519.pub"
  chmod 600 "$HOME/.ssh/id_ed25519"
  [ -f "$HOME/.ssh/id_ed25519.pub" ] && chmod 644 "$HOME/.ssh/id_ed25519.pub"
  ok "Chave restaurada de $SSH_BACKUP_DIR"
else
  warn "Nenhuma chave em ~/.ssh nem em $SSH_BACKUP_DIR — gerando uma nova."
  ssh-keygen -t ed25519 -C "${GIT_EMAIL:-$ME@$(hostname)}" -f "$HOME/.ssh/id_ed25519" -N "" -q
  eval "$(ssh-agent -s)" >/dev/null
  # Sem --apple-use-keychain aqui: essa flag é do fork da Apple e o OpenSSH do
  # Ubuntu rejeita.
  ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null || true
  echo ""
  echo "  >>> Adicione esta chave em https://github.com/settings/ssh/new :"
  echo ""
  cat "$HOME/.ssh/id_ed25519.pub"
  echo ""
fi

if [ ! -f "$HOME/.ssh/config" ]; then
  # `IgnoreUnknown UseKeychain` PRECISA ser a primeira linha: o OpenSSH parseia
  # o arquivo linha a linha e aborta ao ver um keyword desconhecido antes do
  # IgnoreUnknown. Com ela, o MESMO arquivo serve macOS e Linux.
  cat > "$HOME/.ssh/config" <<'EOF'
IgnoreUnknown UseKeychain

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  AddKeysToAgent yes
  UseKeychain yes
EOF
  chmod 600 "$HOME/.ssh/config"
  ok "~/.ssh/config criado"
fi

# --- 5. Clone do mac-setup ---
# ⚠️ ARMADILHA DE ORDEM: a §6 configura
#    url."git@github.com:".insteadOf "https://github.com/"
# que reescreve TODA URL https do GitHub para SSH. Num WSL novo sem chave
# registrada, isso quebra clone anônimo de repo público — inclusive o clone do
# próprio mac-setup — e o fetch de módulos Go. Por isso a chave vem antes (§4) e
# o clone vem antes do git config (§6).
# GIT_CONFIG_GLOBAL=/dev/null é a armadura extra: neutraliza qualquer ~/.gitconfig
# preexistente (por exemplo, um restaurado do backup) só para este comando.
info "Clonando mac-setup em $MACSETUP..."
mkdir -p "$(dirname "$MACSETUP")"
if [ -d "$MACSETUP/.git" ]; then
  GIT_CONFIG_GLOBAL=/dev/null git -C "$MACSETUP" pull --ff-only >/dev/null 2>&1 \
    && ok "mac-setup atualizado" \
    || warn "mac-setup existe mas o pull falhou (branch local suja?) — seguindo com o que está no disco"
else
  GIT_CONFIG_GLOBAL=/dev/null git clone --quiet "$MAC_SETUP_REPO" "$MACSETUP" \
    && ok "mac-setup clonado" \
    || warn "Falha ao clonar $MAC_SETUP_REPO — se o repo for privado, exporte MAC_SETUP_REPO=git@github.com:<user>/mac-setup.git e rode de novo"
fi

# --- 6. Git: identidade + defaults ---
info "Configurando Git..."
if [ -z "$(git config --global user.name || true)" ]; then
  if [ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ]; then
    git config --global user.name  "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
  else
    read -rp "  Nome para os commits: " _gn
    read -rp "  Email para os commits: " _ge
    git config --global user.name  "$_gn"
    git config --global user.email "$_ge"
  fi
fi
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global push.autoSetupRemote true
git config --global fetch.prune true
git config --global color.ui auto
git config --global rerere.enabled true
git config --global core.excludesfile "$HOME/.gitignore_global"
# Dentro do WSL o repositório vive no ext4 e é consumido por ferramentas Linux:
# `input` grava LF no repo e no working tree. NÃO use `true` aqui — CRLF no ext4
# é o bug do `$'\r'` de novo. (`true` é o default do instalador do Git for Windows;
# o lado Windows deste repo também o sobrescreve, para `false`, via
# profile/gitconfig-windows. Os dois lados têm gitconfig próprio, sem herança.)
git config --global core.autocrlf input
# core.editor: o `code` só existe na shell se você abriu a pasta pelo VS Code do
# Windows (o server injeta o wrapper no PATH). Numa shell solta, não existe.
if command -v code >/dev/null 2>&1; then
  git config --global core.editor "code --wait"
else
  git config --global core.editor "vim"
fi
# ⚠️ Esta é a linha da armadilha da §5. Ela é útil (módulos Go privados), mas só
# depois que a chave da §4 está registrada no GitHub.
git config --global url."git@github.com:".insteadOf "https://github.com/"

git config --global alias.st "status -sb"
git config --global alias.co "checkout"
git config --global alias.br "branch"
git config --global alias.cm "commit -m"
git config --global alias.lg "log --oneline --graph --decorate -20"
git config --global alias.last "log -1 HEAD --stat"
git config --global alias.unstage "reset HEAD --"

# git-delta: no Ubuntu o pacote é `git-delta` mas o binário continua `delta`.
if command -v delta >/dev/null 2>&1; then
  git config --global core.pager delta
  git config --global interactive.diffFilter "delta --color-only"
  git config --global delta.navigate true
  git config --global merge.conflictStyle zdiff3
fi
ok "Git configurado"

# --- 7. Dotfiles (sem symlink para o Windows) ---
info "Instalando ~/.zshrc, fragmento do WSL e config do Starship..."

# 7a. ~/.zshrc vira um STUB de três linhas. Não é symlink para o zshrc do Mac
# porque precisamos de duas coisas ao redor dele: o PATH ANTES (senão o bloco
# `# --- CLI modernas ---` do zshrc compartilhado não enxerga os shims) e o
# fragmento do Linux DEPOIS (o zsh-syntax-highlighting tem que ser o último
# source de toda a cadeia).
if [ -e "$HOME/.zshrc" ] && ! grep -q "GERADO por windows-setup" "$HOME/.zshrc" 2>/dev/null; then
  cp "$HOME/.zshrc" "$HOME/.zshrc.backup"
  warn "Backup do .zshrc antigo em ~/.zshrc.backup"
fi
cat > "$HOME/.zshrc" <<'ZSHRC'
# ~/.zshrc — GERADO por windows-setup/wsl/provision.sh. Não edite aqui:
# mexa no mac-setup/zshrc (comum aos dois SOs) ou no ~/.zshrc.linux
# (windows-setup/wsl/zshrc.linux) e rode o provision.sh de novo.

# 1. PATH de ~/.local/bin PRIMEIRO. Ordem é o ponto: o zshrc compartilhado
#    testa `command -v bat` lá no meio, e no Ubuntu o `bat` só existe como
#    shim em ~/.local/bin.
export PATH="$HOME/.local/bin:$PATH"

# 2. zshrc compartilhado do mac-setup (prefere o zshrc.common, se existir).
for _zrc in "$HOME/Projetos/pessoal/mac-setup/zshrc.common" \
            "$HOME/Projetos/pessoal/mac-setup/zshrc"; do
  if [ -f "$_zrc" ]; then source "$_zrc"; break; fi
done
unset _zrc

# 3. Fragmento OS-specific — precisa ser o ÚLTIMO (syntax-highlighting).
[ -f "$HOME/.zshrc.linux" ] && source "$HOME/.zshrc.linux"
ZSHRC
ok "~/.zshrc (stub) escrito"

# 7b. Fragmento do Linux.
if [ "$FRAG_CRLF" = 1 ]; then
  tr -d '\r' < "$DIR/zshrc.linux" > "$HOME/.zshrc.linux"
  ok "~/.zshrc.linux copiado (CRLF removido)"
elif [ "$ON_DRVFS" = 1 ]; then
  cp "$DIR/zshrc.linux" "$HOME/.zshrc.linux"
  ok "~/.zshrc.linux copiado (repo está em /mnt — rode de novo depois de editar)"
else
  ln -sf "$DIR/zshrc.linux" "$HOME/.zshrc.linux"
  ok "~/.zshrc.linux -> $DIR/zshrc.linux (symlink)"
fi

# 7c. Arquivos do mac-setup que portam literalmente. Symlink dentro do ext4 é
# de boa (a restrição de privilégio é do lado Windows, não daqui).
if [ -d "$MACSETUP" ]; then
  [ -f "$MACSETUP/gitignore_global" ] && ln -sf "$MACSETUP/gitignore_global" "$HOME/.gitignore_global"
  if [ -f "$MACSETUP/starship.toml" ]; then
    mkdir -p "$HOME/.config"
    ln -sf "$MACSETUP/starship.toml" "$HOME/.config/starship.toml"
  fi
  ok "gitignore_global e starship.toml apontando para o mac-setup"
fi

# --- 8. Shims bat/fd ---
# No Ubuntu os binários se chamam batcat e fdfind (conflito de nome com outros
# pacotes). Symlink, não alias: alias não vale para scripts nem subprocessos.
info "Criando shims em ~/.local/bin..."
mkdir -p "$HOME/.local/bin"
command -v batcat >/dev/null 2>&1 && ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
command -v fdfind >/dev/null 2>&1 && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
ok "Shims prontos (valide depois com: zsh -ic 'command -v bat')"

# --- 9. Shell padrão ---
if [ "$(getent passwd "$ME" | cut -d: -f7)" != "$(command -v zsh)" ]; then
  info "Trocando o shell padrão para zsh..."
  # `sudo chsh` em vez de `chsh`: o chsh direto pede a senha do usuário, e o
  # usuário criado pelo cloud-init tem a senha travada (lock_passwd: true).
  sudo chsh -s "$(command -v zsh)" "$ME"
  ok "Shell padrão = zsh (vale na próxima sessão)"
fi

# --- 10. Node LTS via fnm + pnpm ---
if command -v fnm >/dev/null 2>&1; then
  info "Instalando Node LTS via fnm..."
  eval "$(fnm env)"
  fnm install --lts
  fnm default lts-latest
  corepack enable
  corepack prepare pnpm@latest --activate
  ok "Node LTS + pnpm prontos"
else
  warn "fnm não encontrado — Node não instalado. O Ubuntu não empacota o fnm; ver README (instalação manual)."
fi
# Sem `npm install -g eas-cli` aqui de propósito: Expo/React Native/Android
# continuam sendo trabalho de Mac (sem USB sem usbipd-win, e o emulador briga
# com a VM do WSL por virtualização aninhada).

# --- 11. Estrutura de pastas ---
# Tudo no ext4. Projeto em /mnt/c custa uma ordem de grandeza em I/O.
mkdir -p "$HOME/Projetos/pessoal" "$HOME/Projetos/empresa"
ok "~/Projetos/{pessoal,empresa}"

# --- 12. Próximos passos (manuais) ---
info "Concluído. O que ainda é manual:"
cat <<EOF

  1. ~/.secrets.zsh NÃO é criado por nada aqui — e o zshrc faz source silencioso
     se ele não existir. Recrie à mão (tokens, credenciais, o que for) e chmod 600.
  2. Teste a chave:            ssh -T git@github.com
  3. Feche TODAS as shells e rode 'wsl --shutdown' no Windows se mexemos no
     /etc/wsl.conf (regra dos 8 segundos).
  4. Abra uma shell nova e valide:  zsh -ic 'command -v bat; command -v fd'
  5. Scripts do mac-setup que rodam aqui sem porte, se você quiser:
       bash $MACSETUP/ai-clis.sh
       bash $MACSETUP/claude-plugins.sh
       bash $MACSETUP/clone-org.sh <org>

EOF
