---
layout: post
title: "Engenharia reversa aplicada à análise de vulnerabilidades: binários ARM e bytecode Dalvik"
date: 2026-05-22 09:00:00 -0300
tags: [reverse-engineering, arm, dalvik, android]
read_min: 28
---

{% raw %}
Esse texto começou como rascunho. Foi se acumulando ao longo dos últimos meses, enquanto eu abria firmware e APK atrás de coisa quebrada. Cheguei num ponto em que o workflow virou automático, e isso é o momento certo pra escrever ele inteiro, antes que vire intuição opaca que nem eu mesmo consigo destrinchar. Esse post é o resultado, do momento que eu recebo o binário até o momento que eu entendo o sistema bem o suficiente pra ter um PoC na mão.

Não é tutorial nem referência. É como eu trabalho, com as opiniões fortes que eu fui juntando no caminho. O assunto aqui é engenharia reversa, o trabalho de leitura. As CVEs que saem disso são subproduto, e aparecem de passagem, sanitizadas. Algumas coisas vão soar óbvias pra quem já faz isso. Outras vão soar estranhas pra quem nunca fez. Tudo bem.

Aviso de sempre: tem parte que eu não posso detalhar ainda. Um dos casos que aparece mais pra frente está em disclosure coordenado, com embargo até julho de 2026. Quando cair, eu volto e escrevo a análise completa daquele caso. Por enquanto, quando o exemplo vier de lá, eu falo no genérico e tiro tudo que identifica o alvo. O mesmo vale pros projetos que ainda estão em triagem: a técnica vai inteira, o nome do produto não.

## A mentalidade antes da ferramenta

Existe um padrão que eu vi tanta vez que virou meu primeiro filtro mental. O engenheiro de software médio confia na camada anterior. O front confia no back, o back confia no proxy, o proxy confia no firewall, o firewall confia que ninguém entrou na rede interna, a rede interna confia que ninguém tem credencial vazada. Cada camada empurrando a responsabilidade pra próxima. Em algum ponto dessa cadeia, alguém deixou de validar uma coisa porque "a outra camada já valida".

Engenharia reversa, na prática, é achar onde essa confiança quebra. Você procura o ponto em que a entrada do usuário atravessa sem ser checada de novo, e onde alguma camada faz algo perigoso com essa entrada: executa um comando, lê um arquivo, monta uma query, constrói uma URL.

A segunda coisa que virou mentalidade é a seguinte: se está embarcado no artefato, está vazado. APK distribuído na Play Store, firmware servido por HTTP do servidor de update, config.bin baixado da interface web do roteador. Qualquer coisa dentro de um artefato que sai do controle do fabricante e chega no dispositivo do usuário tem que ser tratada como pública. Isso inclui chave RSA "privada", credencial "encriptada", token "ofuscado". Se eu consigo extrair, o adversário também consegue.

Terceira: proteção homogênea é ilusão. Quando um fabricante distribui o mesmo firmware, ou o mesmo APK, pra milhões de dispositivos com a mesma chave compartilhada, ele criou uma chave única que destranca a frota inteira. Comprometeu um, comprometeu todos, ao mesmo tempo. Eu vejo isso em quase todo firmware de CPE que eu abro e em boa parte dos APKs corporativos que analiso.

## De onde vem o material

Todo material que eu analiso ou é de equipamento meu, ou veio de pacote distribuído publicamente. Não tem etapa de invasão em lugar nenhum desse workflow.

Pra firmware de CPE, o caminho que mais funcionou pra mim é o backup de configuração. Quase todo modem residencial tem na interface web uma função tipo "Advanced Settings > Backup". Você baixa um config.bin que, descriptografado com a ferramenta certa pra cada fabricante, revela um XML enorme com a configuração inteira do equipamento. No meio desse XML costuma ter uma seção de update com a URL exata do firmware atual no servidor do operador. Eu nunca vi essa URL exigir autenticação. O binwalk extrai o conteúdo em segundos. Em 2017, quando trabalhei em ISP, eu já via um padrão parecido com os CPEs Huawei da época.

Outra rota é UART. Abre o equipamento, identifica os quatro pinos do header serial (VCC, GND, TX, RX), liga num USB-TTL de quinze reais, abre `screen /dev/ttyUSB0 115200` e tem boa chance de cair direto no console do U-Boot. Dali você dumpa a NAND inteira com comando do próprio bootloader. Em CPE residencial brasileiro a senha do U-Boot quase sempre é fraca, default, ou não existe.

