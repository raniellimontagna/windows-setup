# windows-setup

Configuração de um **Windows 11 novo** numa máquina de jogo que também faz dev via WSL2 —
o irmão Windows do [`mac-setup`](https://github.com/raniellimontagna/mac-setup).

Máquina alvo: i5-14600K, RTX 4060 Ti, 32 GB DDR5. Instalação limpa, single boot, conta local.

> **Este repo é público.** Nada de segredo aqui dentro: senhas, tokens e variáveis de trabalho
> moram fora (`~/.secrets.ps1` no Windows, `~/.secrets.zsh` no WSL). Ver [Segurança](#segurança).

---

## O que ele é (e o que não é)

Diferente do `mac-setup`, este repo roda **uma vez a cada dois ou três anos**. O valor dele não é
idempotência industrial — é **documentação executável**: daqui a dois anos você não lembra o que
instalou nem por quê, e os arquivos aqui respondem isso.

A parte que realmente tem prazo é a **pré-instalação**: mídia USB, `autounattend.xml`, BIOS e resgate
de dados. Depois que o instalador roda, refazer significa reinstalar. Comece por
[`unattend/README.md`](./unattend/README.md).

---

## Ordem de execução

Para o dia da instalação, siga o cartão condensado [`DIA-D.md`](./DIA-D.md): a mesma ordem abaixo
em forma de checklist, com os pontos irreversíveis marcados.

| # | Onde | O quê |
|---|---|---|
| 0 | Máquina antiga, ainda bootável | [`unattend/README.md`](./unattend/README.md) — Fases 0 a 6: resgate de dados, mídia USB, BIOS, instalação |
| 1 | Windows recém-instalado, terminal **comum** | `bootstrap.ps1` — traz winget, PowerShell 7 e git; clona este repo; chama o `setup.ps1` |
| 2 | idem, ainda **comum** | `setup.ps1 -Stage 1` → reboot → `setup.ps1 -Stage 2` |
| 3 | opcional | `windows-defaults.ps1` — ajustes de sistema, revise antes |
| 4 | terminal **elevado** | `windows-verify.ps1` — só leitura, confere se o que importa pegou |
| 5 | opcional | [`wsl/README.md`](./wsl/README.md) — ambiente de dev no WSL2 |

### Sobre elevação

**Rode tudo num terminal comum, não elevado.** Num shell elevado, `git config --global`, `~/.ssh`,
o `$PROFILE` e os pacotes per-user (Spotify, Discord, VS Code, Obsidian...) vão parar no perfil do
*administrador*, não no seu — e o sintoma aparece semanas depois, como configuração que "sumiu".

O `setup.ps1` se auto-eleva sozinho, e só para o que precisa de `HKLM` (Developer Mode, features do
WSL, `git --system`). Cada elevação é uma tarefa nomeada (`-ElevatedTask`), com log em
`C:\ProgramData\windows-setup`.

A única exceção é o `windows-verify.ps1`: ele **precisa** de terminal elevado, porque Secure Boot,
TPM, BitLocker e `bcdedit` não são legíveis sem isso. Sem elevação ele reporta SKIP justamente nos
itens que importam.

---

## Os arquivos

### Raiz

- **[`DIA-D.md`](./DIA-D.md)** — roteiro de instalação para seguir na hora: backup, BIOS, instalação,
  primeiro boot, verificação, provisionamento e o que fazer se der errado. O porquê de cada item
  fica no [`unattend/README.md`](./unattend/README.md).
- **[`bootstrap.ps1`](./bootstrap.ps1)** — o primeiro comando numa máquina limpa. Compatível com
  **PowerShell 5.1** por obrigação: um Windows novo não tem outra coisa. Resolve a execution policy,
  conserta o winget (ele registra de forma assíncrona depois do primeiro login e não está usável de
  cara), instala o **PowerShell 7** e o git, clona este repo e reinvoca o `setup.ps1` sob `pwsh`.
- **[`setup.ps1`](./setup.ps1)** — o orquestrador, análogo do `setup.sh` do `mac-setup`. Em dois
  estágios porque habilitar features do Windows exige reboot e o `winget import` não retoma sozinho.
  Marcador de estágio em `C:\ProgramData\windows-setup` (machine-wide de propósito — ver abaixo).
  No Stage 2 ele também conclui o ambiente de desenvolvimento: Node LTS via `fnm`, Corepack/pnpm,
  Python 3.13 via `uv`, Claude Code, Codex CLI, PSFzf e a configuração versionada do Windows Terminal
  com PowerShell 7 + Starship. O fluxo é idempotente e pode ser reexecutado com `-SkipPackages`.
- **[`windows-defaults.ps1`](./windows-defaults.ps1)** — análogo do `macos-defaults.sh`:
  **não é chamado pelo `setup.ps1`**, rode só se concordar com as mudanças. Traz também uma seção
  `# --- Deliberadamente NÃO feito aqui ---` listando os tweaks de "FPS boost" que este repo recusa,
  e por quê. Essa documentação negativa vale tanto quanto a positiva.
- **[`windows-verify.ps1`](./windows-verify.ps1)** — **só leitura**, nunca muda nada. Confere Secure
  Boot, TPM, VBS/HVCI, BitLocker, microcode do CPU, HAGS, TRIM e exclusões do Defender, com um
  resumo PASS/FAIL no fim. É como você descobre que o `windows-defaults.ps1` de fato pegou.
- **[`win11debloat.config.json`](./win11debloat.config.json)** — config do
  [Win11Debloat](https://github.com/Raphire/Win11Debloat), invocado pelo `setup.ps1 -WithDebloat`.
  Conservador de propósito: desliga a captura do Game DVR em vez de desinstalar o Game Bar, e não
  remove Xbox/Gaming Services (alguns launchers dependem deles).

### `packages/`

Manifests do `winget import`, o análogo do `Brewfile`. Cinco arquivos, não um:

| Arquivo | Conteúdo |
|---|---|
| [`packages-core.json`](./packages/packages-core.json) | CLIs, runtimes e apps de desenvolvimento e de uso geral |
| [`packages-gaming.json`](./packages/packages-gaming.json) | VC++ Redistributable e launchers (Steam, EA app, Ubisoft Connect) |
| [`packages-user-scope.json`](./packages/packages-user-scope.json) | Spotify, que falha em shell elevado |
| [`packages-msstore.json`](./packages/packages-msstore.json) | App da Microsoft Store (WhatsApp) |
| [`packages-overlays.json`](./packages/packages-overlays.json) | HWiNFO, RTSS, Afterburner e OBS — **não** importado pelo `setup.ps1` |

Os overlays ficam de fora de propósito: instale depois de confirmar que o anticheat do EA FC passa,
um de cada vez. **Todos rodam não elevados** — ver [`packages/manual.md`](./packages/manual.md)
para o porquê, para os 3 itens que o winget não instala (driver NVIDIA, `rtk`, `grok-build`), e para
os comandos de manutenção.

Todo ID foi verificado contra a árvore de manifests do `microsoft/winget-pkgs`, com match exato de
case. Vários não são o óbvio: `BurntSushi.ripgrep.MSVC`, `dandavison.delta`,
`Telegram.TelegramDesktop`, `aristocratos.btop4win`.

### `unattend/`

A camada pré-instalação — a de maior risco. Answer file com locale pt-BR, teclado ABNT2, layout GPT,
conta local e `PreventDeviceEncryption`.

O caminho ativo é **`install-to-ventoy.sh`**, que **roda no macOS e no Linux**: o pendrive já é um
Ventoy e o answer file chega ao Setup pelo plugin **`auto_install`** (`ventoy/ventoy.json`), não
pela raiz da mídia. O script só copia dois arquivos de texto — não formata nada, não escreve em
block device.

O `build-usb.sh` continua no repo como **alternativa**: monta um pendrive comum, dedicado, apagando
o dispositivo. Roda só no Linux. Serve para instalar com Secure Boot já ligado (o bootloader do
Windows é assinado pela Microsoft; o do Ventoy usa CA própria e pediria enrollment de MOK), ou como
plano B se o Ventoy não bootar nesta placa.

O `autounattend.xml` final é *gerado* e está no `.gitignore` — o que se versiona é o template com
placeholder.

### `lib/` e `tests/`

[`lib/Provision-DevEnvironment.ps1`](./lib/Provision-DevEnvironment.ps1) é a parte do Stage 2 que
provisiona o ambiente de desenvolvimento (Node LTS via `fnm`, Corepack/pnpm, Claude Code e Codex CLI,
Python 3.13 via `uv`, PSFzf e a configuração do Windows Terminal); o `setup.ps1` carrega esse arquivo
por dot-source. [`tests/Provision-DevEnvironment.Tests.ps1`](./tests/Provision-DevEnvironment.Tests.ps1)
testa esse provisionamento e a checagem da configuração do Windows Terminal com comandos simulados
(`fnm`, `npm`, `uv`, `fzf`...), sem instalar nada:

```powershell
pwsh -File tests/Provision-DevEnvironment.Tests.ps1
```

### `profile/`, `wsl/`, `vscode/`

Config de shell (PowerShell 7, Windows Terminal, `.wslconfig`, gitconfig do lado Windows), o ambiente
WSL2 opt-in, e a lista de extensões do VS Code.

---

## Decisões que valem entender antes de mexer

**WSL2 é opt-in (`-WithWSL`), desligado por padrão.** Habilitar o Virtual Machine Platform coloca o
Windows inteiro sob o hypervisor — custo típico de 2-5% de FPS, e "desabilite Hyper-V/VBS" é a
primeira linha de troubleshooting do anticheat da EA. Numa máquina cujo dev principal é outro, o
default honesto é não instalar. Se instalar, o `bcdedit /set hypervisorlaunchtype off` fica como
válvula de escape (documentado em [`wsl/README.md`](./wsl/README.md)).

**Nada de symlink no lado Windows.** Symlink exige `SeCreateSymbolicLinkPrivilege` (admin ou
Developer Mode), e o Git for Windows vem com `core.symlinks=false`, o que faz um clone materializar
cada symlink como um arquivo de texto com um caminho dentro. No lugar: stub que faz dot-source, e
`$env:STARSHIP_CONFIG` apontando para o `mac-setup` clonado. Dentro do WSL, symlink normal.

**Um dono por ajuste.** Developer Mode é do `setup.ps1`. `core.autocrlf`/`symlinks`/`longpaths` são do
`profile/gitconfig-windows`, que o `setup.ps1` conecta via `include.path`. PowerShell 7 é do
`bootstrap.ps1` e por isso **não** aparece nos manifests. Dois donos para o mesmo ajuste é como as
configurações divergem em silêncio.

**Dois diretórios de estado, de propósito.** O `setup.ps1` usa `C:\ProgramData\windows-setup` porque
o marcador de estágio precisa ser lido por processos de contas diferentes (o filho elevado pode ser
outra conta). O `windows-defaults.ps1` usa `%USERPROFILE%\.windows-setup` porque o log dele é
artefato descartável de uma execução manual. Não unifique sem levar isso em conta.

**O que fica em `mac-setup` e não é duplicado aqui:** `zshrc`, `starship.toml`, `gitignore_global`,
`editorconfig` e os instaladores de CLI de IA. O `wsl/provision.sh` clona o `mac-setup` dentro do
Ubuntu e reusa a metade que é Linux-safe. **Não existe um terceiro repo de dotfiles.**

---

## Segurança

- **Segredo nenhum no repo.** `~/.secrets.ps1` (Windows) e `~/.secrets.zsh` (WSL), ambos fora daqui,
  carregados por dot-source se existirem. Nenhum dos dois é criado pela automação — recrie à mão.
- **A senha da conta local não se versiona.** O `autounattend.template.xml` tem placeholder; o
  `install-to-ventoy.sh` (e o `build-usb.sh`) injetam a senha de um arquivo fora do repo e
  **recusam** um arquivo de senha que esteja dentro dele. O XML gerado está no `.gitignore` e
  nunca chega a ser escrito dentro do repo.
- **O pendrive vira segredo físico** depois de rodar o script, enquanto tiver o
  `autounattend.xml` gerado: o answer file fica em `/ventoy/script/autounattend.xml` com a senha
  em texto claro, e exFAT não tem permissão de arquivo.
- **A senha vaza no `C:\Windows\Panther\`** durante a instalação, em texto claro. O answer file
  manda apagar as cópias, mas troque a senha depois do primeiro boot mesmo assim.
- **Não use `irm <url> | iex` com este repo.** Fixe o SHA completo revisado
  (`bootstrap.ps1 -Ref <sha de 40 caracteres>`). SHA abreviado é recusado, e uma tag só vale como
  pin com `-ExpectedCommit <sha>`, porque quem tem push pode mover a tag. Em março de 2026 a Compass Security publicou initial access via
  WinGet Desired State em que o Mark-of-the-Web não era aplicado — vale a paranoia.

---

## Estado

Escrito e revisado, **nunca executado numa máquina real** — a máquina alvo ainda não foi formatada.
Trate a primeira execução como teste, não como rotina. Duas coisas ajudam:

1. O `bootstrap.ps1` clona de uma URL que **só resolve depois que este repo for publicado**. Publique
   antes de apagar o CachyOS, ou passe `-RepoUrl`/copie o repo à mão.
2. O `unattend/iso.sha256` **já está preenchido** (10/ago/2026) com o hash oficial de
   Português (Brasil), e o ISO no pendrive foi conferido contra ele. Os scripts validam o ISO
   antes de escrever qualquer coisa.

Teste o `autounattend.xml` numa VM antes do wipe. XML malformado dá loop de reboot, e descobrir isso
sem sistema operacional e sem backup é o pior cenário possível.

---

## Licença

Distribuído sob a [Licença MIT](LICENSE).
