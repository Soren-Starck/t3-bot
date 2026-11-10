/**
 * Text helpers the real server (t3bot.ts) and the demo (demo.ts) share, so the app gets the same previews,
 * search snippets and quick replies from both.
 */

/** Cuts a line at a word boundary and marks the cut with an ellipsis. `max` counts the ellipsis. */
export function clip(t: string, max: number): string {
  if (t.length <= max) return t
  const cut = t.slice(0, max - 1)
  const space = cut.lastIndexOf(' ')
  // A word that fills the room by itself (a path, a link) is cut where the room ends.
  const kept = space > max * 0.6 ? cut.slice(0, space) : cut
  return kept.replace(/[\s·,;:([-]+$/, '') + '…'
}

/** A message as one line of plain text: no code blocks, images, link targets or markdown marks. */
export function plain(s: string, max = 180): string {
  const t = s
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    // The rule under a table's first row is not text, and its cells stay apart.
    .replace(/^[ \t|:-]*-{2,}[ \t|:-]*$/gm, ' ')
    .replace(/\|/g, ' ')
    // Heading and quote marks go where they start a line; "#12" and "a > b" inside a sentence stay.
    .replace(/^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?)+/gm, '')
    .replace(/[*`]/g, '')
    // Underscores that mark emphasis go; the ones inside a name (read_file) stay.
    .replace(/(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  return clip(t, max)
}

/** A command as one line, with every character kept: `|`, `>`, `*` and `_` mean something in a shell. */
export const oneLineCommand = (s: string, max = 120) => clip(s.replace(/\s+/g, ' ').trim(), max)

/** The line a photo sent from the phone becomes in the message to the bot (t3bot.ts, imageLine). */
const IMAGE_LINES = /^[ \t]*\[Image from [^\n]*$/gm
const MD_IMAGE = /!\[[^\]]*\]\([^)]*\)/

/**
 * A message as Home shows it under a bot's name. The lines that stand for attached photos are left out, and a
 * message that was nothing but pictures reads "Photo". `pictures` is for a server that keeps them beside the text.
 */
export function preview(text: string, max = 160, pictures = 0): string {
  const hadPicture = pictures > 0 || MD_IMAGE.test(text) || /^[ \t]*\[Image from /m.test(text)
  const t = plain(text.replace(IMAGE_LINES, ''), max)
  return t || (hadPicture ? 'Photo' : '')
}

// ---------- search snippets ----------

const TABLE_RULE = /^[\s|:-]*-{2,}[\s|:-]*$/
const LIST_ITEM = /^\s*(?:[-*+]|\d+[.)])\s+/

/**
 * A message as one line that keeps apart what stood apart: the cells of a table row by a space, and lines
 * (rows, list items, lines of code, paragraphs) by " · " unless the line before already ends with punctuation.
 * Code keeps its text and loses its fences, so a match inside a code block still shows.
 */
export function oneLine(s: string): string {
  const cleaned = s
    .replace(IMAGE_LINES, '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
  let out = ''
  let prevText = false
  let gap = false
  let inCode = false
  for (const raw of cleaned.split('\n')) {
    if (/^\s*```/.test(raw)) { inCode = !inCode; gap = true; continue }
    if (!raw.trim()) { gap = true; continue }
    if (!inCode && TABLE_RULE.test(raw)) continue
    const isRow = !inCode && /^\s*\|/.test(raw)
    const isItem = !inCode && LIST_ITEM.test(raw)
    const line = (inCode ? raw : (isRow ? raw.replace(/^\s*\|/, '').replace(/\|\s*$/, '').replace(/\s*\|\s*/g, ' ') : raw)
      .replace(LIST_ITEM, '')
      .replace(/^\s*#{1,6}\s+/, '')
      .replace(/^\s*>\s?/, '')
      .replace(/[*`]/g, '')
      // Underscores that mark emphasis go; the ones inside a name (read_file) stay.
      .replace(/(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])/g, ''))
      .replace(/\s+/g, ' ')
      .trim()
    if (!line) continue
    const isText = !isRow && !isItem && !inCode
    if (out) {
      // A paragraph wrapped over several lines is one sentence; punctuation already keeps two lines apart.
      const wrapped = prevText && isText && !gap
      out += wrapped || /[.!?…:,;]$/.test(out) ? ' ' : ' · '
    }
    out += line
    prevText = isText
    gap = false
  }
  return out
}

/**
 * What a search result shows of a message: the words around the first match, starting and ending on a whole
 * word, with an ellipsis at each end that was cut.
 */
export function snippet(text: string, query: string, max = 200): string {
  const flat = oneLine(text)
  if (flat.length <= max) return flat
  const q = query.toLowerCase().replace(/\s+/g, ' ').trim()
  // A match that only exists in the raw markdown (across a mark the line lost) shows the start of the message.
  const hit = Math.max(0, q ? flat.toLowerCase().indexOf(q) : -1)
  const lead = Math.min(60, Math.floor(max / 3))
  let from = Math.max(0, hit - lead)
  if (from > 0 && flat[from - 1] !== ' ') {
    const next = flat.indexOf(' ', from)
    if (next >= 0 && next < hit) from = next + 1
    else {
      // The match sits inside the word at the cut: start at that word when it is close, at the match otherwise.
      const wordStart = flat.lastIndexOf(' ', hit) + 1
      from = hit - wordStart <= lead ? wordStart : hit
    }
  }
  let to = Math.min(flat.length, from + max)
  if (to < flat.length && flat[to] !== ' ') {
    const space = flat.lastIndexOf(' ', to)
    if (space > hit + q.length && space > from) to = space
  }
  // With the end of the message in reach, show more of what came before the match instead of a short line.
  if (to === flat.length && from > 0) {
    const back = Math.max(0, to - max)
    const next = back === 0 ? -1 : flat.indexOf(' ', back)
    from = back === 0 ? 0 : next >= 0 && next < from ? next + 1 : from
  }
  const body = flat.slice(from, to).replace(/^[·\s]+/, '').replace(/[\s·,;:([-]+$/, '')
  return (from > 0 ? '…' : '') + body + (to < flat.length ? '…' : '')
}

// ---------- quick replies ----------

const CHOICE = new RegExp('\\b(?:' + [
  'let me know', 'tell me (?:which|what|if|whether|when|how|where)', 'which (?:one|do you|would you|should)',
  'your call', 'up to you', 'pick one', 'choose (?:one|between)', 'should i', 'shall i', 'do you want',
  'would you like', 'want me to', 'say the word', 'ok(?:ay)? to (?:go|send|ship|merge|proceed)',
].join('|') + ')\\b', 'i')
const QUESTION = /\?["”')\]*_]*$/

/**
 * True when a message ends by asking the person something: a question, or a request to choose. The end is the
 * last two sentences of the last paragraph; when the message closes with a list or a table (the options), the
 * paragraph before it counts too.
 */
export function asks(text: string): boolean {
  const blocks = text
    .replace(/```[\s\S]*?```/g, '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(IMAGE_LINES, '')
    .split(/\n[ \t]*\n/).map((b) => b.trim()).filter(Boolean)
  if (!blocks.length) return false
  const isList = (b: string) => b.split('\n').every((l) => /^\s*(?:[-*+]\s|\d+[.)]\s|\|)/.test(l))
  const last = blocks[blocks.length - 1]
  const tail = isList(last) && blocks.length > 1 ? [blocks[blocks.length - 2]] : [last]
  return tail.some((b) => {
    const sentences = b.replace(/\s+/g, ' ').split(/(?<=[.!?…]["”')\]*_]*)\s+/).filter(Boolean).slice(-2)
    return sentences.some((s) => QUESTION.test(s) || CHOICE.test(s))
  })
}

/**
 * The quick replies under a bot's last answer. Its own suggestions (the "» a · b · c" line) always win. Without
 * them, the person's saved replies show only when the answer asks them something; an answer that asks nothing
 * gets none.
 */
export function quickReplies(text: string, own: string[] | undefined, saved: string[]): string[] | undefined {
  if (own?.length) return own
  return saved.length && asks(text) ? saved : undefined
}
