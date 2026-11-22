// PowerPoint .pptx reader, written for this client (no third party renderer), loaded on demand.
// It turns a deck into a small slide model that ui/PptxView.tsx draws with plain DOM nodes and
// that pptxThumbnail() paints on a canvas for the attachment card.
//
// What it reads: slide size and order, slide, layout and master backgrounds, the shapes of the
// layout and master that are not placeholders, text (paragraphs, runs, bold, italic, underline,
// strike, size, colour with theme colours and their modifiers, alignment, bullets and numbering,
// spacing, autofit scale), pictures (PNG, JPEG, GIF, BMP, WebP, SVG; EMF, WMF and TIFF are left
// out), solid and linear or radial gradient fills, rect, roundRect, ellipse and a few polygons,
// lines and connectors with arrow heads, tables, groups (child offsets and scale) and the picture
// fallback of embedded objects. Charts, SmartArt, effects, 3D and animations are skipped.
//
// The file comes from a contact, so it is untrusted: the zip reader caps the entry count, the
// size of each part and the total of decompressed bytes (zip bombs), XML with a DOCTYPE is
// refused (entity expansion), slides and shapes are capped, and nothing from the file ever
// becomes markup: the viewer builds React elements and the canvas draws text as text.

export const MAX_SLIDES = 300
export const MAX_TOTAL_BYTES = 200 * 1024 * 1024
const MAX_ENTRIES = 20_000
const MAX_XML_BYTES = 24 * 1024 * 1024
const MAX_ITEMS = 5_000
const MAX_DEPTH = 24
const EMU_PX = 9525

const NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

// ---------------------------------------------------------------------------------------------
// Zip (central directory, stored and deflate entries, inflated with DecompressionStream)

interface ZipEntry {
  method: number
  csize: number
  usize: number
  offset: number
  encrypted: boolean
}

class Zip {
  private used = 0
  private readonly entries = new Map<string, ZipEntry>()

  constructor(private readonly buf: Uint8Array<ArrayBuffer>) {
    const v = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
    let eocd = -1
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) {
      if (v.getUint32(i, true) === 0x06054b50) {
        eocd = i
        break
      }
    }
    if (eocd < 0) throw new Error('not a zip')
    const count = v.getUint16(eocd + 10, true)
    const cdOffset = v.getUint32(eocd + 16, true)
    if (count === 0xffff || cdOffset === 0xffffffff) throw new Error('zip64 is not supported')
    if (count > MAX_ENTRIES) throw new Error('too many entries')
    const dec = new TextDecoder()
    let p = cdOffset
    for (let n = 0; n < count; n++) {
      if (p + 46 > buf.length || v.getUint32(p, true) !== 0x02014b50) throw new Error('bad central directory')
      const flags = v.getUint16(p + 8, true)
      const method = v.getUint16(p + 10, true)
      const csize = v.getUint32(p + 20, true)
      const usize = v.getUint32(p + 24, true)
      const nameLen = v.getUint16(p + 28, true)
      const extraLen = v.getUint16(p + 30, true)
      const commentLen = v.getUint16(p + 32, true)
      const offset = v.getUint32(p + 42, true)
      const name = dec.decode(buf.subarray(p + 46, p + 46 + nameLen)).replace(/^\/+/, '')
      this.entries.set(name, { method, csize, usize, offset, encrypted: (flags & 1) === 1 })
      p += 46 + nameLen + extraLen + commentLen
    }
  }

  has(name: string): boolean {
    return this.entries.has(name)
  }

  async bytes(name: string, cap = MAX_TOTAL_BYTES): Promise<Uint8Array<ArrayBuffer> | null> {
    const e = this.entries.get(name)
    if (!e || e.encrypted) return null
    if (e.usize > cap) return null
    if (this.used + e.usize > MAX_TOTAL_BYTES) throw new Error('deck too large once decompressed')
    const v = new DataView(this.buf.buffer, this.buf.byteOffset, this.buf.byteLength)
    if (e.offset + 30 > this.buf.length || v.getUint32(e.offset, true) !== 0x04034b50) return null
    const start = e.offset + 30 + v.getUint16(e.offset + 26, true) + v.getUint16(e.offset + 28, true)
    const raw = this.buf.subarray(start, start + e.csize)
    let out: Uint8Array<ArrayBuffer>
    if (e.method === 0) out = raw.slice()
    else if (e.method === 8) out = await inflateRaw(raw, e.usize)
    else return null
    this.used += out.length
    return out
  }

  async text(name: string): Promise<string | null> {
    const b = await this.bytes(name, MAX_XML_BYTES)
    return b ? new TextDecoder().decode(b) : null
  }
}

/** Raw deflate, stopped as soon as the output passes the size the zip declared. */
async function inflateRaw(data: Uint8Array<ArrayBuffer>, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  const ds = new DecompressionStream('deflate-raw')
  const writer = ds.writable.getWriter()
  writer.write(data).catch(() => {})
  writer.close().catch(() => {})
  const reader = ds.readable.getReader()
  const chunks: Uint8Array[] = []
  let n = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    n += value.length
    if (n > limit) {
      await reader.cancel().catch(() => {})
      throw new Error('entry larger than declared')
    }
    chunks.push(value)
  }
  const out = new Uint8Array(n)
  let o = 0
  for (const c of chunks) {
    out.set(c, o)
    o += c.length
  }
  return out
}

// ---------------------------------------------------------------------------------------------
// XML helpers (namespace prefixes vary between producers: match on local names)

function parseXml(text: string | null): Document | null {
  if (!text || /<!DOCTYPE/i.test(text.slice(0, 4096))) return null
  const doc = new DOMParser().parseFromString(text, 'application/xml')
  if (doc.getElementsByTagName('parsererror').length) return null
  return doc
}

function kids(el: Element | null | undefined, name?: string): Element[] {
  if (!el) return []
  const out: Element[] = []
  for (let c = el.firstElementChild; c; c = c.nextElementSibling) if (!name || c.localName === name) out.push(c)
  return out
}

function kid(el: Element | null | undefined, name: string): Element | null {
  if (!el) return null
  for (let c = el.firstElementChild; c; c = c.nextElementSibling) if (c.localName === name) return c
  return null
}

function path(el: Element | null | undefined, ...names: string[]): Element | null {
  let cur: Element | null = el ?? null
  for (const n of names) cur = kid(cur, n)
  return cur
}

function int(el: Element | null | undefined, name: string): number | undefined {
  const v = el?.getAttribute(name)
  if (v === null || v === undefined || v === '') return undefined
  const n = Number(v)
  return Number.isFinite(n) ? n : undefined
}

function bool(el: Element | null | undefined, name: string): boolean | undefined {
  const v = el?.getAttribute(name)
  if (v === null || v === undefined) return undefined
  return v === '1' || v === 'true' || v === 'on'
}

function rAttr(el: Element | null | undefined, name: string): string | null {
  if (!el) return null
  return el.getAttributeNS(NS_R, name) ?? el.getAttribute(`r:${name}`)
}

// ---------------------------------------------------------------------------------------------
// Parts and relationships

interface Rel {
  type: string
  target: string
}

interface Part {
  path: string
  doc: Document
  rels: Map<string, Rel>
}

function dirOf(p: string): string {
  const i = p.lastIndexOf('/')
  return i < 0 ? '' : p.slice(0, i + 1)
}