Pra APK Android, eu baixo do APKMirror ou do APKPure. Se o app não está em store pública, caso de app interno que precisa estar no celular do funcionário, o caminho é extrair de um aparelho onde ele já está instalado. `adb shell pm path com.example.app` me diz o caminho do APK no dispositivo, e `adb pull` traz pra minha máquina.

Pra API web, o vetor quase sempre é o próprio app mobile da empresa. Instalo o app, configuro o proxy, instalo o certificado raiz do proxy no dispositivo, e capturo o tráfego enquanto uso o app normalmente. Na maioria dos casos isso já me dá os endpoints, os formatos de request e os tokens de autenticação. Se o app tem SSL pinning eu uso Frida pra contornar, mas isso é menos comum do que se imagina, principalmente em apps de empresa pequena e média.

## Estática primeiro, quase sempre

Análise estática antes da dinâmica, quase sempre. Dinâmica é mais cara em tempo, mais arriscada (você pode brickar equipamento, acionar WAF, ser detectado) e depende de o equipamento estar ligado e funcionando. Estática você faz no seu ritmo, em qualquer máquina, e o resultado é reproduzível.

A exceção é alvo com janela de acesso curta. Equipamento emprestado por um colega que volta a usar em uma semana, ou ambiente de teste que vai ser desmontado. Aí eu inverto a ordem, capturo tudo que der na dinâmica enquanto tenho acesso, e levo o material pra mesa pra analisar com calma depois. Mas é exceção.

## Firmware: abrindo a imagem

Depois que o `binwalk -eMq imagem.bin` cospe um diretório com o filesystem extraído, a primeira coisa que eu rodo são três comandos que dão um mapa do território.

```bash
# 1. Quais binários ELF existem, e qual a arquitetura?
find . -type f -exec file {} \; | grep ELF | sort -u

# 2. Quais scripts existem (web, init, config)?
find . \( -name "*.lua" -o -name "*.sh" -o -name "*.lp" \) -print

# 3. Tem credencial em clear text em algum lugar óbvio?
grep -rlE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' .
grep -rnE 'passwd|secret|hardcode' etc/ 2>/dev/null
```

Esses três greps já me deram vulnerabilidade explorável em mais de um projeto. Não estou brincando. Eu já abri firmware de equipamento que custa milhares de reais e achei chave privada PEM dentro de `/etc/`, que abre direto com `openssl rsa -in chave.pem -noout -text`, sem passphrase nenhuma.

O `file` no passo 1 quase sempre me responde ARM 32-bit ou MIPS, little ou big endian. Isso decide o resto do dia: define qual toolchain de cross-compile eu vou usar se precisar emular, e qual ABI eu vou ter que ter na cabeça lendo assembly. ARM little-endian AAPCS é o caso mais comum em CPE moderno, então é o que eu vou assumir nos exemplos daqui pra frente.

Com o mapa pronto, eu escolho um binário pra atacar. Geralmente é o daemon principal, o processo que atende a interface web e os pedidos de configuração, ou alguma biblioteca que faz coisa interessante. Qualquer `.so` com `auth`, `crypto`, `key` ou `hardcode` no nome ganha minha atenção na hora.

Aí entra o radare2. Tem gente que prefere Ghidra, e o decompiler do Ghidra é melhor, sem discussão. Mas o r2 ganha pra mim em três pontos: é leve, tem o `r2pipe` (que me deixa scriptar análise em Python), e roda em qualquer máquina sem precisar de Java. Em projeto longo eu uso os dois, r2 pra navegar e Ghidra aberto numa outra tela pro pseudo-C. O ponto de partida, porém, é sempre o r2.

```plaintext
r2 -A bin/cfgd
```

O `-A` faz a análise automática. Espera os segundos necessários e você tem todas as funções identificadas, os cross-references montados, as strings indexadas. A primeira coisa que eu olho é a tabela de imports. Eu quero saber o que esse binário sabe fazer.

```plaintext
[0x00000000]> ii~system
ordinal=031 plt=0x00012470 type=FUNC name=system
[0x00000000]> ii~exec
[0x00000000]> ii~popen
[0x00000000]> ii~fork
```

Repare que só o primeiro grep retornou linha. O binário importa `system()`, e não importa nenhuma variante de `execv`/`execl`/`posix_spawn`. Isso já me conta o final da história. Se um binário processa entrada do usuário, dispara processos, e a única rota de execução que ele tem é `system()`, então tudo passa pelo `/bin/sh -c`. O shell interpreta `;`, `&&`, `|`, crase, `$()`. Se a entrada do usuário entrar no comando via `snprintf` ou `strcat`, é command injection, ponto.

