import { generateKeyPairSync } from 'node:crypto'
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

test('restore with no backup for the passkey says so', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const { page, auth } = await open(browser, `pk-e-${tag}`, true)
  // A passkey that never backed anything up on this node.
  await auth!.cdp.send('WebAuthn.addCredential', {
    authenticatorId: auth!.authenticatorId,
    credential: {
      credentialId: Buffer.from(`orphan-${tag}`).toString('base64'),
      isResidentCredential: true,
      rpId: 'localhost',
      privateKey: generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64'),
      userHandle: Buffer.from('orphan-user').toString('base64'),
      signCount: 0,
    },
  } as never)
  await page.getByRole('button', { name: 'Restaurer avec un passkey' }).click()
  await expect(page.getByText(/Aucune sauvegarde pour ce passkey|Ce passkey ne peut pas ouvrir la sauvegarde/)).toBeVisible({
    timeout: 30_000,
  })
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