function resolvePath(base: string, target: string): string {
  if (target.startsWith('/')) return target.slice(1)
  const parts = (dirOf(base) + target).split('/')
  const out: string[] = []
  for (const s of parts) {
    if (s === '..') out.pop()
    else if (s !== '.' && s !== '') out.push(s)
  }
  return out.join('/')
}

async function readPart(zip: Zip, p: string): Promise<Part | null> {
  const doc = parseXml(await zip.text(p))
  if (!doc) return null
  const rels = new Map<string, Rel>()
  const relsPath = `${dirOf(p)}_rels/${p.slice(dirOf(p).length)}.rels`
  const rd = parseXml(await zip.text(relsPath))
  if (rd) {
    for (const r of Array.from(rd.getElementsByTagName('*'))) {
      if (r.localName !== 'Relationship' || r.getAttribute('TargetMode') === 'External') continue
      const id = r.getAttribute('Id')
      const target = r.getAttribute('Target')
      if (id && target) rels.set(id, { type: r.getAttribute('Type') ?? '', target: resolvePath(p, target) })
    }
  }
  return { path: p, doc, rels }
}

function relOfType(part: Part, suffix: string): string | null {
  for (const r of part.rels.values()) if (r.type.endsWith(suffix)) return r.target
  return null
}

// ---------------------------------------------------------------------------------------------
// Colours

type RGB = [number, number, number]

interface Theme {
  colors: Record<string, string>
  major: string
  minor: string
  fills: Element[]
  lines: Element[]
  bgFills: Element[]
}

const PRESET: Record<string, string> = {
  black: '000000', white: 'FFFFFF', red: 'FF0000', green: '008000', blue: '0000FF', yellow: 'FFFF00',
  gray: '808080', grey: '808080', darkGray: 'A9A9A9', lightGray: 'D3D3D3', orange: 'FFA500', purple: '800080',
  navy: '000080', teal: '008080', silver: 'C0C0C0', maroon: '800000', cyan: '00FFFF', magenta: 'FF00FF',
}

function hexRgb(h: string | null | undefined): RGB | null {
  if (!h || !/^[0-9a-fA-F]{6}$/.test(h)) return null
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))
const toLin = (c: number) => {
  const s = c / 255
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}
const fromLin = (l: number) => 255 * (l <= 0.0031308 ? l * 12.92 : 1.055 * l ** (1 / 2.4) - 0.055)

function rgbHsl([r, g, b]: RGB): [number, number, number] {
  const R = r / 255, G = g / 255, B = b / 255
  const max = Math.max(R, G, B), min = Math.min(R, G, B)
  const l = (max + min) / 2
  if (max === min) return [0, 0, l]
  const d = max - min
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  let h = max === R ? (G - B) / d + (G < B ? 6 : 0) : max === G ? (B - R) / d + 2 : (R - G) / d + 4
  h /= 6
  return [h, s, l]
}

function hslRgb([h, s, l]: [number, number, number]): RGB {
  if (s === 0) return [l * 255, l * 255, l * 255]
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s
  const p = 2 * l - q
  const f = (t: number) => {
    t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
    if (t < 1 / 6) return p + (q - p) * 6 * t
    if (t < 1 / 2) return q
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
    return p
  }
  return [f(h + 1 / 3) * 255, f(h) * 255, f(h - 1 / 3) * 255]
}

interface ColorCtx {
  theme: Theme
  clrMap: Record<string, string>
  phClr?: string
}

const COLOR_TAGS = ['srgbClr', 'schemeClr', 'sysClr', 'prstClr', 'scrgbClr', 'hslClr']

/** The first colour child of `parent` as a CSS colour, theme colours and modifiers applied. */
function colorIn(parent: Element | null | undefined, c: ColorCtx): string | null {
  for (const el of kids(parent)) if (COLOR_TAGS.includes(el.localName)) return color(el, c)
  return null
}

