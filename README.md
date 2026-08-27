# t1m3 — gatonet.club

Blog estático de **hardware hacking / engenharia reversa / análise de firmware**,
em Jekyll, servido pelo **GitHub Pages nativo** (sem GitHub Actions), no domínio
`t1m3.gatonet.club`.

- Repositório (user site): **`digitalgangst4r.github.io`**
- Domínio publicado: **`t1m3.gatonet.club`** (subdomínio) — ver `CNAME`
- Layouts do zero em `_layouts/`, CSS puro em `assets/css/` (sem framework)
- Plugins: `jekyll-feed`, `jekyll-seo-tag` (os permitidos pelo Pages nativo)
- Syntax highlighting: Rouge (tema sóbrio em `assets/css/rouge.css`)

## Estrutura

```
digitalgangst4r.github.io/
├── _config.yml          # config do site (url, permalink /papers/:slug/, plugins)
├── CNAME                # t1m3.gatonet.club  (domínio custom do Pages)
├── Gemfile              # deps de BUILD LOCAL (o Pages usa o builder próprio)
├── index.html           # home: banner ASCII + índice tipo diretório
├── papers.html          # /papers/  — arquivo completo
├── about.md             # /about/
├── pgp.md               # /pgp/     — bloco de chave pública (PLACEHOLDER)
├── 404.html
├── _layouts/            # default, post, page
├── _includes/           # head, header (nav), footer
├── _posts/              # 5 artigos migrados (AAAA-MM-DD-slug.md)
├── assets/
│   ├── css/style.css    # estética + regras de leitura
│   ├── css/rouge.css    # tema de código
│   └── img/<slug>/      # imagens baixadas do CDN do Hashnode (27 arquivos)
└── scripts/migrate.rb   # conversor Hashnode->Jekyll (idempotente)
```

## Rodar localmente

```bash
bundle install
bundle exec jekyll serve      # http://127.0.0.1:4000
```

> **Sobre o build do Pages vs. local.** No GitHub Pages o site é compilado pelo
> ambiente nativo `github-pages` (Jekyll 3.x), que **ignora** a versão de Jekyll
> deste `Gemfile`. Localmente usamos Jekyll 4 porque instala limpo em Ruby novo.
> O site só usa recursos compatíveis com os dois — inclusive o corpo dos posts é
> protegido com `{% raw %}…{% endraw %}` (e **não** com `render_with_liquid`, que
> é Jekyll 4+ e seria ignorado no Pages), porque o código dos artigos contém
> `{{ }}` e `{% %}` (ex.: `awk '{print $1}'`, f-strings, templates) que o Liquid
> corromperia. Se quiser reproduzir o ambiente exato do Pages, veja o comentário
> no `Gemfile` (linha `github-pages`).

## Publicação (GitHub Pages nativo)

1. Criar o repositório **`digitalgangst4r.github.io`** na conta `digitalgangst4r`
   e dar push da branch `main` (ver "passo a passo do push" que te passei).
2. Em **Settings → Pages**: *Source* = **Deploy from a branch**, branch `main`,
   pasta `/ (root)`. (User site já publica de `main` por padrão.)
3. Configurar o DNS (abaixo) e esperar propagar.
4. Em **Settings → Pages → Custom domain**, setar **`t1m3.gatonet.club`** e, depois
   que o check de DNS passar, marcar **Enforce HTTPS**.

## DNS — configurar no registrador do `gatonet.club`

### Principal (é o que este repo usa): subdomínio `t1m3.gatonet.club`

Um registro **CNAME**:

| Tipo  | Nome / Host | Valor (destino)                |
|-------|-------------|--------------------------------|
| CNAME | `t1m3`      | `digitalgangst4r.github.io.`   |

- O `Nome/Host` é só `t1m3` (alguns painéis pedem o FQDN `t1m3.gatonet.club`).
- Muitos registradores exigem o **ponto final** no destino: `digitalgangst4r.github.io.`
- O arquivo `CNAME` deste repo contém exatamente `t1m3.gatonet.club` — é o que amarra
  o Pages a esse domínio. Não precisa de registros A para o subdomínio.

### Opcional — apex `gatonet.club` (só se quiser servir/redirecionar o apex também)

Não é necessário para o subdomínio. Se um dia quiser que **`gatonet.club`** (apex)
aponte para um Pages, use os IPs anycast do GitHub:

- 4 registros **A** no apex (`@`):
  ```
  185.199.108.153
  185.199.109.153
  185.199.110.153
  185.199.111.153
  ```
- (opcional, IPv6) 4 registros **AAAA** no apex (`@`):
  ```
  2606:50c0:8000::153
  2606:50c0:8001::153
  2606:50c0:8002::153
  2606:50c0:8003::153
  ```
- `www.gatonet.club` → **CNAME** → `digitalgangst4r.github.io.`

> Atenção: um repositório de Pages só serve **um** domínio custom por vez (o que
> está no arquivo `CNAME`). Servir apex **e** subdomínio ao mesmo tempo exige
> decidir qual é o canônico e, para o outro, um redirect (ex.: regra no
> registrador/CDN). Para este blog, o canônico é `t1m3.gatonet.club`.

## Migração do conteúdo

`scripts/migrate.rb` converteu os 5 `.md` do Hashnode (`/home/t1/hashnode-export/`):
título a partir do `# H1`, frontmatter Jekyll (`layout/title/date/tags/read_min`),
download de todas as imagens do `cdn.hashnode.com` para `assets/img/<slug>/` com
reescrita dos caminhos (dropando `align="center"`), `%%[...]`→blockquote,
`%[url]`→link, e code blocks/tabelas/PoC preservados intactos. É idempotente.

## Ajustes manuais pendentes

- **Gerar a chave PGP** e colar em `pgp.md` (hoje é placeholder) + fingerprint.
- **DNS** conforme acima.
- **Enforce HTTPS** no Pages após o DNS propagar.
- Revisar `about.md` (texto de persona) se quiser.
