import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { readSharedTheme } from './build-theme.mjs'

export const brandSource = 'src/assets/brand/roomlings-icon-flat.svg'
export const wordmarkSource = 'src/assets/brand/roomlings-wordmark.svg'
export const brandCatalog = 'Roomlings/Resources/Assets.xcassets'
const provenancePath = 'Roomlings/Resources/BrandAssets.json'
// The header wordmark sits at the web's 1em beside the 36pt mark, about 26pt tall.
export const wordmarkPoints = 26
const wordmarkSize = { width: 4252, height: 939 }
const wordmark = (scale) => ({
  source: 'wordmark', opaque: false, file: `Wordmark.imageset/Wordmark${scale === 1 ? '' : `@${scale}x`}.png`,
  width: Math.round(wordmarkPoints * scale * wordmarkSize.width / wordmarkSize.height), height: wordmarkPoints * scale,
})
const mark = (file, size, opaque) => ({ source: 'mark', file, width: size, height: size, opaque })
export const brandImages = [
  mark('AppIcon.appiconset/AppIcon.png', 1024, true),
  mark('LaunchMark.imageset/LaunchMark.png', 64, false),
  mark('LaunchMark.imageset/LaunchMark@2x.png', 128, false),
  mark('LaunchMark.imageset/LaunchMark@3x.png', 192, false),
  wordmark(1), wordmark(2), wordmark(3),
]
const digest = (data) => createHash('sha256').update(data).digest('hex')

async function sourceArtwork(source, requireWeb) {
  const svg = await readFile(join(source, brandSource), 'utf8')
  assert.match(svg, /viewBox="0 0 256 256"/, 'Keep the approved mark proportions when regenerating native assets.')
  const theme = await readSharedTheme({ source, requireWeb })
  const background = theme('--paper').toLowerCase()
  assert.equal(background, '#ffffff', 'The approved icon and launch canvas is white. Review a changed web background before regenerating.')
  const words = await readFile(join(source, wordmarkSource), 'utf8')
  assert.match(words, new RegExp(`viewBox="0 0 ${wordmarkSize.width} ${wordmarkSize.height}"`),
    'Keep the approved wordmark proportions when regenerating native assets.')
  return { svg, words, background, svgSHA256: digest(svg), wordmarkSHA256: digest(words) }
}

export function checkBrandPNG(data, image) {
  assert.ok(data.length >= 33, `Missing PNG data: ${image.file}`)
  assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `Not a PNG: ${image.file}`)
  assert.equal(data.toString('ascii', 12, 16), 'IHDR')
  assert.equal(data.readUInt32BE(16), image.width, `Wrong width: ${image.file}`)
  assert.equal(data.readUInt32BE(20), image.height, `Wrong height: ${image.file}`)
  assert.equal(data[24], 8, `Expected eight-bit artwork: ${image.file}`)
  assert.equal(data[25], image.opaque ? 2 : 6,
    image.opaque ? 'The app icon must be RGB without an alpha channel.' : 'The launch mark and wordmark must retain transparency.')
}

export async function checkBrandAssets({ source, project, requireWeb }) {
  const artwork = await sourceArtwork(source, requireWeb)
  const provenance = JSON.parse(await readFile(join(project, provenancePath), 'utf8'))
  const regenerate = 'Regenerate approved native artwork with node Scripts/build-brand-assets.mjs --write.'
  assert.equal(provenance.version, 2, regenerate)
  assert.equal(provenance.source, brandSource, regenerate)
  assert.equal(provenance.svgSHA256, artwork.svgSHA256, regenerate)
  assert.equal(provenance.wordmarkSource, wordmarkSource, regenerate)
  assert.equal(provenance.wordmarkSHA256, artwork.wordmarkSHA256, regenerate)
  assert.equal(provenance.wordmarkPoints, wordmarkPoints, regenerate)
  assert.equal(provenance.background, artwork.background, regenerate)
  assert.equal(provenance.launchSizePoints, 64, regenerate)
  assert.deepEqual(Object.keys(provenance.images).sort(), brandImages.map(({ file }) => file).sort(), regenerate)
  for (const image of brandImages) {
    const data = await readFile(join(project, brandCatalog, image.file))
    checkBrandPNG(data, image)
    assert.equal(provenance.images[image.file], digest(data), `${image.file} changed. ${regenerate}`)
  }
}

export async function generateBrandAssets({ source, project, requireWeb }) {
  const artwork = await sourceArtwork(source, requireWeb)
  const { chromium } = requireWeb('@playwright/test')
  const browser = await chromium.launch({ headless: true })
  const images = {}
  try {
    const page = await browser.newPage({ deviceScaleFactor: 1 })
    let externalRequest = false
    await page.route('**/*', (route) => {
      externalRequest = true
      return route.abort()
    })
    const uris = Object.fromEntries(Object.entries({ mark: artwork.svg, wordmark: artwork.words })
      .map(([name, svg]) => [name, `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`]))
    for (const image of brandImages) {
      await page.setViewportSize({ width: image.width, height: image.height })
      await page.setContent(`<style>
        html,body{margin:0;padding:0;background:${image.opaque ? artwork.background : 'transparent'}}
        img{display:block;width:${image.width}px;height:${image.height}px}
      </style><img alt="" src="${uris[image.source]}">`)
      await page.locator('img').evaluate((image) => image.decode())
      assert.equal(externalRequest, false, 'Native artwork must render entirely offline.')
      const png = await page.screenshot({ type: 'png', omitBackground: !image.opaque, animations: 'disabled' })
      checkBrandPNG(png, image)
      const destination = join(project, brandCatalog, image.file)
      await mkdir(dirname(destination), { recursive: true })
      await writeFile(destination, png)
      images[image.file] = digest(png)
    }
  } finally {
    await browser.close()
  }
  await writeFile(join(project, provenancePath), JSON.stringify({
    version: 2,
    source: brandSource,
    webRevisionAtGeneration: execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    svgSHA256: artwork.svgSHA256,
    wordmarkSource,
    wordmarkSHA256: artwork.wordmarkSHA256,
    wordmarkPoints,
    background: artwork.background,
    launchSizePoints: 64,
    images,
  }, null, 2) + '\n')
  await checkBrandAssets({ source, project, requireWeb })
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: { 'web-root': { type: 'string' }, write: { type: 'boolean' } } })
  const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const source = resolve(project, values['web-root'] ?? process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings')
  const options = { project, source, requireWeb: createRequire(join(source, 'package.json')) }
  if (values.write) await generateBrandAssets(options)
  else await checkBrandAssets(options)
  console.log(values.write ? 'Generated native artwork from the shared Roomlings SVGs.' : 'Native artwork matches the shared Roomlings source.')
}
