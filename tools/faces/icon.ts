// App icon: three bots (the gold Chief in front, a blue and a green one behind) on a flat background,
// in the three iOS appearances: light, dark and tinted (grayscale; iOS applies the tint). bun tools/faces/icon.ts
// Needs Google Chrome (or $CHROME naming a Chromium binary) and ImageMagick's `magick`.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
const ROOT = join(import.meta.dir, '../..')
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const lib = readFileSync(join(ROOT, 'ios/T3Bot/BoopFace/boopface.iife.js'), 'utf8')
const SET = join(ROOT, 'ios/T3Bot/Assets.xcassets/AppIcon.appiconset')
const face = (skin: string, size: number, x: number, y: number, z: number) =>
  `<boop-face skin="${skin}" size="${size}" motion="reduce" auto-sleep="0" style="position:absolute;left:${x}px;top:${y}px;z-index:${z}"></boop-face>`
const bots = face('401', 430, 40, 300, 1) + face('403', 430, 554, 300, 1) + face('902', 600, 212, 300, 2)
const variants: [string, string, string][] = [['icon.png', '#ffffff', ''], ['icon-dark.png', '#101014', ''], ['icon-tinted.png', '#000000', 'filter:grayscale(1) contrast(1.1)']]
const work = mkdtempSync(join(tmpdir(), 't3bot-icon-'))
for (const [file, bg, filter] of variants) {
  const html = join(work, file + '.html')
  writeFileSync(html, `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:1024px;height:1024px;overflow:hidden;position:relative;background:${bg}}#c{position:absolute;inset:0;${filter}}</style></head><body><div id="c">${bots}</div><script>${lib}</script></body></html>`)
  const out = join(SET, file)
  Bun.spawnSync([CHROME, '--headless=new', `--user-data-dir=${join(work, 'p')}`, '--hide-scrollbars', '--window-size=1024,1024', '--virtual-time-budget=3000', `--screenshot=${out}`, `file://${html}`])
  Bun.spawnSync(['magick', out, '-background', bg, '-alpha', 'remove', '-alpha', 'off', out])
  console.log(file)
}
writeFileSync(join(SET, 'Contents.json'), JSON.stringify({ images: [
  { filename: 'icon.png', idiom: 'universal', platform: 'ios', size: '1024x1024' },
  { appearances: [{ appearance: 'luminosity', value: 'dark' }], filename: 'icon-dark.png', idiom: 'universal', platform: 'ios', size: '1024x1024' },
  { appearances: [{ appearance: 'luminosity', value: 'tinted' }], filename: 'icon-tinted.png', idiom: 'universal', platform: 'ios', size: '1024x1024' },
], info: { author: 'xcode', version: 1 } }, null, 2))
rmSync(work, { recursive: true, force: true })
