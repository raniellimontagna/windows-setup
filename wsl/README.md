# WSL2 — opt-in, não default

**Este diretório inteiro é opcional. A recomendação do plano é NÃO instalar WSL2 nesta máquina.**

O motivo é honesto e não é ideológico: habilitar o Virtual Machine Platform coloca o
**Windows inteiro sob o hypervisor**. O custo típico é de **2-5% de FPS**, e "desabilite
Hyper-V/VBS/WSL" é conselho de primeira linha no troubleshooting do anticheat EA Javelin —
que é justamente o motivo desta migração para o Windows. Somando: o dev principal continua
sendo o Mac, e existe um Proxmox para tudo que precisa de Linux de verdade.

Ou seja: o WSL2 aqui é **conveniência**, e ele cobra caro em cima da única coisa que a
máquina precisa fazer bem.

### Se instalar mesmo assim: a válvula de escape

Não aceite o hypervisor como efeito colateral silencioso de um DISM. Deixe o toggle
explícito e documentado — antes de sessão competitiva:

```powershell
bcdedit /set hypervisorlaunchtype off   # + reboot -> WSL2 não sobe, FPS de volta
bcdedit /set hypervisorlaunchtype auto  # + reboot -> WSL2 de volta
```

Isso **não** é o mesmo que desligar Memory Integrity (HVCI), que é uma configuração
separada e vem **ligada por padrão** num clean install deste hardware — ver o
`windows-defaults.ps1` na raiz do repo.

### Quando o WSL passa a valer

- Docker Engine dentro da distro (mais leve que o Docker Desktop: ~200 MB idle contra
  500 MB–1.5 GB).
- Reuso direto de `ai-clis.sh`, `claude-plugins.sh`, `clone-org.sh` do `mac-setup`, sem porte.
- Qualquer coisa que dependa de ferramenta Unix que não tem equivalente decente no Windows.

Se nada disso for rotina diária, pule este diretório e não pague o hypervisor.

---

## Ordem de execução

A ordem importa em três pontos diferentes. Fora de ordem, cada um falha **em silêncio**.

| # | Onde | O quê |
|---|---|---|
| 1 | Windows (PowerShell) | Escrever `%USERPROFILE%\.wslconfig` (ver `profile/wslconfig`) — `sparseVhd` só afeta VHDs **novos**, então tem que existir antes da distro |
| 2 | Windows (PowerShell) | Copiar `cloud-init.user-data` para `%UserProfile%\.cloud-init\Ubuntu-24.04.user-data` |
| 3 | Windows (PowerShell) | `wsl --install -d Ubuntu-24.04 --no-launch` + reboot |
| 4 | Windows (PowerShell) | `wsl -d Ubuntu-24.04` — primeiro boot, o cloud-init roda **aqui** |
| 5 | Ubuntu | `bash provision.sh` |

```powershell
# 2 e 3, do diretorio do repo:
New-Item -ItemType Directory -Force "$env:UserProfile\.cloud-init" | Out-Null
Copy-Item .\wsl\cloud-init.user-data "$env:UserProfile\.cloud-init\Ubuntu-24.04.user-data"
wsl --install -d Ubuntu-24.04 --no-launch
```

**Por que `--no-launch` é obrigatório:** o cloud-init é o caminho unattended suportado pela
Canonical, mas ele roda **só no primeiro boot de uma instância nova** e **não** provisiona
uma instância que já passou pelo OOBE. Sem `--no-launch`, o OOBE roda antes do arquivo
existir e o cloud-init vira no-op — e a única correção é `wsl --unregister Ubuntu-24.04`,
que apaga o ext4 inteiro daquela distro. 🔒

**Por que `Ubuntu-24.04` e não `Ubuntu`:** o nome curto é alvo móvel (a 26.04 LTS saiu em
abr/2026) e o nome do `.user-data` precisa bater exatamente com o nome da distro.

**Idempotência do instalador:** `wsl --install --no-distribution` **só é honrado se o WSL
ainda não estiver instalado**. Um provisionador que chama isso incondicionalmente vira
no-op silencioso na segunda execução — ramifique em `wsl --version` / `wsl --status`.

Conferência depois do primeiro boot, dentro da distro:

```bash
cloud-init status --wait          # done | error
cat /var/log/cloud-init-output.log
```

---

## Arquivos daqui

