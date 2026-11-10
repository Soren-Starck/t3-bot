/**
 * Stand-in pictures for the demo chats when server/demo-assets/ has no file for them: a tiny rasterizer (flat and
 * rounded rectangles) and a PNG encoder, so the demo needs nothing but this folder to show images.
 */
import { deflateSync } from 'zlib'

type RGB = [number, number, number]
const hex = (h: string): RGB => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)]

class Canvas {
  px: Uint8Array
  constructor(public w: number, public h: number, bg: string) {
    this.px = new Uint8Array(w * h * 3)
    this.rect(0, 0, w, h, bg)
  }
  rect(x: number, y: number, w: number, h: number, color: string, radius = 0) {
    const [r, g, b] = hex(color)
    const x1 = Math.max(0, Math.round(x)), y1 = Math.max(0, Math.round(y))
    const x2 = Math.min(this.w, Math.round(x + w)), y2 = Math.min(this.h, Math.round(y + h))
    for (let py = y1; py < y2; py++) {
      for (let px = x1; px < x2; px++) {
        if (radius) {
          const dx = px < x1 + radius ? x1 + radius - px - 0.5 : px >= x2 - radius ? px - (x2 - radius) + 0.5 : 0
          const dy = py < y1 + radius ? y1 + radius - py - 0.5 : py >= y2 - radius ? py - (y2 - radius) + 0.5 : 0
          if (dx > 0 && dy > 0 && dx * dx + dy * dy > radius * radius) continue
        }
        const i = (py * this.w + px) * 3
        this.px[i] = r; this.px[i + 1] = g; this.px[i + 2] = b
      }
    }
  }
  png(): Uint8Array {
    const raw = new Uint8Array((this.w * 3 + 1) * this.h)
    for (let y = 0; y < this.h; y++) raw.set(this.px.subarray(y * this.w * 3, (y + 1) * this.w * 3), y * (this.w * 3 + 1) + 1)
    const chunk = (type: string, data: Uint8Array) => {
      const out = new Uint8Array(12 + data.length)
      const view = new DataView(out.buffer)
      view.setUint32(0, data.length)
      out.set(new TextEncoder().encode(type), 4)
      out.set(data, 8)
      view.setUint32(8 + data.length, Bun.hash.crc32(out.subarray(4, 8 + data.length)))
      return out
    }
    const head = new Uint8Array(13)
    const hv = new DataView(head.buffer)
    hv.setUint32(0, this.w); hv.setUint32(4, this.h)
    head[8] = 8; head[9] = 2
    const parts = [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', head), chunk('IDAT', new Uint8Array(deflateSync(raw))), chunk('IEND', new Uint8Array(0))]
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
    let at = 0
    for (const p of parts) { out.set(p, at); at += p.length }
    return out
  }
}

const INK = '#1f2937', SOFT = '#e5e7eb', MUTED = '#9ca3af', PAPER = '#ffffff', BLUE = '#2c98e2', GREEN = '#40c49b'

/** A bar chart: pairs of bars (before in grey, after in color), or single bars when `before` is empty. */
function chart(after: number[], before: number[], color: string): Uint8Array {
  const c = new Canvas(720, 420, PAPER)
  c.rect(40, 36, 220, 14, INK, 7)
  c.rect(40, 62, 140, 9, MUTED, 4)
  for (let i = 0; i < 4; i++) c.rect(40, 110 + i * 70, 640, 1, SOFT)
  const slot = 640 / after.length, top = 110, floor = 360
  after.forEach((v, i) => {
    const x = 40 + i * slot + slot * 0.18, w = before.length ? slot * 0.28 : slot * 0.64
    if (before.length) {
      const h0 = (floor - top) * before[i]
      c.rect(x, floor - h0, w, h0, '#cbd5e1', 6)
    }
    const h = (floor - top) * v
    c.rect(before.length ? x + w + 6 : x, floor - h, w, h, color, 6)
    c.rect(40 + i * slot + slot * 0.3, 376, slot * 0.4, 8, SOFT, 4)
  })
  c.rect(40, floor, 640, 2, MUTED)
  return c.png()
}

/** A page wireframe: nav, a short headline, a price card and a button. */
function page(): Uint8Array {
  const c = new Canvas(720, 420, '#f8fafc')
  c.rect(0, 0, 720, 52, PAPER)
  c.rect(0, 52, 720, 1, SOFT)
  c.rect(32, 18, 96, 16, INK, 8)
  for (let i = 0; i < 3; i++) c.rect(470 + i * 76, 22, 52, 9, MUTED, 4)
  c.rect(150, 100, 420, 30, INK, 10)
  c.rect(230, 148, 260, 10, MUTED, 5)
  const cards: [number, string][] = [[70, PAPER], [270, PAPER], [470, PAPER]]
  cards.forEach(([x], i) => {
    c.rect(x - 1, 199, 182, 182, i === 1 ? BLUE : SOFT, 16)
    c.rect(x, 200, 180, 180, PAPER, 15)
    c.rect(x + 20, 222, 70, 10, MUTED, 5)
    c.rect(x + 20, 246, 96, 24, INK, 8)
    for (let k = 0; k < 3; k++) c.rect(x + 20, 288 + k * 16, 120 - k * 14, 7, SOFT, 3)
    c.rect(x + 20, 340, 140, 24, i === 1 ? BLUE : '#e2e8f0', 12)
  })
  return c.png()
}

const cache = new Map<string, Uint8Array>()

/** The generated picture for a demo asset name, or null when the name is not one of ours. */
export function generated(name: string): Uint8Array | null {
  if (cache.has(name)) return cache.get(name)!
  const png = name === 'pricing-speed.png' ? chart([0.35, 0.24, 0.97], [0.9, 0.82, 0.61], GREEN)
    : name === 'revenue.png' ? chart([0.52, 0.58, 0.63, 0.7, 0.79, 0.88], [], BLUE)
    : name === 'revenue-october.png' ? chart([0.58, 0.63, 0.7, 0.75, 0.84, 0.92], [], BLUE)
    : name === 'pricing-preview.png' ? page()
    : null
  if (png) cache.set(name, png)
  return png
}
