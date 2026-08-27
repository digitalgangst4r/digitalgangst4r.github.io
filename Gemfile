source "https://rubygems.org"

# ─────────────────────────────────────────────────────────────────────────
# Este Gemfile é só para BUILD LOCAL (bundle exec jekyll serve).
#
# No GitHub Pages o site é compilado pelo builder NATIVO (sem GitHub Actions):
# o Pages usa o próprio ambiente `github-pages` e ignora a versão de Jekyll
# daqui. Como o site só usa plugins permitidos pelo Pages nativo
# (jekyll-feed e jekyll-seo-tag), ele é 100% compatível com esse build.
#
# Localmente usamos Jekyll 4 porque instala limpo em Ruby novo. Se quiser
# reproduzir EXATAMENTE o ambiente do Pages, comente o bloco Jekyll 4 abaixo
# e descomente a linha github-pages (pode exigir um Ruby mais antigo).
# ─────────────────────────────────────────────────────────────────────────

# gem "github-pages", group: :jekyll_plugins   # espelho exato do Pages

gem "jekyll", "~> 4.3"

group :jekyll_plugins do
  gem "jekyll-feed",     "~> 0.17"
  gem "jekyll-seo-tag",  "~> 2.8"
end

# Parser GFM do kramdown (fenced code / autolink), igual ao do Pages.
gem "kramdown-parser-gfm", "~> 1.1"

# Ruby 3+ não traz webrick embutido; necessário para `jekyll serve`.
gem "webrick", "~> 1.8"
