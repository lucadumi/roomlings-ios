import { isIP } from 'node:net'

function isPublicHTTPSOrigin(scheme, host) {
  if (scheme !== 'https' || typeof host !== 'string'
      || !/^[A-Za-z0-9.-]+(?::[0-9]+)?$/.test(host)) return false
  let url
  try {
    url = new URL(`${scheme}://${host}`)
  } catch {
    return false
  }
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash
      || (url.port && Number(url.port) < 1)) return false
  const name = url.hostname
  const labels = name.split('.')
  if (isIP(name) || labels.length < 2 || name.length > 253
      || !labels.every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return false
  const reserved = [
    'localhost', 'local', 'localdomain', 'internal', 'lan', 'home.arpa',
    'test', 'invalid', 'example', 'example.com', 'example.net', 'example.org',
  ]
  return !reserved.some((suffix) => name === suffix || name.endsWith(`.${suffix}`))
}

export function checkArchiveSettings(settings) {
  const failures = []
  if (settings.CONFIGURATION !== 'Release') failures.push('Archive using the Release configuration.')
  if (settings.PLATFORM_NAME !== 'iphoneos') failures.push('Archive for a physical iOS device, not a simulator.')
  for (const kind of ['API', 'INVITATION']) {
    if (!isPublicHTTPSOrigin(settings[`ROOMLINGS_${kind}_SCHEME`], settings[`ROOMLINGS_${kind}_HOST`])) {
      failures.push(`Set ROOMLINGS_${kind}_SCHEME=https and ROOMLINGS_${kind}_HOST to the approved public host, without a path or credentials. Local addresses and example domains cannot be distributed.`)
    }
  }
  if (!/^[A-Z0-9]{10}$/.test(settings.DEVELOPMENT_TEAM ?? '')) {
    failures.push('Set DEVELOPMENT_TEAM to the Apple Developer team identifier.')
  }
  if (settings.CODE_SIGNING_ALLOWED !== 'YES' || settings.CODE_SIGNING_REQUIRED !== 'YES') {
    failures.push('Distribution archives require code signing. Use an unsigned Release build, not archive, for compilation checks.')
  }
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(settings.PRODUCT_BUNDLE_IDENTIFIER ?? '')) {
    failures.push('Set PRODUCT_BUNDLE_IDENTIFIER to the explicit identifier registered in App Store Connect.')
  }
  if (!/^\d+\.\d+\.\d+$/.test(settings.MARKETING_VERSION ?? '')) {
    failures.push('MARKETING_VERSION must contain three numeric components, such as 0.1.0.')
  }
  if (!/^\d+(?:\.\d+){0,2}$/.test(settings.CURRENT_PROJECT_VERSION ?? '')) {
    failures.push('CURRENT_PROJECT_VERSION must contain one to three numeric components. Increment it for each uploaded build.')
  }
  if (settings.ROOMLINGS_APNS_ENVIRONMENT !== 'production') {
    failures.push('TestFlight uses production APNs; set ROOMLINGS_APNS_ENVIRONMENT=production.')
  }
  const swiftFlags = (settings.OTHER_SWIFT_FLAGS ?? '').replace(/["']/g, '')
  if (/\bDEBUG\b/.test(settings.SWIFT_ACTIVE_COMPILATION_CONDITIONS ?? '')
      || /(?:^|\s)-D\s*DEBUG(?:\s|$)/.test(swiftFlags)
      || /(?:^|\s)-enable-testing(?:\s|$)/.test(swiftFlags)
      || settings.ENABLE_TESTABILITY === 'YES') {
    failures.push('Distribution archives must not enable DEBUG code or testability.')
  }
  if (failures.length) {
    throw new Error(`Cannot archive Roomlings:\n${failures.map((failure) => `- ${failure}`).join('\n')}\nSee docs/testflight.md.`)
  }
}

export function checkArchiveSource({ revision, dirty, workflow }) {
  const pins = [...workflow.matchAll(/^  WEB_REVISION: ([a-f0-9]{40})\r?$/gm)]
  if (pins.length !== 1) throw new Error('CI must pin exactly one full web revision before archiving.')
  if (revision !== pins[0][1] || dirty !== false) {
    throw new Error('Archive from a clean web checkout at the revision pinned in CI. Set ROOMLINGS_WEB_ROOT to an isolated checkout; do not change the shared review server checkout. See docs/testflight.md.')
  }
}
