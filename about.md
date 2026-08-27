---
layout: page
title: about
permalink: /about/
description: "t1m3: abro hardware, tiro firmware e caço vulnerabilidade."
---

Sou o t1m3. Passo o tempo abrindo hardware pra ver o que tem dentro: roteador da
operadora, robô aspirador, câmera, o que cair na bancada. Solto o firmware, leio
o binário, desmonto o APK, e vou até entender o que aquilo faz de verdade.

Todo device aqui é meu, comprado pra isso. E isso aqui é onde eu anoto o que
encontro. Sem tutorial, sem remédia de PDF.

<div class="minis two">
  <div class="mini">
    <div class="mh">o que eu faço</div>
    <ul>
      <li>Tiro firmware: <b>UART, SPI-NOR/NAND, eMMC, chip-off</b></li>
      <li>Reverto binário: <b>ARM/MIPS nativo, Dalvik/APK</b></li>
      <li>Acho vuln em CPE de operadora, IoT e roteador SOHO</li>
      <li>Reporto pro vendor antes de escrever qualquer coisa</li>
    </ul>
  </div>
  <div class="mini">
    <div class="mh">como eu penso</div>
    <ul>
      <li>Tá embarcado no artefato? Então tá vazado. Chave, credencial, token, tudo</li>
      <li>A mesma chave na frota inteira destranca a frota inteira</li>
      <li>CVE é o que sobra de ler código, não o alvo</li>
      <li>Se cansa a vista ou não vira PoC, não me interessa</li>
    </ul>
  </div>
</div>

## CVEs

Saíram todas de um roteador só, o ZTE ZXHN F689 V9 que a Claro me deu de brinde.
Como cheguei nelas tá no [paper do ZTE](/papers/zte-zxhn-f689-v9/).

<div class="cve-list">
  <div class="cve"><span class="id">CVE-2026-49005</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 2.4</span></div>
  <div class="cve"><span class="id">CVE-2026-49006</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 5.3</span></div>
  <div class="cve"><span class="id">CVE-2026-49007</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 7.5</span></div>
  <div class="cve"><span class="id">CVE-2026-49008</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 6.5</span></div>
</div>

## Fala comigo

Quer me mandar algo sensível? Cifra. O resto pode vir em claro, mas eu prefiro cifrado.

<div class="minis two">
  <div class="mini">
    <div class="mh">pgp</div>
    <ul>
      <li class="kv"><b>t1m3 &lt;t1m3@segfault.net&gt;</b></li>
      <li>Chave e fingerprint em <a href="/pgp/">/pgp</a></li>
    </ul>
  </div>
  <div class="mini">
    <div class="mh">xmpp / omemo</div>
    <ul>
      <li class="kv"><b>redstone@pwned.life</b></li>
      <li>É o jeito mais rápido de me achar</li>
    </ul>
  </div>
</div>
