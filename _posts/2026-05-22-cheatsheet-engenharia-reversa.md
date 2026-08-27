---
layout: post
title: "Cheatsheet de engenharia reversa: firmware, binários nativos e APK Android"
date: 2026-05-22 12:00:00 -0300
tags: [reverse-engineering, cheatsheet, firmware, android]
read_min: 25
---

{% raw %}
Referência de campo de engenharia reversa. Não é pesquisa de vulnerabilidade, não é pentest, não é disclosure. É o trabalho de pegar um artefato fechado (uma imagem de firmware, um ELF stripado, um APK) e desmontar até entender o que ele faz: extração, disassembly, decompilação, emulação, tracing, instrumentação, patching, deobfuscação.

Organizado por etapa. Pula direto pra onde você está travado. Os exemplos são de trabalho real, com alvo sanitizado.

* * *

## 1\. Identificar o artefato

Antes de desmontar, saber o que é. `file` resolve a maioria, mas mente com header customizado, com artefato cifrado, e com container dentro de container. Aí você lê os bytes.

```bash
file artefato
xxd artefato | head                 # os primeiros bytes não mentem
binwalk artefato                    # assinaturas conhecidas em qualquer offset
binwalk -E artefato                 # curva de entropia
```

Entropia: código e texto ficam entre 4 e 6. Acima de 7.5 e plano do byte zero ao fim, sem header de compressão, é dado cifrado. Comprimido também é alto, mas tem o magic da compressão no começo. Essa distinção decide se o fabricante encriptou o firmware ou só comprimiu.

| Bytes (hex) | ASCII | Artefato |
| --- | --- | --- |
| `7F 45 4C 46` | `.ELF` | binário ELF |
| `64 65 78 0A` | `dex\n` | Dalvik DEX (segue `035`, `038`, `039`) |
| `50 4B 03 04` | `PK..` | ZIP, e portanto APK, JAR |
| `68 73 71 73` | `hsqs` | SquashFS little-endian (`sqsh` se BE) |
| `85 19` / `19 85` |  | JFFS2 |
| `31 18 10 06` |  | nó UBIFS |
| `55 42 49 23` | `UBI#` | volume UBI |
| `27 05 19 56` |  | uImage do U-Boot |
| `D0 0D FE ED` |  | device tree (DTB) |
| `3A FF 26 ED` |  | Android sparse image |
| `41 4E 44 52 4F 49 44 21` | `ANDROID!` | boot.img Android |

* * *

## 2\. Desempacotar firmware embarcado (Linux)

```bash
binwalk -eMq imagem.bin             # extrai, recursivo, quieto
unblob imagem.bin                   # mais robusto com aninhamento
```

O `binwalk` reconhece o SquashFS pelo magic mas o `unsquashfs` recusa quando o fabricante mexeu no compressor ou no dicionário. Ferramentas dedicadas resolvem onde o `binwalk` puro falha.

| Filesystem | Onde aparece | Ferramenta |
| --- | --- | --- |
| SquashFS | quase todo CPE | `unsquashfs`, `sasquatch` (formato adulterado) |
| JFFS2 | flash NOR | `jefferson` |
| UBIFS | flash NAND | `ubireader_extract_files` |
| CramFS | equipamento antigo | `cramfsck`, `binwalk` |
| ext2/3/4 | imagem de disco | `mount -o loop,ro`, `debugfs` |

Layout de partição, lido do alvo rodando ou do dump bruto:

```bash
cat /proc/mtd                       # nome e tamanho de cada partição
ubinfo -a                           # volumes UBI
nanddump --noecc -f part.bin /dev/mtd3
```

### Extração física

Sem interface, sem dump por software, o firmware sai do silício.

UART: quatro pads numa fileira. GND tem continuidade com o terra, acha com multímetro. VCC fica fixo em 3.3V (às vezes 1.8V) no power-on. TX oscila durante o boot, visível com analisador lógico barato. RX fica em nível alto parado.

```bash
screen /dev/ttyUSB0 115200          # tente também 57600, 9600
```

No console do U-Boot (`printenv`, `help`, `md`, `nand dump`) você dumpa a flash inteira pelo próprio bootloader.

Flash SPI NOR (SOIC-8, Winbond W25Qxx, Macronix MX25Lxx): programador CH341A de quinze reais mais `flashrom`.

