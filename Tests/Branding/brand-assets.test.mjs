import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { brandCatalog, brandImages, brandSource, checkBrandAssets, checkBrandPNG } from '../../Scripts/build-brand-assets.mjs'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const source = resolve(project, process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings')
const requireWeb = createRequire(join(source, 'package.json'))

test('native branding retains the approved shared source and exact output dimensions', async () => {
  await checkBrandAssets({ source, project, requireWeb })
  const icon = JSON.parse(await readFile(join(project, brandCatalog, 'AppIcon.appiconset/Contents.json'), 'utf8'))
  assert.deepEqual(icon.images, [{ filename: 'AppIcon.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }])
  const mark = JSON.parse(await readFile(join(project, brandCatalog, 'LaunchMark.imageset/Contents.json'), 'utf8'))
  assert.deepEqual(mark.images.map(({ scale }) => scale), ['1x', '2x', '3x'])
  assert.equal(mark.properties['template-rendering-intent'], 'original')
  const background = JSON.parse(await readFile(join(project, brandCatalog, 'LaunchBackground.colorset/Contents.json'), 'utf8'))
  assert.deepEqual(background.colors[0].color.components, { alpha: '1.000', red: '1.000', green: '1.000', blue: '1.000' })
})

test('incorrect PNG dimensions, alpha format or signatures fail instead of packaging stale artwork', async () => {
  const image = brandImages[0]
  const original = await readFile(join(project, brandCatalog, image.file))
  const resized = Buffer.from(original)
  resized.writeUInt32BE(256, 16)
  assert.throws(() => checkBrandPNG(resized, image), /Wrong width/)
  const alpha = Buffer.from(original)
  alpha[25] = 6
  assert.throws(() => checkBrandPNG(alpha, image), /without an alpha channel/)
  assert.throws(() => checkBrandPNG(Buffer.alloc(0), image), /Missing PNG data/)
  const invalid = Buffer.from(original)
  invalid[0] = 0
  assert.throws(() => checkBrandPNG(invalid, image), /Not a PNG/)
})

test('changing the shared vector requires deliberate regeneration', async (t) => {
  const isolated = await mkdtemp(join(tmpdir(), 'roomlings-brand-source-'))
  t.after(() => rm(isolated, { recursive: true, force: true }))
  await mkdir(join(isolated, 'src/assets/brand'), { recursive: true })
  await writeFile(join(isolated, brandSource), (await readFile(join(source, brandSource), 'utf8')).replace('#527861', '#000000'))
  await writeFile(join(isolated, 'src/style.css'), ':root { --paper: #ffffff; }')
  await assert.rejects(checkBrandAssets({ source: isolated, project, requireWeb }), /Regenerate approved native artwork/)
  await writeFile(join(isolated, 'src/style.css'), ':root { --paper: #fcf9f1; }')
  await assert.rejects(checkBrandAssets({ source: isolated, project, requireWeb }), /approved icon and launch canvas is white/)
})

test('native artwork keeps the shared palette and the approved white or transparent canvas', async () => {
  const { chromium } = requireWeb('@playwright/test')
  const browser = await chromium.launch({ headless: true })
  try {
    const page = await browser.newPage()
    const samples = [
      { x: 70, y: 80, rgba: [82, 120, 97, 255] },
      { x: 180, y: 80, rgba: [224, 122, 95, 255] },
      { x: 70, y: 180, rgba: [242, 204, 143, 255] },
      { x: 170, y: 180, rgba: [129, 178, 154, 255] },
    ]
    for (const image of brandImages) {
      const data = await readFile(join(project, brandCatalog, image.file))
      const pixels = await page.evaluate(async ({ png, size, samples }) => {
        const image = new Image()
        image.src = `data:image/png;base64,${png}`
        await image.decode()
        const canvas = document.createElement('canvas')
        canvas.width = canvas.height = size
        const context = canvas.getContext('2d')
        if (!context) throw new Error('Canvas is unavailable.')
        context.drawImage(image, 0, 0)
        const pixel = (x, y) => [...context.getImageData(x, y, 1, 1).data]
        return {
          corners: [[0, 0], [size - 1, 0], [0, size - 1], [size - 1, size - 1]].map(([x, y]) => pixel(x, y)),
          palette: samples.map(({ x, y }) => pixel(Math.floor(x * size / 256), Math.floor(y * size / 256))),
        }
      }, { png: data.toString('base64'), size: image.size, samples })
      assert.deepEqual(pixels.corners, Array.from({ length: 4 }, () => image.opaque ? [255, 255, 255, 255] : [0, 0, 0, 0]))
      assert.deepEqual(pixels.palette, samples.map(({ rgba }) => rgba))
    }
  } finally {
    await browser.close()
  }
})
