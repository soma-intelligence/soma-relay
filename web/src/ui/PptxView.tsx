// PowerPoint viewer: draws the slide model from media/pptx.ts with plain DOM nodes (no markup
// from the file ever reaches innerHTML). Slides stack vertically like PDF pages, with zoom,
// slide numbers and arrow keys. Each slide is laid out at its own size in CSS pixels and scaled
// with a transform, so text keeps its proportions at every zoom.

import { useEffect, useId, useRef, useState } from 'react'
import type { Box, Deck, Fill, Item, Line, Para, Slide, TextBody } from '../media/pptx'
import { ZoomIn, ZoomOut } from './Icons'

const FONT_FALLBACK = 'Carlito, Calibri, "Helvetica Neue", Arial, system-ui, sans-serif'

function fontStack(font?: string): string {
  return font && /^[\w .-]{1,64}$/.test(font) ? `"${font}", ${FONT_FALLBACK}` : FONT_FALLBACK
}

function useImageUrl(deck: Deck, img: string | null): string | null | undefined {
  const [url, setUrl] = useState<string | null | undefined>(undefined)
  useEffect(() => {
    let off = false
    if (!img) {
      setUrl(null)
      return
    }
    void deck.imageUrl(img).then((u) => !off && setUrl(u))
    return () => {
      off = true
    }
  }, [deck, img])
  return url
}

function fillCss(f: Fill, url?: string | null): React.CSSProperties {
  if (f.kind === 'solid') return { background: f.color }
  if (f.kind === 'grad') return { backgroundImage: f.css }
  if (f.kind === 'img' && url) return { backgroundImage: `url("${url}")`, backgroundSize: '100% 100%' }
  return {}
}

function boxCss(b: Box): React.CSSProperties {
  const t: string[] = []
  if (b.rot) t.push(`rotate(${b.rot}deg)`)
  if (b.flipH || b.flipV) t.push(`scale(${b.flipH ? -1 : 1}, ${b.flipV ? -1 : 1})`)
  return { left: b.x, top: b.y, width: b.w, height: b.h, transform: t.length ? t.join(' ') : undefined }
}

const CLIP: Record<string, string> = {
  triangle: 'polygon(50% 0, 100% 100%, 0 100%)',
  rtTriangle: 'polygon(0 0, 100% 100%, 0 100%)',
  diamond: 'polygon(50% 0, 100% 50%, 50% 100%, 0 50%)',
  parallelogram: 'polygon(25% 0, 100% 0, 75% 100%, 0 100%)',
  hexagon: 'polygon(25% 0, 75% 0, 100% 50%, 75% 100%, 25% 100%, 0 50%)',
  chevron: 'polygon(0 0, 75% 0, 100% 50%, 75% 100%, 0 100%, 25% 50%)',
  homePlate: 'polygon(0 0, 80% 0, 100% 50%, 80% 100%, 0 100%)',
  rightArrow: 'polygon(0 25%, 60% 25%, 60% 0, 100% 50%, 60% 100%, 60% 75%, 0 75%)',
  leftArrow: 'polygon(40% 0, 40% 25%, 100% 25%, 100% 75%, 40% 75%, 40% 100%, 0 50%)',
}

function Paras({ paras }: { paras: Para[] }) {
  return (
    <>
      {paras.map((p, i) => (
        <div
          key={i}
          className="pptx-p"
          style={{
            textAlign: p.align,
            paddingLeft: p.marL,
            textIndent: p.indent,
            lineHeight: p.lineHeightPx ? `${p.lineHeightPx}px` : p.lineHeight,
            marginTop: i ? `${p.spaceBefore}pt` : 0,
            marginBottom: `${p.spaceAfter}pt`,
            fontSize: `${p.size}pt`,
          }}
        >
          {p.bullet && (
            <span className="pptx-bu" style={{ color: p.bullet.color, fontSize: p.bullet.size ? `${p.bullet.size}pt` : undefined, minWidth: p.indent < 0 ? -p.indent : undefined }}>
              {p.bullet.text}
              {p.indent < 0 ? '' : ' '}
            </span>
          )}
          {p.runs.length
            ? p.runs.map((r, j) =>
                r.br ? (
                  <br key={j} />
                ) : (
                  <span
                    key={j}
                    style={{
                      fontSize: `${r.baseline ? r.size * 0.66 : r.size}pt`,
                      fontWeight: r.b ? 700 : undefined,
                      fontStyle: r.i ? 'italic' : undefined,
                      textDecoration: [r.u && 'underline', r.strike && 'line-through'].filter(Boolean).join(' ') || undefined,
                      textTransform: r.caps ? 'uppercase' : undefined,
                      verticalAlign: r.baseline ? (r.baseline > 0 ? 'super' : 'sub') : undefined,
                      color: r.color,
                      fontFamily: r.font ? fontStack(r.font) : undefined,
                    }}
                  >
                    {r.text}
                  </span>
                ),
              )
            : ' '}
        </div>
      ))}
    </>
  )
}

