// Profile and group photos (spec v1.2 section 6): a square crop, 256 x 256 px, JPEG of at most
// 24 KiB, identified by the lowercase hex SHA-256 of the JPEG bytes.

import { fromB64, sha256, toHex } from './bytes'

export const AVATAR_PX = 256
export const AVATAR_MAX_BYTES = 24 * 1024
/** Receivers accept a little more than the sender limit, for other clients' encoders. */
const AVATAR_ACCEPT_BYTES = 40 * 1024

export interface Crop {
  /** Source rectangle, in source pixels. Always square. */
  sx: number
  sy: number
  size: number
}

async function toJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Uint8Array> {
  const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', quality))
  if (!blob) throw new Error('Encodage de la photo impossible.')
  return new Uint8Array(await blob.arrayBuffer())
}

/** Draws the crop at 256 px and lowers the JPEG quality until it fits in 24 KiB. */
export async function encodeAvatar(src: CanvasImageSource, crop: Crop): Promise<Uint8Array> {
  const c = document.createElement('canvas')
  c.width = c.height = AVATAR_PX
  const g = c.getContext('2d')!
  g.fillStyle = '#ffffff'
  g.fillRect(0, 0, AVATAR_PX, AVATAR_PX)
  g.imageSmoothingQuality = 'high'
  g.drawImage(src, crop.sx, crop.sy, crop.size, crop.size, 0, 0, AVATAR_PX, AVATAR_PX)
  for (let q = 0.9; q >= 0.2; q -= 0.08) {
    const bytes = await toJpeg(c, q)
    if (bytes.length <= AVATAR_MAX_BYTES) return bytes
  }
  // Very noisy pictures: halve the detail, then encode at a low quality.
  const s = document.createElement('canvas')
  s.width = s.height = AVATAR_PX / 2
  s.getContext('2d')!.drawImage(c, 0, 0, AVATAR_PX / 2, AVATAR_PX / 2)
  g.drawImage(s, 0, 0, AVATAR_PX, AVATAR_PX)
  return toJpeg(c, 0.5)
}

export async function avatarHash(bytes: Uint8Array): Promise<string> {
  return toHex(await sha256(bytes))
}

/** Checks a received base64 avatar. Returns its hash, or null when it is not a small JPEG. */
export async function checkAvatar(b64: string): Promise<string | null> {
  if (b64.length > Math.ceil((AVATAR_ACCEPT_BYTES * 4) / 3) + 4) return null
  let bytes: Uint8Array
  try {
    bytes = fromB64(b64)
  } catch {
    return null
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null
  return avatarHash(bytes)
}

/** Loads a picked image file, honouring its EXIF orientation. */
export async function loadImage(file: Blob): Promise<ImageBitmap | HTMLImageElement> {
  if (typeof createImageBitmap === 'function') {
    try {
      return await createImageBitmap(file, { imageOrientation: 'from-image' })
    } catch {
      /* fall back to an <img> */
    }
  }
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    return img
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }
}

export const avatarDataUrl = (b64: string): string => `data:image/jpeg;base64,${b64}`