## O daemon que confia na entrada

Num caso recente, e aqui eu preciso ser vago porque é o caso em embargo, o daemon principal de um equipamento de rede tinha dois handlers de diagnóstico vizinhos: um pra ping, outro pra traceroute. Mesmo arquivo, mesmo padrão de código, mesmo tipo de entrada.

Achei os dois pelo cross-reference. `axt sym.imp.system` lista todo lugar que chama `system`, e dali eu fui pulando de função em função com `s` e lendo o disassembly com `pdf`. O handler de ping era assim (offsets e nomes trocados, mas a forma é exata):

```plaintext
0x0008e1a0  ldr   r7, [r5, 0x1c]      ; r7 <- host, campo cru do POST
0x0008e1a4  mov   r0, r7
0x0008e1a8  bl    sym.chk_host        ; valida o formato do endereço
0x0008e1ac  cmp   r0, 0
0x0008e1b0  beq   0x8e1ec             ; inválido? pula a montagem do comando
0x0008e1b4  ldr   r2, str.ping_fmt    ; "ping %s -c %u -W %u"
0x0008e1b8  mov   r3, r7
0x0008e1bc  bl    sym.imp.snprintf    ; snprintf(buf, 0x100, fmt, host, ...)
0x0008e1c8  mov   r0, r4              ; r4 = buffer com o comando montado
0x0008e1cc  bl    sym.imp.system
```

O handler de traceroute era byte por byte a mesma coisa, com uma diferença. Não tinha o `bl sym.chk_host` nem o `cmp`/`beq` logo depois. A entrada ia direto do campo do POST pro `snprintf`, e do `snprintf` pro `system`, sem passar por validação nenhuma.

Esse contraste é um dos sinais mais confiáveis que eu conheço. Função gêmea onde uma foi corrigida e a outra ficou pra trás significa que alguém da empresa achou o bug, arrumou num lugar, e esqueceu de aplicar a mesma correção no irmão. O `chk_host` não nasceu por acaso. Ele foi colado ali depois, num commit de segurança, e o cara que escreveu o commit não procurou os outros pontos com o mesmo padrão.

Quando eu acho um candidato desses, eu rastreio o registrador de trás pra frente até a origem. No caso, `r7`. De onde ele veio? `[r5, 0x1c]`, um offset de uma struct, e essa struct era a request HTTP parseada. Confirmei seguindo `r5` algumas funções acima até bater na rotina que faz o parse dos campos do corpo do POST. Entre o parse e o `system`, zero validação no caminho do traceroute. Exploit confirmado de forma estática.

Eu gosto de fechar essa convicção rodando o handler isolado antes de chegar perto do equipamento de verdade. `qemu-arm-static` consegue executar o binário ARM na minha máquina x86. Pra um daemon inteiro raramente funciona de primeira, mas pra exercitar uma função específica costuma bastar. Subo com `qemu-arm -g 1234 ./cfgd`, conecto o `gdb-multiarch` na porta 1234, ponho um breakpoint no `snprintf` e mando o request com `host=1.1.1.1;id`. Quando o breakpoint bate, eu leio a memória do buffer de destino:

```plaintext
(gdb) x/s $r0
0x7efff3a0:  "ping 1.1.1.1;id -c 1 -W 2"
```

O comando já está montado, com o meu `;id` no meio, esperando o `system`. Não precisei mandar nada pro equipamento real pra saber que vai executar. A confirmação dinâmica final, contra hardware, eu faço depois, e faço com `sleep`, não com `id`, mas isso é assunto de outra seção.

## A credencial "encriptada" e a chave que está do lado

Tem uma classe de bug que eu venho vendo repetidas vezes em firmware de CPE e que merece parágrafo próprio: o cofre de credencial "encriptado".

O padrão é esse. O fabricante sabe que credencial em clear text no firmware é vexame, e talvez algum auditor já tenha apontado isso em algum momento. Então ele cria um arquivo binário em `/etc/` com as credenciais cifradas em AES-256-CBC. Bonito. Só que, em outro arquivo do mesmo firmware, em clear text, ele deixa a chave mestra usada pra derivar a chave AES. A "derivação" costuma ser uma sequência de operações simples: shift de bytes, concatenação com outra string, um SHA-256 do resultado.

A segurança desse esquema depende da chave mestra estar escondida. Mas ela não está. Está em clear text num arquivo que qualquer um baixa. E o algoritmo de derivação está implementado numa biblioteca compartilhada que também está no firmware e que dá pra reverter.