function color(el: Element, c: ColorCtx): string | null {
  let rgb: RGB | null = null
  const val = el.getAttribute('val') ?? ''
  switch (el.localName) {
    case 'srgbClr':
      rgb = hexRgb(val)
      break
    case 'sysClr':
      rgb = hexRgb(el.getAttribute('lastClr')) ?? (val === 'window' ? [255, 255, 255] : [0, 0, 0])
      break
    case 'prstClr':
      rgb = hexRgb(PRESET[val])
      break
    case 'scrgbClr':
      rgb = [fromLin((int(el, 'r') ?? 0) / 100000), fromLin((int(el, 'g') ?? 0) / 100000), fromLin((int(el, 'b') ?? 0) / 100000)]
      break
    case 'hslClr':
      rgb = hslRgb([(int(el, 'hue') ?? 0) / 21600000, (int(el, 'sat') ?? 0) / 100000, (int(el, 'lum') ?? 0) / 100000])
      break
    case 'schemeClr': {
      if (val === 'phClr') {
        const m = c.phClr?.match(/^rgba?\((\d+), (\d+), (\d+)/)
        rgb = m ? [+m[1], +m[2], +m[3]] : null
      } else rgb = hexRgb(c.theme.colors[c.clrMap[val] ?? val])
      break
    }
  }
  if (!rgb) return null
  let alpha = 1
  for (const m of kids(el)) {
    const v = (int(m, 'val') ?? 100000) / 100000
    switch (m.localName) {
      case 'alpha':
        alpha = v
        break
      case 'lumMod': {
        const h = rgbHsl(rgb)
        rgb = hslRgb([h[0], h[1], clamp(h[2] * v, 0, 1)])
        break
      }
      case 'lumOff': {
        const h = rgbHsl(rgb)
        rgb = hslRgb([h[0], h[1], clamp(h[2] + v, 0, 1)])
        break
      }
      case 'satMod': {
        const h = rgbHsl(rgb)
        rgb = hslRgb([h[0], clamp(h[1] * v, 0, 1), h[2]])
        break
      }
      case 'tint':
        rgb = rgb.map((x) => fromLin(toLin(x) * v + (1 - v))) as RGB
        break
      case 'shade':
        rgb = rgb.map((x) => fromLin(toLin(x) * v)) as RGB
        break
    }
  }
  const [r, g, b] = rgb.map((x) => Math.round(clamp(x, 0, 255)))
  return alpha < 1 ? `rgba(${r}, ${g}, ${b}, ${+alpha.toFixed(3)})` : `rgb(${r}, ${g}, ${b})`
}

// ---------------------------------------------------------------------------------------------
// Model

export type Fill =
  | { kind: 'none' }
  | { kind: 'solid'; color: string }
  | { kind: 'grad'; css: string; first: string }
  | { kind: 'img'; img: string }

export interface Line {
  color: string
  width: number
  dash?: boolean
  head?: boolean
  tail?: boolean
}

export interface Run {
  text: string
  br?: boolean
  size: number
  b?: boolean
  i?: boolean
  u?: boolean
  strike?: boolean
  caps?: boolean
  color: string
  font?: string
  baseline?: number
}

export interface Para {
  align: 'left' | 'center' | 'right' | 'justify'
  marL: number
  indent: number
  bullet?: { text: string; color?: string; size?: number }
  lineHeight: number
  lineHeightPx?: number
  spaceBefore: number
  spaceAfter: number
  size: number
  runs: Run[]
}

export interface TextBody {
  anchor: 't' | 'ctr' | 'b'
  inset: [number, number, number, number]
  wrap: boolean
  vert?: 'vert' | 'vert270'
  paras: Para[]
}

export interface Box {
  x: number
  y: number
  w: number
  h: number
  rot: number
  flipH: boolean
  flipV: boolean
}

export type Geom = 'rect' | 'roundRect' | 'ellipse' | 'line' | 'triangle' | 'rtTriangle' | 'diamond' | 'parallelogram' | 'hexagon' | 'chevron' | 'homePlate' | 'rightArrow' | 'leftArrow' | 'none'

export interface Cell {
  text: TextBody
  fill?: string
  colSpan: number
  rowSpan: number
  borders: (Line | null)[]
}

export type Item =
  | { t: 'shape'; box: Box; geom: Geom; radius: number; fill: Fill; line: Line | null; text: TextBody | null }
  | { t: 'pic'; box: Box; img: string | null; crop: [number, number, number, number]; line: Line | null }
  | { t: 'table'; box: Box; cols: number[]; rows: { h: number; cells: (Cell | null)[] }[] }

export interface Slide {
  n: number
  hidden: boolean
  bg: Fill
  items: Item[]
}

export interface Deck {
  width: number
  height: number
  slides: Slide[]
  /** Slides in the file; more than slides.length when the cap cut the deck. */
  total: number
  /** Object URL of a picture (cached, revoked by close), null when the format is not shown. */
  imageUrl(img: string): Promise<string | null>
  imageBlob(img: string): Promise<Blob | null>
  close(): void
}

// ---------------------------------------------------------------------------------------------
// Parsing context

interface Ctx extends ColorCtx {
  zip: Zip
  part: Part
  layout: Part | null
  master: Part | null
  defaults: Element | null
  groupFill?: Fill
  count: { n: number }
}

type Tf = (x: number, y: number, w: number, h: number) => [number, number, number, number]
const identity: Tf = (x, y, w, h) => [x, y, w, h]

function readXfrm(x: Element | null, tf: Tf): Box | null {
  const off = kid(x, 'off')
  const ext = kid(x, 'ext')
  if (!off || !ext) return null
  const [X, Y, W, H] = tf(int(off, 'x') ?? 0, int(off, 'y') ?? 0, int(ext, 'cx') ?? 0, int(ext, 'cy') ?? 0)
  return {
    x: X / EMU_PX,
    y: Y / EMU_PX,
    w: Math.max(0, W / EMU_PX),
    h: Math.max(0, H / EMU_PX),
    rot: (int(x, 'rot') ?? 0) / 60000,
    flipH: bool(x, 'flipH') ?? false,
    flipV: bool(x, 'flipV') ?? false,
  }
}

function readFill(parent: Element | null | undefined, c: Ctx): Fill | undefined {
  for (const el of kids(parent)) {
    switch (el.localName) {
      case 'noFill':
        return { kind: 'none' }
      case 'solidFill': {
        const col = colorIn(el, c)
        return col ? { kind: 'solid', color: col } : { kind: 'none' }
      }
      case 'gradFill': {
        const stops = kids(kid(el, 'gsLst'), 'gs')
          .map((gs) => ({ pos: (int(gs, 'pos') ?? 0) / 1000, col: colorIn(gs, c) }))
          .filter((s): s is { pos: number; col: string } => !!s.col)
          .sort((a, b) => a.pos - b.pos)
        if (!stops.length) return { kind: 'none' }
        const list = stops.map((s) => `${s.col} ${+s.pos.toFixed(2)}%`).join(', ')
        const lin = kid(el, 'lin')
        const css = kid(el, 'path') && !lin ? `radial-gradient(circle, ${list})` : `linear-gradient(${+((int(lin, 'ang') ?? 0) / 60000 + 90).toFixed(2)}deg, ${list})`
        return { kind: 'grad', css, first: stops[0].col }
      }
      case 'blipFill': {
        const img = blipPath(el, c)
        return img ? { kind: 'img', img } : { kind: 'none' }
      }
      case 'grpFill':
        return c.groupFill ?? { kind: 'none' }
    }
  }
  return undefined
}

function blipPath(blipFill: Element, c: Ctx): string | null {
  const id = rAttr(kid(blipFill, 'blip'), 'embed')
  return id ? (c.part.rels.get(id)?.target ?? null) : null
}

function readLine(ln: Element | null, c: Ctx): Line | null | undefined {
  if (!ln) return undefined
  const f = readFill(ln, c)
  if (f?.kind === 'none') return null
  const col = f?.kind === 'solid' ? f.color : f?.kind === 'grad' ? f.first : null
  if (!col) return undefined
  const dash = kid(ln, 'prstDash')?.getAttribute('val')
  const end = (n: string) => {
    const t = kid(ln, n)?.getAttribute('type')
    return !!t && t !== 'none'
  }
  return { color: col, width: Math.max(0.75, (int(ln, 'w') ?? 9525) / EMU_PX), dash: !!dash && dash !== 'solid', head: end('headEnd'), tail: end('tailEnd') }
}

/** A theme style reference (fillRef, lnRef): the indexed style drawn in the reference colour. */
function styleRef(ref: Element | null, list: Element[], c: Ctx): { fill?: Fill; line?: Line | null } {
  const idx = int(ref, 'idx') ?? 0
  if (!ref || idx <= 0) return {}
  const phClr = colorIn(ref, c) ?? undefined
  const sub: Ctx = { ...c, phClr }
  const style = list[(idx >= 1000 ? idx - 1001 : idx - 1)] ?? null
  if (ref.localName === 'lnRef') {
    if (!style) return phClr ? { line: { color: phClr, width: 1 } } : {}
    return { line: readLine(style, sub) ?? null }
  }
  const f = style ? readFill(wrap(style), sub) : undefined
  return { fill: f ?? (phClr ? { kind: 'solid', color: phClr } : undefined) }
}

/** readFill looks at children: give a lone fill element a parent to look into. */
function wrap(el: Element): Element {
  const doc = el.ownerDocument
  const box = doc.createElementNS(null, 'wrap')
  box.appendChild(el.cloneNode(true))
  return box
}

// ---------------------------------------------------------------------------------------------
// Placeholders and text styles

interface PhInfo {
  type: string
  idx?: string
}

function phOf(el: Element): PhInfo | null {
  const nv = kids(el).find((k) => k.localName.startsWith('nv'))
  const ph = path(nv, 'nvPr', 'ph')
  if (!ph) return null
  return { type: ph.getAttribute('type') ?? 'obj', idx: ph.getAttribute('idx') ?? undefined }
}

const normPh = (t: string) => (t === 'ctrTitle' || t === 'title' ? 'title' : t === 'subTitle' || t === 'body' || t === 'obj' ? 'body' : t)

function findPh(part: Part | null, ph: PhInfo, byIdx: boolean): Element | null {
  if (!part) return null
  const tree = path(part.doc.documentElement, 'cSld', 'spTree')
  const all = kids(tree).filter((k) => k.localName === 'sp' || k.localName === 'pic')
  if (byIdx && ph.idx !== undefined) {
    const hit = all.find((k) => phOf(k)?.idx === ph.idx)
    if (hit) return hit
  }
  const want = normPh(ph.type)
  return all.find((k) => {
    const o = phOf(k)
    return !!o && (o.type === ph.type || normPh(o.type) === want)
  }) ?? null
}

interface RunProps {
  size: number
  b?: boolean
  i?: boolean
  u?: boolean
  strike?: boolean
  caps?: boolean
  color?: string
  font?: string
  baseline?: number
}

function applyRun(rp: RunProps, el: Element | null | undefined, c: Ctx) {
  if (!el) return
  const sz = int(el, 'sz')
  if (sz) rp.size = sz / 100
  const b = bool(el, 'b')
  if (b !== undefined) rp.b = b
  const i = bool(el, 'i')
  if (i !== undefined) rp.i = i
  const u = el.getAttribute('u')
  if (u) rp.u = u !== 'none'
  const s = el.getAttribute('strike')
  if (s) rp.strike = s !== 'noStrike'
  const cap = el.getAttribute('cap')
  if (cap) rp.caps = cap === 'all'
  const bl = int(el, 'baseline')
  if (bl !== undefined) rp.baseline = bl / 1000
  const f = readFill(el, c)
  if (f?.kind === 'solid') rp.color = f.color
  else if (f?.kind === 'grad') rp.color = f.first
  const tf = kid(el, 'latin')?.getAttribute('typeface')
  if (tf) rp.font = tf === '+mj-lt' ? c.theme.major : tf === '+mn-lt' ? c.theme.minor : tf.startsWith('+') ? undefined : tf
}

interface ParaProps {
  algn?: string
  marL?: number
  indent?: number
  bu?: { kind: 'none' } | { kind: 'char'; char: string; font?: string } | { kind: 'num'; type: string; start: number }
  buClr?: string
  buSz?: number
  lnPct?: number
  lnPts?: number
  spcBef?: { pct?: number; pts?: number }
  spcAft?: { pct?: number; pts?: number }
}

function spacing(el: Element | null): { pct?: number; pts?: number } | undefined {
  if (!el) return undefined
  const pct = int(kid(el, 'spcPct'), 'val')
  const pts = int(kid(el, 'spcPts'), 'val')
  if (pct !== undefined) return { pct: pct / 100000 }
  if (pts !== undefined) return { pts: pts / 100 }
  return undefined
}

function applyPara(pp: ParaProps, el: Element | null | undefined, c: Ctx) {
  if (!el) return
  const algn = el.getAttribute('algn')
  if (algn) pp.algn = algn
  const marL = int(el, 'marL')
  if (marL !== undefined) pp.marL = marL / EMU_PX
  const indent = int(el, 'indent')
  if (indent !== undefined) pp.indent = indent / EMU_PX
  for (const k of kids(el)) {
    switch (k.localName) {
      case 'buNone':
        pp.bu = { kind: 'none' }
        break
      case 'buChar':
        pp.bu = { kind: 'char', char: k.getAttribute('char') ?? '•', font: pp.bu?.kind === 'char' ? pp.bu.font : undefined }
        break
      case 'buAutoNum':
        pp.bu = { kind: 'num', type: k.getAttribute('type') ?? 'arabicPeriod', start: int(k, 'startAt') ?? 1 }
        break
      case 'buFont':
        if (pp.bu?.kind === 'char') pp.bu.font = k.getAttribute('typeface') ?? undefined
        break
      case 'buClr':
        pp.buClr = colorIn(k, c) ?? undefined
        break
      case 'buSzPct':
        pp.buSz = (int(k, 'val') ?? 100000) / 100000
        break
      case 'lnSpc': {
        const s = spacing(k)
        pp.lnPct = s?.pct
        pp.lnPts = s?.pts
        break
      }
      case 'spcBef':
        pp.spcBef = spacing(k) ?? pp.spcBef
        break
      case 'spcAft':
        pp.spcAft = spacing(k) ?? pp.spcAft
        break
    }
  }
  // buFont may come before buChar in the same element.
  const bf = kid(el, 'buFont')
  if (bf && pp.bu?.kind === 'char') pp.bu.font = bf.getAttribute('typeface') ?? undefined
}

const SYMBOL_BULLETS: Record<string, string> = { '§': '■', 'Ø': '➢', 'ü': '✓', 'q': '❑', 'n': '■', 'l': '●', 'v': '❖', 'Ü': '➔', 'à': '➔', 'o': '○', '¨': '□' }

function bulletChar(ch: string, font?: string): string {
  if (font && /wingdings|symbol|webdings/i.test(font)) return SYMBOL_BULLETS[ch] ?? '•'
  return ch
}

function roman(n: number): string {
  const map: [number, string][] = [[1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'], [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']]
  let s = ''
  for (const [v, r] of map) while (n >= v) {
    s += r
    n -= v
  }
  return s
}

function autoNum(type: string, n: number): string {
  const alpha = (k: number) => String.fromCharCode(97 + ((k - 1) % 26))
  let core = String(n)
  if (type.startsWith('alphaLc')) core = alpha(n)
  else if (type.startsWith('alphaUc')) core = alpha(n).toUpperCase()
  else if (type.startsWith('romanLc')) core = roman(n)
  else if (type.startsWith('romanUc')) core = roman(n).toUpperCase()
  if (type.endsWith('ParenBoth')) return `(${core})`
  if (type.endsWith('ParenR')) return `${core})`
  if (type.endsWith('Plain')) return core
  return `${core}.`
}

interface TextSources {
  /** Lowest first: list styles (lstStyle, txStyles, defaultTextStyle). */
  lists: (Element | null)[]
  /** Base run props applied over `lists`, under the shape own lstStyle (shape style font colour, table header). */
  base?: { color?: string; b?: boolean }
  bodies: (Element | null)[]
}

function readText(txBody: Element, c: Ctx, src: TextSources): TextBody {
  const bodies = [...src.bodies, kid(txBody, 'bodyPr')]
  const b: Record<string, string> = {}
  let scale = 1
  let lnReduce = 0
  for (const bp of bodies) {
    if (!bp) continue
    for (const a of Array.from(bp.attributes)) b[a.localName] = a.value
    const fit = kid(bp, 'normAutofit')
    if (fit) {
      scale = (int(fit, 'fontScale') ?? 100000) / 100000
      lnReduce = (int(fit, 'lnSpcReduction') ?? 0) / 100000
    } else if (kid(bp, 'noAutofit') || kid(bp, 'spAutoFit')) {
      scale = 1
      lnReduce = 0
    }
  }
  const ins = (k: string, d: number) => (b[k] !== undefined && Number.isFinite(+b[k]) ? +b[k] : d) / EMU_PX
  const anchor = b.anchor === 'ctr' || b.anchor === 'b' ? b.anchor : 't'
  const vert = b.vert === 'vert' || b.vert === 'eaVert' || b.vert === 'wordArtVert' ? 'vert' : b.vert === 'vert270' ? 'vert270' : undefined

  const lists = [...src.lists, kid(txBody, 'lstStyle')]
  const counters: number[] = []
  const paras: Para[] = []
  for (const p of kids(txBody, 'p')) {
    const pPr = kid(p, 'pPr')
    const lvl = clamp(int(pPr, 'lvl') ?? 0, 0, 8)
    const levelEls = lists.map((l) => (l ? kid(l, `lvl${lvl + 1}pPr`) : null))
    const pp: ParaProps = {}
    const rpBase: RunProps = { size: 18 }
    lists.forEach((l, i) => {
      if (l) applyRun(rpBase, kid(kid(l, 'defPPr'), 'defRPr'), c)
      applyPara(pp, levelEls[i], c)
      applyRun(rpBase, kid(levelEls[i], 'defRPr'), c)
      if (i === src.lists.length - 1 && src.base) {
        if (src.base.color) rpBase.color = src.base.color
        if (src.base.b !== undefined) rpBase.b = src.base.b
      }
    })
    applyPara(pp, pPr, c)
    applyRun(rpBase, kid(pPr, 'defRPr'), c)
    const fallbackColor = colorFromScheme('tx1', c) ?? 'rgb(0, 0, 0)'

    const runs: Run[] = []
    for (const r of kids(p)) {
      if (r.localName !== 'r' && r.localName !== 'fld' && r.localName !== 'br') continue
      const rp: RunProps = { ...rpBase }
      applyRun(rp, kid(r, 'rPr'), c)
      const text = r.localName === 'br' ? '' : (kid(r, 't')?.textContent ?? '')
      runs.push({
        text,
        br: r.localName === 'br' || undefined,
        size: rp.size * scale,
        b: rp.b,
        i: rp.i,
        u: rp.u,
        strike: rp.strike,
        caps: rp.caps,
        color: rp.color ?? fallbackColor,
        font: rp.font,
        baseline: rp.baseline,
      })
    }
    const endRp: RunProps = { ...rpBase }
    applyRun(endRp, kid(p, 'endParaRPr'), c)
    const size = (runs.find((r) => !r.br)?.size ?? endRp.size * scale)

    let bullet: Para['bullet']
    const hasText = runs.some((r) => r.text.trim())
    if (pp.bu?.kind === 'num' && hasText) {
      counters[lvl] = (counters[lvl] ?? pp.bu.start - 1) + 1
      bullet = { text: autoNum(pp.bu.type, counters[lvl]) }
    } else {
      if (hasText) counters.length = lvl
      if (pp.bu?.kind === 'char' && hasText) bullet = { text: bulletChar(pp.bu.char, pp.bu.font) }
    }
    if (bullet) {
      bullet.color = pp.buClr ?? runs[0]?.color
      bullet.size = size * (pp.buSz ?? 1)
    }
    const algn = pp.algn === 'ctr' ? 'center' : pp.algn === 'r' ? 'right' : pp.algn === 'just' || pp.algn === 'dist' ? 'justify' : 'left'
    const sp = (s: { pct?: number; pts?: number } | undefined) => (s?.pts ?? (s?.pct ? s.pct * size * 1.2 : 0))
    paras.push({
      align: algn,
      marL: pp.marL ?? 0,
      indent: pp.indent ?? 0,
      bullet,
      lineHeight: Math.max(0.5, 1.2 * (pp.lnPct ?? 1) * (1 - lnReduce)),
      lineHeightPx: pp.lnPts ? (pp.lnPts * 96) / 72 : undefined,
      spaceBefore: sp(pp.spcBef),
      spaceAfter: sp(pp.spcAft),
      size,
      runs,
    })
  }
  return {
    anchor,
    inset: [ins('lIns', 91440), ins('tIns', 45720), ins('rIns', 91440), ins('bIns', 45720)],
    wrap: b.wrap !== 'none',
    vert,
    paras,
  }
}

function colorFromScheme(name: string, c: ColorCtx): string | null {
  const rgb = hexRgb(c.theme.colors[c.clrMap[name] ?? name])
  return rgb ? `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})` : null
}

function txStyle(c: Ctx, type: string | null): Element | null {
  const st = path(c.master?.doc.documentElement, 'txStyles')
  if (!st) return null
  if (type === null) return kid(st, 'otherStyle')
  const n = normPh(type)
  return kid(st, n === 'title' ? 'titleStyle' : n === 'body' ? 'bodyStyle' : 'otherStyle')
}

// ---------------------------------------------------------------------------------------------
// Shapes

const GEOMS = new Set<Geom>(['rect', 'roundRect', 'ellipse', 'triangle', 'rtTriangle', 'diamond', 'parallelogram', 'hexagon', 'chevron', 'homePlate', 'rightArrow', 'leftArrow'])
const LINES = new Set(['line', 'straightConnector1', 'bentConnector2', 'bentConnector3', 'curvedConnector3'])

function readShape(el: Element, c: Ctx, tf: Tf, skipPh: boolean): Item | null {
  const ph = phOf(el)
  if (ph && skipPh) return null
  const lph = ph && c.layout && c.part !== c.layout ? findPh(c.layout, ph, true) : null
  const mph = ph && c.master && c.part !== c.master ? findPh(c.master, ph, false) : null
  const spPr = kid(el, 'spPr')
  const inherited = [kid(lph, 'spPr'), kid(mph, 'spPr')]
  const box = readXfrm(kid(spPr, 'xfrm') ?? kid(inherited[0], 'xfrm') ?? kid(inherited[1], 'xfrm'), tf)
  if (!box) return null

  const style = kid(el, 'style')
  const prstEl = kid(spPr, 'prstGeom') ?? (kid(spPr, 'custGeom') ? null : (kid(inherited[0], 'prstGeom') ?? kid(inherited[1], 'prstGeom')))
  const prst = prstEl?.getAttribute('prst') ?? (kid(spPr, 'custGeom') ? 'cust' : 'rect')
  const isLine = LINES.has(prst) || el.localName === 'cxnSp'
  let geom: Geom = isLine ? 'line' : GEOMS.has(prst as Geom) ? (prst as Geom) : prst === 'cust' ? 'none' : 'rect'
  if (prst === 'flowChartProcess' || prst === 'snip1Rect') geom = 'rect'
  if (prst === 'flowChartAlternateProcess' || prst === 'round2SameRect') geom = 'roundRect'
  const adj = kids(kid(prstEl, 'avLst'), 'gd').find((g) => g.getAttribute('name') === 'adj')?.getAttribute('fmla')?.match(/val (-?\d+)/)
  const radius = geom === 'roundRect' ? (Math.min(box.w, box.h) * (adj ? +adj[1] : 16667)) / 100000 : 0

  const fill = readFill(spPr, c) ?? readFill(inherited[0], c) ?? readFill(inherited[1], c) ?? styleRef(kid(style, 'fillRef'), c.theme.fills, c).fill ?? { kind: 'none' as const }
  let line = readLine(kid(spPr, 'ln'), c)
  if (line === undefined) line = readLine(kid(inherited[0], 'ln'), c) ?? readLine(kid(inherited[1], 'ln'), c)
  if (line === undefined) line = styleRef(kid(style, 'lnRef'), c.theme.lines, c).line ?? null

  let text: TextBody | null = null
  const tx = kid(el, 'txBody')
  if (tx && kids(tx, 'p').some((p) => kids(p).some((r) => r.localName === 'r' || r.localName === 'fld'))) {
    const fontColor = colorIn(kid(style, 'fontRef'), c) ?? undefined
    text = readText(tx, c, {
      lists: ph ? [c.defaults, txStyle(c, ph.type), kid(kid(mph, 'txBody'), 'lstStyle'), kid(kid(lph, 'txBody'), 'lstStyle')] : [c.defaults, txStyle(c, null)],
      base: fontColor ? { color: fontColor } : undefined,
      bodies: [path(mph, 'txBody', 'bodyPr'), path(lph, 'txBody', 'bodyPr')],
    })
  }
  if (geom === 'none' && !text) return null
  return { t: 'shape', box, geom, radius, fill, line: line ?? null, text }
}

function readPic(el: Element, c: Ctx, tf: Tf, skipPh: boolean): Item | null {
  const ph = phOf(el)
  if (ph && skipPh) return null
  const spPr = kid(el, 'spPr')
  const lph = ph && c.layout && c.part !== c.layout ? findPh(c.layout, ph, true) : null
  const box = readXfrm(kid(spPr, 'xfrm') ?? path(lph, 'spPr', 'xfrm'), tf)
  if (!box) return null
  const bf = kid(el, 'blipFill')
  const img = bf ? blipPath(bf, c) : null
  const sr = kid(bf, 'srcRect')
  const crop: [number, number, number, number] = [int(sr, 'l') ?? 0, int(sr, 't') ?? 0, int(sr, 'r') ?? 0, int(sr, 'b') ?? 0].map((v) => clamp(v / 100000, -1, 0.99)) as [number, number, number, number]
  const line = readLine(kid(spPr, 'ln'), c) ?? null
  return { t: 'pic', box, img, crop, line }
}

const TABLE_URI = 'http://schemas.openxmlformats.org/drawingml/2006/table'

function readFrame(el: Element, c: Ctx, tf: Tf, out: Item[]) {
  const data = path(el, 'graphic', 'graphicData')
  const box = readXfrm(kid(el, 'xfrm'), tf)
  if (!data || !box) return
  if (data.getAttribute('uri') === TABLE_URI) {
    const t = readTable(kid(data, 'tbl'), c, box)
    if (t) out.push(t)
    return
  }
  // Embedded objects (OLE) carry a picture to show instead: use it.
  const pics = Array.from(data.getElementsByTagName('*')).filter((k) => k.localName === 'pic')
  for (const p of pics.slice(0, 1)) {
    const item = readPic(p, c, tf, false)
    if (item?.t === 'pic') out.push({ ...item, box })
  }
}

function readTable(tbl: Element | null, c: Ctx, box: Box): Item | null {
  if (!tbl) return null
  const pr = kid(tbl, 'tblPr')
  const styled = !!kid(pr, 'tableStyleId') || kids(pr).length === 0
  const firstRow = bool(pr, 'firstRow') ?? false
  const band = bool(pr, 'bandRow') ?? false
  const accent = colorFromScheme('accent1', c) ?? 'rgb(79, 129, 189)'
  const light = colorFromScheme('lt1', c) ?? 'rgb(255, 255, 255)'
  const accentEl = (t: number) => {
    const rgb = accent.match(/\d+/g)!.map(Number)
    const v = t
    return `rgb(${rgb.map((x) => Math.round(fromLin(toLin(x) * v + (1 - v)))).join(', ')})`
  }
  const cols = kids(kid(tbl, 'tblGrid'), 'gridCol').map((g) => (int(g, 'w') ?? 0) / EMU_PX)
  const rows: { h: number; cells: (Cell | null)[] }[] = []
  const trs = kids(tbl, 'tr').slice(0, 500)
  trs.forEach((tr, ri) => {
    const header = styled && firstRow && ri === 0
    const bodyIdx = firstRow ? ri - 1 : ri
    const cells: (Cell | null)[] = []
    for (const tc of kids(tr, 'tc').slice(0, 100)) {
      if (bool(tc, 'hMerge') || bool(tc, 'vMerge')) {
        cells.push(null)
        continue
      }
      const tcPr = kid(tc, 'tcPr')
      const f = readFill(tcPr, c)
      let fill = f?.kind === 'solid' ? f.color : f?.kind === 'grad' ? f.first : undefined
      if (!f && styled) fill = header ? accent : band && bodyIdx % 2 === 0 ? accentEl(0.4) : accentEl(0.2)
      const borders = ['lnL', 'lnT', 'lnR', 'lnB'].map((n) => {
        const l = readLine(kid(tcPr, n), c)
        return l === undefined ? (styled ? { color: light, width: 1 } : null) : l
      })
      const tx = kid(tc, 'txBody')
      const text = tx
        ? readText(tx, c, { lists: [c.defaults, txStyle(c, null)], base: header ? { color: light, b: true } : undefined, bodies: [] })
        : { anchor: 't' as const, inset: [0, 0, 0, 0] as [number, number, number, number], wrap: true, paras: [] }
      const mar = (n: string, d: number) => (int(tcPr, n) ?? d) / EMU_PX
      text.inset = [mar('marL', 91440), mar('marT', 45720), mar('marR', 91440), mar('marB', 45720)]
      const a = tcPr?.getAttribute('anchor')
      text.anchor = a === 'ctr' || a === 'b' ? a : 't'
      cells.push({ text, fill, colSpan: Math.max(1, int(tc, 'gridSpan') ?? 1), rowSpan: Math.max(1, int(tc, 'rowSpan') ?? 1), borders })
    }
    rows.push({ h: (int(tr, 'h') ?? 0) / EMU_PX, cells })
  })
  return { t: 'table', box, cols, rows }
}

function readTree(tree: Element | null, c: Ctx, tf: Tf, out: Item[], depth: number, skipPh: boolean) {
  if (!tree || depth > MAX_DEPTH) return
  for (const el of kids(tree)) {
    if (c.count.n >= MAX_ITEMS) return
    c.count.n++
    try {
      switch (el.localName) {
        case 'sp':
        case 'cxnSp': {
          const it = readShape(el, c, tf, skipPh)
          if (it) out.push(it)
          break
        }
        case 'pic': {
          const it = readPic(el, c, tf, skipPh)
          if (it) out.push(it)
          break
        }
        case 'graphicFrame':
          if (!(skipPh && phOf(el))) readFrame(el, c, tf, out)
          break
        case 'grpSp': {
          const gp = kid(el, 'grpSpPr')
          const x = kid(gp, 'xfrm')
          const off = kid(x, 'off'), ext = kid(x, 'ext'), chOff = kid(x, 'chOff'), chExt = kid(x, 'chExt')
          let inner = tf
          if (off && ext && chOff && chExt) {
            const ox = int(off, 'x') ?? 0, oy = int(off, 'y') ?? 0
            const cx = int(chOff, 'x') ?? 0, cy = int(chOff, 'y') ?? 0
            const sx = (int(chExt, 'cx') ?? 0) ? (int(ext, 'cx') ?? 0) / (int(chExt, 'cx') ?? 1) : 1
            const sy = (int(chExt, 'cy') ?? 0) ? (int(ext, 'cy') ?? 0) / (int(chExt, 'cy') ?? 1) : 1
            inner = (X, Y, W, H) => tf(ox + (X - cx) * sx, oy + (Y - cy) * sy, W * sx, H * sy)
          }
          const sub: Ctx = { ...c, groupFill: readFill(gp, c) ?? c.groupFill }
          readTree(el, sub, inner, out, depth + 1, skipPh)
          break
        }
        case 'AlternateContent': {
          const pick = kid(el, 'Fallback') ?? kid(el, 'Choice')
          readTree(pick, c, tf, out, depth + 1, skipPh)
          break
        }
      }
    } catch (e) {
      // One odd shape never takes the slide down.
      console.info('pptx: shape skipped', e)
    }
  }
}

function readBg(part: Part | null, c: Ctx): Fill | undefined {
  const bg = path(part?.doc.documentElement, 'cSld', 'bg')
  if (!bg || !part) return undefined
  const sub: Ctx = { ...c, part }
  const pr = kid(bg, 'bgPr')
  if (pr) return readFill(pr, sub)
  const ref = kid(bg, 'bgRef')
  if (ref) return styleRef(ref, c.theme.bgFills, sub).fill
  return undefined
}

function clrMapOf(el: Element | null): Record<string, string> | null {
  if (!el) return null
  const m: Record<string, string> = {}
  for (const a of Array.from(el.attributes)) m[a.localName] = a.value
  return m
}

// ---------------------------------------------------------------------------------------------
// Deck

const IMAGE_MIME: Record<string, string> = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', jpe: 'image/jpeg', gif: 'image/gif', bmp: 'image/bmp', webp: 'image/webp', svg: 'image/svg+xml',
}

