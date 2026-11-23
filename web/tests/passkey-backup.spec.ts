import { readFileSync } from 'node:fs'
import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test'

// Passkey backup and restore (spec 2026-11-22-passkey-unlock-backup, sections 3 and 6).
// A CDP virtual authenticator with PRF stands in for the passkey manager. WebAuthn does not
// accept an IP address as relying party id, so the page is opened on `localhost`.

const NODE = process.env.RELAY_NODE_URL
const BASE = NODE?.replace('127.0.0.1', 'localhost')

test.skip(!NODE, 'set RELAY_NODE_URL to a running relay-node that serves web/dist')

interface Authenticator {
  cdp: Awaited<ReturnType<BrowserContext['newCDPSession']>>
  authenticatorId: string
}

async function open(browser: Browser, profile: string, prf: boolean | null): Promise<{ page: Page; auth: Authenticator | null }> {
  const ctx = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  const page = await ctx.newPage()
  page.on('pageerror', (e) => console.log(`[${profile}] ${e.message}`))
  let auth: Authenticator | null = null
  if (prf !== null) {
    const cdp = await ctx.newCDPSession(page)
    await cdp.send('WebAuthn.enable')
    const r = (await cdp.send('WebAuthn.addVirtualAuthenticator', {
      options: {
        protocol: 'ctap2',
        transport: 'internal',
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        hasPrf: prf,
        automaticPresenceSimulation: true,
      },
    } as never)) as { authenticatorId: string }
    auth = { cdp, authenticatorId: r.authenticatorId }
  }
  await page.goto(`${BASE}/?profile=${profile}`)
  return { page, auth }
}

async function onboard(page: Page, name: string) {
  await page.fill('#ob-name', name)
  await page.getByRole('button', { name: 'Créer mon identité' }).click()
  await page.getByRole('button', { name: 'C’est parti' }).click()
}

test('a passkey backup restores the identity in a new browser profile and the old contact still hears it', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const a = await open(browser, `pk-a-${tag}`, true)
  const b = await open(browser, `pk-b-${tag}`, null)
  const alice = a.page
  const ines = b.page
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')

  // Alice and Inès exchange a message.
  await ines.getByRole('button', { name: 'Mon code', exact: true }).first().click()
  await ines.getByRole('button', { name: 'Lien court' }).click()
  await expect(ines.getByRole('button', { name: 'Copié' })).toBeVisible()
  const link = await ines.evaluate(() => navigator.clipboard.readText())
  await ines.keyboard.press('Escape')
  await alice.getByRole('button', { name: 'Ajouter un contact', exact: true }).first().click()
  await alice.getByRole('button', { name: 'Lien' }).click()
  await alice.fill('#add-link', link)
  await alice.locator('form').getByRole('button', { name: 'Ajouter' }).click()
  const hello = `Salut Inès ${tag}`
  await alice.fill('#composer-input', hello)
  await alice.keyboard.press('Enter')
  await ines.getByRole('listitem').filter({ hasText: 'Alice' }).first().click()
  await expect(ines.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })
  const reply = `Reçu ${tag}`
  await ines.fill('#composer-input', reply)
  await ines.keyboard.press('Enter')
  await expect(alice.locator('.bubble', { hasText: reply })).toBeVisible({ timeout: 20_000 })

  // Alice sets up the passkey backup from Settings.
  await alice.getByRole('tab', { name: 'Réglages' }).click()
  const fingerprint = (await alice.getByTestId('my-fingerprint').textContent())!.trim()
  await alice.getByRole('button', { name: 'Créer un passkey' }).click()
  await expect(alice.getByText(/Sauvegardé à \d\d:\d\d/)).toBeVisible({ timeout: 30_000 })

  // A new browser profile: everything local is erased, the passkey manager keeps the passkey.
  // (Chromium's virtual authenticator cannot copy a credential with its PRF secret to another
  // authenticator: `addCredential` drops the hmac-secret, so the copy answers no PRF output.)
  await alice.getByRole('button', { name: 'Effacer', exact: true }).click()
  await alice.getByRole('button', { name: 'Oui, tout effacer' }).click()
  const fresh = { page: alice }

  // Restore there: same identity.
  await fresh.page.getByRole('button', { name: 'Restaurer avec un passkey' }).click()
  await fresh.page.getByRole('tab', { name: 'Réglages' }).click()
  await expect(fresh.page.getByTestId('my-fingerprint')).toHaveText(fingerprint, { timeout: 30_000 })

  // The restored browser talks to the old contact, who hears it.
  await fresh.page.getByRole('tab', { name: 'Contacts' }).click()
  await fresh.page.getByRole('button', { name: /Inès/ }).click()
  const again = `Retour depuis le nouveau navigateur ${tag}`
  await fresh.page.fill('#composer-input', again)
  await fresh.page.keyboard.press('Enter')
  await expect(ines.locator('.bubble', { hasText: again })).toBeVisible({ timeout: 30_000 })
})