Num desses, a função de derivação ficava numa `.so` pequena. O `pdf` mostrava dois loops e duas chamadas de SHA-256 antes do `EVP_DecryptInit_ex`. O primeiro loop era assim:

```plaintext
0x00000f70  ldrb  r3, [r6, r2]        ; r6 = chave mestra, r2 = índice
0x00000f74  add   r3, r3, 3           ; desloca o byte em +3
0x00000f78  strb  r3, [r1, r2]        ; grava no buffer derivado
0x00000f7c  add   r2, r2, 1
0x00000f80  cmp   r2, 0x20
0x00000f84  bne   0xf70
```

Um Caesar de +3 sobre um pedaço de 32 bytes da chave mestra. O segundo loop fazia a mesma coisa com +2 sobre outro pedaço, e logo depois concatenava o resultado com a cauda da string mestra. Cada metade ia pra um `SHA256`, e os dois digests entravam no `EVP_DecryptInit_ex`.

Aqui veio a parte que custou tempo, e é a parte que eu queria mostrar. O Ghidra tinha nomeado uma das variáveis locais de `iv_local` e a outra de `key_local`, porque mais cedo na função teve um `memset` que sugeriu esses papéis. Eu reproduzi o algoritmo em Python seguindo esses nomes e o decrypt saiu lixo. Voltei pro disassembly e olhei só o call site do `EVP_DecryptInit_ex`:

```plaintext
0x00001020  mov   r2, r8             ; r8 -> buffer A   (3o arg = KEY)
0x00001024  mov   r3, r9             ; r9 -> buffer B   (4o arg = IV)
0x00001028  bl    sym.imp.EVP_DecryptInit_ex
```

O buffer que o decompiler chamou de `iv_local` era o `r8`, e `r8` vai pro terceiro argumento, que é a **chave**. Os nomes mentiram. A posição do argumento não. Quando eu inverti os dois no script, o decrypt saiu limpo na primeira tentativa. Lição que eu carrego: o decompiler te dá uma hipótese, não um fato. Quando a hipótese e o dataflow discordam, o dataflow ganha.

O script final tinha menos de cinquenta linhas de `pycryptodome` e cuspiu o cofre inteiro em clear text. O padrão se repete. Procura arquivo binário pequeno em `/etc/` com nome que sugere senha. Procura arquivo de uma linha em clear text do lado. Procura biblioteca com `hardcode` ou `crypto` no nome. Quase sempre tem coisa ali.

## O cadeado que abre com a chave que estava junto

Ainda no mesmo equipamento, o servidor web tinha um mecanismo de "integridade". Todo POST vinha com um header, vou chamar de `Check`, e o servidor recusava o request se o header não batesse. Parecia anti-CSRF.

Reverti o `httpd` e segui a função que lia esse header. A lógica, em pseudo-código depois de eu mapear o disassembly, era essa:

```plaintext
check_integrity(req):
    if (!g_integrity_on)        return OK
    h = http_header(req, "Check")
    if (!h)                     return FAIL
    raw     = base64_decode(h)
    digest  = rsa_private_decrypt(raw, "/etc/keys/priv.pem", passphrase)
    return memcmp(digest, sha256(req.body), 32) == 0
```

O `rsa_private_decrypt` carregava a chave de `/etc/keys/priv.pem`, e a passphrase desse PEM era uma das strings que eu já tinha tirado do cofre da seção anterior. Quer dizer: o cliente assina o corpo do request encriptando o `sha256(body)` com a chave pública, e o servidor "verifica" decriptando com a privada. As duas chaves estão no firmware. As duas são as mesmas em todo equipamento do modelo. Um mecanismo que parece autenticação é só um par de chaves que o atacante também tem.

A confirmação disso é matemática e não precisa de um único request a mais contra o equipamento. Capturei um POST real do navegador, peguei o header `Check`, e decriptei com a privada que eu extraí:

```python
from Crypto.PublicKey import RSA
from Crypto.Cipher import PKCS1_v1_5
import base64, hashlib

body  = "campo1=valor1&campo2=valor2&token=abc"
check = "<valor capturado do header Check>"

priv = RSA.import_key(open("priv.pem", "rb").read(),
                      passphrase=PASSPHRASE_EXTRAIDA)

decifrado = PKCS1_v1_5.new(priv).decrypt(base64.b64decode(check), None)
esperado  = hashlib.sha256(body.encode()).hexdigest()

assert decifrado.decode() == esperado, "chave nao bate"
print("a chave do firmware e a chave em producao.")
```

