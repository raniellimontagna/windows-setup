# unattend/ — camada pré-instalação

Tudo neste diretório é feito **antes** de o instalador tocar no disco. É a única parte do repo
com janela de tempo irreversível: `setup.ps1`, `windows-defaults.ps1` e as listas de pacotes
podem nascer depois do primeiro boot sem perda nenhuma; isto aqui, não.

Legenda usada abaixo:

- ⚠️ = irreversível, ou capaz de brickar / perder dados
- 🔒 = ponto sem volta: a partir daqui não existe desfazer

---

## Arquivos

| Arquivo | O que é |
|---|---|
| `autounattend.template.xml` | O answer file de verdade, com `@@LOCAL_ACCOUNT_PASSWORD@@` no lugar da senha. Versionável, público, sem segredo. |
| `build-usb.sh` | Roda **no Linux** (CachyOS ou VM do Proxmox). Confere o SHA-256 do ISO, injeta a senha vinda de fora do repo e grava o pendrive. |
| `iso.sha256` | Hash do ISO pt-BR usado. Vem com placeholder: preencha antes de rodar o `build-usb.sh`. |

O `autounattend.xml` **gerado** está no `.gitignore` — ele contém a senha da conta local em
texto claro e nunca deve ser commitado.

## Como usar

A senha mora **fora do repo**, mesma regra do `~/.secrets.zsh`:

```bash
printf '%s\n' 'SuaSenhaAqui' > ~/.windows-setup-password
chmod 600 ~/.windows-setup-password
```

Depois, no CachyOS (ou numa VM Linux do Proxmox com o pendrive por USB passthrough):

```bash
# 1. Ensaio: só gera e valida o XML, não toca em disco nenhum.
bash unattend/build-usb.sh --dry-run --password-file ~/.windows-setup-password

# 2. ⚠️ Grava o pendrive do zero. APAGA O DISPOSITIVO INTEIRO. Pede confirmação digitada.
sudo bash unattend/build-usb.sh \
  --iso ~/Downloads/pt-br_windows_11_25h2_x64.iso \
  --device /dev/sdX \
  --password-file ~/.windows-setup-password \
  --extras ~/drivers-placa-mae

# 3. Alternativa não destrutiva: só escreve o autounattend.xml numa mídia que já existe.
bash unattend/build-usb.sh --inject /run/media/$USER/WIN11 --password-file ~/.windows-setup-password
```

O script **se recusa a rodar no macOS**, de propósito: Rufus é Windows-only, Ventoy não tem
build para macOS, e o `install.wim` do 25H2 passa de 4 GB (estoura o limite do FAT32). A mídia
tem que sair do CachyOS **ainda bootável** ou de uma VM. Errar isso é chegar no dia da
instalação sem mídia e sem sistema operacional.

---

## Fase 0 — decisões (30 min, dá para fazer no Mac)

1. Anote a **edition e o tipo de ativação atuais** (Settings > System > Activation): "digital
   license" vs "linked to your Microsoft account", Home vs Pro.
   ⚠️ Reinstalar com edition **diferente** da que está ativada hoje = não reativa sozinho.
2. **Vincule a licença digital à conta Microsoft agora** (Activation > Add an account). É o
   único caminho de recuperação se a placa-mãe for trocada.
3. `(Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey` — **espere
   string vazia** numa máquina montada. Isso é normal: a ativação depende do passo 2, não de
   uma chave extraível. (`wmic` foi removido no 24H2+.)
4. **Conta local, não conta Microsoft.** Com MSA no OOBE, o `%USERPROFILE%` é derivado dos ~5
   primeiros caracteres do e-mail (vira `C:\Users\ranie`) e não dá para renomear depois.
   Conta local primeiro; anexar a MSA depois, se quiser. Já é o que o answer file faz.