test('a passkey manager without PRF says it cannot back up', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const { page } = await open(browser, `pk-n-${tag}`, false)
  await onboard(page, 'Alice')
  await page.getByRole('tab', { name: 'Réglages' }).click()
  await page.getByRole('button', { name: 'Créer un passkey' }).click()
  await expect(page.getByText('Ton gestionnaire ne prend pas en charge la sauvegarde')).toBeVisible({ timeout: 30_000 })
})

/** A real PRF passkey made straight through WebAuthn (no Relay backup behind it). */
async function makePasskey(page: Page): Promise<number[]> {
  return page.evaluate(async () => {
    const c = (await navigator.credentials.create({
      publicKey: {
        rp: { id: 'localhost', name: 'Soma Relay' },
        user: { id: new Uint8Array(16).fill(7), name: 'Zoé', displayName: 'Zoé' },
        challenge: new Uint8Array(32),
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
        extensions: { prf: {} } as never,
      },
    })) as PublicKeyCredential
    return Array.from(new Uint8Array(c.rawId))
  })
}

test('restore with no backup for the passkey says so', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const { page } = await open(browser, `pk-e-${tag}`, true)
  await makePasskey(page)
  await page.getByRole('button', { name: 'Restaurer avec un passkey' }).click()
  await expect(page.getByText('Aucune sauvegarde pour ce passkey', { exact: true })).toBeVisible({ timeout: 30_000 })
})

