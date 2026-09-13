import assert from 'node:assert/strict'
import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const web = resolve(project, process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings')
const requireWeb = createRequire(join(web, 'package.json'))
const { chromium, expect } = requireWeb('@playwright/test')

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
    const page = await browser.newPage({ viewport: { width: 390, height: 750 }, hasTouch: true, deviceScaleFactor: 2 })
    page.on('pageerror', (error) => console.error('Bundled room error:', error.message))
    await page.addInitScript(() => {
      window.roomEvents = []
      window.webkit = { messageHandlers: { roomlings: { postMessage: (event) => window.roomEvents.push(event) } } }
    })
    await page.goto(`http://127.0.0.1:${server.address().port}/`)
    await expect(page.locator('html')).toHaveAttribute('data-room-status', 'ready', { timeout: 30_000 })
    await expect(page.locator('canvas')).toHaveAttribute('data-render-ready', 'true')
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
    await page.evaluate(() => window.RoomlingsRoom.receive({ version: 1, type: 'state', paused: true, roomStyle: 'clay' }))
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-room-style', 'clay')
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-rendering', 'paused', { timeout: 10_000 })
    await page.evaluate(() => window.RoomlingsRoom.receive({ version: 1, type: 'state', paused: false, roomStyle: 'original' }))
    await expect(page.locator('.kitchen-world')).toHaveAttribute('data-rendering', 'active')
    await page.getByRole('button', { name: 'Put the kettle on', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Put the kettle on', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await page.setViewportSize({ width: 1194, height: 834 })
    await expect(page.getByRole('button', { name: 'Zoom in', exact: true })).toBeInViewport()
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