5. **Decida: WSL2 sim ou não.** Habilitar Virtual Machine Platform coloca o Windows inteiro sob
   o hypervisor (2–5% de FPS, e "desligue Hyper-V/VBS/WSL" é conselho de primeira linha no
   troubleshooting do anticheat). Recomendação do plano: **não instalar por padrão**. Essa
   decisão muda o repo inteiro (o diretório `wsl/` some ou fica).

## Fase 1 — resgate 🔒

A partir daqui, tudo que não sair da máquina é perdido. O Windows não lê ext4, btrfs nem LUKS.

6. Do CachyOS: `~/.ssh/` (chave privada **e** pública), `~/.secrets.zsh`, keyring do GPG,
   perfis de browser, repositórios com commit não enviado, saves do Proton em
   `~/.steam/steam/steamapps/compatdata/*/pfx/`.
7. Do lado Windows do dual-boot: Documentos, saves e settings do EA FC, perfis de periférico,
   `.cfg` do Afterburner e — ⚠️ — **a chave de recuperação do BitLocker, se houver**.
8. **Inventário de software do Windows atual.** Só é possível agora:
   ```powershell
   winget export -o packages-snapshot.json --include-versions --accept-source-agreements
   winget list > installed-full.txt
   ```
   O `export` descarta em silêncio tudo que não casa com uma source; o `winget list` é o
   inventário real. Se houver Scoop: `scoop export > scoopfile.json`. Se houver distro WSL:
   `wsl --export <Distro> D:\wsl-backup.tar`.
9. 🔒 **VERIFIQUE as cópias**: abra os arquivos, confira tamanhos, de uma sessão do CachyOS
   bootada — não de memória. Não existe undo.
10. Anote **modelo e serial de cada NVMe/SATA**, para identificar o Disk 0 sem ambiguidade.
11. Nota boa: uma **library da Steam num drive secundário NTFS sobrevive** ao wipe e é
    re-apontada por "Add Library Folder". Poupa centenas de GB de download.

## Fase 2 — repo (no Mac, antes da mídia)

12. `.gitattributes` no **primeiro** commit, antes de qualquer outro arquivo. Um `.sh` com CRLF
    morre dentro do WSL com `$'\r': command not found` e o erro não diz nada sobre isso.
    (Já está feito na raiz deste repo.)
13. **Resolva TODOS os winget IDs agora**, na máquina que ainda funciona:
    `winget show --id <X> -e --source winget`. O `-e/--exact` é **case-sensitive**:
    `Git.Git` ≠ `git.git`. Caçar ID depois do wipe é caçar numa máquina sem ferramenta nenhuma.
14. Escreva o `settings.json` do winget (`installBehavior.preferences.scope: user`,
    `telemetry.disable`). Ele tem que aterrissar **antes** do bulk install, senão a preferência
    de scope nunca se aplica.
15. **Higiene de repo público**: nada de identificador de empregador ou cliente, nada de AWS
    account ID, nada de token. Segredo mora fora do repo e é carregado por dot-source.
16. Publique o repo e **confirme que a URL raw resolve**. Fixe o bootstrap numa **tag ou SHA** —
    nunca documente `irm .../main | iex`.

## Fase 3 — mídia USB ⚠️ (do CachyOS, não do Mac)

17. **Baixe o ISO do Windows 11 25H2 x64 em Português (Brasil).** O ISO é multi-**edition**, não
    multi-**language**: `UILanguage` no answer file **não** converte um ISO en-US em pt-BR.
    Preencha o hash em `iso.sha256` a partir da tabela por idioma da Microsoft e commite.
18. ⚠️ **Decida QUEM é o dono da customização antes de escrever o pendrive.** O Rufus injeta um
    answer file próprio que **vence a ordem de busca do Setup** e faz o seu `autounattend.xml`
    ser **ignorado sem erro nenhum** — você só descobre quando a instalação termina em inglês,
    com conta Microsoft e ESP de 100 MB. Escolha um:
    - **(a) Rufus dono**: use os toggles da tela WUE e não leve XML próprio.
    - **(b) `autounattend.xml` dono** — recomendado, porque é versionável: grave a mídia com o
      `build-usb.sh` daqui, ou com Ventoy/WoeUSB, ou com Rufus com **todos** os checkboxes da
      tela WUE desmarcados.