Bateu. A chave embarcada no firmware é a chave que está rodando em produção, e a partir dela eu forjo o header `Check` pra qualquer POST que eu quiser mandar contra qualquer equipamento daquele modelo.

## O laboratório antes do equipamento real

Quando o exploit é de firmware, tem um passo que poupa dor: reconstruir o equipamento dentro de uma máquina virtual antes de chegar perto do hardware de verdade. O FirmAE tenta isso de forma automática, e quando dá certo é ótimo, mas com CPE de operadora eu quase sempre acabo montando o lab na mão.

A receita é direta na ideia e chata na execução. Pego o rootfs que o binwalk extraiu e subo sob `qemu-system-arm`, com um kernel e um device tree compatíveis com a arquitetura. O daemon web reclama de meia dúzia de coisas que não existem dentro do QEMU: uma partição de configuração, um nó de `/dev` específico, o chip de NAND. Eu vou stubando cada uma, um arquivo vazio aqui, um symlink ali, um valor fixo retornado de uma syscall acolá, até ele subir e servir a interface. Não é elegante. Funciona.

A parte que muda o jogo é o outro lado. CPE de operadora não vive sozinho. Ele conversa o tempo todo com o backend do operador: servidor de update, ACS de TR-069, às vezes um endpoint de telemetria. No lab eu subo um lado servidor falso, um punhado de processos meus que respondem nesses papéis, com certificado e chave que eu mesmo gerei. O modem emulado passa a achar que está conectado à operadora, e eu fico no meio, com `tcpdump` gravando cada pacote dos dois sentidos.

Com isso de pé, eu posso ser destrutivo à vontade. Disparo o command injection com `rm`, com escrita de arquivo, com payload que reinicia o equipamento, e o pior que pode acontecer é eu reiniciar uma VM. Observo o que o exploit faz de verdade, capturo o tráfego que ele gera, comparo com a captura legítima, e só depois, com o comportamento todo mapeado, é que eu levo a versão mínima e não-destrutiva do PoC pro equipamento real. O lab é o que me deixa separar duas coisas que costumam ser tratadas como uma só: entender o bug, e confirmar o bug sem causar dano. São tarefas diferentes, e merecem ambientes diferentes.

## APK: lendo código que mexeram pra não ser lido

Pra Android, a ferramenta que eu uso o tempo todo é o jadx. O `jadx-gui` é melhor pra navegação inicial, mas engasga feio em APK grande, então pra app de 100 MB pra cima eu uso a CLI desde o começo.

```bash
jadx -d jadx_out app.apk
```

Isso reconstrói o código Java a partir do bytecode Dalvik. Não é o código original. Se o app passou por R8 ou ProGuard, os nomes de classe e de variável vêm mangleados. Mas as strings literais sobrevivem, e os cross-references também, e é com isso que se trabalha.

Os greps que eu rodo logo em seguida miram credencial e endpoint:

```bash
cd jadx_out/sources
grep -rnE 'AKIA[0-9A-Z]{16}' .                       # AWS Access Keys
grep -rnE 'AIza[0-9A-Za-z_-]{35}' .                  # chaves Google/Firebase
grep -rnE '(eyJ[A-Za-z0-9_-]+\.){2}[A-Za-z0-9_-]+' . # JWTs embarcados
grep -rnoE 'https?://[a-zA-Z0-9./_-]+' . | sort -u   # endpoints
```

Num app que eu olhei recentemente, ainda em triagem, o grep de JWT não achou nada, mas o de string genérica caiu numa classe chamada `xq2`. Classe de uma letra e dois caracteres é assinatura de ProGuard. Abri o smali, porque às vezes o jadx esconde justamente o `clinit`:

```smali
.class public final Lcom/a/b/xq2;
.field public static final p:Ljava/lang/String;

.method static constructor <clinit>()V
    const-string v0, "hs256-chave-de-assinatura-de-exemplo"
    sput-object v0, Lcom/a/b/xq2;->p:Ljava/lang/String;
.end method
```

Um campo estático com uma string de 40 caracteres. Sozinho não diz nada. O que diz é o cross-reference. Quem lê `xq2.p`? Uma classe que o jadx decompilou mais ou menos assim:

```kotlin
val key = Keys.hmacShaKeyFor(xq2.p.toByteArray())
val jwt = Jwts.builder()
    .claims(mapOf("user_id" to user.id, "email" to user.email))
    .expiration(Date(now + 86_400_000))
    .signWith(key, Jwts.SIG.HS256)
    .compact()
chatSdk.setUserJwt(jwt)
```