function Text({ t, abs = true }: { t: TextBody; abs?: boolean }) {
  return (
    <div
      className={abs ? 'pptx-text' : 'pptx-text cell'}
      style={{
        padding: `${t.inset[1]}px ${t.inset[2]}px ${t.inset[3]}px ${t.inset[0]}px`,
        justifyContent: t.anchor === 'ctr' ? 'center' : t.anchor === 'b' ? 'flex-end' : 'flex-start',
        whiteSpace: t.wrap ? 'pre-wrap' : 'pre',
        writingMode: t.vert ? 'vertical-rl' : undefined,
        transform: t.vert === 'vert270' ? 'rotate(180deg)' : undefined,
      }}
    >
      <Paras paras={t.paras} />
    </div>
  )
}

function lineCss(l: Line | null): React.CSSProperties {
  if (!l) return {}
  const w = l.width
  return { left: -w / 2, top: -w / 2, width: `calc(100% + ${w}px)`, height: `calc(100% + ${w}px)`, border: `${w}px ${l.dash ? 'dashed' : 'solid'} ${l.color}` }
}

function ShapeItem({ deck, it }: { deck: Deck; it: Extract<Item, { t: 'shape' }> }) {
  const url = useImageUrl(deck, it.fill.kind === 'img' ? it.fill.img : null)
  const mid = useId().replace(/:/g, '')
  const { w, h } = it.box
  let geom: React.ReactNode = null
  if (it.geom === 'line') {
    const l = it.line
    if (l)
      geom = (
        <svg className="pptx-line" width={Math.max(w, 1)} height={Math.max(h, 1)} aria-hidden="true">
          {(l.head || l.tail) && (
            <defs>
              <marker id={`a${mid}`} viewBox="0 0 10 10" refX="8" refY="5" markerWidth="4" markerHeight="4" orient="auto-start-reverse">
                <path d="M0 0 L10 5 L0 10 z" fill={l.color} />
              </marker>
            </defs>
          )}
          <line
            x1={0}
            y1={0}
            x2={w}
            y2={h}
            stroke={l.color}
            strokeWidth={l.width}
            strokeDasharray={l.dash ? `${l.width * 3} ${l.width * 2}` : undefined}
            markerStart={l.head ? `url(#a${mid})` : undefined}
            markerEnd={l.tail ? `url(#a${mid})` : undefined}
          />
        </svg>
      )
  } else if (it.geom !== 'none') {
    const clip = CLIP[it.geom]
    geom = (
      <>
        <div
          className="pptx-geom"
          style={{
            ...fillCss(it.fill, url),
            borderRadius: it.geom === 'ellipse' ? '50%' : it.radius || undefined,
            clipPath: clip,
          }}
        />
        {it.line && !clip && (
          <div className="pptx-geom" style={{ ...lineCss(it.line), borderRadius: it.geom === 'ellipse' ? '50%' : it.radius ? it.radius + it.line.width / 2 : undefined }} />
        )}
      </>
    )
  }
  return (
    <div className="pptx-item" style={boxCss(it.box)}>
      {geom}
      {it.text && <Text t={it.text} />}
    </div>
  )
}

function PicItem({ deck, it }: { deck: Deck; it: Extract<Item, { t: 'pic' }> }) {
  const url = useImageUrl(deck, it.img)
  const [l, t, r, b] = it.crop
  const cw = 1 - l - r
  const ch = 1 - t - b
  return (
    <div className="pptx-item pptx-pic" style={boxCss(it.box)}>
      {url ? (
        <img
          src={url}
          alt=""
          draggable={false}
          style={
            l || t || r || b
              ? { position: 'absolute', width: `${100 / cw}%`, height: `${100 / ch}%`, left: `${(-l / cw) * 100}%`, top: `${(-t / ch) * 100}%` }
              : { width: '100%', height: '100%' }
          }
        />
      ) : url === null ? (
        <div className="pptx-missing" />
      ) : null}
      {it.line && <div className="pptx-geom" style={lineCss(it.line)} />}
    </div>
  )
}

