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
const { cameraFraming } = await import(pathToFileURL(join(web, 'src/camera.ts')).href)

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
  assert.deepEqual(await readFile(join(project, 'Build/RoomRenderer/roomlings-loader.png')),
    await readFile(join(web, 'public/brand/roomlings-icon-flat-256.png')))
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
    const resizeViewport = async (viewport) => {
      await page.setViewportSize(viewport)
      // A software-rendered frame can delay ResizeObserver and React beyond the viewport command.
      await page.waitForFunction(({ width, height }) => {
        const root = document.querySelector('.native-room')
        const canvas = root?.querySelector('canvas')
        return root?.clientWidth === width && root.clientHeight === height
          && root.dataset.landscape === String(width > height)
          && canvas?.clientWidth === width && canvas.clientHeight === height
      }, viewport)
    }
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
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original', shoppingEnabled: true,
    })))
    await assert.rejects(page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original', moneyEnabled: true,
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
    await resizeViewport({ width: 1194, height: 834 })
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeInViewport()
    const householdId = randomUUID()
    const roomComponents = defaultRoomComponents().map((component) =>
      component.slotId === 'kitchen-kettle' ? { ...component, installed: false } : component)
    const householdState = {
      version: 1, type: 'state', paused: false, roomStyle: 'clay', householdId, roomComponents,
      choresEnabled: true, shoppingEnabled: true, moneyEnabled: true,
      viewportInsets: { top: 100, right: 12, bottom: 34, left: 12 },
    }
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), householdState)
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('main')).toHaveAttribute('data-household-id', householdId)
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-room-style', 'clay')
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toHaveCount(0)
    const chores = page.getByRole('button', { name: 'Chores', exact: true })
    const shopping = page.getByRole('button', { name: 'Shopping', exact: true })
    const money = page.getByRole('button', { name: 'Money', exact: true })
    const tools = page.getByRole('navigation', { name: 'Household tools' })
    await expect(tools.getByRole('button')).toHaveCount(3)
    await expect(chores).toBeEnabled()
    await expect(shopping).toBeEnabled()
    await expect(money).toBeEnabled()
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
    for (const viewport of [
      { width: 320, height: 568 }, { width: 402, height: 874 }, { width: 874, height: 402 },
      { width: 667, height: 375 }, { width: 375, height: 768 }, { width: 800, height: 900 },
      { width: 820, height: 900 }, { width: 834, height: 1194 }, { width: 1194, height: 834 },
    ]) {
      await resizeViewport(viewport)
      const roomZoom = Math.min(1, Math.max(0.3, viewport.width / viewport.height / 0.767))
      await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, roomZoom })
      const landscape = viewport.width > viewport.height
      await expect(page.locator('main')).toHaveAttribute('data-landscape', String(landscape))
      await expect(camera).toHaveAttribute('data-camera-zoom', roomZoom.toFixed(5))
      await expect(page.locator('.world-camera-controls > span')).toHaveText('100%')
      const expectedSpan = 2 * cameraFraming(viewport.width, viewport.height, 'room', false).halfHeight / roomZoom
      await expect.poll(async () => Number(await camera.getAttribute('data-camera-span'))).toBeCloseTo(expectedSpan, 4)
      // Measuring both boxes in one evaluate keeps them in the same layout pass. Two separate
      // round trips can straddle a dock resize and compare a stale dock against a fresh row.
      await expect.poll(async () => page.evaluate(({ width, height }) => {
        const dock = document.querySelector('.native-tools-dock')?.getBoundingClientRect()
        const quick = document.querySelector('.world-quick-actions')?.getBoundingClientRect()
        const rail = document.querySelector('.world-camera-controls')?.getBoundingClientRect()
        if (!dock || !quick || !rail) return 'a laid out dock, camera rail and quick action row'
        const complaints = []
        if (dock.x < 12) complaints.push(`dock left ${dock.x.toFixed(1)} past the 12px inset`)
        if (dock.right > width - 12) complaints.push(`dock right ${dock.right.toFixed(1)} past ${width - 12}`)
        if (dock.bottom > height - 34) complaints.push(`dock bottom ${dock.bottom.toFixed(1)} past ${height - 34}`)
        if (width > height) {
          if (Math.abs(quick.bottom - dock.bottom) > 1) complaints.push('landscape controls are not level with household tools')
          if (quick.right >= dock.x) complaints.push('landscape controls overlap household tools')
        } else if (quick.bottom >= dock.y) complaints.push(`quick actions end at ${quick.bottom.toFixed(1)}, dock starts at ${dock.y.toFixed(1)}`)
        if (rail.top < 100 || rail.bottom > height - 34) complaints.push('camera controls outside the safe area')
        if (Math.abs(width - 12 - rail.right - 8) > 1) complaints.push('zoom rail is not near the safe right edge')
        if (quick.right > rail.left && quick.left < rail.right && quick.bottom > rail.top && quick.top < rail.bottom) {
          complaints.push(`quick actions overlap camera controls at ${width}x${height}`)
        }
        return complaints.join(' and ') || 'inside the safe area'
      }, viewport)).toBe('inside the safe area')
      await expect(page.locator('canvas')).toHaveCSS('width', `${viewport.width}px`)
      await expect(page.locator('canvas')).toHaveCSS('height', `${viewport.height}px`)
      await expect(shopping).toBeInViewport()
      await expect(money).toBeInViewport()
      const rail = page.locator('.world-camera-controls')
      const viewTools = page.getByRole('group', { name: 'Room view controls', exact: true })
      if (landscape) {
        await expect(rail).toHaveCSS('flex-direction', 'column')
        await expect(rail.getByRole('button')).toHaveCount(2)
        await expect(rail.getByRole('button').nth(0)).toHaveAttribute('aria-label', 'Zoom in')
        await expect(rail.getByRole('button').nth(1)).toHaveAttribute('aria-label', 'Zoom out')
        await expect(viewTools.getByRole('button')).toHaveCount(3)
        assert.deepEqual(await viewTools.getByRole('button').evaluateAll((buttons) => buttons.map((button) => button.getAttribute('aria-label'))),
          ['Hide object labels', 'Reset room view', 'Switch to evening lighting'])
        for (const button of [...await rail.getByRole('button').all(), ...await viewTools.getByRole('button').all()]) {
          await expect(button).toBeInViewport({ ratio: 1 })
          const box = await button.boundingBox()
          assert.ok(box && box.width >= 44 && box.height >= 44, 'Landscape controls keep full touch targets.')
        }
        await viewTools.getByRole('button', { name: 'Hide object labels', exact: true }).click()
        await expect(page.locator('.world-hotspots')).toHaveClass(/hide-labels/)
        await viewTools.getByRole('button', { name: 'Show object labels', exact: true }).click()
        await viewTools.getByRole('button', { name: 'Switch to evening lighting', exact: true }).click()
        await expect(page.locator('.kitchen-world')).toHaveAttribute('data-evening', 'true')
        await viewTools.getByRole('button', { name: 'Switch to daylight', exact: true }).click()
        await viewTools.getByRole('button', { name: 'Reset room view', exact: true }).click()
        await expect(rail.locator(':scope > span')).toHaveText('100%')
      } else {
        await expect(viewTools).toHaveCount(0)
        await expect(rail.getByRole('button')).toHaveCount(5)
      }
    }
    await resizeViewport({ width: 874, height: 402 })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), {
      ...householdState, roomComponents: defaultRoomComponents(),
      viewportInsets: { top: 76, right: 59, bottom: 21, left: 59 },
    })
    await page.evaluate(() => document.fonts.ready)
    const bottomRow = () => page.evaluate(() => {
      const row = document.querySelector('.world-quick-actions')
      const dock = document.querySelector('.native-tools-dock').getBoundingClientRect()
      const native = getComputedStyle(document.querySelector('.native-room'))
      const children = [...row.children].map((child) => child.getBoundingClientRect())
      const centers = children.map((box) => box.y + box.height / 2)
      return {
        height: row.getBoundingClientRect().height,
        singleRowHeight: Math.max(44, dock.height, ...children.map((box) => box.height)),
        centerSpread: Math.max(...centers) - Math.min(...centers),
        measured: Math.abs(parseFloat(native.getPropertyValue('--native-dock-width')) - dock.width) < 0.1
          && Math.abs(parseFloat(native.getPropertyValue('--native-dock-height')) - dock.height) < 0.1,
      }
    })
    const settleBottomRow = async (width, height) => {
      await expect(camera).toHaveCSS('width', `${width}px`)
      await expect(camera).toHaveCSS('height', `${height}px`)
      await expect.poll(async () => (await bottomRow()).measured).toBe(true)
    }
    const expectSingleBottomRow = async () => {
      await expect.poll(async () => {
        const { height, singleRowHeight, centerSpread, measured } = await bottomRow()
        return measured && centerSpread < 1 && Math.abs(height - singleRowHeight) < 1
          ? 'one fitted row' : JSON.stringify({ height, singleRowHeight, centerSpread, measured })
      }, { message: 'The lower controls must fit one row without retaining a previous wrapped height.' }).toBe('one fitted row')
    }
    await settleBottomRow(874, 402)
    await expectSingleBottomRow()
    await resizeViewport({ width: 600, height: 375 })
    await settleBottomRow(600, 375)
    await expect.poll(async () => {
      const { height, singleRowHeight } = await bottomRow()
      return height - singleRowHeight
    }).toBeGreaterThan(20)
    await resizeViewport({ width: 874, height: 402 })
    await settleBottomRow(874, 402)
    await expectSingleBottomRow()
    await resizeViewport({ width: 390, height: 750 })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), householdState)
    const world = page.locator('.kitchen-world')
    const settleFraming = async () => {
      await expect.poll(async () => {
        const canvas = await camera.boundingBox()
        assert.ok(canvas)
        const expected = [0, 0, canvas.width, canvas.height].map((value) => value.toFixed(3)).join(',')
        return await camera.getAttribute('data-camera-area') === expected
      }).toBe(true)
      await expect(world).toHaveAttribute('data-camera-moving', 'false')
    }
    await expect(camera).toHaveAttribute('width', '780')
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await settleFraming()
    const originalSpan = Number(await camera.getAttribute('data-camera-span'))
    assert.ok(originalSpan > 0)
    const portraitState = { ...householdState, roomZoom: 0.6 }
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), portraitState)
    await expect(camera).toHaveAttribute('data-camera-zoom', '0.60000')
    await settleFraming()
    const portraitSpan = Number(await camera.getAttribute('data-camera-span'))
    assert.equal(Number((originalSpan / portraitSpan).toFixed(3)), 0.6,
      'The portrait pullback must apply to the shared entry framing.')
    assert.ok(portraitSpan < 16, 'The native default must use the close entry view, not the old pulled-back shell.')
    await expect(page.locator('.world-camera-controls > span')).toHaveText('100%')
    const roomTarget = await camera.getAttribute('data-camera-target')
    for (const roomZoom of [0, -1, 0.29, 1.51, '0.6']) {
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
    const focusedSpan = Number(await camera.getAttribute('data-camera-span'))
    assert.ok(focusedSpan < portraitSpan,
      'Focusing the fridge must magnify the enlarged default view even while the native sheet pauses the room.')
    const expectFocusedPercent = async () => {
      const span = Number(await camera.getAttribute('data-camera-span'))
      await expect(page.locator('.world-camera-controls > span')).toHaveText(`${Math.round(portraitSpan / span * 100)}%`)
    }
    await expectFocusedPercent()
    await expect(page.locator('.world-camera-controls > span')).not.toHaveText('100%')
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeDisabled()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), portraitState)
    await page.emulateMedia({ reducedMotion: 'reduce' })
    for (const zoom of [1.1, 1.2, 1.3, 1.4, 1.5]) {
      await page.getByRole('button', { name: 'Zoom in', exact: true }).click()
      await expect(camera).toHaveAttribute('data-camera-zoom', zoom.toFixed(5))
      await expectFocusedPercent()
    }
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeDisabled()
    await expect(page.getByRole('button', { name: 'Zoom out', exact: true })).toBeEnabled()
    await page.getByRole('button', { name: 'Reset room view', exact: true }).click()
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(camera).toHaveAttribute('data-camera-zoom', '0.60000')
    await expect(page.locator('.world-camera-controls > span')).toHaveText('100%')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    assert.ok(Math.abs(Number(await camera.getAttribute('data-camera-span')) - portraitSpan) < 0.001)
    await marker.click()
    await expect(world).toHaveAttribute('data-component-focus', 'true')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.00000')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    assert.ok(Math.abs(Number(await camera.getAttribute('data-camera-span')) - focusedSpan) < 0.001,
      'Selecting the same object after Reset must restore exactly its focused magnification.')
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
    await expect(camera).toHaveAttribute('data-camera-zoom', '0.60000')
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    await page.getByRole('button', { name: 'Hide object labels', exact: true }).click()
    await expect(page.locator('.world-hotspots')).toHaveClass(/hide-labels/)
    await page.getByRole('button', { name: 'Show object labels', exact: true }).click()
    await chores.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-chores', householdId,
    })
    await shopping.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-shopping', householdId,
    })
    await money.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-money', householdId,
    })
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...portraitState, paused: true })
    await expect(chores).toBeDisabled()
    await expect(shopping).toBeDisabled()
    await expect(money).toBeDisabled()
    await expect(marker).toBeDisabled()
    await expect(page.getByRole('button', { name: 'Hide object labels', exact: true })).toBeDisabled()
    await chores.evaluate((button) => button.click())
    await shopping.evaluate((button) => button.click())
    await money.evaluate((button) => button.click())
    await marker.evaluate((button) => button.click())
    assert.equal((await page.evaluate(() => window.roomEvents)).filter((event) => event.type === 'open-chores').length, 3)
    assert.equal((await page.evaluate(() => window.roomEvents)).filter((event) => event.type === 'open-shopping').length, 1)
    assert.equal((await page.evaluate(() => window.roomEvents)).filter((event) => event.type === 'open-money').length, 1)
    await resizeViewport({ width: 1194, height: 834 })
    await expect(camera).toHaveAttribute('width', '2388')
    const nextHousehold = randomUUID()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, householdId: nextHousehold })
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(camera).toHaveAttribute('data-camera-zoom', '1.00000')
    await shopping.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-shopping', householdId: nextHousehold,
    })
    await money.click()
    assert.deepEqual((await page.evaluate(() => window.roomEvents)).at(-1), {
      version: 1, type: 'open-money', householdId: nextHousehold,
    })
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
    await expect(tools.getByRole('button')).toHaveCount(2)
    await expect(shopping).toBeEnabled()
    await expect(money).toBeEnabled()
    await expect(world).toHaveAttribute('data-component-focus', 'false')
    await expect(page.getByRole('button', { name: 'Hide object labels', exact: true })).toHaveCount(0)
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), { ...householdState, householdId: nextHousehold })
    await expect(marker).toBeVisible()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), {
      ...householdState, householdId: nextHousehold, shoppingEnabled: false,
    })
    await expect(shopping).toHaveCount(0)
    await expect(money).toBeEnabled()
    await expect(chores).toBeEnabled()
    await page.evaluate((payload) => window.RoomlingsRoom.receive(payload), {
      ...householdState, householdId: nextHousehold, moneyEnabled: false,
    })
    await expect(money).toHaveCount(0)
    await expect(chores).toBeEnabled()
    await page.evaluate(() => window.RoomlingsRoom.receive({
      version: 1, type: 'state', paused: false, roomStyle: 'original',
    }))
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('main')).toHaveAttribute('data-household-id', '')
    await expect(chores).toHaveCount(0)
    await expect(shopping).toHaveCount(0)
    await expect(money).toHaveCount(0)
    await expect(page.locator('.world-hotspots')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toBeVisible()
    await resizeViewport({ width: 808, height: 900 })
    await page.emulateMedia({ reducedMotion: 'no-preference' })
    await expect.poll(async () => Number(await camera.getAttribute('data-camera-span'))).toBeCloseTo(9.2, 4)
    await expect(world).toHaveAttribute('data-camera-moving', 'false')
    await page.evaluate(() => {
      window.resizeSpans = []
      window.recordingResize = true
      const measure = () => {
        window.resizeSpans.push({ time: performance.now(), span: Number(document.querySelector('canvas').dataset.cameraSpan) })
        if (window.recordingResize) requestAnimationFrame(measure)
      }
      requestAnimationFrame(measure)
    })
    await resizeViewport({ width: 812, height: 900 })
    const finalSpan = cameraFraming(812, 900, 'room', false).halfHeight * 2
    await expect.poll(async () => Number(await camera.getAttribute('data-camera-span'))).toBeCloseTo(finalSpan, 4)
    const spans = await page.evaluate(() => {
      window.recordingResize = false
      return window.resizeSpans
    })
    assert.ok(spans.length > 1)
    assert.ok(spans.every(({ span }) => Number.isFinite(span) && span >= 9.2 && span <= finalSpan + 0.0001))
    const maximumSpringSpeed = (finalSpan - 9.2) * 16 / Math.E
    for (let index = 1; index < spans.length; index++) {
      const seconds = (spans[index].time - spans[index - 1].time) / 1000
      assert.ok(Math.abs(spans[index].span - spans[index - 1].span) <= maximumSpringSpeed * seconds + 0.01,
        'Resizing follows the camera spring without jumping faster than its maximum speed.')
    }
    await expect(page.locator('.world-camera-controls > span')).toHaveText('100%')
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
