/**
 * A small QR code encoder with no dependencies, for `t3bot pair`: byte mode, error correction level L, versions 1 to 40.
 * The method follows Project Nayuki's QR Code generator (MIT License, https://www.nayuki.io/page/qr-code-generator-library).
 *
 * MIT License. Permission is hereby granted, free of charge, to any person obtaining a copy of this file to deal in
 * it without restriction, including the rights to use, copy, modify, merge, publish, distribute, sublicense and sell
 * copies. The software is provided "as is", without warranty of any kind.
 */

// Level L, indexed by version (index 0 unused).
const ECC_PER_BLOCK = [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
const BLOCKS = [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25]

function rawModules(ver: number): number {
  let n = (16 * ver + 128) * ver + 64
  if (ver >= 2) {
    const align = Math.floor(ver / 7) + 2
    n -= (25 * align - 10) * align - 55
    if (ver >= 7) n -= 36
  }
  return n
}
const dataCodewords = (ver: number) => Math.floor(rawModules(ver) / 8) - ECC_PER_BLOCK[ver] * BLOCKS[ver]

// Reed-Solomon over GF(2^8) with the QR polynomial 0x11D.
function mul(x: number, y: number): number {
  let z = 0
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d)
    z ^= ((y >>> i) & 1) * x
  }
  return z & 0xff
}
function divisor(degree: number): number[] {
  const out = new Array<number>(degree).fill(0)
  out[degree - 1] = 1
  let root = 1
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      out[j] = mul(out[j], root)
      if (j + 1 < degree) out[j] ^= out[j + 1]
    }
    root = mul(root, 2)
  }
  return out
}
function remainder(data: number[], div: number[]): number[] {
  const out = new Array<number>(div.length).fill(0)
  for (const b of data) {
    const factor = b ^ (out.shift() as number)
    out.push(0)
    div.forEach((coef, i) => { out[i] ^= mul(coef, factor) })
  }
  return out
}

function alignmentPositions(ver: number): number[] {
  if (ver === 1) return []
  const size = ver * 4 + 17
  const n = Math.floor(ver / 7) + 2
  const step = ver === 32 ? 26 : Math.ceil((ver * 4 + 4) / (n * 2 - 2)) * 2
  const out = [6]
  for (let pos = size - 7; out.length < n; pos -= step) out.splice(1, 0, pos)
  return out
}

