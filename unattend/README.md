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
| `install-to-ventoy.sh` | **O caminho ativo.** Roda **no macOS ou no Linux**. Confere o SHA-256 do ISO, injeta a senha vinda de fora do repo e publica o answer file no pendrive Ventoy. Não formata nada. |
| `../ventoy/ventoy.json` | A configuração do **plugin `auto_install`** do Ventoy (mais duas chaves de `control`). É o arquivo que amarra o ISO ao answer file. |
| `build-usb.sh` | **Alternativa, não é o caminho normal.** Roda só **no Linux**. Constrói um pendrive **comum** (sem Ventoy) do zero, apagando o dispositivo. Ver "Quando usar o `build-usb.sh`". |
| `iso.sha256` | Hash do ISO pt-BR usado. **Já preenchido** (10/ago/2026) com a linha oficial de "Português (Brasil) 64-bit". |

O `autounattend.xml` **gerado** está no `.gitignore` — ele contém a senha da conta local em
texto claro e nunca deve ser commitado. Ele também nunca é escrito dentro do repo: o
`install-to-ventoy.sh` gera num diretório temporário e copia direto para o pendrive.

## Como usar — pendrive Ventoy (caminho ativo)

O pendrive é **um só** e já tem 13 ISOs. Ele não vai ser reformatado: o Ventoy entrega o
answer file pelo plugin **`auto_install`**, que mapeia um ISO a um template de instalação.
Por isso o `autounattend.xml` **não** vai na raiz do pendrive — naquele lugar ele seria
simplesmente ignorado, porque quem boota o ISO aqui é o Ventoy, não a mídia da Microsoft.

A senha mora **fora do repo**, mesma regra do `~/.secrets.zsh`:

```bash
printf '%s\n' 'SuaSenhaAqui' > "$HOME/.windows-setup-password"
chmod 600 "$HOME/.windows-setup-password"
```

Com o pendrive plugado no Mac (ele monta em `/Volumes/Ventoy`):

```bash
# 1. Ensaio: confere o SHA-256 do ISO, gera o XML, calcula o merge e mostra o diff.
#    Não escreve nada no pendrive.
bash unattend/install-to-ventoy.sh --dry-run --password-file "$HOME/.windows-setup-password"

# 2. Para valer. Mostra exatamente o que vai mudar no /ventoy/ventoy.json e pede confirmação
#    caso o arquivo já exista.
bash unattend/install-to-ventoy.sh --password-file "$HOME/.windows-setup-password"
```

O script faz, nesta ordem: **(1)** confere o SHA-256 do ISO contra o `iso.sha256` **antes de
qualquer outra coisa** — leva alguns minutos, são 7,6 GiB por USB, e é de propósito: um answer
file perfeito colado num ISO errado produz exatamente o desastre que este diretório existe para
evitar; **(2)** recusa um arquivo de senha que esteja **dentro do repo**; **(3)** substitui o
placeholder e **aborta se sobrar qualquer placeholder** no XML gerado; **(4)** faz **merge** do
`/ventoy/ventoy.json`, nunca sobrescrita.

O resultado no pendrive são dois arquivos:

```
/ventoy/ventoy.json               ← config do plugin (merge, com backup datado)
/ventoy/script/autounattend.xml   ← o answer file com a senha em texto claro
```

### O merge do `ventoy.json` é levado a sério

O pendrive é a caixa de ferramentas dele, com 13 ISOs. Se um dia houver ali um `theme`, um
`menu_alias`, um `persistence` ou uma entrada de `auto_install` de outro ISO, **sobrescrever o
arquivo destruiria tudo isso sem aviso**. O script:

- faz **backup datado** (`ventoy.json.bak-AAAAMMDD-HHMMSS`) antes de tocar no arquivo;
- preserva **todas** as chaves de plugin que não são nossas, intocadas;
- dentro de `auto_install`, substitui **só** a entrada cuja `image` é o nosso ISO e preserva as
  outras;
- dentro de `control`, substitui **só** as chaves que declaramos e preserva as demais, na ordem;
- **para e não escreve nada** se o JSON existente estiver corrompido, se a raiz não for um
  objeto, ou se `auto_install`/`control` não tiverem o formato esperado;
- imprime o **diff completo** antes de mudar qualquer coisa, e pede confirmação;
- é **idempotente**: rodar de novo sem mudar nada não gera backup nem altera o arquivo.

