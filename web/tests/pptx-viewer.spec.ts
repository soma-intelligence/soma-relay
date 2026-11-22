import { expect, test, type Browser, type Page } from '@playwright/test'
import { fileURLToPath } from 'node:url'

// A PowerPoint deck travels between two profiles; the receiver sees the first-slide thumbnail
// on the card and opens the deck in the slide viewer (our own reader, no third party renderer).

const NODE = process.env.RELAY_NODE_URL
const DECK = fileURLToPath(new URL('./fixtures/sample.pptx', import.meta.url))

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

test('a pptx deck renders in the slide viewer', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const alice = await open(browser, `xa-${tag}`)
  const ines = await open(browser, `xb-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')

  await ines.getByRole('button', { name: 'Mon code', exact: true }).first().click()
  await ines.getByRole('button', { name: 'Lien court' }).click()
  await expect(ines.getByRole('button', { name: 'Copié' })).toBeVisible()
  const link = await ines.evaluate(() => navigator.clipboard.readText())
  await ines.keyboard.press('Escape')
  await alice.getByRole('button', { name: 'Ajouter un contact', exact: true }).first().click()
  await alice.getByRole('button', { name: 'Lien' }).click()
  await alice.fill('#add-link', link)
  await alice.locator('form').getByRole('button', { name: 'Ajouter' }).click()
  const hello = `Les slides ${tag}`
  await alice.fill('#composer-input', hello)
  await alice.keyboard.press('Enter')
  await ines.getByRole('listitem').filter({ hasText: 'Alice' }).first().click()
  await expect(ines.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })

  // Alice attaches the deck as a document: the card gets a thumbnail and a slide count.
  await alice.locator('input[type="file"]:not([accept])').setInputFiles(DECK)
  const card = ines.locator('.file-card', { hasText: 'sample.pptx' })
  await expect(card).toBeVisible({ timeout: 20_000 })
  await expect(card).toContainText('PRÉSENTATION')
  await expect(card).toContainText('3 diapos')
  await expect(card.locator('.doc-thumb img')).toBeVisible()

  // Inès opens it: three slides, their text, the table and the picture.
  await card.click()
  const viewer = ines.getByRole('dialog', { name: 'sample.pptx' })
  await expect(viewer.locator('.pptx-slide')).toHaveCount(3, { timeout: 20_000 })
  const first = viewer.getByRole('region', { name: 'Diapositive 1' })
  await expect(first).toContainText('Stand 4 meetup')
  await expect(first).toContainText('Offline mesh, post-quantum, no SIM')
  await expect(first).toContainText('Rounded badge')
  await expect
    .poll(() => first.locator('.pptx-pic img').evaluate((img) => (img as HTMLImageElement).naturalWidth), { timeout: 10_000 })
    .toBe(320)
  const second = viewer.getByRole('region', { name: 'Diapositive 2' })
  await expect(second).toContainText('Agenda today')
  await expect(second).toContainText('Keys and identities')
  await expect(second.locator('.pptx-bu').first()).toHaveText('•')
  await expect(second.locator('.pptx-table td')).toHaveCount(9)
  await expect(second.locator('.pptx-table')).toContainText('Review')
  await expect(second).toContainText('Group B')
  await expect(viewer.getByRole('region', { name: 'Diapositive 3' })).toContainText('Merci')

  // Arrow keys move between slides; the counter follows.
  await expect(viewer.getByRole('toolbar', { name: 'Zoom' })).toContainText('1 / 3')
  await ines.keyboard.press('ArrowDown')
  await expect(viewer.getByRole('toolbar', { name: 'Zoom' })).toContainText('2 / 3')
  await ines.keyboard.press('End')
  await expect(viewer.getByRole('toolbar', { name: 'Zoom' })).toContainText('3 / 3')

  // Zoom keeps the slide proportions (4:3 deck).
  const before = await first.locator('.pptx-box').boundingBox()
  await viewer.getByRole('button', { name: 'Zoomer', exact: true }).click()
  const after = await first.locator('.pptx-box').boundingBox()
  expect(after!.width).toBeGreaterThan(before!.width * 1.2)
  expect(Math.abs(after!.height / after!.width - 0.75)).toBeLessThan(0.01)

  // Closing revokes the picture URLs.
  const url = await first.locator('.pptx-pic img').getAttribute('src')
  await viewer.getByRole('button', { name: 'Fermer' }).click()
  await expect(viewer).toHaveCount(0)
  const alive = await ines.evaluate(async (u) => fetch(u!).then(() => true, () => false), url)
  expect(alive).toBe(false)
})
