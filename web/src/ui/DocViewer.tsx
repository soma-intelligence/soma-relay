// Document viewer, loaded on demand. Each renderer is its own dynamic import too:
// PDF (pdf.js, pages and zoom), Word .docx (docx-preview), spreadsheets and CSV (SheetJS),
// PowerPoint .pptx (our own reader in media/pptx.ts, drawn by PptxView), text and code as text,
// images and media inline. Older presentation formats (.ppt, .key, .odp) show the sender's
// thumbnail and a download.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { formatSize } from '../media/media'
import { docType } from './Message'
import { Close, Download, File, ZoomIn, ZoomOut } from './Icons'
import { downloadBlob } from './common'
import { SlidesView } from './PptxView'

export default function DocViewer({ m, onClose }: { m: ChatMessage; onClose: () => void }) {
  const a = m.attachment!
  const kind = docType(a.name, a.mime)
  const [blob, setBlob] = useState<Blob | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let off = false
    relay
      .mediaUrl(m)
      .then(async (url) => {
        if (!url) throw new Error('Fichier indisponible.')
        const b = await (await fetch(url)).blob()
        if (!off) setBlob(b)
      })
      .catch((e) => !off && setError(e instanceof Error ? e.message : 'Téléchargement impossible.'))
    return () => {
      off = true
    }
  }, [m])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const save = () => blob && downloadBlob(new Blob([blob], { type: a.mime }), a.name ?? 'fichier')
  const objUrl = useMemo(() => (blob && (kind === 'image' || kind === 'media') ? URL.createObjectURL(blob) : null), [blob, kind])
  useEffect(() => () => void (objUrl && URL.revokeObjectURL(objUrl)), [objUrl])
  const failPdf = useCallback(() => setError('Ce PDF ne s’ouvre pas ici.'), [])
  const failDocx = useCallback(() => setError('Ce document Word ne s’ouvre pas ici.'), [])
  const failSheet = useCallback(() => setError('Ce tableur ne s’ouvre pas ici.'), [])
  const failSlides = useCallback(() => setError('Cette présentation ne s’ouvre pas ici.'), [])
  const pptx = kind === 'slides' && (/\.pptx$/i.test(a.name ?? '') || a.mime.includes('presentationml.presentation'))

  let body: React.ReactNode
  if (error) body = <Fallback m={m} note={error} onSave={save} />
  else if (!blob) body = <div className="dv-center"><span className="spinner" aria-label="Chargement" /></div>
  else if (kind === 'pdf') body = <PdfView blob={blob} onFail={failPdf} />
  else if (kind === 'word' && /\.docx$/i.test(a.name ?? '.docx')) body = <DocxView blob={blob} onFail={failDocx} />
  else if (kind === 'sheet') body = <SheetView blob={blob} name={a.name ?? ''} onFail={failSheet} />
  else if (pptx) body = <SlidesView blob={blob} onFail={failSlides} />
  else if (kind === 'text') body = <TextView blob={blob} />
  else if (kind === 'image') body = <div className="dv-center"><img className="dv-img" src={objUrl ?? ''} alt={a.name ?? ''} /></div>
  else if (kind === 'media')
    body = (
      <div className="dv-center">
        {a.mime.startsWith('audio/') ? <audio src={objUrl ?? ''} controls /> : <video className="dv-img" src={objUrl ?? ''} controls />}
      </div>
    )
  else
    body = (
      <Fallback
        m={m}
        note={kind === 'slides' ? 'L’aperçu des présentations n’est pas disponible dans le navigateur. Télécharge-la pour l’ouvrir.' : 'Pas d’aperçu pour ce type de fichier.'}
        onSave={save}
      />
    )

  return (
    <div className="docview" role="dialog" aria-modal="true" aria-label={a.name ?? 'Document'}>
      <header className="dv-head glass">
        <button className="icon-btn" aria-label="Fermer" onClick={onClose} autoFocus>
          <Close />
        </button>
        <div className="dv-title">
          <b>{a.name ?? 'Document'}</b>
          <span className="mono">
            {formatSize(a.size)}
            {a.pages ? ` · ${pageCount(a.pages, kind === 'slides')}` : ''}
          </span>
        </div>
        <button className="icon-btn" aria-label="Télécharger" onClick={save} disabled={!blob}>
          <Download />
        </button>
      </header>
      <div className="dv-body">{body}</div>
    </div>
  )
}

/** "3 pages" for documents, "3 diapos" for presentations. */
function pageCount(n: number, slides: boolean): string {
  return `${n} ${slides ? 'diapo' : 'page'}${n > 1 ? 's' : ''}`
}

