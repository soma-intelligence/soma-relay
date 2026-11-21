// CipherQR: the pairing code as one object through three moments, ported from OnePass
// (DesignKit CipherQRCode.swift) to canvas.
//
// - code: QR in round dots with the Relay mark in the middle. Arrives as a wave of cipher
//   characters from the center that settle into dots, then holds still for the camera.
// - connecting: the same wave turns the dots back into cipher and clears the tile; characters
//   keep scrambling in the middle.
// - verify: the scrambling characters settle one by one into the words to compare.
// The tile stays white with dark modules in dark mode too (cameras need the contrast).
// Reduced motion: each moment drawn still.

import { useEffect, useRef } from 'react'
import QRCode from 'qrcode'

export type CipherStage = { kind: 'code'; text: string } | { kind: 'connecting' } | { kind: 'verify'; lines: string[] }

const T = {
  wave: 0.62,
  glyphIn: 0.2,
  dotIn: 0.3,
  dotOut: 0.09,
  glyphHold: 0.23,
  glyphOut: 0.13,
  slotsAt: 0.52,
  slotsIn: 0.35,
  settleStep: 0.07,
  tick: 0.06,
}
const INK = '#121212'
const HEX = '0123456789ABCDEF'

interface Matrix {
  side: number
  dark: (x: number, y: number) => boolean
}

const matrixCache = new Map<string, Matrix>()
function matrixOf(text: string): Matrix | null {
  const hit = matrixCache.get(text)
  if (hit) return hit
  try {
    const qr = QRCode.create(text, { errorCorrectionLevel: 'Q' })
    const { size, data } = qr.modules
    const m: Matrix = { side: size, dark: (x, y) => data[y * size + x] === 1 }
    matrixCache.set(text, m)
    return m
  } catch {
    return null
  }
}

const isFinder = (side: number, x: number, y: number) =>
  (x < 7 && y < 7) || (x >= side - 7 && y < 7) || (x < 7 && y >= side - 7)

/** Deterministic 0..1 noise from two integers (decoration, not randomness). */
function noise(a: number, b: number): number {
  let x = (Math.imul(a, 0x9e3779b1) ^ Math.imul(b, 0x85ebca77)) >>> 0
  x ^= x >>> 15
  x = Math.imul(x, 0x2c1b3c6d) >>> 0
  x ^= x >>> 12
  x = Math.imul(x, 0x297a2d39) >>> 0
  x ^= x >>> 15
  return (x & 0xffff) / 65536
}

const unit = (v: number) => Math.min(1, Math.max(0, v))
const easeOut = (p: number) => 1 - (1 - p) ** 3
function back(p: number): number {
  if (p <= 0) return 0
  const s = 1.6
  const q = p - 1
  return q * q * ((s + 1) * q + s) + 1
}

interface Frame {
  appear: number
  dissolve: number | null
  settle: number | null
  lines: string[] | null
  scrambles: boolean
}

function cell(f: Frame, d: number): { dot: number; glyph: number } {
  const inWave = f.appear - d * T.wave
  let dot = back(unit((inWave - T.glyphIn) / T.dotIn))
  let glyph = inWave < 0 ? 0 : inWave < T.glyphIn ? unit(inWave / 0.06) : 1 - unit((inWave - T.glyphIn) / 0.11)
  if (f.dissolve !== null) {
    const out = f.dissolve - d * T.wave
    dot *= 1 - unit(out / T.dotOut)
    glyph = out < 0 ? glyph : out < T.glyphHold ? 1 : 1 - unit((out - T.glyphHold) / T.glyphOut)
  }
  return { dot, glyph: f.scrambles ? glyph : 0 }
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath()
  ctx.roundRect(x, y, w, h, r)
}