O app assina, no próprio cliente, um JWT que identifica o usuário pra um SDK de chat de suporte. A chave HMAC é a string que está naquele campo estático. Quer dizer que qualquer um que extrai o APK forja um JWT com `user_id` arbitrário e entra no chat de suporte fazendo-se passar por qualquer cliente. A verificação de identidade do SDK existe pra evitar exatamente isso, mas só funciona se a chave ficar no servidor. Ela não ficou.

Quando o app é ofuscado a ponto de o jadx não dar conta, ou quando a string que eu quero é montada em runtime e nunca aparece como literal, eu paro de ler estático e instrumento. Frida pra isso é difícil de bater. O hook que eu mais uso é genérico, no construtor do `SecretKeySpec`, e ele me entrega toda chave simétrica que o app usa, não importa de onde ela veio:

```js
Java.perform(function () {
  const SKS = Java.use('javax.crypto.spec.SecretKeySpec');
  SKS.$init.overload('[B', 'java.lang.String').implementation =
    function (key, alg) {
      console.log('[SecretKeySpec] alg=' + alg +
                  ' key=' + bytesToHex(key));
      return this.$init(key, alg);
    };
});
```

Roda o app, exercita a tela que te interessa, e o terminal do Frida lista cada chave AES no momento em que ela é instanciada, derivada ou não. Pra SSL pinning a ideia é a mesma, só muda o alvo do hook: o `okhttp3.CertificatePinner.check` ou o `checkServerTrusted` do `X509TrustManager`, forçando retorno limpo. Quando o pinning não cai com hook, eu vou de `apktool`: decompila o APK, edito o `network_security_config.xml` pra confiar em CA de usuário, recompilo, assino com chave minha, instalo. Vinte minutos.

## Confirmando sem quebrar nada

Análise estática me diz "isso provavelmente é explorável". Análise dinâmica prova. E o disclosure depende dessa prova.

PoC dinâmico tem que ser não-destrutivo. Nunca modifica dado de terceiro, nunca cria persistência, nunca derruba serviço pra outros usuários. Se a vuln é command injection, eu confirmo com `sleep N` ou `id`, jamais com `rm` ou escrita de arquivo. Se é IDOR, leio um único objeto que claramente não é meu, confirmo, e paro. Não enumero. E eu logo tudo. Data, hora, IP de origem, request exato, response exato. O vendor às vezes contesta no dia do disclosure, e nessa hora eu quero o histórico completo na mão.

Pra command injection, time-based é a forma mais limpa. Manda um payload sem injeção, mede o tempo. Manda com `;sleep 5`, mede de novo. Se o segundo é uns 5 segundos maior, executou.

```python
import requests, time

def bench(host, n=5):
    ts = []
    for _ in range(n):
        t0 = time.time()
        requests.post(URL, data={"Host": host})
        ts.append(time.time() - t0)
    ts.sort()
    return ts[len(ts) // 2]   # mediana, aguenta outlier

base = bench("1.1.1.1")
inj  = bench("1.1.1.1;sleep 5")
print(f"baseline {base:.2f}s, injetado {inj:.2f}s")
```

Pra IDOR, o protocolo é simples. Tenho duas contas, A e B. Logado como A, identifico o ID de um objeto que é da B. Logado como A, peço esse objeto. Se vier, IDOR confirmado. Num app que eu olhei, o backend era um `.asmx` clássico de .NET, e a chamada que carregava o cadastro do cliente recebia o ID dentro de um CDATA:

```xml
<GetDadoPessoal>
  <dsXML><![CDATA[
    <data><cdCliente>10231</cdCliente></data>
  ]]></dsXML>
</GetDadoPessoal>
```

O `cdCliente` era um sequencial global. Troquei `10231` por `10232` e veio o cadastro de outra pessoa, com nome, documento, telefone, endereço. O servidor autenticava o request, mas não checava se a sessão autenticada tinha direito àquele ID específico. Autenticação sem autorização não é autenticação, é roleta.

Vale registrar um detalhe que eu quase deixei passar nesse mesmo alvo. O endpoint respondia 403 quando o `User-Agent` era `okhttp/4.12.0`, o default da lib HTTP do Android. Troquei pra `Mozilla/5.0` e veio 200. O WAF estava filtrando a assinatura de cliente automatizado, não o conteúdo do request. A proteção inteira se resumia a "parece um navegador?". WAF que filtra por User-Agent não filtra nada.

