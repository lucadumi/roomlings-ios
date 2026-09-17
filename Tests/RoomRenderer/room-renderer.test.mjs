import assert from 'node:assert/strict'
import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { randomUUID } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const web = resolve(project, process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings')
const requireWeb = createRequire(join(web, 'package.json'))
const { chromium, expect: baseExpect } = requireWeb('@playwright/test')
const expect = baseExpect.configure({ timeout: process.env.CI ? 10_000 : 5_000 })
const { defaultRoomComponents, componentCatalog, componentChoreArea } = await import(pathToFileURL(join(web, 'shared/roomComponents.ts')).href)
const { roomIds, roomCatalog } = await import(pathToFileURL(join(web, 'shared/rooms.ts')).href)
const { roomFramingArea } = await import(pathToFileURL(join(web, 'src/camera.ts')).href)

test('the native chore catalog is generated from the shared rooms and object definitions', async () => {
  const catalog = JSON.parse(await readFile(join(project, 'Build/RoomRenderer/chores.json'), 'utf8'))
  assert.equal(catalog.version, 1)
  assert.deepEqual(catalog.rooms, roomIds.map((id) => ({ id, name: roomCatalog[id].name, areas: roomCatalog[id].areas })))
  for (const kind of Object.keys(componentCatalog)) {
    for (const roomId of roomIds) {
      assert.equal(catalog.componentAreas[kind][roomId], componentChoreArea({ kind, roomId }))
    }
  }
  assert.deepEqual(catalog.defaultComponents, defaultRoomComponents().map(({ id, name, kind, roomId, slotId, installed }) => ({
    id, name, kind, roomId, slotId, installed,
  })))
})

test('@room the bundled kitchen stays offline, uses the shared controls and validates the native bridge', async () => {
  const types = { '/': 'text/html', '/room.js': 'text/javascript', '/room.css': 'text/css' }
  const resources = new Map()
  for (const path of Object.keys(types)) {
    resources.set(path, await readFile(join(project, 'Build/RoomRenderer', path === '/' ? 'index.html' : path.slice(1))))
  }
  const requests = []
  const server = createServer((request, response) => {
    requests.push(request.url)
    const body = resources.get(request.url)
    response.writeHead(body ? 200 : 404, { 'Content-Type': types[request.url] ?? 'text/plain' })
    response.end(body ?? 'Not found')
  }).listen(0, '127.0.0.1')
  await once(server, 'listening')
  let browser
  try {
    browser = await chromium.launch()
    const page = await browser.newPage({
      viewport: { width: 390, height: 750 }, hasTouch: true, deviceScaleFactor: 2, reducedMotion: 'reduce',
    })
    page.setDefaultTimeout(process.env.CI ? 90_000 : 30_000)
    page.on('pageerror', (error) => console.error('Bundled room error:', error.message))
    await page.addInitScript(() => {
      window.roomEvents = []
      window.webkit = { messageHandlers: { roomlings: { postMessage: (event) => window.roomEvents.push(event) } } }
    })
    await page.goto(`http://127.0.0.1:${server.address().port}/`)
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('canvas')).toHaveAttribute('data-render-ready', 'true')
    await page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original',
      viewportInsets: { top: 100, right: 12, bottom: 34, left: 12 },
    }))
    await expect(page.locator('.kitchen-world')).toHaveCSS('top', '100px')
    assert.deepEqual(await page.locator('main').boundingBox(), { x: 0, y: 0, width: 390, height: 750 })
    assert.deepEqual(await page.locator('canvas').boundingBox(), { x: 0, y: 0, width: 390, height: 750 })
    const safeRoom = await page.locator('.kitchen-world').boundingBox()
    assert.deepEqual(safeRoom, { x: 12, y: 100, width: 366, height: 616 })
    const quickActions = await page.locator('.world-quick-actions').boundingBox()
    assert.ok(quickActions && quickActions.y + quickActions.height <= 716)
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original',
      viewportInsets: { top: -1, right: 0, bottom: 0, left: 0 },
    })))
    await page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original',
    }))
    await expect(page.getByRole('button')).toHaveCount(6)
    await expect(page.getByRole('button', { name: 'Hide object labels' })).toHaveCount(0)
    await expect(page.locator('.world-hotspots')).toHaveCount(0)
    const resetBox = await page.getByRole('button', { name: 'Reset room view', exact: true }).boundingBox()
    const lightBox = await page.getByRole('button', { name: 'Switch to evening lighting', exact: true }).boundingBox()
    assert.ok(resetBox && lightBox)
    await page.touchscreen.tap(resetBox.x + resetBox.width / 2, resetBox.y + resetBox.height / 2)
    await page.touchscreen.tap(lightBox.x + lightBox.width / 2, lightBox.y + lightBox.height / 2)
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-evening', 'true')
    await page.touchscreen.tap(lightBox.x + lightBox.width / 2, lightBox.y + lightBox.height / 2)
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-evening', 'false')
    await page.getByRole('button', { name: 'Zoom in', exact: true }).click()
    await expect(page.locator('.world-camera-controls > span')).toHaveText('110%')
    await page.getByRole('button', { name: 'Reset room view', exact: true }).click()
    await expect(page.locator('.world-camera-controls > span')).toHaveText('100%')
    await page.getByRole('button', { name: 'Switch to evening lighting', exact: true }).click()
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-evening', 'true')
    await page.getByRole('button', { name: 'Switch to daylight', exact: true }).click()
    await page.getByRole('button', { name: 'Close the fridge', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Peek inside', exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Peek inside', exact: true }).click()
    const camera = page.locator('canvas')
    const angle = await camera.getAttribute('data-camera-orbit')
    assert.notEqual(angle, null)
    await page.mouse.move(130, 260)
    await page.mouse.down()
    await page.mouse.move(220, 290, { steps: 12 })
    await page.mouse.up()
    await expect(camera).not.toHaveAttribute('data-camera-orbit', angle)
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original', token: 'not-allowed',
    })))
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 2, type: 'state', paused: false, roomStyle: 'original',
    })))
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original', choresEnabled: true,
    })))
    await page.emulateMedia({ reducedMotion: 'no-preference' })
    await page.evaluate(() => window.RoomlingsRoom.receive({ version: 1, type: 'state', paused: true, roomStyle: 'clay' }))
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-room-style', 'clay')
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-rendering', 'paused', { timeout: 10_000 })
    await page.evaluate(() => window.RoomlingsRoom.receive({ version: 1, type: 'state', paused: false, roomStyle: 'original' }))
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-rendering', 'active')
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.getByRole('button', { name: 'Put the kettle on', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await page.setViewportSize({ width: 1194, height: 834 })
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeInViewport()
    const householdId = randomUUID()
    const roomComponents = defaultRoomComponents().map((component) =>
      component.slotId === 'kitchen-kettle' ? { ...component, installed: false } : component)
    const householdState = {
      version: 1, type: 'state', paused: false, roomStyle: 'clay', householdId, roomComponents, choresEnabled: true,
      viewportInsets: { top: 100, right: 12, bottom: 34, left: 12 },
    }
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), householdState)
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('main')).toHaveAttribute('data-household-id', householdId)
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-room-style', 'clay')
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toHaveCount(0)
    const chores = page.getByRole('button', { name: 'Chores', exact: true })
    const tools = page.getByRole('navigation', { name: 'Household tools' })
    await expect(tools.getByRole('button')).toHaveCount(1)
    await expect(chores).toBeEnabled()
    await expect(page.locator('.world-hotspots')).toHaveCount(1)
    const object = roomComponents.find((component) => component.slotId === 'kitchen-fridge')
    assert.ok(object)
    const marker = page.locator(`.world-hotspot[data-component-id="${object.id}"]`)
    await expect(marker).toBeVisible()
    const kettle = roomComponents.find((component) => component.slotId === 'kitchen-kettle')
    assert.ok(kettle)
    await expect(page.locator(`.world-hotspot[data-component-id="${kettle.id}"]`)).toHaveCount(0)
    const markerIDs = await page.locator('.world-hotspot').evaluateAll((buttons) => buttons.map((button) => button.dataset.componentId))
    assert.ok(markerIDs.every((id) => roomComponents.some((component) =>
      component.id === id && component.installed && component.roomId === 'kitchen')))
    for (const viewport of [{ width: 390, height: 750 }, { width: 1194, height: 834 }]) {
      await page.setViewportSize(viewport)
      await expect.poll(async () => {
        const dock = await tools.boundingBox()
        const quick = await page.locator('.world-quick-actions').boundingBox()
        return dock !== null && quick !== null && dock.x >= 12 && dock.x + dock.width <= viewport.width - 12
          && dock.y + dock.height <= viewport.height - 34 && quick.y + quick.height < dock.y
      }).toBe(true)
      await expect(page.locator('canvas')).toHaveCSS('width', `${viewport.width}px`)
      await expect(page.locator('canvas')).toHaveCSS('height', `${viewport.height}px`)
    }
    await page.setViewportSize({ width: 390, height: 750 })
    const world = page.locator('.kitchen-world')
    const settleFraming = async () => {
      await expect.poll(async () => {
        const [canvas, stage, controls] = await Promise.all([
          camera.boundingBox(), world.boundingBox(), page.locator('.world-camera-controls').boundingBox(),
        ])
        assert.ok(canvas && stage && controls)
        const area = roomFramingArea(canvas, stage, controls)
        const expected = [area.x, area.y, area.width, area.height].map((value) => value.toFixed(3)).join(',')
        return await camera.getAttribute('data-camera-area') === expected
      }).toBe(true)
      await expect(world).toHaveAttribute('data-camera-moving', 'false')
    }
    await expect(camera).toHaveAttribute('width', '780')
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await settleFraming()
    const originalSpan = Number(await camera.getAttribute('data-camera-span'))
    assert.ok(originalSpan > 0)
    const portraitState = { ...householdState, roomZoom: 1.35 }
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), portraitState)
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.35000')
    await settleFraming()
    const portraitSpan = Number(await camera.getAttribute('data-camera-span'))
    assert.equal(Number((originalSpan / portraitSpan).toFixed(3)), 1.35,
      'Portrait framing must actually magnify the room by 35%.')
    const roomTarget = await camera.getAttribute('data-camera-target')
    for (const roomZoom of [0, -1, 1.51, '1.35']) {
      await assert.rejects(page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, roomZoom }))
    }
    await page.emulateMedia({ reducedMotion: 'no-preference' })
    await marker.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-chores', householdId, componentId: object.id,
    })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...portraitState, paused: true })
    await expect(world).toHaveAttribute('data-selected-component', object.id)
    await expect(world).toHaveAttribute('data-component-focus', 'true')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    await expect(world).toHaveAttribute('data-rendering', 'paused')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.00000')
    await expect(camera).not.toHaveAttribute('data-camera-target', roomTarget)
    assert.ok(Number(await camera.getAttribute('data-camera-span')) < portraitSpan * 0.8,
      'Selecting an object must finish a real close-up even while the native sheet pauses the room.')
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeDisabled()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), portraitState)
    await page.getByRole('button', { name: 'Reset room view', exact: true }).click()
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.35000')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    assert.ok(Math.abs(Number(await camera.getAttribute('data-camera-span')) - portraitSpan) < 0.001)
    await marker.click()
    await expect(world).toHaveAttribute('data-component-focus', 'true')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.00000')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    assert.ok(Number(await camera.getAttribute('data-camera-span')) < portraitSpan * 0.8,
      'Selecting the same object after Reset must focus it again.')
    const fridgeTarget = await camera.getAttribute('data-camera-target')
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), {
      ...portraitState, roomComponents: roomComponents.map((component) =>
        component.id === kettle.id ? { ...component, installed: true } : component),
    })
    await page.getByRole('button', { name: 'Put the kettle on', exact: true }).click()
    await expect(world).toHaveAttribute('data-focus', 'brew')
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    await expect(camera).not.toHaveAttribute('data-camera-target', fridgeTarget)
    await expect(page.locator('.world-view-label')).toHaveText('A little tea break')
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), portraitState)
    await page.getByRole('button', { name: 'Reset room view', exact: true }).click()
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.35000')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    await page.getByRole('button', { name: 'Hide object labels', exact: true }).click()
    await expect(page.locator('.world-hotspots')).toHaveClass(/hide-labels/)
    await page.getByRole('button', { name: 'Show object labels', exact: true }).click()
    await chores.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-chores', householdId,
    })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...portraitState, paused: true })
    await expect(chores).toBeDisabled()
    await expect(marker).toBeDisabled()
    await expect(page.getByRole('button', { name: 'Hide object labels', exact: true })).toBeDisabled()
    await chores.evaluate((button) => button.click())
    await marker.evaluate((button) => button.click())
    assert.equal((await page.evaluate(() => window.roomEvents)).filter((event) => event.type === 'open-chores').length, 3)
    await page.setViewportSize({ width: 1194, height: 834 })
    await expect(camera).toHaveAttribute('width', '2388')
    const nextHousehold = randomUUID()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, householdId: nextHousehold })
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.00000')
    await chores.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-chores', householdId: nextHousehold,
    })
    await marker.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-chores', householdId: nextHousehold, componentId: object.id,
    })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), {
      ...householdState, householdId: nextHousehold, choresEnabled: false,
    })
    await expect(page.locator('.world-hotspots')).toHaveCount(0)
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(page.getByRole('button', { name: 'Hide object labels', exact: true })).toHaveCount(0)
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, householdId: nextHousehold })
    await expect(marker).toBeVisible()
    await page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original',
    }))
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('main')).toHaveAttribute('data-household-id', '')
    await expect(chores).toHaveCount(0)
    await expect(page.locator('.world-hotspots')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toBeVisible()
    await assert.rejects(page.evaluate(() => fetch('/api/account')))
    assert.ok(!requests.some((path) => path.startsWith('/api/')))
    assert.ok((await page.evaluate(() => window.roomEvents)).some((event) => event.version === 1 && event.status === 'ready'))
    assert.equal(await page.evaluate(() => localStorage.length), 0)
    await page.evaluate(() => document.querySelector('canvas').dispatchEvent(new Event('webglcontextlost', { cancelable: true })))
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'unavailable')
    assert.equal((await page.evaluate(() => window.roomEvents)).at(-1).status, 'unavailable')
  } finally {
    await browser?.close()
    const closed = once(server, 'close')
    server.close()
    await closed
  }
})
