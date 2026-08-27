---
layout: page
title: about
permalink: /about/
description: t1m3 — pesquisador de hardware hacking, engenharia reversa de firmware e análise de vulnerabilidades.
---

`t1m3` — pesquisador de **hardware hacking**, engenharia reversa de firmware e
análise de vulnerabilidades. Brasil. O que aparece aqui é trabalho de bancada:
soldar UART num extender, dumpar SPI NAND sob lupa, brigar com NFTL, ler ELF
stripado, desmontar bytecode Dalvik — do artefato fechado até o PoC.

<div class="minis two">
  <div class="mini">
    <div class="mh">foco</div>
    <ul>
      <li><b>Extração de firmware</b> — UART, SPI-NOR/NAND, eMMC, chip-off</li>
      <li><b>Engenharia reversa</b> — binário nativo ARM/MIPS, bytecode Dalvik/APK</li>
      <li><b>Descoberta de vulns</b> — CPE de operadora, IoT, roteadores SOHO</li>
      <li><b>Disclosure coordenado</b> — vendor primeiro, prazo, depois o paper</li>
    </ul>
  </div>
  <div class="mini">
    <div class="mh">postura</div>
    <ul>
      <li>Se está <b>embarcado no artefato, está vazado</b> — chave, credencial, token</li>
      <li>Proteção <b>homogênea é ilusão</b>: mesma chave na frota inteira</li>
      <li>CVE é <b>subproduto</b> do trabalho de leitura, não o objetivo</li>
      <li>Nada de remédia de PDF — aqui é o caminho até o PoC</li>
    </ul>
  </div>
</div>

## CVEs

Vulnerabilidades atribuídas, todas no ZTE ZXHN F689 V9 (ONT da Claro Brasil).
Write-up completo em [Vulnerabilidades no Roteador do Meu Provedor](/papers/zte-zxhn-f689-v9/).

<div class="cve-list">
  <div class="cve"><span class="id">CVE-2026-49005</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 2.4</span></div>
  <div class="cve"><span class="id">CVE-2026-49006</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 5.3</span></div>
  <div class="cve"><span class="id">CVE-2026-49007</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 7.5</span></div>
  <div class="cve"><span class="id">CVE-2026-49008</span><span class="tgt">ZTE ZXHN F689 V9</span><span class="cvss">CVSS 6.5</span></div>
</div>

## Contato

Para report sensível, disclosure coordenado ou verificação de autoria, **cifre**.

<div class="minis two">
  <div class="mini">
    <div class="mh">pgp</div>
    <ul>
      <li class="kv"><b>t1m3 &lt;t1m3@segfault.net&gt;</b></li>
      <li>Chave pública e fingerprint em <a href="/pgp/">/pgp</a></li>
    </ul>
  </div>
  <div class="mini">
    <div class="mh">xmpp / omemo</div>
    <ul>
      <li class="kv"><b>redstone@pwned.life</b></li>
      <li>Cifre qualquer coisa que envolva alvo não publicado</li>
    </ul>
  </div>
</div>
