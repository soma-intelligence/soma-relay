// Ring and ringback generated with WebAudio (no audio files).

export class Ringer {
  private ctx: AudioContext | null = null
  private timer: ReturnType<typeof setInterval> | null = null

  /** incoming: two soft chimes every 3 s. outgoing: a quiet 425 Hz tone, 1 s on, 3 s off. */
  start(kind: 'incoming' | 'outgoing') {
    this.stop()
    try {
      this.ctx = new AudioContext()
    } catch {
      return
    }
    const play = () => (kind === 'incoming' ? this.chime() : this.ringback())
    play()
    this.timer = setInterval(play, kind === 'incoming' ? 3000 : 4000)
  }

  private tone(freq: number, at: number, dur: number, gain: number) {
    const ctx = this.ctx
    if (!ctx) return
    const o = ctx.createOscillator()
    const g = ctx.createGain()
    o.type = 'sine'
    o.frequency.value = freq
    const t = ctx.currentTime + at
    g.gain.setValueAtTime(0, t)
    g.gain.linearRampToValueAtTime(gain, t + 0.02)
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur)
    o.connect(g).connect(ctx.destination)
    o.start(t)
    o.stop(t + dur + 0.05)
  }

  private chime() {
    this.tone(880, 0, 0.5, 0.18)
    this.tone(1318.5, 0.18, 0.7, 0.14)
    this.tone(880, 0.9, 0.5, 0.18)
    this.tone(1318.5, 1.08, 0.7, 0.14)
  }

  private ringback() {
    this.tone(425, 0, 1.0, 0.06)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    this.ctx?.close().catch(() => {})
    this.ctx = null
  }
}