### ⚠️ O Ventoy faz bypass do Windows 11 por padrão — e aqui isso é desligado

Este é o detalhe que mais fácil passa batido. Desde a v1.0.86, o Ventoy vem com **os dois
bypasses do Windows 11 LIGADOS por padrão**:

| Chave (`control`) | Padrão do Ventoy | O que faz |
|---|---|---|
| `VTOY_WIN11_BYPASS_CHECK` | `"1"` | Escreve as chaves de registro que **burlam a checagem de TPM, Secure Boot, CPU e RAM**. |
| `VTOY_WIN11_BYPASS_NRO` | `"1"` | Escreve `BypassNRO`, que **burla a exigência de conta Microsoft** no OOBE. |

Isso **contradiz frontalmente** a decisão da Fase 3 (item 19): esta máquina passa nos requisitos
nativamente, e a instalação tem que ser limpa, sem marca de bypass. Por isso o
`ventoy/ventoy.json` daqui traz explicitamente:

```json
"control": [
    { "VTOY_WIN11_BYPASS_CHECK": "0" },
    { "VTOY_WIN11_BYPASS_NRO": "0" }
]
```

O `BYPASS_NRO` é desligado pelo mesmo princípio do item 18: **o answer file é o dono da
customização.** Ele já cria a conta local `ranielli` e o OOBE nunca chega a perguntar — deixar o
Ventoy escrever uma chave de registro por conta própria seria um segundo dono, invisível, no
lugar onde não se quer surpresa.

> ⚠️ O `ventoy.json` **não aceita comentários** — o parser JSON do Ventoy é simples e
> comentário quebra o arquivo. Por isso o "porquê" de cada chave mora aqui no README, e não
> dentro do JSON.

Duas outras opções de `control` que **ficam no padrão**, de propósito:
`VTOY_SECURE_BOOT_POLICY` (padrão `"0"` = o Ventoy contorna a checagem de Secure Boot) e
`VTOY_SECONDARY_BOOT_MENU`. A primeira é irrelevante aqui porque o Secure Boot fica
**desligado** durante o boot da mídia (Fase 5, item 28); mexer nela afetaria o boot dos outros
12 ISOs sem necessidade.

## Quando usar o `build-usb.sh` (pendrive comum)

O `build-usb.sh` continua no repo, mas **não é o caminho normal** e não roda no macOS. Ele
apaga um dispositivo inteiro e monta uma mídia dedicada só do Windows, com o `autounattend.xml`
na raiz. Vale a pena em dois casos:

1. **Instalar com Secure Boot já ligado.** O bootloader do Windows é assinado pela Microsoft e
   boota com as chaves de fábrica; o do Ventoy usa CA própria e cairia no MOK manager pedindo
   enrollment — ver a ressalva na Fase 5, item 28.
2. **Plano B**, se o Ventoy não bootar nesta placa.

Nesse caso, a mídia tem que sair do CachyOS **ainda bootável** ou de uma VM Linux, porque o
`install.wim` do 25H2 passa de 4 GB e precisa ser dividido com o wimlib. (No caminho Ventoy
esse limite não existe: o Ventoy boota o ISO direto do arquivo, sem copiar o `install.wim` para
lugar nenhum.)

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

## Fase 3 — mídia USB ⚠️ (do Mac mesmo, com o pendrive Ventoy)

17. ✅ **ISO do Windows 11 25H2 x64 em Português (Brasil), já baixado e conferido.** O ISO é
    multi-**edition**, não multi-**language**: `UILanguage` no answer file **não** converte um
    ISO en-US em pt-BR. O hash já está preenchido no `iso.sha256`, da tabela por idioma da
    Microsoft, e o `install-to-ventoy.sh` o confere a cada execução.
18. ⚠️ **Decida QUEM é o dono da customização antes de escrever o pendrive.** Ferramentas de
    gravação injetam answer files próprios que **vencem a ordem de busca do Setup** e fazem o
    seu `autounattend.xml` ser **ignorado sem erro nenhum** — você só descobre quando a
    instalação termina em inglês, com conta Microsoft e ESP de 100 MB. Aqui a decisão está
    tomada: **o `autounattend.xml` deste repo é o dono**, entregue pelo plugin `auto_install`
    do Ventoy. Consequências práticas:
    - o Ventoy é só o **loader**: os dois bypasses dele são desligados no `ventoy.json`
      (ver "O Ventoy faz bypass do Windows 11 por padrão", acima);
    - o `autounattend.xml` **não** vai na raiz do pendrive — no fluxo Ventoy aquele lugar não é
      lido. Ele vai em `/ventoy/script/autounattend.xml`, referenciado pela chave `template`;
    - se um dia usar o Rufus como plano B, desmarque **todos** os checkboxes da tela WUE.
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
    ⚠️ Esse "sem bypass" só vale se os bypasses **do Ventoy** também estiverem desligados. Eles
    vêm ligados de fábrica; o `ventoy/ventoy.json` daqui os zera. Ver a seção acima.
