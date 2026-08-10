# manual.md — o que o `winget` não instala, e as ressalvas por pacote

Complemento dos quatro manifests desta pasta. JSON não aceita comentário: toda ressalva
presa a um ID mora aqui, na tabela da seção 3.

**Uso:** leitura. Nada nesta pasta é executável — `setup.ps1` consome os `.json`, e os três
itens da seção 1 são feitos à mão, uma vez, por um humano.

> ⚠️ `winget import` é **aditivo**. Ele nunca remove nada e nunca converge para o estado do
> arquivo. Não existe análogo de `brew bundle --cleanup` — ver seção 4.

---

## 1. Genuinamente manuais (3 itens)

Nenhum destes tem manifest no `microsoft/winget-pkgs`. Não force um ID inventado no JSON.

### 1.1 Driver NVIDIA (RTX 4060 Ti)

Não existe no winget. Verificado direto na árvore de manifests: `manifests/n/Nvidia/` contém
apenas `CUDA`, `DisplayIDFirmwareUpdater`, `DisplayPortFirmwareUpdater`, `FrameView`,
`GeForceNow`, `ICAT`, `MDL-SDK`, `Nsight`, `PhysX`, `PhysXLegacy`, `RTXVoice`,
`UEFIFirmwareUpdater40xx`, `UEFIFirmwareUpdater50xx`, `VCR`, `VideoEffectsSDK` — nenhum driver
de display.

- O **Windows Update entrega um WHQL funcional** para a 4060 Ti. Isso já basta para o primeiro boot.
- A NVIDIA App vem depois, direto do site.
- **A versão atual do driver não foi verificada. Não fixe versão neste repo.**
- Lembrete do plano: o NVIDIA Control Panel foi aposentado (driver 610.47, mai/2026). G-Sync/VRR
  se configura no NVIDIA app e **não existe caminho suportado de registry versionável** — isso é
  checklist manual do README, não automação.

### 1.2 `rtk` (Rust Token Killer)

Sem manifest winget. Duas saídas:

- Release do GitHub `rtk-ai/rtk`, asset `rtk-x86_64-pc-windows-msvc.zip`.
- Ou build Linux dentro do WSL, se o WSL existir nesta máquina.

### 1.3 `grok-build`

Sem manifest winget.

- O one-liner `irm https://x.ai/cli/install.ps1 | iex` circula, mas **não foi verificado
  (nao verificado)**. **Não hardcode esse comando no repo.**
- Abra `x.ai/cli`, leia o instalador documentado na hora e siga o que estiver lá.
- Vale a regra geral do plano sobre `irm | iex` em repo público: fixe em tag/SHA, revise antes de
  rodar (Compass Security, mar/2026: initial access via WinGet Desired State, MotW não aplicado).

### 1.4 Apêndice — RawAccel

**RawAccel não tem manifest winget (nao verificado).** Fica como link manual. O remap de botões
está coberto por `Highresolution.X-MouseButtonControl`, que está em `packages-core.json`. Boa parte
do que o `linearmouse` fazia no Mac é desnecessária aqui — não há natural-scroll para desfazer.

---

## 2. Ordem de execução e elevação

A elevação é inconsistente no winget e é o motivo de existirem quatro arquivos em vez de um.
Um `winget import` único como admin **falha parcialmente**.

**Rode os quatro num shell NÃO elevado.** Um shell elevado não é necessário em lugar nenhum:

- `DEVCOM.JetBrainsMonoNerdFont` é `ElevationRequirement: elevatesSelf` (ver §4) — o próprio winget
  levanta o UAC quando chega nele. Elevar o shell inteiro por causa da fonte arrastava junto uns 20
  apps per-user (`Warp`, `Discord`, `Obsidian`, `Telegram`, `Microsoft.VisualStudioCode`,
  `Bitwarden`) para o perfil errado.
- `Spotify.Spotify` é `elevationProhibited` — **falha** se o shell estiver elevado. Por isso ele vive
  sozinho em `packages-user-scope.json`, e por isso a separação continua existindo mesmo com todos
  os imports não elevados.

| Arquivo | Shell | Observação |
|---|---|---|
| `packages-core.json` | **NÃO elevado** | a fonte se auto-eleva; o resto é per-user |
| `packages-gaming.json` | **NÃO elevado** | só launchers e VCRedist |
| `packages-overlays.json` | **NÃO elevado** | **o `setup.ps1` não importa este.** Manual, e só depois de validar o EA FC — ver abaixo |
| `packages-msstore.json` | **NÃO elevado** | source `msstore` é `Microsoft.Rest`, não a source `winget` |
| `packages-user-scope.json` | **NÃO elevado** | `Spotify.Spotify` é `elevationProhibited` |

