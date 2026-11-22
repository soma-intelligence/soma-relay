import { expect, test, type Browser, type Page } from '@playwright/test'

// v1.2 (spec section 6): profile photos travel between profiles, a group of three talks and
// loses a member who leaves, and search finds messages from the list and inside a chat.

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

async function shortLink(page: Page): Promise<string> {
  await page.getByRole('button', { name: 'Mon code', exact: true }).first().click()
  await page.getByRole('button', { name: 'Lien court' }).click()
  await expect(page.getByRole('button', { name: 'Copié' })).toBeVisible()
  const link = await page.evaluate(() => navigator.clipboard.readText())
  await page.keyboard.press('Escape')
  await expect(page.locator('.mycard')).toHaveCount(0)
  return link
}

/** `from` adds `to` by link and writes; `to` opens the chat and answers. */
async function meet(from: Page, to: Page, toName: string, fromName: string, tag: string) {
  const link = await shortLink(to)
  await from.getByRole('button', { name: 'Ajouter un contact', exact: true }).first().click()
  await from.getByRole('button', { name: 'Lien', exact: true }).click()
  await from.fill('#add-link', link)
  await from.locator('form').getByRole('button', { name: 'Ajouter' }).click()
  await expect(from.locator('.chat-title .name')).toHaveText(toName)
  const hello = `Salut ${toName} ${tag}`
  await from.fill('#composer-input', hello)
  await from.keyboard.press('Enter')
  await to.getByRole('listitem').filter({ hasText: fromName }).first().click()
  await expect(to.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })
  const back = `Salut ${fromName} ${tag}`
  await to.fill('#composer-input', back)
  await to.keyboard.press('Enter')
  await expect(from.locator('.bubble', { hasText: back })).toBeVisible({ timeout: 20_000 })
}

/** A 640 x 480 PNG drawn in the page, so the test needs no fixture file. */
async function testImage(page: Page, hue: number): Promise<Buffer> {
  const b64 = await page.evaluate((h) => {
    const c = document.createElement('canvas')
    c.width = 640
    c.height = 480
    const g = c.getContext('2d')!
    const gr = g.createLinearGradient(0, 0, 640, 480)
    gr.addColorStop(0, `hsl(${h} 70% 45%)`)
    gr.addColorStop(1, `hsl(${(h + 60) % 360} 80% 70%)`)
    g.fillStyle = gr
    g.fillRect(0, 0, 640, 480)
    g.fillStyle = '#fff'
    g.beginPath()
    g.arc(320, 240, 120, 0, Math.PI * 2)
    g.fill()
    return c.toDataURL('image/png').split(',')[1]
  }, hue)
  return Buffer.from(b64, 'base64')
}

async function setPhotoInSettings(page: Page, hue: number) {
  await page.getByRole('tab', { name: 'Réglages' }).click()
  await page.locator('.settings [data-testid="avatar-file"]').setInputFiles({ name: 'moi.png', mimeType: 'image/png', buffer: await testImage(page, hue) })
  const crop = page.getByRole('dialog', { name: 'Recadrer la photo' })
  await expect(crop.locator('.crop-view img')).toBeVisible()
  await crop.getByRole('button', { name: 'Choisir' }).click()
  await expect(crop).toHaveCount(0)
  await expect(page.locator('.settings .profile-row .avatar-img')).toBeVisible()
  await page.getByRole('tab', { name: 'Discussions' }).click()
}

