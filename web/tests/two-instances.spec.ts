import { expect, test, type Browser, type Page } from '@playwright/test'

// Two separate browser profiles (two contexts, two IndexedDB namespaces) meet through the node:
// Inès shares her short link, Alice adds it (the node returns the full card), then they talk.

const NODE = process.env.RELAY_NODE_URL

test.skip(!NODE, 'set RELAY_NODE_URL to a running relay-node that serves web/dist')

async function open(browser: Browser, profile: string): Promise<Page> {
  const ctx = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  const page = await ctx.newPage()
  page.on('pageerror', (e) => console.log(`[${profile}] ${e.message}`))
  await page.goto(`/?profile=${profile}`)
  return page
}

async function onboard(page: Page, name: string) {
  await page.fill('#ob-name', name)
  await page.getByRole('button', { name: 'Créer mon identité' }).click()
  await page.getByRole('button', { name: 'C’est parti' }).click()
}

test('two instances exchange a message through the node', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const alice = await open(browser, `a-${tag}`)
  const ines = await open(browser, `b-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')

  // Inès copies her short link (relay1c:), small enough for a QR code.
  await ines.getByRole('button', { name: 'Mon code', exact: true }).first().click()
  await ines.getByRole('button', { name: 'Lien court' }).click()
  await expect(ines.getByRole('button', { name: 'Copié' })).toBeVisible()
  const link = await ines.evaluate(() => navigator.clipboard.readText())
  expect(link.startsWith('relay1c:')).toBe(true)
  await ines.keyboard.press('Escape')

  // Alice pastes it; the client fetches the full card from GET /v1/cards/{mailbox}.
  await alice.getByRole('button', { name: 'Ajouter un contact', exact: true }).first().click()
  await alice.getByRole('button', { name: 'Lien' }).click()
  await alice.fill('#add-link', link)
  await alice.locator('form').getByRole('button', { name: 'Ajouter' }).click()

  const hello = `Salut Inès ${tag}`
  await alice.fill('#composer-input', hello)
  await alice.keyboard.press('Enter')

  // First message carries Alice's card: Inès gets a message request and reads it.
  await ines.getByRole('listitem').filter({ hasText: 'Alice' }).first().click()
  await expect(ines.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })

  const reply = `Reçu, Alice ${tag}`
  await ines.fill('#composer-input', reply)
  await ines.keyboard.press('Enter')
  await expect(alice.locator('.bubble', { hasText: reply })).toBeVisible({ timeout: 20_000 })
})
