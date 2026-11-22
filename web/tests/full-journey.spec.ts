import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test'

// A full journey across three browser profiles, for what the other specs do not cover: photos
// from the gallery and from the in-app camera, a PDF opened in the viewer, a location pin, a link
// preview, the banner and list order when a message lands in another conversation, disappearing
// messages, a message sent while the other side is closed, and an audio call. On a node that hands
// out TURN credentials, the call is forced through the TURN relay.

const NODE = process.env.RELAY_NODE_URL

test.skip(!NODE, 'set RELAY_NODE_URL to a running relay-node that serves web/dist')

test.use({
  launchOptions: { args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] },
})

async function context(browser: Browser): Promise<BrowserContext> {
  return browser.newContext({
    permissions: ['clipboard-read', 'clipboard-write', 'geolocation', 'camera', 'microphone'],
    geolocation: { latitude: 48.8566, longitude: 2.3522, accuracy: 12 },
  })
}

async function open(ctx: BrowserContext, profile: string, relayOnly = false, fakeMedia = false): Promise<Page> {
  const page = await ctx.newPage()
  page.on('pageerror', (e) => console.log(`[${profile}] ${e.message}`))
  page.on('console', (m) => { if (process.env.E2E_DEBUG) console.log(`[${profile}] ${m.type()} ${m.text()}`) })
  // Record every peer connection; with relayOnly, force them through TURN so a connected call
  // proves the relay works.
  await page.addInitScript((relay) => {
    const Native = window.RTCPeerConnection
    const all: RTCPeerConnection[] = []
    ;(window as unknown as { __pcs: RTCPeerConnection[] }).__pcs = all
    const Shim = function (cfg?: RTCConfiguration) {
      const pc = new Native(relay ? { ...(cfg ?? {}), iceTransportPolicy: 'relay' } : cfg)
      all.push(pc)
      return pc
    } as unknown as typeof RTCPeerConnection
    Shim.prototype = Native.prototype
    // @ts-expect-error static members
    Shim.generateCertificate = Native.generateCertificate
    window.RTCPeerConnection = Shim
  }, relayOnly)
  await page.goto(`/?profile=${profile}${fakeMedia ? '&fakemedia' : ''}`)
  return page
}

async function onboard(page: Page, name: string) {
  await page.fill('#ob-name', name)
  await page.getByRole('button', { name: 'Créer mon identité' }).click()
  await page.getByRole('button', { name: 'C’est parti' }).click()
}

async function shortLink(page: Page): Promise<string> {
  await page.getByRole('button', { name: 'Mon code', exact: true }).first().click()
  await page.getByRole('button', { name: 'Lien court' }).click()
  await expect(page.getByRole('button', { name: 'Copié' })).toBeVisible()
  const link = await page.evaluate(() => navigator.clipboard.readText())
  await page.keyboard.press('Escape')
  await expect(page.locator('.mycard')).toHaveCount(0)
  return link
}

async function say(page: Page, text: string) {
  await page.fill('#composer-input', text)
  await page.keyboard.press('Enter')
}

async function meet(from: Page, to: Page, toName: string, fromName: string, tag: string) {
  const link = await shortLink(to)
  await from.getByRole('button', { name: 'Ajouter un contact', exact: true }).first().click()
  await from.getByRole('button', { name: 'Lien', exact: true }).click()
  await from.fill('#add-link', link)
  await from.locator('form').getByRole('button', { name: 'Ajouter' }).click()
  await expect(from.locator('.chat-title .name')).toHaveText(toName)
  const hello = `Salut ${toName} ${tag}`
  await say(from, hello)
  await to.getByRole('list', { name: 'Discussions' }).getByRole('listitem').filter({ hasText: fromName }).first().click()
  await expect(to.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })
  const back = `Salut ${fromName} ${tag}`
  await say(to, back)
  await expect(from.locator('.bubble', { hasText: back })).toBeVisible({ timeout: 20_000 })
}

async function openChat(page: Page, name: string) {
  const back = page.getByRole('button', { name: 'Retour' })
  if (await back.isVisible()) await back.click()
  await page.getByRole('list', { name: 'Discussions' }).getByRole('listitem').filter({ hasText: name }).first().click()
  await expect(page.locator('.chat-title .name')).toHaveText(name)
}

async function attach(page: Page, item: string) {
  await page.getByRole('button', { name: 'Joindre' }).first().click()
  await page.getByRole('menuitem', { name: item }).click()
}