/** The code as rows of modules, true for a dark one. Throws when the text is too long for a QR code. */
export function qrModules(text: string): boolean[][] {
  const bytes = Array.from(new TextEncoder().encode(text))
  let ver = 1
  for (; ver <= 40; ver++) {
    if (4 + (ver < 10 ? 8 : 16) + bytes.length * 8 <= dataCodewords(ver) * 8) break
  }
  if (ver > 40) throw new Error('too long for a QR code')
  const size = ver * 4 + 17

  // The bit stream: mode, length, data, terminator, padding.
  const bits: number[] = []
  const put = (value: number, len: number) => { for (let i = len - 1; i >= 0; i--) bits.push((value >>> i) & 1) }
  put(4, 4)
  put(bytes.length, ver < 10 ? 8 : 16)
  for (const b of bytes) put(b, 8)
  const capacity = dataCodewords(ver) * 8
  put(0, Math.min(4, capacity - bits.length))
  put(0, (8 - (bits.length % 8)) % 8)
  for (let pad = 0xec; bits.length < capacity; pad ^= 0xec ^ 0x11) put(pad, 8)
  const data: number[] = []
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0))

  // Error correction blocks, interleaved.
  const numBlocks = BLOCKS[ver], eccLen = ECC_PER_BLOCK[ver]
  const rawCodewords = Math.floor(rawModules(ver) / 8)
  const numShort = numBlocks - (rawCodewords % numBlocks)
  const shortLen = Math.floor(rawCodewords / numBlocks)
  const div = divisor(eccLen)
  const blocks: number[][] = []
  for (let i = 0, k = 0; i < numBlocks; i++) {
    const dat = data.slice(k, k + shortLen - eccLen + (i < numShort ? 0 : 1))
    k += dat.length
    const ecc = remainder(dat, div)
    if (i < numShort) dat.push(0)
    blocks.push(dat.concat(ecc))
  }
  const codewords: number[] = []
  for (let i = 0; i < blocks[0].length; i++) {
    blocks.forEach((block, j) => { if (i !== shortLen - eccLen || j >= numShort) codewords.push(block[i]) })
  }

  const dark: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false))
  const fixed: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false))
  const set = (x: number, y: number, on: boolean) => { dark[y][x] = on; fixed[y][x] = true }

  // Timing, finder and alignment patterns.
  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0) }
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const x = cx + dx, y = cy + dy, dist = Math.max(Math.abs(dx), Math.abs(dy))
      if (x >= 0 && x < size && y >= 0 && y < size) set(x, y, dist !== 2 && dist !== 4)
    }
  }
  const align = alignmentPositions(ver)
  align.forEach((ax, i) => align.forEach((ay, j) => {
    const last = align.length - 1
    if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1)
  }))

  const drawFormat = (mask: number) => {
    const info = (1 << 3) | mask // level L is 01
    let rem = info
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537)
    const f = ((info << 10) | rem) ^ 0x5412
    const bit = (i: number) => ((f >>> i) & 1) !== 0
    for (let i = 0; i <= 5; i++) set(8, i, bit(i))
    set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i))
    for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i))
    for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i))
    set(8, size - 8, true)
  }
  drawFormat(0)
  if (ver >= 7) {
    let rem = ver
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25)
    const v = (ver << 12) | rem
    for (let i = 0; i < 18; i++) {
      const on = ((v >>> i) & 1) !== 0, a = size - 11 + (i % 3), b = Math.floor(i / 3)
      set(a, b, on); set(b, a, on)
    }
  }

  // The codewords, in the zigzag from the bottom right.
  let n = 0
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j, upward = ((right + 1) & 2) === 0, y = upward ? size - 1 - vert : vert
        if (!fixed[y][x] && n < codewords.length * 8) {
          dark[y][x] = ((codewords[n >>> 3] >>> (7 - (n & 7))) & 1) !== 0
          n++
        }
      }
    }
  }

  const MASKS: ((x: number, y: number) => boolean)[] = [
    (x, y) => (x + y) % 2 === 0, (_x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0, (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
  ]
  const applyMask = (m: number) => {
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fixed[y][x] && MASKS[m](x, y)) dark[y][x] = !dark[y][x]
  }
  // The mask that leaves the fewest long runs, 2x2 blocks and finder look-alikes, and the best balance.
  const penalty = (): number => {
    let p = 0
    const lines: string[] = []
    for (let i = 0; i < size; i++) {
      lines.push(dark[i].map((d) => (d ? '1' : '0')).join(''))
      lines.push(dark.map((row) => (row[i] ? '1' : '0')).join(''))
    }
    for (const line of lines) {
      for (const run of line.match(/0{5,}|1{5,}/g) ?? []) p += run.length - 2
      for (const pattern of ['10111010000', '00001011101']) {
        for (let at = line.indexOf(pattern); at >= 0; at = line.indexOf(pattern, at + 1)) p += 40
      }
    }
    let total = 0
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
      if (dark[y][x]) total++
      if (x + 1 < size && y + 1 < size && dark[y][x] === dark[y][x + 1] && dark[y][x] === dark[y + 1][x] && dark[y][x] === dark[y + 1][x + 1]) p += 3
    }
    return p + Math.floor(Math.abs(total * 20 - size * size * 10) / (size * size)) * 10
  }
  let best = 0, bestScore = Infinity
  for (let m = 0; m < 8; m++) {
    applyMask(m); drawFormat(m)
    const score = penalty()
    if (score < bestScore) { bestScore = score; best = m }
    applyMask(m)
  }
  applyMask(best); drawFormat(best)
  return dark
}

/**
 * The code as text for a terminal, two module rows per line. With `color` (the default on a terminal) it is drawn
 * black on white whatever the theme; without, dark modules are full blocks, which reads on a light background, and
 * `invert` flips that for a dark one.
 */
export function qrTerminal(text: string, opts: { color?: boolean; invert?: boolean; margin?: number } = {}): string {
  const modules = qrModules(text)
  const margin = opts.margin ?? 4
  const size = modules.length + margin * 2
  const at = (x: number, y: number) => {
    const d = modules[y - margin]?.[x - margin] ?? false
    return opts.invert && !opts.color ? !d : d
  }
  const lines: string[] = []
  for (let y = 0; y < size; y += 2) {
    let line = ''
    for (let x = 0; x < size; x++) {
      const top = at(x, y), bottom = y + 1 < size ? at(x, y + 1) : !!(opts.invert && !opts.color)
      line += top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' '
    }
    lines.push(opts.color ? `\x1b[38;5;16;48;5;231m${line}\x1b[0m` : line)
  }
  return lines.join('\n')
}