function TableItem({ it }: { it: Extract<Item, { t: 'table' }> }) {
  const border = (l: Line | null) => (l ? `${l.width}px ${l.dash ? 'dashed' : 'solid'} ${l.color}` : undefined)
  return (
    <div className="pptx-item" style={{ ...boxCss(it.box), height: undefined }}>
      <table className="pptx-table" style={{ width: it.cols.reduce((a, b) => a + b, 0) || it.box.w }}>
        <colgroup>
          {it.cols.map((w, i) => (
            <col key={i} style={{ width: w }} />
          ))}
        </colgroup>
        <tbody>
          {it.rows.map((row, i) => (
            <tr key={i} style={{ height: row.h }}>
              {row.cells.map((c, j) =>
                c ? (
                  <td
                    key={j}
                    colSpan={c.colSpan > 1 ? c.colSpan : undefined}
                    rowSpan={c.rowSpan > 1 ? c.rowSpan : undefined}
                    style={{
                      background: c.fill,
                      borderLeft: border(c.borders[0]),
                      borderTop: border(c.borders[1]),
                      borderRight: border(c.borders[2]),
                      borderBottom: border(c.borders[3]),
                      verticalAlign: c.text.anchor === 'ctr' ? 'middle' : c.text.anchor === 'b' ? 'bottom' : 'top',
                      padding: `${c.text.inset[1]}px ${c.text.inset[2]}px ${c.text.inset[3]}px ${c.text.inset[0]}px`,
                    }}
                  >
                    <Paras paras={c.text.paras} />
                  </td>
                ) : null,
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/** One slide at its own size (CSS pixels), scaled to `width`. */
export function SlideStage({ deck, slide, width }: { deck: Deck; slide: Slide; width: number }) {
  const bgUrl = useImageUrl(deck, slide.bg.kind === 'img' ? slide.bg.img : null)
  const scale = width / deck.width
  return (
    <div className="pptx-stage" style={{ width: deck.width, height: deck.height, transform: `scale(${scale})`, ...fillCss(slide.bg, bgUrl) }}>
      {slide.items.map((it, i) =>
        it.t === 'shape' ? <ShapeItem key={i} deck={deck} it={it} /> : it.t === 'pic' ? <PicItem key={i} deck={deck} it={it} /> : <TableItem key={i} it={it} />,
      )}
    </div>
  )
}

export function SlidesView({ blob, onFail }: { blob: Blob; onFail: () => void }) {
  const [deck, setDeck] = useState<Deck | null>(null)
  const [zoom, setZoom] = useState(1)
  const [page, setPage] = useState(1)
  const [width, setWidth] = useState(0)
  const scroller = useRef<HTMLDivElement>(null)
  const boxes = useRef<(HTMLDivElement | null)[]>([])
  const cur = useRef(1)
  const failRef = useRef(onFail)
  failRef.current = onFail

  useEffect(() => {
    let opened: Deck | null = null
    let off = false
    void (async () => {
      try {
        const mod = await import('../media/pptx')
        const d = await mod.openPptx(new Uint8Array(await blob.arrayBuffer()))
        if (off) return d.close()
        opened = d
        if (!d.slides.length) throw new Error('no slides')
        setDeck(d)
      } catch (e) {
        console.info('pptx failed', e)
        if (!off) failRef.current()
      }
    })()
    return () => {
      off = true
      opened?.close()
    }
  }, [blob])

  useEffect(() => {
    const el = scroller.current
    if (!el) return
    const ro = new ResizeObserver(() => {
      const w = Math.min(el.clientWidth - 32, 1100)
      setWidth((prev) => (Math.abs(prev - w) > 24 ? w : prev))
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const onVisible = useRef((n: number) => {
    cur.current = n
    setPage(n)
  }).current

  useEffect(() => {
    if (!deck) return
    const count = deck.slides.length
    const go = (n: number) => {
      const t = Math.min(count, Math.max(1, n))
      cur.current = t
      setPage(t)
      const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
      boxes.current[t - 1]?.scrollIntoView({ block: 'start', behavior: reduce ? 'auto' : 'smooth' })
    }
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName
      if (e.defaultPrevented || e.altKey || e.metaKey || e.ctrlKey || tag === 'INPUT' || tag === 'TEXTAREA') return
      let n: number | null = null
      if (['ArrowDown', 'ArrowRight', 'PageDown'].includes(e.key) || (e.key === ' ' && tag !== 'BUTTON')) n = cur.current + 1
      else if (['ArrowUp', 'ArrowLeft', 'PageUp'].includes(e.key)) n = cur.current - 1
      else if (e.key === 'Home') n = 1
      else if (e.key === 'End') n = count
      if (n === null) return
      e.preventDefault()
      go(n)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [deck])

  const onWheel = (e: React.WheelEvent) => {
    if (!e.ctrlKey) return
    e.preventDefault()
    setZoom((z) => Math.min(4, Math.max(0.5, z * Math.exp(-e.deltaY * 0.01))))
  }

  const slideW = Math.round(width * zoom)
  return (
    <div className="pdf-wrap">
      <div className="pdf-scroll pptx-scroll" ref={scroller} onWheel={onWheel}>
        {deck &&
          width > 0 &&
          deck.slides.map((s, i) => (
            <SlideFrame
              key={s.n}
              deck={deck}
              slide={s}
              width={slideW}
              root={scroller}
              onVisible={onVisible}
              boxRef={(el) => {
                boxes.current[i] = el
              }}
            />
          ))}
        {deck && deck.total > deck.slides.length && <p className="hint center">Aperçu limité aux {deck.slides.length} premières diapositives.</p>}
        {!deck && <div className="dv-center"><span className="spinner" aria-label="Chargement de la présentation" /></div>}
      </div>
      {deck && (
        <div className="pdf-tools glass" role="toolbar" aria-label="Zoom">
          <button className="icon-btn" aria-label="Dézoomer" onClick={() => setZoom((z) => Math.max(0.5, +(z / 1.25).toFixed(2)))}>
            <ZoomOut />
          </button>
          <button className="pdf-zoom mono" onClick={() => setZoom(1)} aria-label="Ajuster à la largeur">
            {Math.round(zoom * 100)} %
          </button>
          <button className="icon-btn" aria-label="Zoomer" onClick={() => setZoom((z) => Math.min(4, +(z * 1.25).toFixed(2)))}>
            <ZoomIn />
          </button>
          <span className="mono pdf-page" aria-live="polite">
            {page} / {deck.slides.length}
          </span>
        </div>
      )}
    </div>
  )
}

function SlideFrame({
  deck,
  slide,
  width,
  root,
  onVisible,
  boxRef,
}: {
  deck: Deck
  slide: Slide
  width: number
  root: React.RefObject<HTMLDivElement | null>
  onVisible: (n: number) => void
  boxRef: (el: HTMLDivElement | null) => void
}) {
  const box = useRef<HTMLDivElement>(null)
  const [near, setNear] = useState(slide.n <= 3)
  useEffect(() => {
    const el = box.current
    if (!el) return
    const io = new IntersectionObserver((es) => es.some((e) => e.isIntersecting) && setNear(true), { root: root.current, rootMargin: '800px 0px' })
    const seen = new IntersectionObserver((es) => es.some((e) => e.isIntersecting) && onVisible(slide.n), { root: root.current, threshold: 0.6 })
    io.observe(el)
    seen.observe(el)
    return () => {
      io.disconnect()
      seen.disconnect()
    }
  }, [slide.n, onVisible, root])
  const height = Math.round((width * deck.height) / deck.width)
  return (
    <section
      className={`pptx-slide${slide.hidden ? ' hidden-slide' : ''}`}
      aria-label={`Diapositive ${slide.n}`}
      ref={(el) => {
        box.current = el as HTMLDivElement | null
        boxRef(el as HTMLDivElement | null)
      }}
    >
      <span className="pptx-num mono" aria-hidden="true">
        {slide.n}
        {slide.hidden ? ' · masquée' : ''}
      </span>
      <div className={`pdf-page-box pptx-box${near ? ' done' : ''}`} style={{ width, height }}>
        {near && <SlideStage deck={deck} slide={slide} width={width} />}
      </div>
    </section>
  )
}