```bash
flashrom -p ch341a_spi              # detecta o chip
flashrom -p ch341a_spi -r d1.bin
flashrom -p ch341a_spi -r d2.bin
sha256sum d1.bin d2.bin             # têm que bater; se não, leitura suja
```

Leitura in-circuit com clip SOIC-8 é rápida mas a flash faz backpowering da placa e a leitura sai corrompida (os dois dumps não batem). Segure o SoC em reset, ou parta pro chip-off: dessolda, lê no soquete, ressolda. eMMC é BGA, não clipa: use os test points de ISP (CLK, CMD, DAT0, VCC, GND) com um leitor de eMMC, ou chip-off com reballing.

JTAG são 4 ou 5 sinais (TCK, TMS, TDI, TDO, TRST opcional), SWD são 2 (SWDIO, SWCLK). Pra mapear header desconhecido sem queimar nada, o JTAGulator (Joe Grand) faz brute-force das combinações de pino lendo o IDCODE. Software com OpenOCD.

### Firmware cifrado

Entropia 8.0 plana, sem header de compressão. A chave está em algum lugar: TEE (TrustZone), eFuse ou OTP do SoC, ou hardcoded no bootloader. O caminho prático é achar o updater no userspace, o binário que recebe a imagem nova e a aplica. Ele descriptografa pra validar, então a rotina de derivação passa por ele. Reverte o updater (próximas seções), acha o `AES`, o `EVP_`, e rastreia de onde vem o material da chave.

* * *

## 3\. Desempacotar firmware Android

ROM de fábrica raramente é um arquivo só. É uma cebola: pacote do vendor, dentro dele uma `super.img`, dentro dela as partições dinâmicas, cada uma um filesystem.

```bash
# imagem sparse do Android -> imagem raw
simg2img system.img system_raw.img          # magic 3a ff 26 ed = sparse

# super.img com partições dinâmicas -> partições separadas
lpunpack super.img out/                     # gera system.img, vendor.img, product.img...

# pacote OTA: payload.bin dentro do zip
payload-dumper-go -o out/ payload.bin       # extrai cada partição do update

# MediaTek: ler partição direto do device via BROM/Preloader
python3 mtk.py rl dump/                     # readback de todas as partições
python3 mtk.py r system,vendor sys.img,vnd.img
```

Slots A/B: as partições vêm com sufixo `_a` e `_b`. O slot ativo é o que tem conteúdo, o inativo costuma estar vazio. O filesystem dentro é ext4 nas ROMs antigas e erofs nas novas.

```bash
mount -o loop,ro system_a.img /mnt/sys           # ext4
fsck.erofs --extract=out_erofs vendor_a.img      # erofs
file system_a.img                                # "ext2 ... (extents)" = ext4
```

Montado, o que interessa por diretório: `app/` e `priv-app/` têm os APKs (privilegiados em `priv-app/`), `framework/` tem os JARs do framework, `bin/` e `lib*/` os binários e libs nativas, `etc/selinux/*.cil` a política SELinux. Em cada pasta de APK costuma haver `oat/<arch>/` com `.odex` e `.vdex`, que é o bytecode pré-compilado pelo ART. O `.dex` original ainda está dentro do APK.

`boot.img` se desmonta com o magic `ANDROID!`: separa kernel e ramdisk, e o kernel costuma estar comprimido (gzip, lz4). `binwalk -eMq boot.img` resolve, ou `unpack_bootimg`.

* * *

## 4\. ELF e binário nativo

O header do ELF e a tabela dinâmica contam quase tudo antes de você ler uma instrução.

```bash
file bin
readelf -h bin                      # arquitetura, endianness, tipo (EXEC/DYN), entry
readelf -d bin                      # NEEDED (libs), RUNPATH, e o interpretador
readelf -l bin | grep interpreter   # /lib/ld-uClibc.so.0 ? glibc ? bionic ?
readelf -S bin                      # seções
nm -D bin                           # símbolos dinâmicos
objdump -d bin                      # disassembly cru
strings -n 8 -t x bin               # strings com offset em hex
```

O que ler nessa saída, com um exemplo real de um agente de CPE que reversei:

```plaintext
ELF 32-bit LSB pie executable, ARM, EABI5, dynamically linked,
interpreter /lib/ld-uClibc.so.0, stripped
```