20. **Senha fora do repo.** O `install-to-ventoy.sh` lê de um arquivo passado em
    `--password-file` (ou em `$WINSETUP_PASSWORD_FILE`) e **se recusa** a usar um arquivo que
    esteja dentro do repo (symlinks são resolvidos, então apontar para dentro também é pego).
    A senha nunca é passada por argv, que é visível no `ps` para qualquer usuário da máquina.

    > Ela **passa** por disco fora do pendrive, sim: o XML é gerado num diretório temporário
    > (`mktemp -d`, modo 700, `/var/folders/...` no macOS) e apagado por um trap de EXIT.
    > O trap não sobrevive a um `SIGKILL` nem a um desligamento abrupto. Na prática é
    > irrelevante, mas dizer "nunca toca o disco" seria mentira.
21. ⚠️ **Estague na USB o driver de rede da placa-mãe** (Intel I225/I226 ou Realtek 2.5GbE).
    Este é o único item verdadeiramente crítico: sem NIC no primeiro boot, winget, scoop e choco
    morrem todos na largada. Junto: INF do chipset, driver Intel RST/VMD (`f6vmdflpy-x64`) se o
    VMD ficar ligado, e o `bootstrap.ps1`.
    No pendrive Ventoy isso é só copiar uma pasta para a raiz da partição — não existe
    `--extras` aqui, e nem precisa: a partição é exFAT e o Windows a lê normalmente durante a
    instalação. Não use `/ventoy/` para isso; crie algo como `/drivers/`.
    O driver da NVIDIA é *nice-to-have*: o Windows Update entrega um WHQL funcional para a 4060 Ti.
22. **Plano B do winget offline**: `Microsoft.DesktopAppInstaller_*.msixbundle` **mais**
    `DesktopAppInstaller_Dependencies.zip` (VCLibs Desktop e Microsoft.UI.Xaml — sem eles o
    `Add-AppxPackage` falha), e o `*_License1.xml` se for usar `Add-AppxProvisionedPackage`.

## Fase 4 — provar que a injeção funcionou (antes do wipe, não depois)

O modo de falha que importa aqui é **silencioso**: se o `ventoy.json` estiver com um caminho
errado, um erro de sintaxe ou uma `image` que não casa com o nome do ISO, o Ventoy simplesmente
**boota o Windows sem answer file nenhum** e a instalação segue normal, em inglês, pedindo conta
Microsoft. Não há mensagem de erro. Por isso a verificação é em três camadas, da mais barata
para a mais cara — **faça as três**.

23. **Camada 1 — no Mac, sem bootar nada (segundos).** Rode com `--dry-run`. Ele confere o
    SHA-256 do ISO, gera o XML, prova que nenhum placeholder sobreviveu e mostra o diff do
    `ventoy.json`. Confirme visualmente que a `image` do diff é **exatamente** o nome do ISO
    que está no pendrive (maiúsculas, `_v2`, tudo):

    ```bash
    bash unattend/install-to-ventoy.sh --dry-run --password-file "$HOME/.windows-setup-password"
    ls -1 /Volumes/Ventoy/*.iso     # o nome tem que bater caractere a caractere
    ```

24. **Camada 2 — o próprio Ventoy valida o JSON (1 minuto, sem instalar nada).** Boote o
    pendrive (numa VM ou na própria máquina, **com Secure Boot desligado**) e, no menu do
    Ventoy, pressione **F5 (Tools)**. Confira, nesta ordem, que cada um destes reporta OK:

    - `Check plugin json configuration (ventoy.json)`
    - `Check auto install plugin configuration`
    - `Check global control plugin configuration`

    Erro de sintaxe, arquivo ausente ou caminho de `template` errado aparecem **aqui**, de
    graça. Se o primeiro disser que `/ventoy/ventoy.json` não existe, você escreveu no lugar
    errado (partição VTOYEFI, ou outro pendrive).

    Depois, selecione o ISO do Windows: com `autosel` e **sem** `timeout`, o Ventoy **não pode**
    mostrar menu de escolha de template. Se aparecer um menu perguntando qual template usar, a
    configuração não está valendo.