Invocação (as flags de aceite são as mesmas do wrapper do plano §3):

```powershell
winget import -i .\packages\packages-core.json `
  --accept-package-agreements --accept-source-agreements --disable-interactivity
```

**A idempotência de verdade não vem do `import`** — vem do wrapper por pacote do plano §3, que
trata os códigos de saída de no-op:

```powershell
$ok = @(0, -1978335135, -1978335189)   # 0x8A150061 ja instalado; 0x8A15002B nada a atualizar
```

Nunca coloque `-1978335212` (0x8A150014, *no packages found*) nessa allowlist: é erro de casing no
`-e`, não no-op.

---

## 3. Ressalvas por ID

Substitui os comentários que o JSON não permite. Ordem: os IDs opacos primeiro, porque são os
ilegíveis daqui a seis meses.

### Microsoft Store — `packages-msstore.json`

O bloco `SourceDetails` deste arquivo usa `"Identifier": "StoreEdgeFD"`. **Não troque** — o
`winget import` casa a source por `Type` + `Identifier`, e errar isso zera o arquivo inteiro.
Ver seção 5.

| PackageIdentifier | App | Nota |
|---|---|---|
| `9NKSQGP7F2NH` | **WhatsApp** | Confirmado em `apps.microsoft.com/detail/9nksqgp7f2nh` |
| `9PFXXSHC64H3` | **Raycast** | Existe na Store, **não** é item manual. `Raycast.Raycast` **não existe** na source `winget` — é um ID morto que o winstall.app lista |

### Source `winget`

| PackageIdentifier | Ressalva |
|---|---|
| `BurntSushi.ripgrep.MSVC` | `BurntSushi.ripgrep` puro **não é pacote**. Verificado: `manifests/b/BurntSushi/ripgrep/` contém só a subpasta `MSVC`, sem pasta de versão própria |
| `dandavison.delta` | **Não** `git-delta` nem `dandavison.git-delta` (ambos ausentes da árvore de manifests) |
| `Telegram.TelegramDesktop` | **Não** `Telegram.Telegram` (ausente da árvore) |
| `DBeaver.DBeaver.Community` | Três segmentos. `DBeaver.DBeaver` sozinho não é o Community |
| `ElementLabs.LMStudio` | O publisher é **ElementLabs**, não `LMStudio.*` |
| `Microsoft.VCRedist.2015+.x64` | O `+` faz parte do ID. Em path de manifest ele aparece como `2015%2B` |
| `aristocratos.btop4win` | **Codebase diferente** do `btop` do Mac. A config **não porta** — não symlinke a do `mac-setup` |
| `Schniz.fnm` | No Windows o init é hook no `$PROFILE` do PowerShell, **não** `eval` de zsh |
| `DEVCOM.JetBrainsMonoNerdFont` | **Exige elevação.** Manifest: `InstallerType: wix`, `ElevationRequirement: elevatesSelf` |
| `Spotify.Spotify` | **Falha em shell elevado** — por isso está isolado em `packages-user-scope.json` com `"Scope": "user"`. Manifest: `Scope: user`, `ElevationRequirement: elevationProhibited`, `InstallerType: exe`. (O plano descreve como "per-user MSIX"; o manifest real diz `exe` — o que importa, e está confirmado, é o `elevationProhibited`) |
| `Docker.DockerDesktop` | Alternativa: Docker Engine **dentro do WSL** (~200 MB idle vs 500 MB–1.5 GB). **Não rode os dois na mesma distro** — a integração WSL do Desktop injeta um shim `docker` que sombreia o binário real |
| `Microsoft.WindowsTerminal` | Ocupa o slot do `ghostty`, que **não tem build Windows oficial** (1.3.0, mar/2026, só macOS/Linux) |
| `Warp.Warp` | Agora tem build Windows |
| `Microsoft.PowerToys` | FancyZones cobre o `rectangle`; Snap Layouts nativo cobre o resto |
| `ShareX.ShareX` | Substitui o `shottr`. Win+Shift+S nativo cobre o caso simples |
| `7zip.7zip` | Substitui o `keka`. Alternativa: `M2Team.NanaZip` (não incluída — escolha uma) |
| `Highresolution.X-MouseButtonControl` | Só remap de botão. Aceleração/curva é RawAccel — manual, ver §1.4 |
| `REALiX.HWiNFO` | Junto com RTSS/Afterburner ocupa o slot do `stats` do Mac. Vive em `packages-overlays.json` |
| `Guru3D.RTSS` | ⚠️ **Instale e valide o EA FC ANTES disto.** A falha típica do Javelin em instalação limpa não é Secure Boot — é conflito com outro software kernel-level/overlay. (Produtos conflitantes específicos: *nao verificado*) |
| `Guru3D.Afterburner` | ⚠️ Mesma ressalva do RTSS. Empilhar overlay antes de validar o anticheat é como se perde uma noite |
| `OBSProject.OBSStudio` | ⚠️ Mesma ressalva, e o motivo surpreende: o **Game Capture** do OBS injeta um graphics hook no processo do jogo — mesma classe do RTSS, não é "só um gravador". **Display Capture e Window Capture não injetam nada** e são o fallback quando o anticheat implica. Manifest confirmado (versões até 32.2.1) |

### Por que os overlays têm arquivo próprio

Os três acima estavam em `packages-gaming.json`, junto do `ElectronicArts.EADesktop`. O aviso
"valide o EA FC antes" existia nesta mesma tabela — e era **inaplicável**, porque um único
`winget import` instalava o launcher e os três overlays na mesma passada. Um aviso que a própria
automação impede de cumprir não é aviso, é decoração.

Agora `packages-overlays.json` é o único manifest que o `setup.ps1` **não** importa. Depois que o
EA FC entrar numa partida sem reclamar:

```powershell
winget import -i .\packages\packages-overlays.json `
  --accept-package-agreements --accept-source-agreements --disable-interactivity
```