Linha por linha. `32-bit LSB` é ARM little-endian. `pie` (tipo `ET_DYN` com entry e com interpretador) é position-independent, então todo endereço que você anotar é relativo à base de carga. `interpreter /lib/ld-uClibc.so.0` entrega que é firmware embarcado, uClibc e não glibc, o que muda layout de struct e comportamento de `malloc`. `stripped` significa que não tem tabela de símbolos, você vai trabalhar com `fcn.0001a2b4` em vez de nomes, e renomear na mão conforme entende.

`readelf -d` mostra o `RUNPATH`. Naquele binário era `/Plugin/<nome>/lib:./lib:/lib`, ou seja ele carrega `.so` proprietárias de um diretório próprio. Você vai precisar dessas libs pra emular depois.

Hardening, sem instalar `checksec`: NX está ligado se existe o segmento `GNU_STACK` sem flag de execução. Stack canary existe se o símbolo `__stack_chk_fail` aparece. RELRO é parcial com `GNU_RELRO` e total se também tem `BIND_NOW`.

* * *

## 5\. Arquiteturas: ARM, MIPS e convenções

Pra rastrear a entrada até um sink, você precisa saber onde cada ABI põe os argumentos.

| ABI | Argumentos | Retorno | Syscall: número / instrução |
| --- | --- | --- | --- |
| x86-64 SysV | RDI, RSI, RDX, RCX, R8, R9 | RAX | RAX, args RDI RSI RDX R10 R8 R9, `syscall` |
| ARM32 AAPCS | R0, R1, R2, R3 | R0 (R0:R1 se 64-bit) | R7, args R0-R6, `svc #0` |
| ARM64 AAPCS64 | X0 a X7 | X0 | X8, args X0-X5, `svc #0` |
| MIPS o32 | A0, A1, A2, A3 | V0 | V0, args A0-A3, `syscall` |

Em ARM32, o caso mais comum em CPE, R4 a R11 são preservados pela função chamada, então é neles que o compilador guarda ponteiro de vida longa. R13 é SP, R14 é LR (endereço de retorno), R15 é PC.

Três pegadinhas que o disassembler erra e que contaminam toda a análise:

**Thumb contra ARM.** ARM tem dois conjuntos de instrução, ARM de 32 bits e Thumb de 16 (Thumb-2 mistura). O modo é codificado no bit 0 do endereço da função: ímpar é Thumb. `BX` e `BLX` trocam de modo. Se o disassembler escolhe o modo errado, sai instrução-lixo plausível e você analisa ficção. Em radare2 force com `ahb 16` (Thumb) ou `ahb 32` (ARM).

**Blocos IT.** Em Thumb, execução condicional vem do bloco `IT`/`ITT`/`ITTT`, que torna condicionais de 1 a 4 instruções seguintes. Decompilador erra bloco IT e gera fluxo de controle que não existe.

**Branch delay slot do MIPS.** A instrução logo depois de um branch ou jump sempre executa, antes do branch tomar efeito. A instrução visualmente abaixo de `jr $ra` roda antes do retorno. O que parece código morto depois de um `j` não é morto.

Identificar a libc importa: `strings bin | grep -iE 'glibc|uclibc|musl|gcc version'` e `readelf -p .comment bin` costuma entregar a versão do GCC. uClibc é binário pequeno e comum em CPE, glibc é grande, musl é enxuto e sem versioning de símbolo, bionic é Android.

* * *

## 6\. Disassembly e decompilação

`r2 -A bin` abre e roda a análise. Tem quem prefira Ghidra, e o decompiler do Ghidra é melhor. O r2 ganha em ser leve, scriptável por `r2pipe`, e rodar sem Java. Em projeto longo, os dois: r2 pra navegar, Ghidra noutra tela pro pseudo-C.

| Comando | Faz |
| --- | --- |
| `aaa` / `aaaa` | (re)análise, profunda |
| `afl` / `afl~auth` | lista funções / filtra |
| `ii` / `iE` | imports / exports |
| `izz~http` | strings do binário todo, filtradas |
| `axt addr` | xrefs **para** (quem chama) |
| `axf addr` | xrefs **a partir de** |
| `s sym.func` / `s 0x39170` | seek |
| `pdf` / `pd 30` / `pd -10` | disassembly da função / 30 instr / 10 pra trás |
| `pdg` | decompilador (plugin `r2ghidra`) |
| `VV` | grafo de fluxo (`q` sai) |
| `/ texto` / `/x e3530001` | busca string / hex |
| `afn nome addr` | renomeia função |
| `agc` | callgraph |

