// Builds the screenshot gallery from gallery.json: resized JPEGs in out/img/, out/index.html, and out/publish-files.json (the Artifact files map). Run: node tools/gallery/build-gallery.mjs   (once: npm install --prefix tools/gallery)
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import sharp from 'sharp'

const here = dirname(fileURLToPath(import.meta.url))
const g = JSON.parse(readFileSync(join(here, 'gallery.json'), 'utf8'))
const shotRoot = resolve(here, g.shotRoot ?? '../../..')
const out = join(here, 'out')
rmSync(join(out, 'img'), { recursive: true, force: true })
mkdirSync(join(out, 'img'), { recursive: true })

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
const missing = [], errors = [], files = {}, chips = [], sections = []
let count = 0

for (const s of g.sections) {
  const figs = []
  for (const [i, [src, caption, kind = 'shot']] of s.shots.entries()) {
    if (s.status === 'merged' && !src.startsWith(`${g.integration}/`)) errors.push(`${s.id}: merged section points into a lane worktree: ${src}`)
    const abs = join(shotRoot, src)
    if (!existsSync(abs)) { missing.push(`${s.id}: ${src}`); continue }
    const name = `img/${s.id}-${i + 1}.jpg`
    const long = kind === 'wide' || kind === 'map' ? 2000 : 1600
    const info = await sharp(abs).resize(long, long, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 72 }).toFile(join(out, name))
    files[name] = join(out, name)
    // width/height stop lazy images from shifting the page, so section links land in the right place
    figs.push(`<figure class="${esc(kind)}"><img src="${name}" width="${info.width}" height="${info.height}" loading="lazy" alt="${esc(caption)}"><figcaption>${esc(caption)}</figcaption></figure>`)
    count++
  }
  const lane = s.status !== 'merged'
  chips.push(`<a href="#${esc(s.id)}"${lane ? ' class="lane"' : ''}>${esc(s.chip ?? s.id)}</a>`)
  sections.push(`<section id="${esc(s.id)}"><h2>${esc(s.title)}</h2>
<p class="meta"><span class="pill${lane ? ' lane' : ''}">${lane ? 'On a lane' : 'Merged'}</span> <code>${esc(s.commit)}</code>${s.cards?.length ? ` · cards ${esc(s.cards.join(', '))}` : ''}</p>
<p>${esc(s.about)}</p><div class="grid">${figs.join('')}</div></section>`)
}

if (errors.length) { console.error(errors.join('\n')); process.exit(1) }

const page = `<title>${esc(g.title)}</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--muted:#57534e;--card:#fff;--line:#e7e5e4;--ok:#15803d;--lane:#b45309}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0c0a09;--fg:#f5f5f4;--muted:#a8a29e;--card:#1c1917;--line:#292524;--ok:#4ade80;--lane:#fbbf24}}
:root[data-theme="dark"]{--bg:#0c0a09;--fg:#f5f5f4;--muted:#a8a29e;--card:#1c1917;--line:#292524;--ok:#4ade80;--lane:#fbbf24}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
nav{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 16px}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chips a{border:1px solid var(--line);border-radius:999px;padding:2px 10px;color:var(--fg);text-decoration:none;font-size:13px}
.chips a.lane{border-style:dashed}
nav button{display:none;width:100%;justify-content:space-between;gap:8px;background:none;border:0;color:var(--fg);font:inherit;padding:6px 0}
#here{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
main{max-width:1200px;margin:0 auto;padding:0 16px 48px}
section{scroll-margin-top:72px;border-top:1px solid var(--line);padding-top:8px}
.meta{color:var(--muted);font-size:13px}
.pill{border:1px solid var(--ok);color:var(--ok);border-radius:999px;padding:0 8px}
.pill.lane{border:1px dashed var(--lane);color:var(--lane)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,360px),1fr));gap:12px}
figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
figure.wide,figure.map{grid-column:1/-1}
figure img{display:block;width:100%;height:auto;cursor:zoom-in}
figure.phone img{width:auto;max-width:100%;max-height:420px;margin:0 auto}
figcaption{padding:8px 10px;font-size:13px;color:var(--muted)}
dialog{padding:0;border:0;background:transparent;max-width:96vw;max-height:96vh}
dialog img{display:block;max-width:96vw;max-height:92vh;width:auto;height:auto}
dialog::backdrop{background:rgb(0 0 0/.8)}
@media (max-width:700px){nav button{display:flex}.chips{display:none}nav.open .chips{display:flex;max-height:60vh;overflow:auto;padding-top:8px}}
</style>
<nav id="nav"><button type="button" aria-expanded="false" aria-controls="chips"><span>Sections</span><span id="here"></span></button><div class="chips" id="chips">${chips.join('')}</div></nav>
<main><h1>${esc(g.title)}</h1><p>${esc(g.intro)}</p>
${sections.join('\n')}
<footer class="meta">${count} shots</footer></main>
<dialog id="zoom"><img alt=""></dialog>
<script>
const nav = document.getElementById('nav'), btn = nav.querySelector('button'), here = document.getElementById('here')
const setOpen = (o) => { nav.classList.toggle('open', o); btn.setAttribute('aria-expanded', String(o)) }
btn.onclick = () => setOpen(!nav.classList.contains('open'))
nav.querySelectorAll('.chips a').forEach((a) => { a.onclick = () => setOpen(false) })
const io = new IntersectionObserver((es) => { for (const e of es) if (e.isIntersecting) here.textContent = e.target.querySelector('h2').textContent }, { rootMargin: '-20% 0px -70% 0px' })
document.querySelectorAll('section').forEach((s) => io.observe(s))
const dlg = document.getElementById('zoom'), big = dlg.querySelector('img')
document.querySelectorAll('figure img').forEach((i) => { i.onclick = () => { big.src = i.src; big.alt = i.alt; dlg.showModal() } })
dlg.onclick = () => dlg.close()
</script>`

writeFileSync(join(out, 'index.html'), page)
writeFileSync(join(out, 'publish-files.json'), JSON.stringify(files, null, 2))
if (missing.length) console.log(`missing (skipped):\n  ${missing.join('\n  ')}`)
console.log(`${count} shots in ${g.sections.length} sections -> ${join(out, 'index.html')}`)
