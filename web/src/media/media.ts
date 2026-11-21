// Client-side media preparation (spec section 5).
// Photos: longest side 2048, AVIF or WebP at 0.7 when the browser encodes it, else JPEG.
// Thumbnails: 64 px, JPEG, kept under 4 KiB. Video: sent as is (25 MB cap), poster frame.
// Voice: MediaRecorder, audio/mp4 (AAC) first so iPhones play it, else webm/opus.

export const VIDEO_MAX_BYTES = 25 * 1024 * 1024
export const FILE_MAX_BYTES = 100 * 1024 * 1024

export interface PreparedMedia {
  bytes: Uint8Array
  mime: string
  width?: number
  height?: number
  duration_ms?: number
  thumb?: string
}

const encoderCache = new Map<string, boolean>()

async function canEncode(mime: string): Promise<boolean> {
  if (encoderCache.has(mime)) return encoderCache.get(mime)!
  const c = document.createElement('canvas')
  c.width = c.height = 2
  const blob = await new Promise<Blob | null>((r) => c.toBlob(r, mime, 0.7))
  const ok = !!blob && blob.type === mime
  encoderCache.set(mime, ok)
  return ok
}

function toBlob(canvas: HTMLCanvasElement, mime: string, q: number): Promise<Blob> {
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('encode failed'))), mime, q),
  )
}

async function blobToB64(blob: Blob): Promise<string> {
  const b = new Uint8Array(await blob.arrayBuffer())
  let s = ''
  for (const x of b) s += String.fromCharCode(x)
  return btoa(s)
}

/** A tiny JPEG of `source`, longest side 64 px, under 4 KiB (quality steps down). */
export async function thumbnail(source: CanvasImageSource, w: number, h: number): Promise<string> {
  const scale = 64 / Math.max(w, h)
  const c = document.createElement('canvas')
  c.width = Math.max(1, Math.round(w * scale))
  c.height = Math.max(1, Math.round(h * scale))
  c.getContext('2d')!.drawImage(source, 0, 0, c.width, c.height)
  for (const q of [0.6, 0.45, 0.3, 0.2]) {
    const b = await toBlob(c, 'image/jpeg', q)
    if (b.size <= 4096) return blobToB64(b)
  }
  return blobToB64(await toBlob(c, 'image/jpeg', 0.1))
}

export async function prepareImage(file: File): Promise<PreparedMedia> {
  const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height))
  const w = Math.round(bitmap.width * scale)
  const h = Math.round(bitmap.height * scale)
  const c = document.createElement('canvas')
  c.width = w
  c.height = h
  const ctx = c.getContext('2d')!
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(bitmap, 0, 0, w, h)
  let mime = 'image/jpeg'
  if (await canEncode('image/avif')) mime = 'image/avif'
  else if (await canEncode('image/webp')) mime = 'image/webp'
  const blob = await toBlob(c, mime, 0.7)
  const thumb = await thumbnail(bitmap, bitmap.width, bitmap.height)
  bitmap.close()
  return { bytes: new Uint8Array(await blob.arrayBuffer()), mime, width: w, height: h, thumb }
}

export async function prepareVideo(file: File): Promise<PreparedMedia> {
  if (file.size > VIDEO_MAX_BYTES) throw new Error('Vidéo trop lourde (25 Mo max).')
  const url = URL.createObjectURL(file)
  try {
    const video = document.createElement('video')
    video.muted = true
    video.playsInline = true
    video.preload = 'auto'
    video.src = url
    await new Promise<void>((resolve, reject) => {
      video.onloadeddata = () => resolve()
      video.onerror = () => reject(new Error('video'))
      setTimeout(() => resolve(), 4000)
    })
    video.currentTime = Math.min(0.5, (video.duration || 1) / 2)
    await new Promise<void>((r) => {
      video.onseeked = () => r()
      setTimeout(r, 1500)
    })
    const w = video.videoWidth || 320
    const h = video.videoHeight || 240
    let thumb: string | undefined
    try {
      thumb = await thumbnail(video, w, h)
    } catch {
      thumb = undefined
    }
    return {
      bytes: new Uint8Array(await file.arrayBuffer()),
      mime: file.type || 'video/mp4',
      width: w,
      height: h,
      duration_ms: Number.isFinite(video.duration) ? Math.round(video.duration * 1000) : undefined,
      thumb,
    }
  } finally {
    URL.revokeObjectURL(url)
  }
}

export async function prepareFile(file: File): Promise<PreparedMedia> {
  if (file.size > FILE_MAX_BYTES) throw new Error('Fichier trop lourd (100 Mo max).')
  return { bytes: new Uint8Array(await file.arrayBuffer()), mime: file.type || 'application/octet-stream' }
}

export function voiceMime(): string {
  const prefs = ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/ogg;codecs=opus', 'audio/webm']
  for (const m of prefs) if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(m)) return m
  return ''
}

export class VoiceRecorder {
  private rec: MediaRecorder | null = null
  private chunks: Blob[] = []
  private stream: MediaStream | null = null
  private started = 0
  analyser: AnalyserNode | null = null
  private ctx: AudioContext | null = null

  async start() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
    })
    const mime = voiceMime()
    this.rec = new MediaRecorder(this.stream, mime ? { mimeType: mime, audioBitsPerSecond: 32_000 } : undefined)
    this.chunks = []
    this.rec.ondataavailable = (e) => e.data.size && this.chunks.push(e.data)
    this.rec.start(250)
    this.started = performance.now()
    try {
      this.ctx = new AudioContext()
      this.analyser = this.ctx.createAnalyser()
      this.analyser.fftSize = 256
      this.ctx.createMediaStreamSource(this.stream).connect(this.analyser)
    } catch {
      this.analyser = null
    }
  }

  get elapsed(): number {
    return this.started ? performance.now() - this.started : 0
  }

  async stop(): Promise<PreparedMedia | null> {
    const rec = this.rec
    if (!rec) return null
    const duration = this.elapsed
    await new Promise<void>((r) => {
      rec.onstop = () => r()
      rec.stop()
    })
    this.cleanup()
    const type = (rec.mimeType || 'audio/webm').split(';')[0]
    const blob = new Blob(this.chunks, { type })
    if (duration < 400 || blob.size === 0) return null
    return { bytes: new Uint8Array(await blob.arrayBuffer()), mime: type, duration_ms: Math.round(duration) }
  }

  cancel() {
    if (this.rec && this.rec.state !== 'inactive') this.rec.stop()
    this.cleanup()
  }

  private cleanup() {
    this.stream?.getTracks().forEach((t) => t.stop())
    this.ctx?.close().catch(() => {})
    this.ctx = null
    this.analyser = null
    this.rec = null
    this.stream = null
    this.started = 0
  }
}

export function formatDuration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export function formatSize(n: number): string {
  if (n < 1024) return `${n} o`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} Ko`
  return `${(n / 1024 / 1024).toFixed(1).replace('.', ',')} Mo`
}