| Arquivo | Vai para | Observação |
|---|---|---|
| `cloud-init.user-data` | `%UserProfile%\.cloud-init\Ubuntu-24.04.user-data` (Windows) | roda uma vez, no primeiro boot |
| `wsl.conf` | `/etc/wsl.conf` (dentro da distro) | `[boot] systemd=true`, `[user] default=` |
| `provision.sh` | roda dentro da distro | idempotente, reusa a metade Linux-safe do `mac-setup/setup.sh` |
| `zshrc.linux` | `~/.zshrc.linux` (dentro da distro) | fragmento OS-specific do zsh |

O `.wslconfig` (memória, CPU, `sparseVhd`, `defaultVhdSize`) **não** mora aqui — ele é do
lado Windows e está em `profile/wslconfig`.

### O que o `provision.sh` faz, e a armadilha de ordem

`git config --global url."git@github.com:".insteadOf "https://github.com/"` reescreve toda
URL https do GitHub para SSH. Num WSL novo **sem chave registrada**, isso quebra clone
anônimo de repo público — **incluindo o clone do próprio `mac-setup`** — e o fetch de
módulos Go. Por isso a ordem no script é:

> **chave SSH (§4) → clone do `mac-setup` (§5) → git config (§6)**

O clone ainda roda com `GIT_CONFIG_GLOBAL=/dev/null` como armadura extra, caso você tenha
restaurado um `~/.gitconfig` de backup antes de rodar o script.

Variáveis aceitas (nenhuma obrigatória):

```bash
SSH_BACKUP_DIR=~/ssh-restore \
GIT_NAME="Seu Nome" GIT_EMAIL="voce@exemplo.com" \
  bash provision.sh
```

### As quatro quebras que o `zshrc.linux` conserta

O `zshrc` do `mac-setup` é compartilhado entre os dois SOs. Três das quatro quebras abaixo
falham **em silêncio** (guard `[ -f ]` ou `2>/dev/null`), que é o pior tipo:

1. **Plugins do zsh** — vêm de `/opt/homebrew/share/...` no Mac; no Ubuntu é
   `/usr/share/zsh-autosuggestions/` e `/usr/share/zsh-syntax-highlighting/`. Maior
   regressão diária.
2. **`PNPM_HOME`** — `$HOME/Library/pnpm` sem guard de SO. **Bug real**, não no-op: no
   Linux é `~/.local/share/pnpm`.
3. **fzf** — o Ubuntu 24.04 traz fzf 0.44.1 e a flag `--zsh` só existe do 0.48.0 em
   diante. Use `/usr/share/doc/fzf/examples/key-bindings.zsh`, senão você perde Ctrl+R e
   Ctrl+T sem nenhuma pista.
4. **`bat`→`batcat`, `fd`→`fdfind`** — shims em `~/.local/bin`, **e o
   `export PATH="$HOME/.local/bin:$PATH"` tem que estar no TOPO do zshrc**. No zshrc do Mac
   ele está ~40 linhas *abaixo* do bloco `# --- CLI modernas ---` que roda `command -v bat`.
   Por isso o `~/.zshrc` gerado é um stub de três partes: PATH → zshrc comum → fragmento.

Valide com: `zsh -ic 'command -v bat; command -v fd'`.

---

## Regras que nenhum script aplica por você

### `~/.secrets.zsh` é manual

Nada na automação recria esse arquivo dentro do WSL, e o `zshrc` faz `source` silencioso se
ele não existir — você não recebe erro nenhum, só perde as variáveis. Recrie à mão e
`chmod 600`. Segredo mora fora do repo, mesma regra do Mac.

### Projeto no ext4, nunca em `/mnt/c`

Isso, somado às exclusões do Defender, vale mais que todo o resto somado. Clone em
`~/Projetos/...` dentro da distro.

**Dev Drive não ajuda** — a Microsoft é explícita que é otimização do filesystem do
Windows: não serve ao VHDX ext4, não pode ser o C:, e quebra a mount option `metadata` do
WSL em ReFS.

### Exclusões do Defender — leia antes de aplicar