export async function openPptx(bytes: Uint8Array): Promise<Deck> {
  const zip = new Zip(bytes.slice())
  const presPath = 'ppt/presentation.xml'
  const pres = await readPart(zip, presPath)
  if (!pres) throw new Error('no presentation part')
  const root = pres.doc.documentElement
  const sz = kid(root, 'sldSz')
  const width = (int(sz, 'cx') ?? 9144000) / EMU_PX
  const height = (int(sz, 'cy') ?? 6858000) / EMU_PX

  const themeCache = new Map<string, Theme>()
  const partCache = new Map<string, Part | null>()
  const part = async (p: string | null) => {
    if (!p) return null
    if (!partCache.has(p)) partCache.set(p, await readPart(zip, p))
    return partCache.get(p) ?? null
  }
  const themeOf = async (master: Part | null): Promise<Theme> => {
    const tp = master ? relOfType(master, '/theme') : null
    if (tp && themeCache.has(tp)) return themeCache.get(tp)!
    const doc = tp ? (await part(tp))?.doc : null
    const te = doc?.documentElement
    const scheme = path(te, 'themeElements', 'clrScheme')
    const colors: Record<string, string> = {}
    for (const k of kids(scheme)) {
      const v = kids(k)[0]
      const hex = v?.localName === 'srgbClr' ? v.getAttribute('val') : v?.localName === 'sysClr' ? v.getAttribute('lastClr') : null
      if (hex) colors[k.localName] = hex
    }
    colors.dk1 ??= '000000'
    colors.lt1 ??= 'FFFFFF'
    const fonts = path(te, 'themeElements', 'fontScheme')
    const fmt = path(te, 'themeElements', 'fmtScheme')
    const t: Theme = {
      colors,
      major: path(fonts, 'majorFont', 'latin')?.getAttribute('typeface') ?? 'Calibri',
      minor: path(fonts, 'minorFont', 'latin')?.getAttribute('typeface') ?? 'Calibri',
      fills: kids(kid(fmt, 'fillStyleLst')),
      lines: kids(kid(fmt, 'lnStyleLst')),
      bgFills: kids(kid(fmt, 'bgFillStyleLst')),
    }
    if (tp) themeCache.set(tp, t)
    return t
  }

  const ids = kids(kid(root, 'sldIdLst'), 'sldId')
  const total = ids.length
  const slides: Slide[] = []
  for (const [i, sid] of ids.slice(0, MAX_SLIDES).entries()) {
    const target = pres.rels.get(rAttr(sid, 'id') ?? '')?.target
    const sp = target ? await part(target) : null
    if (!sp) {
      slides.push({ n: i + 1, hidden: false, bg: { kind: 'solid', color: 'rgb(255, 255, 255)' }, items: [] })
      continue
    }
    const layout = await part(relOfType(sp, '/slideLayout'))
    const master = await part(layout ? relOfType(layout, '/slideMaster') : null)
    const theme = await themeOf(master)
    const baseMap = clrMapOf(kid(master?.doc.documentElement, 'clrMap')) ?? {}
    const over = (p: Part | null) => clrMapOf(path(p?.doc.documentElement, 'clrMapOvr', 'overrideClrMapping'))
    const clrMap = { bg1: 'lt1', tx1: 'dk1', bg2: 'lt2', tx2: 'dk2', ...baseMap, ...(over(layout) ?? {}), ...(over(sp) ?? {}) }
    const c: Ctx = { zip, theme, clrMap, part: sp, layout, master, defaults: kid(root, 'defaultTextStyle'), count: { n: 0 } }

    const items: Item[] = []
    const showMaster = (p: Part | null) => p?.doc.documentElement.getAttribute('showMasterSp') !== '0'
    if (master && showMaster(sp) && showMaster(layout)) readTree(path(master.doc.documentElement, 'cSld', 'spTree'), { ...c, part: master }, identity, items, 0, true)
    if (layout && showMaster(sp)) readTree(path(layout.doc.documentElement, 'cSld', 'spTree'), { ...c, part: layout }, identity, items, 0, true)
    readTree(path(sp.doc.documentElement, 'cSld', 'spTree'), c, identity, items, 0, false)

    const bg = readBg(sp, c) ?? readBg(layout, c) ?? readBg(master, c) ?? { kind: 'solid', color: colorFromScheme('bg1', c) ?? 'rgb(255, 255, 255)' }
    slides.push({ n: i + 1, hidden: sp.doc.documentElement.getAttribute('show') === '0', bg, items })
  }

  const urls = new Map<string, Promise<string | null>>()
  let closed = false
  const imageBlob = async (img: string): Promise<Blob | null> => {
    const ext = img.split('.').pop()?.toLowerCase() ?? ''
    const mime = IMAGE_MIME[ext]
    if (!mime || closed) return null
    const b = await zip.bytes(img, 64 * 1024 * 1024).catch(() => null)
    return b ? new Blob([b], { type: mime }) : null
  }
  return {
    width,
    height,
    slides,
    total,
    imageBlob,
    imageUrl(img) {
      if (!urls.has(img)) {
        urls.set(
          img,
          imageBlob(img).then((b) => {
            if (!b) return null
            const u = URL.createObjectURL(b)
            if (closed) {
              URL.revokeObjectURL(u)
              return null
            }
            return u
          }),
        )
      }
      return urls.get(img)!
    },
    close() {
      closed = true
      for (const p of urls.values()) void p.then((u) => u && URL.revokeObjectURL(u))
      urls.clear()
    },
  }
}

