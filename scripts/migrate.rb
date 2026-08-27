#!/usr/bin/env ruby
# encoding: UTF-8
# Migração Hashnode -> Jekyll. Idempotente: re-rodar reescreve _posts e
# rebaixa imagens que faltarem. Não reescreve nem resume o conteúdo técnico.

require "fileutils"

SRC   = File.expand_path("../hashnode-export", __dir__ + "/..")
# __dir__ = .../digitalgangst4r.github.io/scripts ; export está em /home/t1
ROOT  = File.expand_path("..", __dir__)                    # repo root
EXPORT = "/home/t1/hashnode-export"
POSTS = File.join(ROOT, "_posts")
IMGDIR = File.join(ROOT, "assets", "img")

FileUtils.mkdir_p(POSTS)

# src, slug, date(com hora p/ ordenar empates), tags
CONFIG = [
  { src: "LDRobot_LR852K.md",   slug: "kabum-smart-900-ldrobot-lr852k",
    date: "2026-08-17 12:00:00 -0300",
    tags: %w[firmware iot reverse-engineering spi-nand tuya] },
  { src: "ZTE_ZXHN_F689_V9.md", slug: "zte-zxhn-f689-v9",
    date: "2026-08-07 12:00:00 -0300",
    tags: %w[firmware roteador cve reverse-engineering] },
  { src: "UART-RE305.md",       slug: "tp-link-re305-uart",
    date: "2026-05-27 12:00:00 -0300",
    tags: %w[firmware uart hardware tp-link] },
  { src: "cheatsheet.md",       slug: "cheatsheet-engenharia-reversa",
    date: "2026-05-22 12:00:00 -0300",
    tags: %w[reverse-engineering cheatsheet firmware android] },
  { src: "rev-eng-aplicada.md", slug: "engenharia-reversa-arm-dalvik",
    date: "2026-05-22 09:00:00 -0300",
    tags: %w[reverse-engineering arm dalvik android] },
]

failures = []   # [{slug:, url:}]
report   = []   # linhas de resumo

def yaml_escape(s)
  '"' + s.gsub("\\", "\\\\\\\\").gsub('"', '\"') + '"'
end

def ext_for(url)
  path = url.split("?").first.split("#").first
  e = File.extname(path).downcase
  e = ".png" if e.empty? || e.length > 5
  e
end

def download(url, dest)
  return :exists if File.exist?(dest) && File.size(dest) > 0
  ok = system("curl", "-sS", "-L", "--fail", "--max-time", "60",
              "-o", dest, url, out: File::NULL, err: File::NULL)
  if ok && File.exist?(dest) && File.size(dest) > 0
    :ok
  else
    File.delete(dest) if File.exist?(dest) && File.size(dest) == 0
    :fail
  end
end

IMG_RE = /!\[(.*?)\]\(\s*([^)\s]+)(?:\s+[^)]*)?\)/m

CONFIG.each do |c|
  src = File.join(EXPORT, c[:src])
  raise "faltando #{src}" unless File.exist?(src)
  body = File.read(src, encoding: "UTF-8")

  # 1) título = primeiro H1; remove a linha do corpo
  title = nil
  body = body.sub(/\A\s*/, "")
  if body =~ /\A\#\s+(.+?)\s*\r?\n/
    title = $1.strip
    body  = body.sub(/\A\#\s+.+?\r?\n/, "")
  else
    title = c[:slug]
  end
  body = body.sub(/\A\s*\r?\n+/, "")   # tira linhas em branco iniciais

  # 2) imagens: baixa e reescreve caminho (dropando align="center")
  destdir = File.join(IMGDIR, c[:slug])
  img_ok = 0; img_kept = 0; idx = 0
  body = body.gsub(IMG_RE) do
    alt = $1.to_s; url = $2
    unless url =~ %r{\Ahttps?://}i
      next $&           # já é caminho local; deixa
    end
    idx += 1
    fname = format("img-%02d%s", idx, ext_for(url))
    FileUtils.mkdir_p(destdir)
    dest = File.join(destdir, fname)
    st = download(url, dest)
    if st == :fail
      failures << { slug: c[:slug], url: url }
      img_kept += 1
      "![#{alt}](#{url})"                       # mantém remoto
    else
      img_ok += 1
      "![#{alt}](/assets/img/#{c[:slug]}/#{fname})"
    end
  end

  # 3) callouts %%[...] -> blockquote ; embeds %[url] -> link
  body = body.gsub(/^%%\[(.+?)\]\s*$/m) { "> #{$1.strip}" }
  body = body.gsub(/(?<!%)%\[(.+?)\]/m) do
    inner = $1.strip
    "[#{inner}](#{inner})"
  end

  # 4) reading time (inclui código; ~200 wpm)
  words = body.split(/\s+/).reject(&:empty?).size
  read_min = [(words / 200.0).ceil, 1].max

  # 5) frontmatter
  cover = nil
  first = File.join(destdir, "img-01#{ext_for("x.png")}")
  Dir.glob(File.join(destdir, "img-01.*")).each { |f| cover = "/assets/img/#{c[:slug]}/#{File.basename(f)}" }

  fm  = +"---\n"
  fm << "layout: post\n"
  fm << "title: #{yaml_escape(title)}\n"
  fm << "date: #{c[:date]}\n"
  fm << "tags: [#{c[:tags].join(', ')}]\n"
  fm << "read_min: #{read_min}\n"
  fm << "image: #{cover}\n" if cover
  fm << "---\n\n"

  # 6) Protege o corpo do processamento de Liquid. Os posts têm código com
  #    {{ }} e {% %} (awk '{print $1}', templates, hexdumps). {% raw %} é
  #    compatível com o Jekyll 3.x do GitHub Pages nativo (ao contrário de
  #    render_with_liquid, que é Jekyll 4+ e seria ignorado no Pages).
  body_wrapped = "{% raw %}\n#{body}\n{% endraw %}\n"

  date_prefix = c[:date][0, 10]
  out = File.join(POSTS, "#{date_prefix}-#{c[:slug]}.md")
  File.write(out, fm + body_wrapped)

  report << { slug: c[:slug], title: title, out: File.basename(out),
              words: words, read_min: read_min,
              img_ok: img_ok, img_kept: img_kept, cover: !cover.nil? }
end

puts "== MIGRAÇÃO =="
report.each do |r|
  puts "- #{r[:out]}"
  puts "    title    : #{r[:title]}"
  puts "    palavras : #{r[:words]}  (~#{r[:read_min]} min)"
  puts "    imagens  : #{r[:img_ok]} baixadas, #{r[:img_kept]} mantidas remotas, cover=#{r[:cover]}"
end
puts
if failures.empty?
  puts "IMAGENS: todas baixadas com sucesso."
else
  puts "IMAGENS QUE FALHARAM (#{failures.size}) — mantidas como URL remota:"
  failures.each { |f| puts "  [#{f[:slug]}] #{f[:url]}" }
end
total_ok = report.sum { |r| r[:img_ok] }
total_kept = report.sum { |r| r[:img_kept] }
puts
puts "TOTAL imagens: #{total_ok} baixadas / #{total_kept} remotas / #{total_ok + total_kept} referências"
puts "POSTS gerados: #{report.size}"
