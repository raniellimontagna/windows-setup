# DIA-D — roteiro de instalação

Cartão condensado para seguir na hora. O detalhe e o "porquê" de cada item estão em
[`unattend/README.md`](./unattend/README.md); aqui é só a ordem.

⚠️ = irreversível · 🔒 = ponto sem volta

---

## Antes de desligar o CachyOS

- [ ] Backup conferido (não "acho que sim" — abra os arquivos): `~/.ssh/`, `~/.secrets.zsh`,
      GPG, saves de Proton, commits não pushados. **Windows não lê ext4/btrfs.** 🔒
- [ ] Anote modelo e serial dos NVMe/SATA, para identificar o disco certo sem ambiguidade.
- [ ] Delete as entradas UEFI órfãs do GRUB: `efibootmgr` para listar, `efibootmgr -b <n> -B`
      para remover. O Setup do Windows **não** limpa a NVRAM.

## BIOS ⚠️

- [ ] **Flashe a BIOS mais nova disponível.** Motivo: microcode Raptor Lake (Vmin shift).
      Confira a revisão depois. Intel estendeu a garantia para 5 anos nas peças afetadas.
- [ ] Load Optimized Defaults, depois:
- [ ] **Intel Default Settings → Performance** (14600K: PL1=PL2=181 W, IccMax 200 A).
- [ ] **Multi-Core Enhancement / auto-OC do fabricante: OFF.** Foi isso que acelerou a
      degradação por Vmin nessa geração.
- [ ] TPM / Intel PTT: **ON** (requisito duro do EA FC)
- [ ] VT-x + VT-d: ON · XMP/EXPO: ON · Resizable BAR + Above 4G Decoding: ON
- [ ] CSM/Legacy: **OFF**, boot UEFI only
- [ ] Secure Boot: **"Restore Factory Keys"**, e **deixe DESLIGADO por enquanto.**
      (Ligado, o Ventoy cai no MOK manager e suja o keystore recém-limpo.)
- [ ] Salve o perfil de BIOS.

## Instalação ⚠️

- [ ] **Desconecte fisicamente os drives secundários.** Senão a ESP pode parar no disco errado
      e a máquina não boota se aquele drive sair.
- [ ] Se houver **Intel VMD/RST** habilitado, mude para **AHCI** — senão o Setup não enxerga o
      NVMe ("no drives found").
- [ ] Boote o pendrive. No menu do Ventoy escolha **`Windows 11 25H2 pt-BR OFICIAL`**.
      (As entradas marcadas `MODIFICADA` **não** têm answer file — sobem em instalação manual.)
- [ ] **Não deve aparecer menu de escolha de template.** Se aparecer, a config não pegou: pare.
- [ ] **A tela de idioma/teclado não deve aparecer.** Se aparecer, o answer file não foi
      injetado — pare antes do particionamento e me chame. 🔒
- [ ] O answer file apaga o **Disk 0** inteiro, sem perguntar. Se algo parecer errado, desligue
      na força antes do particionamento.

## Primeiro boot

- [ ] **Desligue Memory Integrity (HVCI).** Vem LIGADO por padrão neste hardware e custa FPS.
      Windows Security → Device security → Core isolation.
- [ ] **Troque a senha da conta local.** Ela esteve em texto claro no answer file e vaza em
      `C:\Windows\Panther\`.
- [ ] Crie o **PIN** (Settings → Contas → Opções de entrada). Não reaproveite nada que já
      tenha circulado.
- [ ] Confirme que `PreventDeviceEncryption` valeu **antes** do próximo passo.

## Voltar na BIOS ⚠️ — o passo mais fácil de esquecer

- [ ] **Tire o pendrive** (senão cai no MOK manager do Ventoy).
- [ ] **Ligue o Secure Boot.** Confirme "Enabled" + "User Mode".
      **Sem isso o EA FC não roda** — e a máquina já vai estar funcionando e parecendo pronta.

## Verificação

```powershell
# terminal ELEVADO — sem elevação ele pula Secure Boot, TPM, BitLocker e bcdedit
.\windows-verify.ps1
```

- [ ] Secure Boot: Enabled · TPM: 2.0 presente · VBS: Not enabled · BitLocker: sem protector

## Provisionamento

```powershell
# terminal COMUM, não elevado
.\bootstrap.ps1
```

- [ ] `bootstrap.ps1` → instala winget, PowerShell 7, git, clona o repo
      Sem acesso ao GitHub, passe `-RepoUrl` ou copie o repo à mão.
- [ ] `setup.ps1 -Stage 1` → reboot → `setup.ps1 -Stage 2`
- [ ] **Instale e valide o EA FC ANTES dos overlays.** Entre numa partida.
- [ ] Só então: `winget import -i .\packages\packages-overlays.json --accept-package-agreements
      --accept-source-agreements --disable-interactivity` — um de cada vez, testando o jogo
      entre eles.

---

## Se der errado

| Sintoma | O que é |
|---|---|
| Setup pede idioma/teclado | Answer file não injetou. Confira `/ventoy/ventoy.json` no pendrive. |
| Menu de escolha de template | `autosel` não valeu. Ventoy antigo? Rode F5 → Tools. |
| "No drives found" | Intel VMD/RST ligado. Mude para AHCI. |
| Loop de reboot | XML malformado. Não deveria acontecer (validado com xmllint), mas se acontecer, pare. |
| EA FC reclama de Secure Boot | Você esqueceu de voltar na BIOS. |
| EA FC falha com Secure Boot ON | Conflito kernel-level. Desinstale overlays um a um. |
| Pendrive apagado durante a instalação | O USB era o Disk 0. Reconstrua pelo Mac: baixe o ISO, `bash unattend/install-to-ventoy.sh`. |