function draw(ctx: CanvasRenderingContext2D, size: number, matrix: Matrix | null, f: Frame) {
  ctx.clearRect(0, 0, size, size)
  ctx.fillStyle = '#ffffff'
  roundRect(ctx, 0, 0, size, size, size * 0.075)
  ctx.fill()
  const margin = size * 0.085
  const area = size - 2 * margin
  const c = size / 2
  const reach = area * 0.7071
  const dist = (x: number, y: number) => Math.min(1, Math.hypot(x - c, y - c) / reach)
  const markSide = area * 0.2

  if (matrix) {
    const cs = area / matrix.side
    const clear = markSide / 2 + cs * 0.4
    ctx.fillStyle = INK
    ctx.beginPath()
    for (let y = 0; y < matrix.side; y++) {
      for (let x = 0; x < matrix.side; x++) {
        if (!matrix.dark(x, y) || isFinder(matrix.side, x, y)) continue
        const px = margin + (x + 0.5) * cs
        const py = margin + (y + 0.5) * cs
        if (Math.abs(px - c) < clear && Math.abs(py - c) < clear) continue
        const r = cs * 0.46 * cell(f, dist(px, py)).dot
        if (r <= 0.05) continue
        ctx.moveTo(px + r, py)
        ctx.arc(px, py, r, 0, Math.PI * 2)
      }
    }
    ctx.fill()
    const eyes = [
      [3.5, 3.5],
      [matrix.side - 3.5, 3.5],
      [3.5, matrix.side - 3.5],
    ]
    for (const [ex, ey] of eyes) {
      const px = margin + ex * cs
      const py = margin + ey * cs
      const mod = cs * cell(f, dist(px, py)).dot
      if (mod <= 0.05) continue
      const sq = (half: number, corner: number, color: string) => {
        ctx.fillStyle = color
        roundRect(ctx, px - half * mod, py - half * mod, 2 * half * mod, 2 * half * mod, corner * mod)
        ctx.fill()
      }
      sq(3.5, 2.2, INK)
      sq(2.5, 1.5, '#ffffff')
      sq(1.5, 0.9, INK)
    }
    // The Relay mark: a radar on a dark tile.
    const markScale = back(unit((f.appear - 0.15) / 0.4)) * (1 - unit((f.dissolve ?? 0) / 0.2))
    if (markScale > 0.01) {
      const s = markSide * markScale
      ctx.fillStyle = INK
      roundRect(ctx, c - s / 2, c - s / 2, s, s, s * 0.24)
      ctx.fill()
      ctx.strokeStyle = 'rgba(255,255,255,0.35)'
      ctx.lineWidth = Math.max(1, s * 0.035)
      for (const rr of [0.34, 0.2]) {
        ctx.beginPath()
        ctx.arc(c, c, s * rr, 0, Math.PI * 2)
        ctx.stroke()
      }
      ctx.fillStyle = '#ffffff'
      ctx.beginPath()
      ctx.arc(c, c, s * 0.06, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = '#c6f24e'
      ctx.beginPath()
      ctx.arc(c + s * 0.22, c - s * 0.22, s * 0.075, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  // The cipher: one hex character per cell of a coarser grid, changing every tick.
  if (f.scrambles && matrix) {
    const columns = Math.max(8, Math.floor(area / 10))
    const step = area / columns
    const tick = Math.floor((Math.max(f.appear, 0) + (f.dissolve ?? 0)) / T.tick) & 0xffff
    ctx.font = `600 ${step * 0.92}px ui-monospace, 'SF Mono', Menlo, monospace`
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillStyle = INK
    const appearing = f.dissolve === null
    for (let row = 0; row < columns; row++) {
      for (let col = 0; col < columns; col++) {
        const i = row * columns + col
        const presence = noise(i, 7)
        if (presence >= 0.66) continue
        const px = margin + (col + 0.5) * step
        const py = margin + (row + 0.5) * step
        if (appearing && Math.abs(px - c) < markSide / 2 + step * 0.5 && Math.abs(py - c) < markSide / 2 + step * 0.5) continue
        const a = cell(f, dist(px, py)).glyph * (presence < 0.42 ? 1 : 0.38)
        if (a <= 0.02) continue
        ctx.globalAlpha = a
        ctx.fillText(HEX[Math.floor(noise(i, tick) * 16) & 15], px, py)
      }
    }
    ctx.globalAlpha = 1
  }

  // The characters in the middle: scrambling while connecting, then the words.
  if (f.dissolve === null) return
  const lines = f.lines ?? ['······']
  const shown = easeOut(unit((f.dissolve - T.slotsAt) / T.slotsIn))
  if (shown <= 0.01 || (!f.scrambles && !f.lines)) return
  const longest = Math.max(...lines.map((l) => l.length))
  const fontSize = Math.min(size * 0.14, (size * 0.84) / (longest * 0.62))
  ctx.font = `600 ${fontSize}px ui-monospace, 'SF Mono', Menlo, monospace`
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  const adv = ctx.measureText('0').width * 1.04
  const lineH = fontSize * 1.35
  const tick = Math.floor(f.dissolve / T.tick) & 0xffff
  let k = 0
  lines.forEach((line, li) => {
    const y = c + (li - (lines.length - 1) / 2) * lineH
    for (let i = 0; i < line.length; i++, k++) {
      const ch = line[i]
      const settled = !!f.lines && (f.settle ?? -1) >= k * T.settleStep
      if (!settled && !f.scrambles) continue
      if (ch === ' ') continue
      ctx.globalAlpha = shown * (settled ? 1 : 0.42)
      ctx.fillStyle = settled ? INK : '#6b7280'
      ctx.fillText(settled ? ch : HEX[Math.floor(noise(900 + k, tick) * 16) & 15], c + (i - (line.length - 1) / 2) * adv, y)
    }
  })
  ctx.globalAlpha = 1
}

export function CipherQR({ stage, label }: { stage: CipherStage; label: string }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const st = useRef({
    text: null as string | null,
    appearAt: -Infinity,
    dissolveAt: null as number | null,
    settleAt: null as number | null,
    raf: 0,
    quietAt: 0,
  })

  // Callers often pass a fresh object each render: the animation restarts only when the
  // stage really changes.
  const key = JSON.stringify(stage)
  const stageRef = useRef(stage)
  stageRef.current = stage

  useEffect(() => {
    const stage = stageRef.current
    const canvas = ref.current
    if (!canvas) return
    const s = st.current
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches
    const now = performance.now() / 1000
    const startDissolve = () => {
      if (s.dissolveAt !== null) return s.dissolveAt
      s.dissolveAt = s.text === null ? now - T.slotsAt : now
      return s.dissolveAt
    }
    let lines: string[] | null = null
    if (stage.kind === 'code') {
      s.text = stage.text
      s.appearAt = now
      s.dissolveAt = null
      s.settleAt = null
      s.quietAt = now + T.wave + T.glyphIn + T.dotIn + 0.3
    } else if (stage.kind === 'connecting') {
      startDissolve()
      s.settleAt = null
      s.quietAt = Infinity
    } else {
      lines = stage.lines
      const start = startDissolve()
      s.settleAt = Math.max(now, start + T.slotsAt + T.slotsIn + 0.25)
      const chars = stage.lines.join('').length
      s.quietAt = s.settleAt + chars * T.settleStep + 0.4
    }
    const matrix = s.text ? matrixOf(s.text) : null

    const render = () => {
      const dpr = Math.min(3, window.devicePixelRatio || 1)
      const css = canvas.clientWidth || 300
      const px = Math.round(css * dpr)
      if (canvas.width !== px) {
        canvas.width = px
        canvas.height = px
      }
      const ctx = canvas.getContext('2d')!
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      const t = performance.now() / 1000
      const frame: Frame = reduce
        ? {
            appear: Infinity,
            dissolve: stage.kind === 'code' ? null : Infinity,
            settle: lines ? Infinity : null,
            lines,
            scrambles: false,
          }
        : {
            appear: t - s.appearAt,
            dissolve: s.dissolveAt === null ? null : t - s.dissolveAt,
            settle: s.settleAt === null ? null : t - s.settleAt,
            lines,
            scrambles: true,
          }
      draw(ctx, css, matrix, frame)
      if (!reduce && t < s.quietAt) s.raf = requestAnimationFrame(render)
    }
    cancelAnimationFrame(s.raf)
    render()
    return () => cancelAnimationFrame(s.raf)
  }, [key])

  return <canvas ref={ref} role="img" aria-label={label} style={{ aspectRatio: '1', width: '100%' }} />
}