// ---------------------------------------------------------------------------------------------
// Canvas painter (thumbnail for the attachment card)

function fillStyle(f: Fill): string | null {
  return f.kind === 'solid' ? f.color : f.kind === 'grad' ? f.first : null
}

function shapePath(g: CanvasRenderingContext2D, geom: Geom, w: number, h: number, radius: number) {
  g.beginPath()
  const poly = (pts: number[][]) => {
    pts.forEach(([x, y], i) => (i ? g.lineTo(x * w, y * h) : g.moveTo(x * w, y * h)))
    g.closePath()
  }
  switch (geom) {
    case 'ellipse':
      g.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2)
      break
    case 'roundRect':
      g.roundRect(0, 0, w, h, Math.min(radius, w / 2, h / 2))
      break
    case 'triangle':
      poly([[0.5, 0], [1, 1], [0, 1]])
      break
    case 'rtTriangle':
      poly([[0, 0], [1, 1], [0, 1]])
      break
    case 'diamond':
      poly([[0.5, 0], [1, 0.5], [0.5, 1], [0, 0.5]])
      break
    default:
      g.rect(0, 0, w, h)
  }
}

function wrapLines(g: CanvasRenderingContext2D, text: string, width: number): string[] {
  const words = text.split(/(\s+)/)
  const lines: string[] = []
  let cur = ''
  for (const w of words) {
    const next = cur + w
    if (cur && g.measureText(next).width > width) {
      lines.push(cur.trimEnd())
      cur = w.trimStart()
    } else cur = next
  }
  if (cur) lines.push(cur)
  return lines
}