O fluxo que eu uso, e que usei pra reverter aquele agente de CPE de cerca de 600 funções stripadas. Primeiro mapeio o callgraph e olho os imports pra saber o que o binário sabe fazer. Depois escolho um alvo: o que chama `system`, o que configura TLS, o que mexe com cripto. `axt sym.imp.system` lista todo chamador do sink. Pra cada um, `s` até lá e `pdf`. Rastreio o registrador do argumento de trás pra frente com `pd -N` até a origem do dado. Quando o binário usa uma biblioteca conhecida, o truque que mais acelera é comparar a sequência de chamadas com o código-fonte da lib: vendo `curl_easy_setopt` com um certo número de opção e o valor `0`, você abre o header do curl, confere que aquele número é `CURLOPT_SSL_VERIFYPEER`, e sabe sem dúvida que a verificação de certificado foi desligada.

Automação com r2pipe, pra varredura em lote:

```python
import r2pipe
r2 = r2pipe.open("bin")
r2.cmd("aaa")
for ref in r2.cmdj("axtj sym.imp.system"):     # axtj = JSON
    print(hex(ref["from"]), ref.get("fcn_name"))
```

Ghidra paralelo. Pro pseudo-C ele ganha do r2, principalmente em ARM com saltos condicionais e em código com OLLVM. Equivalências de quem alterna entre os dois: ir pra endereço `s 0x...` é `g`, renomear é `L`, xrefs é clique direito → References, decompiler é nativo (não precisa do plugin `r2ghidra`). Pra script em lote, `analyzeHeadless` é o equivalente do `r2pipe`: roda um script Python ou Java em N binários sem abrir GUI, ideal pra varrer um diretório de firmware atrás do mesmo padrão.

* * *

## 7\. APK e Android

APK é um ZIP: `AndroidManifest.xml` (XML binário), `classes.dex` e `classes2.dex`, `classes3.dex` em app grande, `resources.arsc`, `res/`, `assets/`, `lib/<abi>/*.so`, `META-INF/`.

```bash
unzip -l app.apk                              # estrutura, sem decompilar
apkid app.apk                                 # packer, compilador, anti-análise antes de decompilar
jadx -d jadx_out app.apk                      # Java reconstruído (CLI p/ APK grande)
jadx-gui app.apk                              # navegação interativa
apktool d -f -o apktool_out app.apk           # smali + recursos + manifest legível
```

`jadx` decompila Dalvik. Quando ele falha num método (ofuscação pesada, bytecode estranho), caia pro smali do `apktool`, que sempre sai. Os mesmos passos valem pra amostra hostil; a diferença é postura: diretório isolado, sem rede, você decompila e lê, nunca instala nem executa.

### Antes de tudo: que framework é

Se a lógica não está no dex, `jadx` te mostra um shell vazio. Identifique no primeiro minuto.

| Framework | Identifica por | Lógica está em |
| --- | --- | --- |
| Dalvik puro | só `classes*.dex` relevante | o dex, `jadx` resolve |
| Flutter | `libflutter.so` + `libapp.so` | `libapp.so`, snapshot AOT de Dart |
| React Native | `assets/index.android.bundle` | bundle JS, ou bytecode Hermes (magic `c6 1f bc 03`) |
| Cordova/Capacitor | `assets/www/` | app web inteiro em `www/` |
| Xamarin/MAUI | `assemblies/`, `libmonodroid.so` | DLLs .NET, abre no ILSpy/dnSpy |
| Unity | `libil2cpp.so`, `global-metadata.dat` | IL2CPP, reconstrói com Il2CppDumper |

Flutter ignora `jadx`: `reFlutter` repatcheia a engine, `Blutter` reconstrói nomes de classe do snapshot. React Native com bytecode Hermes desmonta com `hbctool` ou `hermes-dec`.

### Manifest e smali

```bash
cat apktool_out/AndroidManifest.xml
```

Smali em trinta segundos. Tipos: `V` void, `Z` boolean, `I` int, `J` long, `L pacote/Classe;` objeto, `[` prefixa array. Registradores: `p0` é o `this`, `p1`... os parâmetros, `v0`... os locais. `const-string` carrega literal, `sget-object` lê campo estático, `invoke-virtual`/`invoke-static`/`invoke-direct` chamam método. Quando o `jadx` esconde uma string montada no `<clinit>`, ela está no smali.

