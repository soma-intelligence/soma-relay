// pdf.js, loaded on demand (dynamic import from media.ts and the document viewer).
// Scripting and eval stay off: a PDF from a contact is untrusted.

import * as pdfjs from 'pdfjs-dist'
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl

export type PdfDoc = pdfjs.PDFDocumentProxy

export interface OpenedPdf {
  doc: PdfDoc
  close: () => void
}

export async function openPdf(bytes: Uint8Array): Promise<OpenedPdf> {
  // pdf.js transfers the buffer to its worker: hand it a copy.
  const task = pdfjs.getDocument({ data: bytes.slice(), enableXfa: false })
  const doc = await task.promise
  return { doc, close: () => void task.destroy() }
}

export async function renderPage(doc: PdfDoc, n: number, canvas: HTMLCanvasElement, cssWidth: number) {
  const page = await doc.getPage(n)
  const base = page.getViewport({ scale: 1 })
  const dpr = Math.min(window.devicePixelRatio || 1, 2)
  const scale = (cssWidth / base.width) * dpr
  const viewport = page.getViewport({ scale })
  canvas.width = Math.floor(viewport.width)
  canvas.height = Math.floor(viewport.height)
  canvas.style.width = `${Math.floor(viewport.width / dpr)}px`
  canvas.style.height = `${Math.floor(viewport.height / dpr)}px`
  const task = page.render({ canvas, viewport })
  await task.promise
  return task
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
 * First page as a small JPEG for the bubble (at most 4 KiB, like every thumb) plus the page
 * count. Width steps down until it fits.
 */
export async function pdfThumbnail(bytes: Uint8Array): Promise<{ thumb?: string; pages: number; width: number; height: number }> {
  const { doc, close } = await openPdf(bytes)
  try {
    const page = await doc.getPage(1)
    const base = page.getViewport({ scale: 1 })
    let last: string | undefined
    for (const w of [200, 160, 120]) {
      const viewport = page.getViewport({ scale: w / base.width })
      const c = document.createElement('canvas')
      c.width = Math.round(viewport.width)
      c.height = Math.round(viewport.height)
      const ctx = c.getContext('2d')!
      ctx.fillStyle = '#fff'
      ctx.fillRect(0, 0, c.width, c.height)
      await page.render({ canvas: c, viewport, background: '#ffffff' }).promise
      for (const q of [0.6, 0.45, 0.3]) {
        const { b64, size } = await jpegB64(c, q)
        last = b64
        if (size <= 4096) return { thumb: b64, pages: doc.numPages, width: Math.round(base.width), height: Math.round(base.height) }
      }
    }
    return { thumb: last && last.length < 8000 ? last : undefined, pages: doc.numPages, width: Math.round(base.width), height: Math.round(base.height) }
  } finally {
    close()
  }
}