function paintText(g: CanvasRenderingContext2D, t: TextBody, w: number, h: number) {
  const [l, top, r, b] = t.inset
  const inner = Math.max(1, w - l - r)
  const laid: { font: string; color: string; text: string; lh: number; align: string; x: number }[] = []
  for (const p of t.paras) {
    const first = p.runs.find((x) => x.text) ?? p.runs[0]
    const px = (p.size * 96) / 72
    const font = `${first?.i ? 'italic ' : ''}${first?.b ? 'bold ' : ''}${px}px sans-serif`
    g.font = font
    const text = (p.bullet ? `${p.bullet.text} ` : '') + p.runs.map((x) => (x.br ? '\n' : x.caps ? x.text.toUpperCase() : x.text)).join('')
    const lh = p.lineHeightPx ?? px * p.lineHeight
    const lines = text.split('\n').flatMap((s) => (t.wrap ? wrapLines(g, s, inner - p.marL) : [s]))
    for (const s of lines.length ? lines : ['']) laid.push({ font, color: first?.color ?? '#000', text: s, lh, align: p.align, x: p.marL })
  }
  const total = laid.reduce((s, x) => s + x.lh, 0)
  let y = t.anchor === 'ctr' ? (h - total) / 2 : t.anchor === 'b' ? h - b - total : top
  g.textBaseline = 'middle'
  for (const x of laid) {
    g.font = x.font
    g.fillStyle = x.color
    const tw = g.measureText(x.text).width
    const left = l + x.x
    const X = x.align === 'center' ? left + (inner - x.x - tw) / 2 : x.align === 'right' ? w - r - tw : left
    g.fillText(x.text, X, y + x.lh / 2)
    y += x.lh
  }
}