### Código nativo (JNI)

A função nativa que o Java chama segue `Java_pacote_Classe_metodo`, e o primeiro argumento de toda função JNI é `JNIEnv*`, o segundo é o `this`. App que não quer o nome exposto não usa esse mangling: registra a função em runtime via `RegisterNatives`, normalmente dentro de `JNI_OnLoad`. `RegisterNatives` recebe um array de `{nome, assinatura, ponteiro}`. Pra achar a função real, vá em `JNI_OnLoad`, siga até o `RegisterNatives`, leia o array.

```bash
nm -D --defined-only libnative.so | grep Java_
```

* * *

## 8\. Emulação

Rodar o binário sem o hardware. Pra um ELF standalone, `qemu-user` resolve. Pra firmware inteiro, `qemu-system` ou FirmAE.

O caso que vale detalhar é emular um binário de firmware com dependências proprietárias, que foi o que fiz com aquele agente de CPE. Ele é ARM, dinâmico, linkado contra uClibc, e carrega `.so` próprias de um diretório fora do padrão. A receita:

```bash
# 1. monte um sysroot: copie o rootfs extraído do firmware
rsync -a _firmware.extracted/rootfs/ ./sysroot/

# 2. -L aponta o QEMU pro sysroot (onde achar o interpretador uClibc e libs)
# 3. LD_LIBRARY_PATH cobre o diretório proprietário de .so
env LD_LIBRARY_PATH=/Plugin/agente/lib:/lib \
  qemu-arm-static -L ./sysroot ./sysroot/usr/bin/agente --base_domain https://exemplo
```

`qemu-arm-static` é estático, roda direto no host x86. O `-L sysroot` (equivale a setar `QEMU_LD_PREFIX`) é o que faz o loader uClibc do ARM ser encontrado, sem isso o binário nem inicia. Quando o binário reclama de algo que não existe no QEMU (um `/dev` específico, uma partição), você stuba: arquivo vazio, symlink, ou um valor fixo. Não é elegante, funciona.

Pra firmware completo, `qemu-system-arm` com kernel e device tree compatíveis, ou FirmAE, que automatiza e funciona em parte dos casos.

* * *

## 9\. Debugging e tracing

```bash
qemu-arm -g 1234 -L ./sysroot ./bin           # emula e espera o gdb na 1234
gdb-multiarch ./bin
  target remote :1234
  set architecture arm
  b *0x39170
  x/s $r0                                     # string apontada por registrador
  x/16xw $sp                                  # 16 words da stack
  info registers
```

`strace` e `ltrace` mostram comportamento sem você ler assembly. E têm um uso que vale destacar: reverter o protocolo de rede de um binário sem decifrar TLS nenhum. O syscall `connect` revela IP e porta dos endpoints, `openat` revela cada arquivo tocado, e `read`/`write`/`send` carregam o payload. Quando o protocolo não é cifrado, ou quando a verificação de TLS do próprio binário está quebrada, o que cruza o `write` é texto claro.

```bash
strace -ff -s 8192 -xx \
  -e trace=connect,openat,read,write,send,sendto,recvfrom,writev,sendmsg \
  -o trace.log \
  env LD_LIBRARY_PATH=... qemu-arm-static -L ./sysroot ./bin --base_domain https://exemplo
```

Os flags importam. `-ff` segue forks, um arquivo de log por PID. `-s 8192` evita o truncamento padrão de 32 bytes, que cortaria um JSON no meio. `-xx` despeja em hex mais ASCII, recuperando dado binário. Depois é só garimpar o log:

```bash
grep -hEo '\{[^}]{10,}\}' trace.log*          # candidatos a JSON
grep -Eo 'https?://[^ ]+' trace.log* | sort -u # endpoints
```

Foi assim que eu peguei o formato exato da mensagem de registro daquele agente, com os nomes de campo e o material que ele mandava, sem montar servidor nenhum.

* * *

## 10\. Instrumentação dinâmica

`strace` mostra a borda de syscall. Frida (de Ole André Vadla Ravnås) mostra qualquer função, com argumento e retorno, em runtime.