25. **Camada 3 — instalação completa numa VM ⚠️ (não pule).** Suba uma VM no **Proxmox** (ou
    UTM no Mac) com um disco virtual descartável, boote o pendrive e deixe ir até o fim.
    Confirme: conta local `ranielli` criada, **zero** prompt de OOBE, locale e teclado
    pt-BR/ABNT2, encryption desligada, ESP de 1 GB e partição de recovery no fim do disco.
    ⚠️ XML malformado = **loop de reboot**. Descobrir isso sem sistema operacional e sem backup
    é o pior cenário possível desta lista inteira.
    ⚠️ A VM precisa de **TPM 2.0 e Secure Boot capable** habilitados no hipervisor — os
    bypasses do Ventoy estão desligados de propósito, então uma VM sem TPM vai falhar na
    checagem de requisitos. Isso é o comportamento correto, não um bug da configuração.

## Fase 5 — BIOS/firmware ⚠️ (com o CachyOS ainda bootando)

26. ⚠️ **Flashe a BIOS mais nova que o fabricante oferece.** O motivo real é microcode Raptor
    Lake. `0x12F` (mai/2025) é o fix de Vmin Shift mais recente verificado e supera `0x129` e
    `0x12B` — mas **não trate `0x12F` como alvo**: pegue a mais nova e registre a revisão.
    A Intel estendeu a garantia para **5 anos** nas peças afetadas (14600K de 2024 → até 2029).
    - Verificação: `reg query HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 /v "Update Revision"`.
    - ⚠️ O flash **apaga o perfil de BIOS** e pode resetar o TPM. Se o Windows atual tiver
      BitLocker ativo, **suspenda ou decripte e exporte a recovery key antes**.
27. Depois do flash: Load Optimized Defaults, e então:
    - **Intel Default Settings → tier Performance** (14600K: PL1=PL2=181 W, IccMax 200 A).
      O tier Baseline é 125/143 W e sub-alimenta. **Não existe tier Extreme para i5** — é só i9.
    - **Desligue Multi-Core Enhancement / auto-OC do fabricante.** Foi exatamente isso que
      acelerou a degradação por Vmin.
    - **VT-x + VT-d ON** (o WSL2 não sobe sem).
    - **TPM ON (Intel PTT)** — requisito duro do EA FC.
    - XMP/EXPO ON. **Resizable BAR ON + Above 4G Decoding ON** (importa na 4060 Ti).
    - CSM/Legacy **OFF**, boot **UEFI only**.
28. ⚠️ **Secure Boot**: "Restore Factory Keys" / reset para Setup Mode e install default keys
    (purga as chaves MOK/shim que o CachyOS deixou). **Faça a restauração das chaves agora, mas
    deixe o Secure Boot DESLIGADO até o Windows estar instalado** — ver a ressalva do Ventoy
    logo abaixo. Habilite no passo 35, e só então confirme "Enabled" e "User Mode".

    > **A mídia É Ventoy: não ligue o Secure Boot antes de instalar.** Isto deixou de ser
    > hipótese — é o caminho escolhido, e esta é a razão de o Secure Boot ficar desligado aqui.
    > O Ventoy assina o próprio bootloader com uma CA própria (nova desde a v1.1.14) e, com
    > Secure Boot ligado, o primeiro boot cai no MOK manager pedindo enrollment da chave dele.
    > Enrollar essa chave **recoloca um certificado de terceiro exatamente no keystore que você
    > acabou de limpar** — numa máquina cujo motivo de existir é passar num anticheat kernel.
    > A documentação do próprio Ventoy ainda avisa que ele **contorna as checagens de Secure Boot
    > por padrão**, e que em algumas placas a solução simplesmente não funciona.
    >
    > Não precisa: o requisito da Microsoft é **"UEFI, Secure Boot capable"** — *capaz*, não
    > *ligado*. O Setup instala com Secure Boot desligado sem reclamar e sem bypass nenhum.
    > O que precisa estar ligado é o **TPM 2.0**, esse sim desde já.
    >
    > Alternativa, se preferir instalar já com Secure Boot ligado: grave um pendrive **comum**
    > só com o Windows com o `build-usb.sh` (o bootloader dele é assinado pela Microsoft, boota
    > com as chaves de fábrica, zero enrollment) e mantenha o Ventoy como caixa de ferramentas
    > multi-ISO. Custa um segundo pendrive — que é exatamente o que se quis evitar.
    - ⚠️ Restaurar chaves de fábrica numa placa desenhada antes de 2023 reinstala só os CAs de
      2011 e descarta certificados de 2023 que o Windows tenha instalado. Reconfira depois do
      boot em Windows Security > Device security > Secure boot certificate status.
    - ⚠️ Ligar o Secure Boot é justamente um dos gatilhos que faz uma máquina que **não**
      qualificava para device encryption passar a qualificar. Daí o `PreventDeviceEncryption`.