/** A one-page PDF with a line of text, built in the test so no fixture is needed. */
function tinyPdf(text: string): Buffer {
  const stream = `BT /F1 24 Tf 72 720 Td (${text}) Tj ET`
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ]
  let out = '%PDF-1.4\n'
  const offs: number[] = []
  objs.forEach((o, i) => {
    offs.push(out.length)
    out += `${i + 1} 0 obj\n${o}\nendobj\n`
  })
  const xref = out.length
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
  for (const o of offs) out += `${String(o).padStart(10, '0')} 00000 n \n`
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return Buffer.from(out, 'latin1')
}

async function pngOf(page: Page, hue: number): Promise<Buffer> {
  const b64 = await page.evaluate((h) => {
    const c = document.createElement('canvas')
    c.width = 800
    c.height = 600
    const g = c.getContext('2d')!
    g.fillStyle = `hsl(${h} 70% 50%)`
    g.fillRect(0, 0, 800, 600)
    return c.toDataURL('image/png').split(',')[1]
  }, hue)
  return Buffer.from(b64, 'base64')
}

test('full journey: media, documents, location, preview, banner, offline, disappearing', async ({ browser }) => {
  test.setTimeout(240_000)
  const tag = Date.now().toString(36)
  const ctxA = await context(browser)
  const ctxI = await context(browser)
  const ctxB = await context(browser)
  const alice = await open(ctxA, `ja-${tag}`)
  let ines = await open(ctxI, `jb-${tag}`)
  const bob = await open(ctxB, `jc-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')
  await onboard(bob, 'Bob')
  await meet(alice, ines, 'Inès', 'Alice', tag)
  await meet(bob, ines, 'Inès', 'Bob', tag)
  await openChat(ines, 'Alice')
  await openChat(alice, 'Inès')

  // 1. Photo from the gallery.
  await alice.locator('input[type=file][multiple][accept^="image"]').setInputFiles({ name: 'plage.png', mimeType: 'image/png', buffer: await pngOf(alice, 200) })
  const sentPhotos = alice.locator('.msg.out .photo-wrap')
  await expect(sentPhotos).toHaveCount(1, { timeout: 20_000 })
  await expect(ines.locator('.msg .photo-wrap')).toHaveCount(1, { timeout: 30_000 })

  // 2. Photo from the in-app camera (fake device).
  await alice.getByRole('button', { name: 'Prendre une photo' }).click()
  const cam = alice.locator('.cam-scrim')
  await expect(cam.getByRole('button', { name: 'Prendre la photo' })).toBeEnabled({ timeout: 15_000 })
  await cam.getByRole('button', { name: 'Prendre la photo' }).click()
  await cam.locator('form button.btn.primary').click()
  await expect(cam).toHaveCount(0)
  await expect(ines.locator('.msg .photo-wrap')).toHaveCount(2, { timeout: 30_000 })

  // 3. A PDF opens in the viewer on the other side.
  await alice.locator('input[type=file]:not([accept])').setInputFiles({ name: 'billet.pdf', mimeType: 'application/pdf', buffer: tinyPdf(`Billet ${tag}`) })
  const card = ines.getByRole('button', { name: 'Ouvrir billet.pdf' })
  await expect(card).toBeVisible({ timeout: 30_000 })
  await card.click()
  const viewer = ines.getByRole('dialog', { name: 'billet.pdf' })
  await expect(viewer).toBeVisible()
  await expect(viewer.locator('canvas').first()).toBeVisible({ timeout: 20_000 })
  await viewer.getByRole('button', { name: 'Fermer' }).click()

  // 4. Location pin.
  await attach(alice, 'Position')
  await alice.getByRole('button', { name: 'Envoyer ma position' }).click()
  await expect(ines.getByRole('button', { name: /Position/ }).or(ines.locator('[aria-label="Position"]')).first()).toBeVisible({ timeout: 30_000 })

  // 5. Link preview, built by the sender.
  await alice.fill('#composer-input', 'Regarde https://github.com/soma-intelligence/soma-relay')
  await expect(alice.locator('.link-draft')).toBeVisible({ timeout: 15_000 })
  await alice.keyboard.press('Enter')
  await expect(ines.locator('.link-card').last()).toBeVisible({ timeout: 30_000 })
  await expect(ines.locator('.link-card').last()).toContainText(/github|soma-relay/i)

  // 6. Bob writes while Inès reads Alice: banner, and Bob's conversation goes to the top.
  const fromBob = `Tu viens ce soir ? ${tag}`
  await openChat(bob, 'Inès')
  await say(bob, fromBob)
  const banner = ines.getByRole('button', { name: new RegExp(`Nouveau message de Bob`) })
  await expect(banner).toBeVisible({ timeout: 30_000 })
  await banner.click()
  await expect(ines.locator('.chat-title .name')).toHaveText('Bob')
  await expect(ines.locator('.bubble', { hasText: fromBob })).toBeVisible()
  await ines.getByRole('button', { name: 'Retour' }).click()
  await expect(ines.getByRole('list', { name: 'Discussions' }).getByRole('listitem').first()).toContainText('Bob')

  // 7. Inès closes her tab; Alice writes; Inès comes back and gets it from the node.
  await ines.close()
  const whileAway = `Message pendant ton absence ${tag}`
  await say(alice, whileAway)
  await expect(alice.locator('.msg.out', { hasText: whileAway })).toBeVisible()
  await new Promise((r) => setTimeout(r, 3_000))
  ines = await open(ctxI, `jb-${tag}`)
  await openChat(ines, 'Alice')
  await expect(ines.locator('.bubble', { hasText: whileAway })).toBeVisible({ timeout: 30_000 })
  await expect(ines.locator('.msg .photo-wrap')).toHaveCount(2)

  // 8. Inès loses her network without closing anything: the P2P channel looks open on Alice's
  // side for a while, the message goes in and is lost, and the missing receipt sends it again
  // through the node.
  await ctxI.setOffline(true)
  const lost = `Tu captes encore ? ${tag}`
  await say(alice, lost)
  await new Promise((r) => setTimeout(r, 8_000))
  await ctxI.setOffline(false)
  await expect(ines.locator('.bubble', { hasText: lost })).toBeVisible({ timeout: 45_000 })

  // 9. Disappearing messages: Alice turns them on, both sides see the timer on new messages.
  await alice.getByRole('button', { name: 'Infos sur Inès' }).click()
  await alice.getByLabel('Durée des messages éphémères').selectOption({ index: 1 })
  await alice.keyboard.press('Escape')
  const eph = `Ce message va disparaître ${tag}`
  await say(alice, eph)
  await expect(ines.locator('.msg', { hasText: eph }).locator('[aria-label="Message éphémère"]')).toBeVisible({ timeout: 30_000 })

  await alice.screenshot({ path: 'screenshots/e2e/journey-alice.png' })
  await ines.screenshot({ path: 'screenshots/e2e/journey-ines.png' })
})

test('audio call connects (through TURN when the node offers it)', async ({ browser, request }) => {
  test.setTimeout(120_000)
  const ice = await (await request.get('/v1/ice')).json()
  const hasTurn = JSON.stringify(ice).includes('turn:')
  const tag = Date.now().toString(36)
  const alice = await open(await context(browser), `ca-${tag}`, hasTurn, true)
  const ines = await open(await context(browser), `cb-${tag}`, hasTurn, true)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')
  await meet(alice, ines, 'Inès', 'Alice', tag)

  await alice.getByRole('button', { name: 'Appeler' }).click()
  const incoming = ines.getByRole('alertdialog', { name: 'Appel audio de Alice' })
  await expect(incoming).toBeVisible({ timeout: 30_000 })
  await incoming.getByRole('button', { name: 'Répondre' }).click()

  // Active: the timer shows a duration and the pill says the media is end to end encrypted.
  for (const p of [alice, ines]) {
    const call = p.getByRole('dialog', { name: /Appel avec/ })
    await expect(call.locator('.timer')).toHaveText(/^\d+:\d\d$/, { timeout: 40_000 })
    await expect(call.locator('.pill')).toContainText('P2P')
  }
  const kind = await alice.evaluate(async () => {
    // The call's connection is the one that carries an audio track.
    const pcs = (window as unknown as { __pcs: RTCPeerConnection[] }).__pcs
    const pc = pcs.find((p) => p.getSenders().some((x) => x.track?.kind === 'audio'))
    if (!pc) return 'none'
    const stats = await pc.getStats()
    let out = 'none'
    stats.forEach((s) => {
      if (s.type === 'transport' && s.selectedCandidatePairId) {
        const pair = stats.get(s.selectedCandidatePairId)
        out = stats.get(pair.localCandidateId)?.candidateType ?? 'none'
      }
    })
    return out
  })
  if (hasTurn) expect(kind).toBe('relay')
  console.log(`call candidate type: ${kind}, turn offered: ${hasTurn}`)
  await alice.screenshot({ path: 'screenshots/e2e/call-alice.png' })
  await alice.getByRole('button', { name: 'Raccrocher' }).click()
  await expect(ines.getByRole('dialog', { name: /Appel avec/ }).locator('.timer')).toHaveText(/terminé|raccroch/i, { timeout: 20_000 })
})