test('profile photo travels to the other profile and shows in list and header', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const alice = await open(browser, `va-${tag}`)
  const ines = await open(browser, `vb-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')

  // Alice picks a photo before meeting Inès: it goes out after Inès's first message.
  await setPhotoInSettings(alice, 160)
  await meet(alice, ines, 'Inès', 'Alice', tag)
  await expect(ines.locator('.chat-title .avatar-img')).toBeVisible({ timeout: 20_000 })
  const row = ines.getByRole('list', { name: 'Discussions' }).getByRole('listitem').filter({ hasText: 'Alice' })
  await expect(row.locator('.avatar-img')).toHaveAttribute('src', /^data:image\/jpeg;base64,/)

  // Inès sets hers once they already talk: it is broadcast to Alice.
  await setPhotoInSettings(ines, 280)
  const aliceRow = alice.getByRole('list', { name: 'Discussions' }).getByRole('listitem').filter({ hasText: 'Inès' })
  await expect(aliceRow.locator('.avatar-img')).toBeVisible({ timeout: 20_000 })
  await expect(alice.locator('.chat-title .avatar-img')).toBeVisible()

  // A profile message is no bubble and no unread.
  await expect(alice.locator('.msg')).toHaveCount(2)
})

test('a group of three exchanges messages and a member leaves', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const alice = await open(browser, `ga-${tag}`)
  const ines = await open(browser, `gb-${tag}`)
  const bob = await open(browser, `gc-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')
  await onboard(bob, 'Bob')
  await meet(alice, ines, 'Inès', 'Alice', tag)
  await meet(alice, bob, 'Bob', 'Alice', tag)

  // Alice creates the group from the conversations header.
  const group = `Festival ${tag}`
  await alice.getByRole('button', { name: 'Nouveau groupe' }).first().click()
  await alice.fill('#group-name', group)
  await alice.locator('.pick-row', { hasText: 'Inès' }).click()
  await alice.locator('.pick-row', { hasText: 'Bob' }).click()
  await alice.getByRole('button', { name: 'Créer le groupe à 3' }).click()
  await expect(alice.locator('.chat-title .name')).toHaveText(group)

  const hello = `Bienvenue à tous ${tag}`
  await alice.fill('#composer-input', hello)
  await alice.keyboard.press('Enter')

  // The two others see the group at the top of their list and the message inside.
  for (const p of [ines, bob]) {
    const row = p.getByRole('list', { name: 'Discussions' }).getByRole('listitem').first()
    await expect(row).toContainText(group, { timeout: 20_000 })
    await row.click()
    await expect(p.locator('.bubble', { hasText: hello })).toBeVisible({ timeout: 20_000 })
  }

  // Inès answers; Alice and Bob (who is not her contact) both get it.
  const reply = `Je suis là ${tag}`
  await ines.fill('#composer-input', reply)
  await ines.keyboard.press('Enter')
  await expect(alice.locator('.bubble', { hasText: reply })).toBeVisible({ timeout: 20_000 })
  await expect(bob.locator('.bubble', { hasText: reply })).toBeVisible({ timeout: 20_000 })
  await expect(bob.locator('.msg', { hasText: reply }).locator('.sender')).toHaveText('Inès')

  // Bob leaves: Alice sees the line and, as admin, removes him from the member list.
  await bob.getByRole('button', { name: `Infos sur ${group}` }).click()
  await bob.getByRole('button', { name: 'Quitter le groupe' }).click()
  await bob.getByRole('button', { name: 'Quitter et effacer' }).click()
  await expect(alice.locator('.system', { hasText: 'Bob a quitté le groupe.' })).toBeVisible({ timeout: 20_000 })
  await expect(alice.locator('.chat-title .fp')).toContainText('2 membres', { timeout: 20_000 })
  await expect(bob.getByRole('list', { name: 'Discussions' }).getByRole('listitem').filter({ hasText: group })).toHaveCount(0)
})

test('search finds a message from the list and inside the chat', async ({ browser }) => {
  const tag = Date.now().toString(36)
  const alice = await open(browser, `sa-${tag}`)
  const ines = await open(browser, `sb-${tag}`)
  await onboard(alice, 'Alice')
  await onboard(ines, 'Inès')
  await meet(alice, ines, 'Inès', 'Alice', tag)

  const word = `girafe${tag}`
  const texts = [`On se voit à la ${word} bleue`, 'Rien à voir', `La ${word} est fermée`, 'Bon, je rentre']
  for (const t of texts) {
    await alice.fill('#composer-input', t)
    await alice.keyboard.press('Enter')
  }
  await expect(ines.locator('.bubble', { hasText: 'Bon, je rentre' })).toBeVisible({ timeout: 20_000 })

  // From the list: two message hits, the match is highlighted; a click opens and flashes it.
  await ines.getByRole('button', { name: 'Retour' }).click()
  await ines.fill('#conv-search', word)
  const hits = ines.getByRole('list', { name: 'Messages trouvés' }).getByRole('listitem')
  await expect(hits).toHaveCount(2)
  await expect(hits.first().locator('mark')).toHaveText(word)
  await hits.filter({ hasText: 'bleue' }).click()
  const target = ines.locator('.msg', { hasText: 'bleue' })
  await expect(target).toBeVisible()
  await expect(target).toHaveClass(/flash/)

  // Inside the chat: "1 sur 2" on the newest hit, up goes to the older one.
  await ines.getByRole('button', { name: 'Chercher dans la discussion' }).click()
  await ines.fill('#chat-search', word)
  const count = ines.getByTestId('search-count')
  await expect(count).toHaveText('1 sur 2')
  await ines.locator('#chat-search').press('Enter')
  await expect(count).toHaveText('2 sur 2')
  await ines.locator('#chat-search').press('Shift+Enter')
  await expect(count).toHaveText('1 sur 2')
  await expect(ines.locator('.msg.flash', { hasText: 'fermée' })).toBeVisible()
})