test('a vault opened and sealed again by the web keeps channelsPrefs and the photo byte for byte', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const { page, auth } = await open(browser, `pk-r-${tag}`, true)
  const wasm = await import('../src/core/pkg/relay_wasm.js')
  wasm.initSync({ module: readFileSync(new URL('../src/core/pkg/relay_wasm_bg.wasm', import.meta.url)) })

  // The vault of another device (iOS): its engine, a channel list and a photo.
  const engine = wasm.RelayEngine.create('Zoé')
  const credentialId = Uint8Array.from(await makePasskey(page))
  const salt = Array.from(wasm.prfSaltBackup())
  const second = await page.evaluate(async ([id, salt]) => {
    const r = (await navigator.credentials.get({
      publicKey: {
        rpId: 'localhost',
        challenge: new Uint8Array(32),
        userVerification: 'required',
        allowCredentials: [{ type: 'public-key', id: new Uint8Array(id) }],
        extensions: { prf: { eval: { first: new Uint8Array(salt), second: new Uint8Array(salt) } } } as never,
      },
    })) as PublicKeyCredential
    const out = (r.getClientExtensionResults() as { prf?: { results?: { second?: ArrayBuffer } } }).prf?.results?.second
    return Array.from(new Uint8Array(out!))
  }, [Array.from(credentialId), salt] as const)
  const key = wasm.vaultKey(Uint8Array.from(second))
  const id = wasm.vaultId(credentialId)
  const channelsPrefs = new TextEncoder().encode('["alpha","beta","gamma"]')
  // Not a decodable JPEG: the web cannot show it, and must still carry it.
  const photo = Uint8Array.from({ length: 300 }, (_, i) => (i * 7) % 256)
  const blob = wasm.sealVault(key, id, { engine: engine.exportState(), handle: null, nodeUrl: null, channelsPrefs, photo })

  // Put it on the node as that device: authenticate the mailbox over the WebSocket, then PUT.
  const ws = new WebSocket(`${BASE!.replace('http', 'ws')}/v1/ws`)
  await new Promise<void>((resolve, reject) => {
    ws.onerror = () => reject(new Error('ws'))
    ws.onopen = () =>
      ws.send(JSON.stringify({ t: 'hello', mailbox: engine.mailboxHex(), pub: Buffer.from(engine.deviceSigningPublic()).toString('base64url') }))
    ws.onmessage = (ev) => {
      const f = JSON.parse(String(ev.data)) as { t: string; nonce?: string }
      if (f.t === 'challenge')
        ws.send(JSON.stringify({ t: 'auth', sig: Buffer.from(engine.signNodeChallenge(Buffer.from(f.nonce!, 'base64url'))).toString('base64url') }))
      if (f.t === 'ready') resolve()
    }
  })
  const put = await fetch(`${BASE}/v1/vault/${id}`, {
    method: 'PUT',
    headers: {
      'x-relay-mailbox': engine.mailboxHex(),
      'x-relay-sig': Buffer.from(engine.signVault(id, blob)).toString('base64'),
    },
    body: blob,
  })
  expect(put.status).toBe(200)

  // The web restores it and seals it again at once.
  // (Playwright cannot read a Blob request body: the node's copy is read back with a GET.)
  const stored = async () => new Uint8Array(await (await fetch(`${BASE}/v1/vault/${id}`)).arrayBuffer())
  const before = await stored()
  const resealed = page.waitForResponse((r) => r.request().method() === 'PUT' && r.url().includes(`/v1/vault/${id}`) && r.ok(), { timeout: 30_000 })
  await page.getByRole('button', { name: 'Restaurer avec un passkey' }).click()
  await resealed
  const body = await stored()
  expect(Buffer.from(body).equals(Buffer.from(before))).toBe(false)
  const plain = wasm.openVault(key, id, body) as { channelsPrefs: Uint8Array; photo: Uint8Array | null; engine: Uint8Array }
  expect(Buffer.from(plain.channelsPrefs).equals(Buffer.from(channelsPrefs))).toBe(true)
  expect(plain.photo && Buffer.from(plain.photo).equals(Buffer.from(photo))).toBe(true)

  // A later reseal (a rename) still carries both.
  await expect(page.getByRole('tab', { name: 'Réglages' })).toBeVisible({ timeout: 30_000 })
  await page.getByRole('tab', { name: 'Réglages' }).click()
  const again = page.waitForResponse((r) => r.request().method() === 'PUT' && r.url().includes(`/v1/vault/${id}`) && r.ok(), { timeout: 15_000 })
  await page.fill('#set-name', 'Zoé B')
  await page.getByRole('button', { name: 'OK', exact: true }).first().click()
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await again
  const second2 = wasm.openVault(key, id, await stored()) as { channelsPrefs: Uint8Array; photo: Uint8Array | null }
  expect(Buffer.from(second2.channelsPrefs).equals(Buffer.from(channelsPrefs))).toBe(true)
  expect(second2.photo && Buffer.from(second2.photo).equals(Buffer.from(photo))).toBe(true)

  // A new passkey made from Settings after the restore carries the channels and the photo too.
  const firstId = id
  const newPut = page.waitForResponse((r) => r.request().method() === 'PUT' && r.url().includes('/v1/vault/') && !r.url().includes(firstId) && r.ok(), { timeout: 30_000 })
  await page.getByRole('button', { name: 'Changer de passkey' }).click()
  const newUrl = (await newPut).url()
  const { credentials } = (await auth!.cdp.send('WebAuthn.getCredentials', { authenticatorId: auth!.authenticatorId })) as {
    credentials: { credentialId: string }[]
  }
  const newCred = credentials.map((c) => Uint8Array.from(Buffer.from(c.credentialId, 'base64'))).find((c) => wasm.vaultId(c) !== firstId)!
  const newId = wasm.vaultId(newCred)
  expect(newUrl.endsWith(newId)).toBe(true)
  const newSecond = await page.evaluate(async ([cid, salt]) => {
    const r = (await navigator.credentials.get({
      publicKey: {
        rpId: 'localhost',
        challenge: new Uint8Array(32),
        userVerification: 'required',
        allowCredentials: [{ type: 'public-key', id: new Uint8Array(cid) }],
        extensions: { prf: { eval: { first: new Uint8Array(salt), second: new Uint8Array(salt) } } } as never,
      },
    })) as PublicKeyCredential
    const out = (r.getClientExtensionResults() as { prf?: { results?: { second?: ArrayBuffer } } }).prf?.results?.second
    return Array.from(new Uint8Array(out!))
  }, [Array.from(newCred), salt] as const)
  const newBlob = new Uint8Array(await (await fetch(`${BASE}/v1/vault/${newId}`)).arrayBuffer())
  const third = wasm.openVault(wasm.vaultKey(Uint8Array.from(newSecond)), newId, newBlob) as { channelsPrefs: Uint8Array; photo: Uint8Array | null }
  expect(Buffer.from(third.channelsPrefs).equals(Buffer.from(channelsPrefs))).toBe(true)
  expect(third.photo && Buffer.from(third.photo).equals(Buffer.from(photo))).toBe(true)
  ws.close()
})

test('a save after the backup marks it dirty and going to the background uploads it', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const { page } = await open(browser, `pk-f-${tag}`, true)
  await onboard(page, 'Alice')
  await page.getByRole('tab', { name: 'Réglages' }).click()
  await page.getByRole('button', { name: 'Créer un passkey' }).click()
  await expect(page.getByText(/Sauvegardé à \d\d:\d\d/)).toBeVisible({ timeout: 30_000 })

  // A rename saves the engine state: the backup is owed (not yet uploaded, the debounce is 10 s).
  await page.fill('#set-name', 'Alice B')
  await page.getByRole('button', { name: 'OK', exact: true }).first().click()
  await expect(page.getByText('En attente du réseau')).toBeVisible({ timeout: 5_000 })

  // The tab goes to the background: the upload happens at once.
  const put = page.waitForRequest((r) => r.method() === 'PUT' && r.url().includes('/v1/vault/'), { timeout: 5_000 })
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await put
  await expect(page.getByText(/Sauvegardé à \d\d:\d\d/)).toBeVisible({ timeout: 10_000 })
})