function Fallback({ m, note, onSave }: { m: ChatMessage; note: string; onSave: () => void }) {
  const a = m.attachment!
  return (
    <div className="dv-center dv-fallback">
      {a.thumb ? <img src={`data:image/jpeg;base64,${a.thumb}`} alt="" /> : <span className="dv-ico"><File size={40} /></span>}
      <p>{note}</p>
      <button className="btn primary" onClick={onSave}>
        <Download /> Télécharger
      </button>
    </div>
  )
}

function PdfView({ blob, onFail }: { blob: Blob; onFail: () => void }) {
  const [pdf, setPdf] = useState<{ doc: import('../media/pdf').PdfDoc; render: typeof import('../media/pdf').renderPage } | null>(null)
  const [zoom, setZoom] = useState(1)
  const [page, setPage] = useState(1)
  const [ratio, setRatio] = useState(1.414)
  const scroller = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)

  useEffect(() => {
    let close: (() => void) | null = null
    let off = false
    void (async () => {
      try {
        const mod = await import('../media/pdf')
        const opened = await mod.openPdf(new Uint8Array(await blob.arrayBuffer()))
        close = opened.close
        const p1 = await opened.doc.getPage(1)
        const v = p1.getViewport({ scale: 1 })
        if (off) return opened.close()
        setRatio(v.height / v.width)
        setPdf({ doc: opened.doc, render: mod.renderPage })
      } catch (e) {
        console.info('pdf failed', e)
        if (!off) onFail()
      }
    })()
    return () => {
      off = true
      close?.()
    }
  }, [blob, onFail])

  useEffect(() => {
    const el = scroller.current
    if (!el) return
    // Only real size changes count: a scrollbar coming and going must not re-render the pages.
    const ro = new ResizeObserver(() => {
      const w = Math.min(el.clientWidth - 32, 900)
      setWidth((prev) => (Math.abs(prev - w) > 24 ? w : prev))
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const onWheel = (e: React.WheelEvent) => {
    if (!e.ctrlKey) return
    e.preventDefault()
    setZoom((z) => Math.min(4, Math.max(0.5, z * Math.exp(-e.deltaY * 0.01))))
  }

  const pageW = Math.round(width * zoom)
  return (
    <div className="pdf-wrap">
      <div className="pdf-scroll" ref={scroller} onWheel={onWheel}>
        {pdf && width > 0 &&
          Array.from({ length: pdf.doc.numPages }, (_, i) => (
            <PdfPage key={i} n={i + 1} pdf={pdf} width={pageW} ratio={ratio} onVisible={setPage} root={scroller} />
          ))}
        {!pdf && <div className="dv-center"><span className="spinner" aria-label="Chargement du PDF" /></div>}
      </div>
      {pdf && (
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
            {page} / {pdf.doc.numPages}
          </span>
        </div>
      )}
    </div>
  )
}

function PdfPage({
  n,
  pdf,
  width,
  ratio,
  onVisible,
  root,
}: {
  n: number
  pdf: { doc: import('../media/pdf').PdfDoc; render: typeof import('../media/pdf').renderPage }
  width: number
  ratio: number
  onVisible: (n: number) => void
  root: React.RefObject<HTMLDivElement | null>
}) {
  const box = useRef<HTMLDivElement>(null)
  const canvas = useRef<HTMLCanvasElement>(null)
  const [near, setNear] = useState(n <= 2)
  const [done, setDone] = useState(false)

  useEffect(() => {
    const el = box.current
    if (!el) return
    // Two observers: the margin one starts rendering early, the plain one tracks the page shown
    // (a root margin would also count pages below the screen as visible).
    const io = new IntersectionObserver((es) => es.some((e) => e.isIntersecting) && setNear(true), {
      root: root.current,
      rootMargin: '600px 0px',
    })
    const seen = new IntersectionObserver((es) => es.some((e) => e.isIntersecting) && onVisible(n), {
      root: root.current,
      threshold: 0.25,
    })
    io.observe(el)
    seen.observe(el)
    return () => {
      io.disconnect()
      seen.disconnect()
    }
  }, [n, onVisible, root])

  useEffect(() => {
    if (!near || !canvas.current || width <= 0) return
    let task: { cancel: () => void } | null = null
    let off = false
    setDone(false)
    const t = setTimeout(() => {
      pdf
        .render(pdf.doc, n, canvas.current!, width)
        .then((rt) => {
          task = rt
          if (!off) setDone(true)
        })
        .catch(() => {})
    }, 60)
    return () => {
      off = true
      clearTimeout(t)
      task?.cancel()
    }
  }, [near, width, n, pdf])

  return (
    <div className={`pdf-page-box${done ? ' done' : ''}`} ref={box} style={{ width, height: Math.round(width * ratio) }} aria-label={`Page ${n}`}>
      <canvas ref={canvas} />
    </div>
  )
}

function DocxView({ blob, onFail }: { blob: Blob; onFail: () => void }) {
  const box = useRef<HTMLDivElement>(null)
  const [busy, setBusy] = useState(true)
  useEffect(() => {
    let off = false
    void (async () => {
      try {
        const { renderAsync } = await import('docx-preview')
        if (off || !box.current) return
        await renderAsync(blob, box.current, undefined, {
          className: 'docx',
          inWrapper: true,
          breakPages: true,
          ignoreLastRenderedPageBreak: true,
          renderComments: false,
          renderChanges: false,
          useBase64URL: true,
        })
        // Links from a document open outside the app, never in this tab.
        box.current.querySelectorAll('a[href]').forEach((el) => {
          el.setAttribute('target', '_blank')
          el.setAttribute('rel', 'noopener noreferrer nofollow')
        })
      } catch (e) {
        console.info('docx failed', e)
        if (!off) onFail()
      } finally {
        if (!off) setBusy(false)
      }
    })()
    return () => {
      off = true
    }
  }, [blob, onFail])
  return (
    <div className="docx-scroll">
      {busy && <div className="dv-center"><span className="spinner" aria-label="Chargement du document" /></div>}
      <div ref={box} />
    </div>
  )
}

const MAX_ROWS = 2000
const MAX_COLS = 60

function SheetView({ blob, name, onFail }: { blob: Blob; name: string; onFail: () => void }) {
  const [book, setBook] = useState<{ names: string[]; rows: (sheet: string) => string[][] } | null>(null)
  const [sheet, setSheet] = useState(0)
  const failRef = useRef(onFail)
  failRef.current = onFail
  useEffect(() => {
    let off = false
    void (async () => {
      try {
        const XLSX = await import('xlsx')
        const isText = /\.(csv|tsv)$/i.test(name)
        const wb = isText ? XLSX.read(await blob.text(), { type: 'string', raw: true }) : XLSX.read(await blob.arrayBuffer(), { type: 'array', cellDates: true })
        if (off) return
        setBook({
          names: wb.SheetNames,
          rows: (s) =>
            (XLSX.utils.sheet_to_json(wb.Sheets[s], { header: 1, raw: false, blankrows: false, defval: '' }) as unknown[][])
              .slice(0, MAX_ROWS)
              .map((r) => r.slice(0, MAX_COLS).map((c) => (c === null || c === undefined ? '' : String(c)))),
        })
      } catch (e) {
        console.info('sheet failed', e)
        if (!off) failRef.current()
      }
    })()
    return () => {
      off = true
    }
  }, [blob, name])
  const rows = useMemo(() => (book ? book.rows(book.names[sheet]) : []), [book, sheet])
  if (!book) return <div className="dv-center"><span className="spinner" aria-label="Chargement du tableur" /></div>
  const cols = Math.max(0, ...rows.map((r) => r.length))
  return (
    <div className="sheet-view">
      {book.names.length > 1 && (
        <div className="seg sheet-tabs" role="tablist" aria-label="Feuilles">
          {book.names.map((n, i) => (
            <button key={n} role="tab" aria-pressed={i === sheet} aria-selected={i === sheet} onClick={() => setSheet(i)}>
              {n}
            </button>
          ))}
        </div>
      )}
      <div className="sheet-scroll">
        <table>
          <thead>
            <tr>
              <th />
              {Array.from({ length: cols }, (_, i) => (
                <th key={i}>{colName(i)}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i}>
                <th>{i + 1}</th>
                {Array.from({ length: cols }, (_, j) => (
                  <td key={j}>{r[j] ?? ''}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length >= MAX_ROWS && <p className="hint center">Aperçu limité aux {MAX_ROWS} premières lignes.</p>}
      </div>
    </div>
  )
}

function colName(i: number): string {
  let s = ''
  let n = i + 1
  while (n > 0) {
    const r = (n - 1) % 26
    s = String.fromCharCode(65 + r) + s
    n = Math.floor((n - 1) / 26)
  }
  return s
}

function TextView({ blob }: { blob: Blob }) {
  const [text, setText] = useState<string | null>(null)
  useEffect(() => {
    void blob
      .slice(0, 1024 * 1024)
      .text()
      .then(setText)
  }, [blob])
  return (
    <pre className="text-view">
      {text ?? ''}
      {blob.size > 1024 * 1024 ? '\n\n[…] Aperçu limité au premier Mo.' : ''}
    </pre>
  )
}