Exclusões exigem **shell elevado** e **podem ser bloqueadas por Tamper Protection**.
`Add-MpPreference` pode *parecer* ter funcionado sem fazer absolutamente nada. Confira
sempre:

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
```

E a parte honesta: **você está reduzindo a proteção no maior blob gravável da máquina.**
O ganho de I/O é real, o risco também. O caminho exato do VHDX depende de como a distro foi
instalada (**nao verificado** para o WSL 2.7.x) — localize-o antes e exclua o diretório do
VHDX, não `C:\` inteiro.

### Regra dos 8 segundos

Mudanças em `.wslconfig` e `/etc/wsl.conf` só valem depois que a VM para de vez, o que
acontece **~8 s depois de fechar a última shell**. Rode `wsl --shutdown` no Windows entre
escrever e verificar, senão você testa o estado velho e conclui que "não funcionou".

Relacionado: `sparseVhd` e `autoMemoryReclaim` continuam sob **`[experimental]`**, não sob
`[wsl2]` — na seção errada eles falham em silêncio. E `sparseVhd=true` só afeta VHDs
**novos**: escreva o `.wslconfig` antes de criar a distro. O VHDX cresce e **nunca encolhe
sozinho**; use `defaultVhdSize` (documentado, `[wsl2]`, default 1 TB) como teto real.

### `networkingMode=mirrored`: não use

Bugs abertos e não resolvidos: o Windows não alcança portas publicadas do Docker via IPv4
do host (microsoft/WSL #41284) e o loopback WSL→Windows leva RST por mismatch de porta
efêmera (#40343). Persistem mesmo com `hostAddressLoopback=true`. Fique no NAT default.

### CUDA (se for usar a 4060 Ti para inferência)

- Só o **driver do Windows** (R495+). Ele já expõe a GPU para a distro.
- **Nunca** instale driver de display Linux dentro do WSL. Isso quebra o passthrough.
- Só o meta-package **`cuda-toolkit-*`** do repositório `wsl-ubuntu` — nunca `cuda`,
  `cuda-<ver>` ou `cuda-drivers` (esses puxam o driver de display).
- **Não hardcode a versão** (`12-x` está velho, o CUDA está na 13.x). Resolva a versão e a
  URL do keyring na hora, na página oficial de download do CUDA, para o release do Ubuntu
  que estiver instalado.

### Docker: escolha um

Não rode Docker Desktop e Docker Engine na mesma distro. A integração WSL do Desktop injeta
um shim `docker` que **sombreia o binário real**, e você passa uma tarde depurando um
daemon que não é o que você acha que é.

### Nada de Android / React Native aqui

Sem USB sem `usbipd-win`, e o emulador briga com a VM do WSL por virtualização aninhada.
Isso continua sendo trabalho de Mac — por isso o `provision.sh` não instala `eas-cli` e o
`zshrc.linux` remove os aliases de iOS.

### Line endings

Um `.sh` com CRLF morre dentro do WSL com `$'\r': command not found`, e o erro não diz nada
sobre line ending. O `.gitattributes` da raiz cobre `*.sh`, `*.conf` e `*.user-data`;
`zshrc.linux` cai no `* text=auto`, então o `provision.sh` detecta CRLF e instala uma cópia
sanitizada em vez do symlink. Dentro do WSL o git fica com `core.autocrlf input`.

O git do WSL **não herda** o `profile/gitconfig-windows` — cada lado tem o seu. Para referência,
o lado Windows usa `core.autocrlf false` (não `true`): o `.gitattributes` já resolve line ending
por repo, então converter de novo no checkout só cria conversão dupla. O `true` que aparece por
aí é o **default do instalador do Git for Windows**, que este repo sobrescreve.

---

## Ferramentas que o Ubuntu não empacota

`starship` e `fnm` não estão nos repositórios do noble, e o `provision.sh` **não** os
instala por `curl ... | sh` — a mesma regra que proíbe `irm ... | iex` no lado Windows vale
aqui. Instale à mão, revisando o instalador na hora:

- starship — <https://starship.rs/> (o `starship.toml` do `mac-setup` porta sem alteração e
  já é symlinkado pelo `provision.sh`)
- fnm — <https://github.com/Schniz/fnm> (depois é só rodar o `provision.sh` de novo: a §10
  detecta o binário e faz `fnm install --lts` + `corepack prepare pnpm@latest`)

Os opcionais `eza`, `zoxide`, `git-delta`, `lazygit` e `btop` são tentados pelo apt num laço
tolerante — a disponibilidade de cada um no noble é **nao verificado**, e o script avisa em
vez de morrer.

---

## Desfazer

```powershell
wsl --shutdown
wsl --unregister Ubuntu-24.04          # 🔒 apaga o ext4 da distro, sem undo
bcdedit /set hypervisorlaunchtype off  # + reboot, para tirar o custo do hypervisor
```

Antes de qualquer `--unregister`, tire o que interessa: `wsl --export Ubuntu-24.04 D:\wsl-backup.tar`.