Nem toda confirmação é por request HTTP. Em outro app, a vuln era um push do Firebase mal validado. O serviço de mensagens recebia o push, fazia um `sendBroadcast`, um `BroadcastReceiver` exportado pegava, e a partir dali subia um foreground service que ligava o GPS. Eu confirmei lendo o logcat enquanto disparava o push:

```plaintext
FirebaseMsg  onMessageReceived data={tipo=corrida, id=...}
LocReceiver  broadcast app.update.pushmessage recebido
ActivityMgr  Background started FGS: LocationService
LocationSvc  requestLocationUpdates PRIORITY_HIGH_ACCURACY 500ms
```

O logcat é um tracer que já está ligado. Quatro linhas, e dá pra ver a entrada externa atravessar o app inteiro até acionar um sensor. Pra componente exportado, a mesma ideia vale com `adb shell am start`. Você dispara a Activity de fora, com a Intent que quiser, e lê no logcat o que ela faz. Se uma Activity exportada aceita um `file://` na Intent e abre o arquivo, mandar `file:///data/data/<pacote>/databases/algo.db` e ver no log que ela tentou ler aquele caminho privado é prova suficiente de exposição.

Pra chave RSA extraída de firmware, como mostrei mais atrás, a confirmação é matemática e passiva. Você compara a chave embarcada com uma assinatura capturada do tráfego legítimo, e nem toca no equipamento.

## As ferramentas, e por que essas

Pra interceptação HTTP eu uso mitmproxy bem mais que Burp. Burp ganha quando eu preciso de uma cadeia interativa longa, modificando request a request no Repeater. Mitmproxy ganha em captura passiva, em scripting (você escreve addon em Python) e em rodar no terminal, sem GUI, de forma persistente em background enquanto eu uso o app normalmente. Quando eu quero olhar request específico, o `mitmweb` me dá a interface.

Pra emular binário ARM ou MIPS quando o equipamento real não está na mão, `qemu-user-static` resolve os casos simples, utilitário standalone e função isolada, e o FirmAE tenta o firmware inteiro. FirmAE não é mágica e falha em mais da metade dos firmwares que eu testo, mas quando funciona economiza dias.

O resto da bancada não muda muito de projeto pra projeto. Radare2 com r2pipe e Ghidra pra estática de binário. Binwalk e unblob pra extrair filesystem. Jadx e apktool pro lado Android, mais hermes-dec quando o app é React Native com bundle Hermes. Openssl e pycryptodome pra reproduzir cripto custom. Frida pra hook em runtime. Ffuf quando preciso de fuzzing rápido de parâmetro. A linguagem de cola é Python, com Go raríssimo quando performance importa de verdade. C eu só leio, nunca escrevo.

## Três cadeias

As CVEs de que eu mais gosto raramente são bug isolado. São cadeias. A vulnerabilidade A sozinha é Medium, a B sozinha é Low, e A mais B é RCE remoto sem autenticação. É o tipo de coisa que mostra que o pesquisador entendeu o sistema, e não só rodou um grep com sorte.

Sei que tem gente que vai discordar. Bug bounty costuma pagar melhor por uma critical isolada do que por uma chain explicada, e tem analista que prefere submeter as vulns separadas pra maximizar payout. Não é errado. Pra disclosure responsável e pra portfólio técnico, a cadeia conta mais. Pra programa de bounty com payout escalonado, talvez não. Vou descrever três, com identificadores trocados, só pra mostrar a forma do raciocínio.

**Do APK ao banco de clientes.** App interno de técnico de campo, distribuído publicamente na loja. Baixo, rodo jadx. Numa classe central acho dois métodos curtos que retornam usuário e senha de um Basic Auth da API. Monto o header e bato num endpoint qualquer de health: 200. A credencial está viva em produção. Testo o endpoint de login do app com usuário e senha inventados, e ele responde `{"Valido":true}`. Testo com strings vazias, mesma resposta. O login do app é teatro. Aí eu chego no que importa: um endpoint que lista os atendimentos de um técnico, recebendo o ID do técnico na URL, e cada atendimento traz nome completo do cliente, documento, endereço, e credencial de rede. Itero o ID de 1 a 1000, sem rate limit, sem detecção de anomalia. Cada passo é uma vuln conhecida, credencial embarcada, autenticação quebrada, IDOR, falta de rate limit. O impacto real só aparece quando você encadeia, e você só encadeia se trata cada resposta como pista pra próxima requisição.