```bash
frida-ps -Uai
frida -U -f com.pkg -l hook.js --no-pause     # spawn + injeta
```

Dump de toda chave simétrica que o app instancia, não importa como foi derivada:

```js
Java.perform(function () {
  const SKS = Java.use('javax.crypto.spec.SecretKeySpec');
  SKS.$init.overload('[B', 'java.lang.String').implementation = function (k, a) {
    console.log('[SecretKeySpec] alg=' + a + ' key=' + bytesToHex(k));
    return this.$init(k, a);
  };
});
```

Hook em função nativa dentro de uma `.so`, quando a lógica está no C:

```js
const base = Module.getBaseAddress('libnative.so');
Interceptor.attach(base.add(0x4a10), {     // offset a partir da base do módulo
  onEnter(args) { this.p = args[2]; },     // args[0]=JNIEnv, args[1]=this
  onLeave(ret)  { console.log('ret=' + Memory.readUtf8String(this.p)); }
});
```

### Anti-Frida e anti-debug

O binário detecta o instrumentador e fecha, ou finge funcionar. Conhecer a checagem é saber o que esconder. As detecções comuns: varrer `/proc/self/maps` atrás de `frida-agent` ou `linjector`; testar a porta 27042 (default do `frida-server`); achar thread chamada `gmain` ou `gum-js-loop`; ler `TracerPid` em `/proc/self/status` (diferente de zero indica debugger). Bypass: renomear o `frida-server` no device, usar `frida-gadget` embutido via repack, fazer `spawn` com `--no-pause` pra hookar a checagem antes dela rodar, ou simplesmente substituir o retorno da função de detecção.

* * *

## 11\. Patching binário

Modificar o binário pra ele se comportar do jeito que você precisa pra analisar: pular uma checagem, redirecionar uma URL, neutralizar uma proteção. Patch in-place, preservando tamanho.

Exemplo real, sanitizado. Aquele agente de CPE validava a resposta de um comando comparando um contador com uma constante, e abortava se não batesse. Isso atrapalhava a análise dinâmica. A instrução, em ARM32, no offset `0x39170`:

```plaintext
0x39170:  01 00 53 e3    cmp r3, 1        ; bytes little-endian da word 0xE3530001
0x39174:  23 00 00 0a    beq 0x39208      ; pula se igual
```

O patch troca a comparação de "r3 contra o imediato 1" por "r3 contra r3", que é sempre verdadeira, então o `beq` sempre é tomado e a checagem deixa de barrar:

```plaintext
0x39170:  03 00 53 e1    cmp r3, r3       ; word 0xE1530003
```

Mudaram dois bytes. O `e3` (cmp com imediato) virou `e1` (cmp com registrador), e o operando `01` virou `03` (r3). Pra achar e aplicar:

```bash
xxd -s 0x39170 -l 8 bin                       # confirma os bytes no offset
printf '\x03\x00\x53\xe1' | dd of=bin bs=1 seek=$((0x39170)) conv=notrunc
xxd -s 0x39170 -l 8 bin                       # verifica o patch
```

O segundo tipo de patch foi em string. O binário buscava uma URL fixa em `.rodata`. Sobrescrevendo essa string in-place, com o cuidado de não passar do tamanho original, dá pra apontar pro seu ambiente de análise. URL aceita barra no fim sem quebrar o parse, então sobra de espaço se preenche com `/`. O mesmo `dd ... conv=notrunc`, ou um script Python com `struct`, aplica.

Conferir se o patch fez efeito é rodar o binário emulado (seção 8) e olhar o `strace` (seção 9). Se a checagem que tu neutralizou levava a `exit` ou a uma chamada que aparecia no trace, e essa chamada agora some, o patch pegou. Patch silencioso, que não muda comportamento observável, geralmente é patch errado.

Regra de ouro do patching: preserve o tamanho do arquivo. Mudar o tamanho desloca todo offset seguinte, quebra a tabela de seções, e o ELF não carrega mais. Patch é substituir bytes, nunca inserir.

Quando não patchar. Frida hookando a mesma checagem em runtime resolve o mesmo problema sem alterar o binário, e é melhor quando o binário tem assinatura ou checksum, quando tu precisa alternar entre comportamento patchado e original na mesma sessão, ou quando tu quer comparar os dois lados sem reabrir o arquivo. Patching ganha quando precisa distribuir o binário pra rodar em outro lugar (lab emulado num colega, fuzzer rodando offline), quando o alvo não aceita instrumentação, ou quando a alteração é permanente (URL apontada pra endpoint controlado).

