/**
 * Renders each bot's BoopFace (MIT, CX ArtLab; ios/T3Bot/BoopFace) to avatars/<id>.png with headless Chrome.
 * Each bot wears one of the 188 skins (`face.skin` in the config the server uses), picked to look nothing like
 * the others. `bun tools/faces/render.ts --skins` renders the whole catalogue for the app's picker.
 *   bun tools/faces/render.ts [id ...]        (all bots when no id)
 * The iPhone app draws the same face live (ios/T3Bot/Face.swift); these PNGs are for lists and the server.
 * Needs Google Chrome or Chromium ($CHROME names another binary). Without one nothing is drawn and the server
 * shows the skin's stock picture from avatars/skins instead.
 */
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { configPath } from '../../server/config'

const ROOT = join(import.meta.dir, '../..')
const CHROME = [process.env.CHROME, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium',
  Bun.which('google-chrome'), Bun.which('chromium'), Bun.which('chromium-browser')].find((p): p is string => !!p && existsSync(p)) ?? ''
const lib = readFileSync(join(ROOT, 'ios/T3Bot/BoopFace/boopface.iife.js'), 'utf8')
function needChrome() {
  if (CHROME) return
  console.error('No Chrome or Chromium found (set CHROME to its binary). Nothing was drawn.')
  process.exit(3)
}

export function facePage(face: { skin: string }, size: number, state = 'idle') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent;overflow:hidden}
  body{display:flex;align-items:center;justify-content:center;width:${size}px;height:${size}px}</style></head><body>
  <boop-face id="f" size="${Math.round(size * 0.86)}" skin="${face.skin}" motion="reduce" auto-sleep="0"></boop-face>
  <script>${lib}</script>
  <script>
    const f = document.getElementById('f');
    ${state !== 'idle' ? `setTimeout(() => f.play(${JSON.stringify(state)}), 60);` : ''}
  </script></body></html>`
}

if (import.meta.main) process.argv.includes('--skins') ? catalogue() : main()

/** Every skin as a 128 px thumbnail in avatars/skins/<number>.png: one page, one screenshot, cut with magick. */
function catalogue() {
  needChrome()
  const skins: { n: string }[] = JSON.parse(readFileSync(join(import.meta.dir, 'skins.json'), 'utf8'))
  const cols = 14, cell = 128, rows = Math.ceil(skins.length / cols)
  const work = mkdtempSync(join(tmpdir(), 't3bot-skins-'))
  const html = join(work, 'all.html')
  writeFileSync(html, `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent}
    body{display:grid;grid-template-columns:repeat(${cols},${cell}px);grid-auto-rows:${cell}px}
    div{display:flex;align-items:center;justify-content:center}</style></head><body>
    ${skins.map((s) => `<div><boop-face size="110" skin="${s.n}" motion="reduce" auto-sleep="0"></boop-face></div>`).join('')}
    <script>${lib}</script></body></html>`)
  const atlas = join(work, 'atlas.png')
  Bun.spawnSync([CHROME, '--headless=new', `--user-data-dir=${join(work, 'profile')}`, '--hide-scrollbars', '--default-background-color=00000000',
    `--window-size=${cols * cell},${rows * cell}`, '--virtual-time-budget=6000', `--screenshot=${atlas}`, `file://${html}`])
  const dir = join(ROOT, 'avatars/skins')
  Bun.spawnSync(['mkdir', '-p', dir])
  Bun.spawnSync(['magick', atlas, '-crop', `${cell}x${cell}`, '+repage', join(work, 'tile_%03d.png')])
  skins.forEach((s, i) => Bun.spawnSync(['mv', join(work, `tile_${String(i).padStart(3, '0')}.png`), join(dir, `${s.n}.png`)]))
  rmSync(work, { recursive: true, force: true })
  console.log(`${skins.length} skins in ${dir}`)
}

function main() {
needChrome()
// The same config the server reads: $T3BOT_CONFIG, then ~/.config/t3bot/agents.json, then config/agents.json here.
let cfg: { agents?: { id: string; face?: { skin: string } }[] } = {}
try { cfg = JSON.parse(readFileSync(configPath(), 'utf8')) } catch { console.error(`No readable config at ${configPath()}. Nothing was drawn.`); process.exit(1) }
const ids = process.argv.slice(2)
const work = mkdtempSync(join(tmpdir(), 't3bot-faces-'))
for (const a of cfg.agents ?? []) {
  if (ids.length && !ids.includes(a.id)) continue
  if (!a.face) continue
  const html = join(work, `${a.id}.html`)
  writeFileSync(html, facePage(a.face, 512))
  const out = join(ROOT, 'avatars', `${a.id}.png`)
  const p = Bun.spawnSync([CHROME, '--headless=new', `--user-data-dir=${join(work, 'profile')}`, '--hide-scrollbars',
    '--default-background-color=00000000', '--window-size=512,512', '--virtual-time-budget=2500', `--screenshot=${out}`, `file://${html}`])
  console.log(a.id, p.exitCode === 0 ? 'ok' : p.stderr.toString().slice(-200))
}
rmSync(work, { recursive: true, force: true })
}