Melhor ainda: um de cada vez, testando o jogo entre eles. É a diferença entre saber qual brigou e
adivinhar entre três.

---

## 4. Manutenção

```powershell
winget upgrade --all --include-unknown      # sem --include-unknown, muitos nunca atualizam
winget pin add --id <Id> --blocking         # primitiva nativa de pin (nao scoop hold)
winget pin list
```

**`winget import` é aditivo — nunca remove, nunca converge.** Consequências práticas:

- Tirar um ID de `packages-core.json` **não desinstala nada**. Desinstale à mão
  (`winget uninstall --id <Id> -e`) e só então edite o JSON.
- Rodar o import de novo depois de instalar algo à mão não "limpa" a máquina de volta para o
  arquivo. O arquivo é uma lista de desejos, não um estado desejado.
- Não existe `brew bundle --cleanup`, e não existe `brew bundle check`. O substituto do `check`
  é o loop da seção 5.
- Isso é **de propósito** neste repo: o valor aqui é documentação executável, não idempotência
  industrial. Máquina de uma pessoa, reinstalada a cada 2-3 anos.

---

## 5. Validação dos IDs

Rode na máquina Windows, contra a source de verdade:

```powershell
winget show --id <Id> -e --source winget
```

- **`-e`/`--exact` é case-sensitive.** `Git.Git` ≠ `git.git` — verificado: `git.git` não existe na
  árvore de manifests.
- Um ID errado retorna `-1978335212` (0x8A150014, *no packages found*). Isso é **erro**, não no-op.
- **Nunca valide contra agregador.** A API do winget.run tem dados de 2023 e o **winstall.app lista
  `Raycast.Raycast`, que não existe**. A fonte é a árvore de manifests do `microsoft/winget-pkgs`.

### O que já foi verificado, e o que isso não prova

Estes manifests foram escritos num Mac, onde não há winget. **Os 50 IDs da source `winget` e os 2
IDs da Store foram conferidos um a um contra `microsoft/winget-pkgs`** — não só a existência da
pasta, mas a presença de `<PackageIdentifier>.yaml` dentro de uma pasta de versão. Nenhum ID ficou
sem confirmação.

O método foi validado com controles negativos, que corretamente falharam: `Raycast.Raycast`,
`Telegram.Telegram`, `dandavison.git-delta`, `git.git`, `BurntSushi.Ripgrep`, `BurntSushi.ripgrep`,
`Nvidia.GeForceExperience`.

**O que isso NÃO prova:** que o pacote resolve na máquina. Cache de source desatualizado, região,
ou a source `msstore` fora do ar derrubam um ID válido. Rode o loop do `winget show` **antes** do
bulk install, na máquina real.

### O bloco `Sources` fica FORA do alcance desse loop

Registro de um defeito real deste repo, porque ele delimita com precisão o que a validação
acima cobre. O `packages-msstore.json` foi escrito com um `Identifier` inventado:

```json
"Identifier": "Microsoft.Winget.MSStore.Source_8wekyb3d8bbwe"   // errado
"Identifier": "StoreEdgeFD"                                     // correto
```

O valor certo é **`StoreEdgeFD`** — winget-cli, `SourceList.cpp`:
`s_Source_MSStoreDefault_Identifier = "StoreEdgeFD"`.

**Por que o `winget show` por ID passaria limpo mesmo assim:** os dois IDs da Store estavam
certos. O errado era o `SourceDetails` que os embrulha — e envelope não tem ID de pacote para
validar. A validação per-ID não tinha como pegar isso.

Como o `winget import` casa a source:

- **só `Type` + `Identifier`.** O `Name` é ignorado na comparação e sobrescrito pelo nome da
  source já registrada na máquina — ter `"Name": "msstore"` correto não salva nada.
- sem match ele **aborta o arquivo inteiro**, com
  `APPINSTALLER_CLI_ERROR_SOURCE_NAME_DOES_NOT_EXIST` (0x8A150012 / `-1978335214`). Não é falha
  por pacote: é **zero pacote instalado**.
- esse código é **erro**, não no-op. Nunca entra na allowlist da seção 2 — mesma regra do
  `-1978335212`.

**O check barato que pega isso:** `winget source export` (ou `winget source list --name msstore`)
reporta o `Identifier` real da source registrada na máquina. Compare com o do JSON *antes* de
rodar o import.

**A lição sobre o loop desta seção:** validar ID por ID prova que os IDs existem, e nada além
disso. Um manifest de import ainda pode falhar 100% por causa do envelope (`Sources`,
`SourceDetails`) ou por precisar de algo que o schema 2.0 não expressa — é exatamente o caso do
`Microsoft.PowerShell` na seção 6, que está fora dos manifests por não caber no schema.

---

## 6. Deliberadamente fora dos manifests

Não são esquecimento. Cada um tem um motivo.

| Pacote | Por que não está no JSON |
|---|---|
| `Microsoft.PowerShell` | **Dono único: `bootstrap.ps1`** — ele instala o PowerShell 7 com chamada explícita, antes de passar o bastão, e depois re-invoca o `setup.ps1` sob `pwsh.exe` (não sob o 5.1). Um pacote, um dono: por isso ele **não** aparece em nenhum manifest. O motivo técnico de não caber aqui: precisa de `--installer-type wix`, e **`winget import` não sabe expressar installer type** — o schema 2.0 só tem `PackageIdentifier`/`Version`/`Channel`/`Scope`/`InitialOverrideArguments`/`InitialCustomSwitches`. Verificado no manifest 7.6.4.0: existem instaladores `msix` (x64/x86/arm64) **e** `wix` (`Scope: machine`). O MSIX bloqueia perfil AllUsers e `Set-ExecutionPolicy -Scope LocalMachine`. **A partir do 7.7.0 não existe MSI no winget** — o script precisa degradar para o MSI/ZIP do GitHub release |
| `Python.Python.3.14` | Existe (confirmado), mas o `uv` gerencia interpretadores. O plano recomenda dropar |
| `Google.AndroidStudio` | Opt-in, e o plano sugere dropar. Android/React Native continua sendo trabalho de Mac |
| `EclipseAdoptium.Temurin.17.JDK` | Só faz sentido se o Android Studio ficar |
| `Microsoft.DirectX` | É **só o runtime legado DX9 de jun/2010**. DX12 é componente do SO e **não é pré-requisito do EA FC** |
| `Microsoft.WSL`, `Canonical.Ubuntu.2404` | Só se a decisão for instalar WSL2 — e **o plano recomenda não instalar por padrão** (Virtual Machine Platform põe o Windows sob o hypervisor: 2-5% de FPS, e "desabilite Hyper-V/VBS/WSL" é conselho de primeira linha no troubleshooting do EA Javelin). Ambos existem no winget se a decisão mudar (`Microsoft.WSL` 2.7.11 confirmado). Fixe `Ubuntu-24.04`, nunca `Ubuntu` — é alvo móvel |
| `wez.wezterm` | Alternativa ao `Microsoft.WindowsTerminal`. Escolha uma |
| `M2Team.NanaZip` | Alternativa ao `7zip.7zip`. Escolha uma |
| `EpicGames.EpicGamesLauncher`, `Blizzard.BattleNet`, `GOG.Galaxy` | Removidos em 10/ago/2026: **não são usados**. Estavam ali por completude, não por necessidade — e launcher não usado é serviço em background, entrada de autostart e mais uma superfície kernel-level para o anticheat brigar. IDs confirmados, é só recolocar a linha em `packages-gaming.json` se um dia entrar um jogo dessas lojas |
| `Bitwarden.CLI` | ID separado do `Bitwarden.Bitwarden`. Adicione só se for usar o CLI |
| Chocolatey | Terceiro banco de pacotes paralelo, exige admin, não cobre nada que winget já não cubra |
| Scoop | Provavelmente desnecessário. Ganha argumento forte **só** se a decisão for não instalar WSL — aí ele resolve sozinho o conflito de elevação entre Spotify e a Nerd Font |
| `cocoapods`, `watchman` | Dropados. iOS/Metro é trabalho de Mac |
| `zsh-autosuggestions`, `zsh-syntax-highlighting` | Só fazem sentido dentro do WSL (`apt install`). No Windows o PSReadLine já dá predictive |