Equipamento com bootloader que valida assinatura do filesystem (CPE moderno de fabricante grande quase sempre faz) recusa imagem patchada. Aí o patch da seção do binário não passa no boot, e a saída é ou bypass do verificador (que volta pra seção 2, e às vezes exige glitching), ou patchar o processo já carregado em memória via Frida ou kernel module, sem tocar na flash.

* * *

## 12\. Deobfuscação e unpacking

APK que abre no `jadx` sem erro e tem só uma `MainActivity` minúscula está empacotado. O `classes.dex` real é descomprimido em runtime. `.so` com nome tipo `libjiagu`, `libsecexe`, `libsecmain` é packer (Jiagu, Bangcle, SecNeo). O caminho é dumpar o dex da memória depois que o packer o carregou, com Frida hookando `DexClassLoader` ou `DefineClass`, ou ferramentas como `frida-dexdump`.

Em código nativo, Obfuscator-LLVM (OLLVM) deixa três marcas. Control flow flattening transforma o fluxo num laço gigante com um `switch` central despachando blocos por uma variável de estado, o grafo vira uma estrela. Bogus control flow injeta caminho morto guardado por condição opaca. Instruction substitution troca uma operação simples por uma sequência equivalente esquisita. Reconhecer o dispatcher achatado é o primeiro passo; pra remediar há plugins de deobfuscação pra Ghidra e IDA, ou execução simbólica resolvendo a variável de estado.

Pistas de ofuscação em Java: classe e método de uma ou duas letras é R8 ou ProGuard; string que virou chamada de um método decodificador é string encryption.

* * *

## 13\. Reverter cripto embarcada

Reconhecer o que tu está vendo, antes de tentar quebrar. Codificação não é cifra: `A-Za-z0-9+/` com `=` no fim e comprimento múltiplo de 4 é base64, decodifica e segue. Cifra de bloco deixa rastro no tamanho: AES tem bloco de 16 bytes, ciphertext em ECB ou CBC tem comprimento múltiplo de 16; DES e 3DES têm bloco de 8; RSA produz saída do tamanho da chave, 256 bytes pra RSA-2048. Se o "token" tem exatamente 256 bytes, é quase certo RSA. ECB se denuncia sozinho: blocos de plaintext idênticos viram blocos de ciphertext idênticos, e se tu cifra uma imagem com regiões de cor sólida ainda dá pra ver o contorno. Vale o mesmo pra config estruturada com campo repetido.

Firmware que cifra um cofre de credencial quase sempre usa a mesma receita: uma chave mestra em texto puro num arquivo, uma derivação simples (shift de bytes, concatenação, um SHA-256) e AES-256-CBC. Reverter isso é RE: você lê a função de derivação no disassembly e a reproduz.

No r2, ache a função pelas chamadas a `EVP_DecryptInit_ex`, `SHA256`, `AES_set_*`. Leia passo a passo o que ela faz com o material da chave. Reproduza em Python:

```python
from Crypto.Cipher import AES
import hashlib
key = hashlib.sha256(material_a).digest()        # 32 bytes
iv  = hashlib.sha256(material_b).digest()[:16]   # 16 bytes
pt  = AES.new(key, AES.MODE_CBC, iv).decrypt(ct)
```

A armadilha que custa tempo: o decompiler nomeia uma variável de `key` e outra de `iv` por causa de um `memset` anterior, mas no call site do `EVP_DecryptInit_ex` os ponteiros entram trocados. O nome é hipótese. A posição do argumento é fato. Em conflito, confie no dataflow.

* * *

## 14\. Patch diffing

Pega duas versões do mesmo firmware ou do mesmo binário e compara. O que mudou entre v1 e v2 costuma ser o que o fabricante consertou sem dizer.

```bash
diff <(binwalk fw_v1.bin) <(binwalk fw_v2.bin)   # macro: o que mudou
diff -rq rootfs_v1/ rootfs_v2/                    # quais arquivos diferem
```

No nível de função, BinDiff (zynamics, hoje Google) e Diaphora (Joxean Koret) casam funções entre as duas versões e destacam as que mudaram. O sinal de ouro é uma função que ganhou um bloco novo de validação, um bounds check, uma chamada de sanitização. Essa função tinha bug na v1, e o diff te entrega exatamente onde olhar.