19. Gere e confira o answer file. O `autounattend.template.xml` daqui já traz:
    UI/user locale **pt-BR**; teclado **`0416:00010416`** (ABNT2 — `0416:00000416` é ABNT puro e
    erra `/` e `?`); timezone `E. South America Standard Time`; GPT com **ESP de 1 GB** (não
    100 MB: 100 MB causa falha de servicing no 25H2), MSR de 16 MB, Windows ocupando o resto e
    **recovery de 990 MB imediatamente depois da partição do Windows**; **conta local**;
    **`PreventDeviceEncryption=1`**; a chave genérica de **seleção** de edition Pro
    `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (ela **seleciona** a edition, **não ativa** nada); e a
    limpeza das cópias em `C:\Windows\Panther\` no primeiro logon.
    ❌ Sem bypass de TPM / Secure Boot / RAM: o hardware passa nativamente, e o bypass deixaria
    o Secure Boot desligado — que quebra o EA FC, o motivo inteiro da migração.
20. **Senha fora do repo.** O `build-usb.sh` lê de um arquivo passado em `--password-file` (ou
    em `$WINSETUP_PASSWORD_FILE`) e se recusa a usar um arquivo que esteja dentro do repo.
21. ⚠️ **Estague na USB o driver de rede da placa-mãe** (Intel I225/I226 ou Realtek 2.5GbE).
    Este é o único item verdadeiramente crítico: sem NIC no primeiro boot, winget, scoop e choco
    morrem todos na largada. Junto: INF do chipset, driver Intel RST/VMD (`f6vmdflpy-x64`) se o
    VMD ficar ligado, e o `bootstrap.ps1`. Use `--extras <pasta>` no `build-usb.sh`.
    O driver da NVIDIA é *nice-to-have*: o Windows Update entrega um WHQL funcional para a 4060 Ti.
22. **Plano B do winget offline**: `Microsoft.DesktopAppInstaller_*.msixbundle` **mais**
    `DesktopAppInstaller_Dependencies.zip` (VCLibs Desktop e Microsoft.UI.Xaml — sem eles o
    `Add-AppxPackage` falha), e o `*_License1.xml` se for usar `Add-AppxProvisionedPackage`.

## Fase 4 — teste em VM (antes do wipe, não depois)

23. Suba uma VM no **Proxmox** com o ISO e o unattend e confirme: conta local criada, **zero**
    prompt de OOBE, locale e teclado pt-BR/ABNT2, encryption desligada, ESP de 1 GB e partição
    de recovery no fim do disco.
    ⚠️ XML malformado = **loop de reboot**. Descobrir isso sem sistema operacional e sem backup
    é o pior cenário possível desta lista inteira. Não pule esta fase.

## Fase 5 — BIOS/firmware ⚠️ (com o CachyOS ainda bootando)

24. ⚠️ **Flashe a BIOS mais nova que o fabricante oferece.** O motivo real é microcode Raptor
    Lake. `0x12F` (mai/2025) é o fix de Vmin Shift mais recente verificado e supera `0x129` e
    `0x12B` — mas **não trate `0x12F` como alvo**: pegue a mais nova e registre a revisão.
    A Intel estendeu a garantia para **5 anos** nas peças afetadas (14600K de 2024 → até 2029).
    - Verificação: `reg query HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 /v "Update Revision"`.
    - ⚠️ O flash **apaga o perfil de BIOS** e pode resetar o TPM. Se o Windows atual tiver
      BitLocker ativo, **suspenda ou decripte e exporte a recovery key antes**.
25. Depois do flash: Load Optimized Defaults, e então:
    - **Intel Default Settings → tier Performance** (14600K: PL1=PL2=181 W, IccMax 200 A).
      O tier Baseline é 125/143 W e sub-alimenta. **Não existe tier Extreme para i5** — é só i9.
    - **Desligue Multi-Core Enhancement / auto-OC do fabricante.** Foi exatamente isso que
      acelerou a degradação por Vmin.
    - **VT-x + VT-d ON** (o WSL2 não sobe sem).
    - **TPM ON (Intel PTT)** — requisito duro do EA FC.
    - XMP/EXPO ON. **Resizable BAR ON + Above 4G Decoding ON** (importa na 4060 Ti).
    - CSM/Legacy **OFF**, boot **UEFI only**.
26. ⚠️ **Secure Boot**: "Restore Factory Keys" / reset para Setup Mode e install default keys
    (purga as chaves MOK/shim que o CachyOS deixou), **e só depois** habilite. Confirme
    "Enabled" e "User Mode".
    - ⚠️ Restaurar chaves de fábrica numa placa desenhada antes de 2023 reinstala só os CAs de
      2011 e descarta certificados de 2023 que o Windows tenha instalado. Reconfira depois do
      boot em Windows Security > Device security > Secure boot certificate status.
    - ⚠️ Ligar o Secure Boot é justamente um dos gatilhos que faz uma máquina que **não**
      qualificava para device encryption passar a qualificar. Daí o `PreventDeviceEncryption`.
27. **Delete as entradas UEFI órfãs do GRUB/systemd-boot** (`efibootmgr -b <n> -B` no Linux, ou
    pelo menu da BIOS). O Setup do Windows **não** limpa a NVRAM.
28. Salve/exporte o perfil de BIOS depois de tudo tunado.

## Fase 6 — durante o instalador ⚠️

29. ⚠️ **Desconecte fisicamente os drives secundários.** O Setup coloca a ESP em outro disco sem
    avisar, e você acaba com uma máquina que não boota se aquele drive sair.
30. Se o **Intel VMD/RST** estiver habilitado, o Setup **não enxerga o NVMe** ("no drives found").
    Ou mude para AHCI (recomendado num boot único), ou use "Load driver" com o `f6vmdflpy-x64`
    da USB.
31. 🔒 **Delete TODAS as partições do disco alvo**: root e home do Linux, a ESP antiga, o Windows
    velho e a recovery dele. Não reaproveite a ESP criada pelo Linux.
    (Com o `autounattend.xml` daqui isso é automático: `WillWipeDisk=true` no Disk 0.)
32. Se por algum motivo o answer file **não** estiver em uso, faça Shift+F10 na tela de região e
    rode à mão, antes de continuar:
    ```cmd
    reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f
    ```

---

## Por que o `PreventDeviceEncryption` é obrigatório

Numa **clean install** que qualifica, o Windows inicializa device encryption no drive do sistema
**e em todos os fixed data drives**, com clear key, **independentemente de a conta ser local ou
Microsoft**. A conta local muda apenas o *escrow*: o volume fica "encrypted but unprotected" e
**nenhuma recovery key existe em lugar nenhum**. O 24H2 removeu os pré-requisitos de DMA/HSTI,
então esta máquina qualifica. Um drive de jogos NTFS que esteja plugado pode ser criptografado
junto. Isto não é cinto e suspensório — é o item nº 1 de risco de perda de dados da lista.

## Depois do primeiro boot

Nada aqui é responsabilidade do `unattend/`, mas vale anotar o gancho:

- ⚠️ **Memory Integrity (HVCI) vem LIGADO por padrão** numa clean install deste hardware. Não é
  "deixe desligado", é **desligue ativamente** — e antes que a auto-encryption complete.
- **Troque a senha da conta local.** Ela esteve em texto claro no `autounattend.xml` da mídia.
- Rode o `windows-verify.ps1` (só leitura) para conferir Secure Boot, TPM, VBS, HAGS e BitLocker.
  **Precisa de terminal elevado.** Sem elevação, Secure Boot, TPM, BitLocker e `bcdedit` reportam
  SKIP — ou seja, exatamente os itens que importam nesta etapa.
- Guarde o pendrive como um segredo físico enquanto ele tiver o `autounattend.xml` gerado.