async function paintSlide(g: CanvasRenderingContext2D, deck: Deck, s: Slide, scale: number) {
  g.save()
  g.scale(scale, scale)
  const bgc = fillStyle(s.bg)
  g.fillStyle = bgc ?? '#fff'
  g.fillRect(0, 0, deck.width, deck.height)
  const draw = async (img: string, x: number, y: number, w: number, h: number, crop: number[] = [0, 0, 0, 0]) => {
    const blob = await deck.imageBlob(img)
    if (!blob) return
    try {
      const bmp = await createImageBitmap(blob)
      const [cl, ct, cr, cb] = crop
      const sw = bmp.width * (1 - cl - cr), sh = bmp.height * (1 - ct - cb)
      if (sw > 0 && sh > 0) g.drawImage(bmp, bmp.width * cl, bmp.height * ct, sw, sh, x, y, w, h)
      bmp.close()
    } catch {
      // Formats createImageBitmap cannot decode (SVG in some browsers) stay blank.
    }
  }
  if (s.bg.kind === 'img') await draw(s.bg.img, 0, 0, deck.width, deck.height)
  for (const it of s.items) {
    const { x, y, w, h, rot, flipH, flipV } = it.box
    g.save()
    g.translate(x + w / 2, y + h / 2)
    if (rot) g.rotate((rot * Math.PI) / 180)
    g.scale(flipH ? -1 : 1, flipV ? -1 : 1)
    g.translate(-w / 2, -h / 2)
    if (it.t === 'pic' && it.img) await draw(it.img, 0, 0, w, h, it.crop)
    else if (it.t === 'shape') {
      if (it.geom === 'line') {
        if (it.line) {
          g.strokeStyle = it.line.color
          g.lineWidth = it.line.width
          g.beginPath()
          g.moveTo(0, 0)
          g.lineTo(w, h)
          g.stroke()
        }
      } else if (it.geom !== 'none') {
        shapePath(g, it.geom, w, h, it.radius)
        const fs = fillStyle(it.fill)
        if (fs) {
          g.fillStyle = fs
          g.fill()
        }
        if (it.fill.kind === 'img') await draw(it.fill.img, 0, 0, w, h)
        if (it.line) {
          g.strokeStyle = it.line.color
          g.lineWidth = it.line.width
          g.stroke()
        }
      }
      if (it.text) {
        if (flipH || flipV) g.scale(flipH ? -1 : 1, flipV ? -1 : 1)
        paintText(g, it.text, w, h)
      }
    } else if (it.t === 'table') {
      let ty = 0
      const total = it.rows.reduce((a, r) => a + r.h, 0) || h
      for (const row of it.rows) {
        const rh = (row.h / total) * h
        let tx = 0
        row.cells.forEach((cell, ci) => {
          const cw = it.cols[ci] ?? 0
          if (cell) {
            const span = it.cols.slice(ci, ci + cell.colSpan).reduce((a, b) => a + b, 0)
            if (cell.fill) {
              g.fillStyle = cell.fill
              g.fillRect(tx, ty, span, rh)
            }
            g.save()
            g.translate(tx, ty)
            paintText(g, cell.text, span, rh)
            g.restore()
          }
          tx += cw
        })
        ty += rh
      }
    }
    g.restore()
  }
  g.restore()
}