* * *

## 15\. Execução simbólica

Quando o caminho até um ponto do código depende de uma condição de input específica, e resolver na mão é chato, execução simbólica resolve o input pra você.

```python
import angr
proj  = angr.Project('bin', auto_load_libs=False)
simgr = proj.factory.simulation_manager(proj.factory.entry_state())
simgr.explore(find=0x39208, avoid=[0x392a0])
if simgr.found:
    print(simgr.found[0].posix.dumps(0))         # input que leva ao endereço
```

angr (da equipe do angr, Shellphish/UC Santa Barbara) vale quando o caminho é complexo. Não vale quando o binário é grande e o número de estados explode. Mitigue: comece o estado de um endereço perto do alvo (`blank_state(addr=...)`) em vez do entrypoint, e marque simbólico só o que interessa, o resto concreto.

* * *

## 16\. Reverter um protocolo

Binário que fala um protocolo proprietário, sem documentação. A reconstrução combina o que já apareceu nas seções anteriores. Estática primeiro: as strings entregam URLs, nomes de endpoint, nomes de campo, verbos. O disassembly da função que monta a mensagem mostra a ordem dos campos e os tipos. Dinâmica depois: `strace` nos syscalls de rede captura a mensagem real cruzando o `write`, e se o protocolo for cifrado você reverte o lado servidor (um servidor mínimo que responde o que o binário espera) pra fazer o binário continuar falando e revelar mais do fluxo.

Foi assim que reconstruí o protocolo de registro daquele agente: as strings deram os endpoints e o esqueleto do JSON, o disassembly deu a ordem de montagem dos campos, e o `strace` confirmou a mensagem exata no fio. Pra protocolo binário sem nome de campo no payload, se for protobuf, `protoc --decode_raw < blob.bin` mostra os campos por número e tipo, e você reconstrói o `.proto` a partir daí.

Reconhecer encoding no fio quando o protocolo é binário e tu não tem fonte. Protobuf começa com um varint de field-tag onde os 3 bits baixos são o wire type (0 varint, 1 fixed64, 2 length-delimited, 5 fixed32), e o resto é o número do campo. TLV custom costuma ter prefixo de 1, 2 ou 4 bytes de tamanho, identifica olhando se o tamanho anunciado bate com o resto do payload. MessagePack começa com byte de tipo numa faixa pequena (mapa em `80-8f` ou `de`/`df`, array em `90-9f` ou `dc`/`dd`). CBOR tem estrutura parecida com major types diferentes. BSON e similares têm o tamanho total como primeiro `int32` little-endian. Se nada disso encaixa, é blob proprietário e a única saída é o disassembly da função que monta o pacote.

* * *

## 17\. Armadilhas

`file` mente em artefato com header customizado. Confira os bytes.

Entropia alta não é sempre cripto, pode ser só compressão. Olhe se tem header de gzip, xz ou lzma antes de concluir.

O decompiler dá hipótese, não verdade. Ghidra e jadx erram tipo, erram nome, erram bloco IT. Em decisão importante, leia o assembly ou o smali cru.

Em binário PIE, todo endereço é relativo à base. O `0x39170` que você anotou no r2 só vale somado à base de carga real em runtime.

`binwalk` reconhecer um SquashFS não quer dizer que extrai. Tenha `sasquatch`, `jefferson`, `ubireader` à mão.

APK que abre limpo no `jadx` e só tem uma `MainActivity` minúscula está empacotado. O dex real aparece em runtime.

Binário ARM lido no modo errado (ARM em vez de Thumb) vira instrução-lixo plausível. Na dúvida, force o modo e compare.

A instrução depois de um branch em MIPS executa. Sempre. Não é código morto.

Patching que muda o tamanho do arquivo desloca todo offset e quebra o ELF. Substitua bytes, nunca insira.

Emular binário dinâmico sem o `-L sysroot` correto falha logo no loader, e a mensagem de erro não diz que o problema é o interpretador. Se o `qemu-user` morre antes do `main`, suspeite do interpretador e das libs antes de qualquer outra coisa.

* * *

Esse arquivo nunca está fechado. Cada coisa nova que me faz perder uma tarde vira uma linha aqui.


{% endraw %}