29. **Delete as entradas UEFI órfãs do GRUB/systemd-boot** (`efibootmgr -b <n> -B` no Linux, ou
    pelo menu da BIOS). O Setup do Windows **não** limpa a NVRAM.
30. Salve/exporte o perfil de BIOS depois de tudo tunado.

## Fase 6 — durante o instalador ⚠️

31. ⚠️ **Desconecte fisicamente os drives secundários.** O Setup coloca a ESP em outro disco sem
    avisar, e você acaba com uma máquina que não boota se aquele drive sair.
32. Se o **Intel VMD/RST** estiver habilitado, o Setup **não enxerga o NVMe** ("no drives found").
    Ou mude para AHCI (recomendado num boot único), ou use "Load driver" com o `f6vmdflpy-x64`
    da USB.
33. 🔒 **Delete TODAS as partições do disco alvo**: root e home do Linux, a ESP antiga, o Windows
    velho e a recovery dele. Não reaproveite a ESP criada pelo Linux.
    (Com o `autounattend.xml` daqui isso é automático: `WillWipeDisk=true` no Disk 0.)
34. Se por algum motivo o answer file **não** estiver em uso, faça Shift+F10 na tela de região e
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

35. ⚠️ **Volte na BIOS e ligue o Secure Boot** (o passo 28 deixou as chaves de fábrica restauradas
    e o Secure Boot desligado só para o boot da mídia). Confirme "Enabled" + "User Mode".
    Sem isso o EA FC não roda — e este é o passo mais fácil de esquecer, porque a máquina já está
    funcionando e parece pronta.
    - ⚠️ Ligar o Secure Boot é justamente um dos gatilhos que faz uma máquina que **não**
      qualificava para device encryption passar a qualificar. Confirme que o
      `PreventDeviceEncryption` está valendo **antes** de ligar.
    - Retire o pendrive antes, para não cair no MOK manager do Ventoy sem querer.

- ⚠️ **Memory Integrity (HVCI) vem LIGADO por padrão** numa clean install deste hardware. Não é
  "deixe desligado", é **desligue ativamente** — e antes que a auto-encryption complete.
- **Troque a senha da conta local.** Ela esteve em texto claro no `autounattend.xml` da mídia.
- Rode o `windows-verify.ps1` (só leitura) para conferir Secure Boot, TPM, VBS, HAGS e BitLocker.
  **Precisa de terminal elevado.** Sem elevação, Secure Boot, TPM, BitLocker e `bcdedit` reportam
  SKIP — ou seja, exatamente os itens que importam nesta etapa.
- ⚠️ **O pendrive é um segredo físico** enquanto existir
  `/ventoy/script/autounattend.xml` nele: exFAT não tem permissão de arquivo, então qualquer
  máquina em que ele for plugado lê a senha. Quando a instalação estiver concluída e a senha
  trocada, apague esse arquivo — o `ventoy.json` pode ficar, ele não tem segredo nenhum:

  ```bash
  rm /Volumes/Ventoy/ventoy/script/autounattend.xml
  # cópias antigas deixadas por versões anteriores do install-to-ventoy.sh, se houver:
  rm -f /Volumes/Ventoy/ventoy/script/autounattend.xml.bak-*
  ```

  Se o `install-to-ventoy.sh` substituiu um answer file que já estava no pendrive, o backup
  dele (com a senha antiga) fica nesta máquina, em
  `~/.local/state/windows-setup/ventoy-backup/`, numa pasta 700. Apague quando não precisar mais.