async function jpegB64(c: HTMLCanvasElement, q: number): Promise<{ b64: string; size: number }> {
  const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', q))
  if (!blob) throw new Error('encode')
  const b = new Uint8Array(await blob.arrayBuffer())
  let s = ''
  for (const x of b) s += String.fromCharCode(x)
  return { b64: btoa(s), size: b.length }
}

/**
 * First slide as a small JPEG for the bubble (at most 4 KiB, like the PDF thumb) plus the slide
 * count. Width steps down until it fits.
 */
export async function pptxThumbnail(bytes: Uint8Array): Promise<{ thumb?: string; pages: number; width: number; height: number }> {
  const deck = await openPptx(bytes)
  try {
    const s = deck.slides[0]
    const size = { pages: deck.total, width: Math.round(deck.width), height: Math.round(deck.height) }
    if (!s) return size
    let last: string | undefined
    for (const w of [200, 160, 120]) {
      const c = document.createElement('canvas')
      const scale = w / deck.width
      c.width = w
      c.height = Math.max(1, Math.round(deck.height * scale))
      await paintSlide(c.getContext('2d')!, deck, s, scale)
      for (const q of [0.6, 0.45, 0.3]) {
        const { b64, size: n } = await jpegB64(c, q)
        last = b64
        if (n <= 4096) return { ...size, thumb: b64 }
      }
    }
    return { ...size, thumb: last && last.length < 8000 ? last : undefined }
  } finally {
    deck.close()
  }
}
