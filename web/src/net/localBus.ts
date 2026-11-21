// LocalBus: a stand-in node between tabs of the same browser, over BroadcastChannel.
// For development and demos without a node: no store and forward (both tabs must be open),
// no authentication. Turned on in Settings, and by default with the mock engine.

import { fromB64, toB64Url } from '../lib/bytes'

type Frame =
  | { t: 'env'; to: string; env: string }
  | { t: 'here'; mailbox: string }

export class LocalBus {
  private ch: BroadcastChannel
  private seen = new Map<string, number>()
  private beat: ReturnType<typeof setInterval>

  constructor(
    private mailbox: string,
    private onEnv: (env: Uint8Array) => void,
  ) {
    this.ch = new BroadcastChannel('soma-relay-localbus')
    this.ch.onmessage = (e: MessageEvent<Frame>) => {
      const f = e.data
      if (f.t === 'env' && f.to === this.mailbox) this.onEnv(fromB64(f.env))
      else if (f.t === 'here') this.seen.set(f.mailbox, Date.now())
    }
    const hello = () => this.ch.postMessage({ t: 'here', mailbox: this.mailbox } satisfies Frame)
    hello()
    this.beat = setInterval(hello, 5000)
  }

  send(to: string, env: Uint8Array): boolean {
    this.ch.postMessage({ t: 'env', to, env: toB64Url(env) } satisfies Frame)
    return true
  }

  online(mailboxes: string[]): string[] {
    const now = Date.now()
    return mailboxes.filter((m) => now - (this.seen.get(m) ?? 0) < 12_000)
  }

  close() {
    clearInterval(this.beat)
    this.ch.close()
  }
}