**Reset de senha sem autenticação.** App de cliente final, React Native com bundle Hermes. Bytecode Hermes é mais chato que Java, mas decompila com `hermes-dec`, e a tabela de strings já me entregou a URL base da API. Capturo no mitmproxy o fluxo de "esqueci minha senha" e vejo um POST simples com o documento do usuário no corpo, sem token, sem nonce, sem captcha. Testo com o meu próprio documento e recebo um SMS na hora com senha nova, a antiga invalidada. Testo com um documento aleatório válido e a resposta é diferente de quando o documento não existe, o que transforma o endpoint num oráculo de enumeração. A cadeia completa é enumerar, resetar a senha do alvo, e quem tiver como ler o SMS do alvo toma a conta. Quem não tiver, pelo menos derruba o acesso da vítima. PoC só contra a minha própria conta. Não enumerei terceiros.

**Do firmware ao MitM da operadora.** Essa é a que está em embargo, então vai em prosa e sem identificar nada. Modem GPON de fabricante grande, mesmo firmware em milhões de assinantes. Comecei pelo config.bin do meu equipamento, descriptografado, e o XML expôs a URL HTTP do firmware no servidor da operadora, sem TLS e sem autenticação. Binwalk, e o filesystem inteiro estava na minha frente. As seções acima são todas desse caso: o cofre de credencial cifrado com a chave que estava do lado, o par de chaves RSA do "anti-CSRF". Junte a isso uma chave privada de TLS que abre com uma passphrase do cofre, e um certificado servidor que é o mesmo em todo equipamento do modelo. Com posicionamento de rede adequado, dá pra fazer MitM de TLS contra qualquer assinante, porque o navegador da vítima confia no certificado que também é o do roteador dela. Some o command injection do diagnóstico, e a cadeia fecha em shell root no equipamento de qualquer cliente. Cada peça dessa eu achei numa sessão diferente, em semanas diferentes, e foi só montando o quebra-cabeça que a gravidade apareceu. Sai detalhado em julho.

## O tempo, que é o recurso de verdade

Eu tenho família, trabalho com gestão de vulnerabilidade de dia, e faço pesquisa nessas brechas e nas madrugadas. Tempo de pesquisa compete direto com tempo de família e com sono. Não tem como romantizar isso. O que eu tenho é um workflow apertado, escrito ao longo dos meses na base de descobrir o que funciona.

A primeira sessão, de duas a três horas, é aquisição e mapa do território. Baixar o firmware ou o APK, extrair, rodar os greps iniciais, identificar os pontos quentes. No fim dela eu já tenho uma lista priorizada do que olhar.

As sessões seguintes são análise estática profunda, cada uma focada num binário ou num conjunto de arquivos relacionados. Aqui eu uso o método de "deixa pro próximo". No fim de cada sessão eu escrevo, num `notes.md`, exatamente onde parei e o que eu ia olhar a seguir. Sem isso eu perderia meia hora no início de cada sessão tentando lembrar o contexto. Esse arquivo foi o meu maior ganho de produtividade dos últimos dois anos, e não é exagero. Quando você só tem noventa minutos por noite, perder trinta deles pra se reorientar é insustentável. Boa parte do trabalho braçal dessa fase, listar componente exportado, marcar o que precisa de confirmação dinâmica, eu hoje deixo num pipeline meu de triagem, que faz a primeira varredura e me entrega o mapa pronto pra eu decidir onde cavar.

As sessões de confirmação dinâmica vêm só depois que eu tenho boa convicção estática. Setup do ambiente, testes mínimos, PoC documentado. A redação do report é uma sessão à parte, porque eu não consigo redigir bem alternando com análise. Boto música, abro o template, escrevo do começo ao fim. O ciclo completo de uma vulnerabilidade não-trivial fica entre 20 e 60 horas pra mim. Cadeia grande passa fácil de 100.

## Onde isso vai

Tem um caso meu em embargo que vai render bastante quando puder sair, são 9 CVEs reportadas mas apenas 4 o vendor confirmou. Endereços, disassembly, payload, scripts de PoC, e o timeline inteiro do disclosure. É material denso o suficiente pra virar uma série, não só um post, e eu volto aqui pra escrever quando o embargo cair.

Por enquanto, se você está começando agora em engenharia reversa, o conselho é direto. Pega um equipamento que você já tem em casa, o roteador da operadora, uma câmera IP, uma smart TV (quanto 'menor' a marca, melhor). Abre o firmware. Faz os três greps. Você vai achar coisa. Toda vez.

Se quiser trocar ideia sobre algum projeto, ou tem dúvida específica de workflow, me chama no Discord, `@privescalation`.

Até a próxima =)

t1m3

{% endraw %}
