import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { checkArchiveSettings, checkArchiveSource } from '../../Scripts/check-release.mjs'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const settings = {
  CONFIGURATION: 'Release',
  PLATFORM_NAME: 'iphoneos',
  DEVELOPMENT_TEAM: 'A1B2C3D4E5',
  CODE_SIGNING_ALLOWED: 'YES',
  CODE_SIGNING_REQUIRED: 'YES',
  PRODUCT_BUNDLE_IDENTIFIER: 'com.roomlings.app',
  MARKETING_VERSION: '0.1.0',
  CURRENT_PROJECT_VERSION: '1',
  ROOMLINGS_API_SCHEME: 'https',
  ROOMLINGS_API_HOST: 'api.roomlings.app',
  ROOMLINGS_INVITATION_SCHEME: 'https',
  ROOMLINGS_INVITATION_HOST: 'roomlings.app',
  ROOMLINGS_APNS_ENVIRONMENT: 'production',
  SWIFT_ACTIVE_COMPILATION_CONDITIONS: '',
  ENABLE_TESTABILITY: 'NO',
}

test('a signed device Release configuration with public HTTPS origins is accepted without network access', () => {
  const original = { ...settings }
  checkArchiveSettings(settings)
  checkArchiveSettings({ ...settings, ROOMLINGS_API_HOST: 'API.ROOMLINGS.APP:8443' })
  assert.deepEqual(settings, original)
})

for (const kind of ['API', 'INVITATION']) {
  test(`${kind} rejects local, reserved, malformed and credential-bearing origins`, () => {
    for (const host of [
      '', 'localhost', 'localhost:4311', 'app.localhost', '127.0.0.1', '127.1', '2130706433', '0x7f000001',
      '0.0.0.0', '10.0.0.1:443', '172.16.0.1', '192.168.1.2', '8.8.8.8', '[::1]', '[2001:4860:4860::8888]',
      'app.local', 'app.localdomain', 'app.lan', 'app.home.arpa', 'app.internal', 'app.test',
      'app.example', 'app.invalid', 'example.com', 'app.example.net', 'app.example.org',
      'app', 'roomlings.app/path', 'roomlings.app/', 'roomlings.app?token=private', 'roomlings.app#fragment',
      'private:secret@roomlings.app', '//roomlings.app', 'https://roomlings.app',
      'roomlings.app:0', 'roomlings.app:99999', 'roomlings.app:abc', 'roomlings.app:', 'roomlings..app', '-bad.roomlings.app',
      '\u00e9.roomlings.app',
      'bad_.roomlings.app', 'roomlings.app.', ' roomlings.app', 'roomlings.app\n', 'roomlings.app\\path',
      'roomlings.app%2Fprivate', `${'a'.repeat(64)}.roomlings.app`,
    ]) {
      assert.throws(
        () => checkArchiveSettings({ ...settings, [`ROOMLINGS_${kind}_HOST`]: host }),
        new RegExp(`ROOMLINGS_${kind}_HOST`), host,
      )
    }
    for (const scheme of ['', 'http', 'file', 'https ', '$(inherited)']) {
      assert.throws(
        () => checkArchiveSettings({ ...settings, [`ROOMLINGS_${kind}_SCHEME`]: scheme }),
        new RegExp(`ROOMLINGS_${kind}_SCHEME`),
      )
    }
  })
}

test('archive failures identify settings without echoing credentials or private URLs', () => {
  assert.throws(() => checkArchiveSettings({
    ...settings, ROOMLINGS_API_HOST: 'secret-user:secret-password@roomlings.app',
    ROOMLINGS_INVITATION_HOST: 'roomlings.app?private-code', DEVELOPMENT_TEAM: 'private-team',
  }), (error) => {
    assert.match(error.message, /ROOMLINGS_API_HOST/)
    assert.match(error.message, /ROOMLINGS_INVITATION_HOST/)
    assert.match(error.message, /DEVELOPMENT_TEAM/)
    assert.doesNotMatch(error.message, /secret-user|secret-password|private-code|private-team/)
    return true
  })
})

test('shipping configurations require signing, production APNs and no debug/test entry points', () => {
  for (const [key, value, error] of [
    ['CONFIGURATION', 'Debug', /Release configuration/],
    ['PLATFORM_NAME', 'iphonesimulator', /physical iOS device/],
    ['DEVELOPMENT_TEAM', '', /DEVELOPMENT_TEAM/],
    ['DEVELOPMENT_TEAM', '$(inherited)', /DEVELOPMENT_TEAM/],
    ['CODE_SIGNING_ALLOWED', 'NO', /code signing/],
    ['CODE_SIGNING_REQUIRED', 'NO', /code signing/],
    ['ROOMLINGS_APNS_ENVIRONMENT', 'development', /production APNs/],
    ['SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'FEATURE DEBUG OTHER', /DEBUG code/],
    ['OTHER_SWIFT_FLAGS', '-DDEBUG', /DEBUG code/],
    ['OTHER_SWIFT_FLAGS', '-D DEBUG -D FEATURE', /DEBUG code/],
    ['OTHER_SWIFT_FLAGS', '"-D" "DEBUG"', /DEBUG code/],
    ['OTHER_SWIFT_FLAGS', '-enable-testing', /testability/],
    ['ENABLE_TESTABILITY', 'YES', /testability/],
    ['PRODUCT_BUNDLE_IDENTIFIER', 'com.roomlings.*', /PRODUCT_BUNDLE_IDENTIFIER/],
    ['PRODUCT_BUNDLE_IDENTIFIER', 'com.roomlings_app', /PRODUCT_BUNDLE_IDENTIFIER/],
  ]) {
    assert.throws(() => checkArchiveSettings({ ...settings, [key]: value }), error)
  }
  for (const key of Object.keys(settings).filter((key) => !['SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'ENABLE_TESTABILITY'].includes(key))) {
    const missing = { ...settings }
    delete missing[key]
    assert.throws(() => checkArchiveSettings(missing), /Cannot archive/)
  }
})

test('versions follow the Apple numeric metadata formats without fixing them to the first build', () => {
  for (const version of ['0.1.0', '1.2.3', '10.20.30']) {
    for (const build of ['1', '2', '12345', '2.10', '2.10.3']) {
      checkArchiveSettings({ ...settings, MARKETING_VERSION: version, CURRENT_PROJECT_VERSION: build })
    }
  }
  for (const version of ['', '1', '1.2', '1.2.3.4', '1.2.3-beta', 'v1.2.3', '1.2.-3', '1.2.3 ', '$(MARKETING_VERSION)']) {
    assert.throws(() => checkArchiveSettings({ ...settings, MARKETING_VERSION: version }), /MARKETING_VERSION/)
  }
  for (const build of ['', '-1', '1.2.3.4', '1.0-beta', '1e2', '1 ', '$(CURRENT_PROJECT_VERSION)']) {
    assert.throws(() => checkArchiveSettings({ ...settings, CURRENT_PROJECT_VERSION: build }), /CURRENT_PROJECT_VERSION/)
  }
})

test('an archive requires the exact clean web revision pinned in CI', () => {
  const revision = '1'.repeat(40)
  const workflow = `env:\n  WEB_REVISION: ${revision}\n`
  checkArchiveSource({ revision, dirty: false, workflow })
  assert.throws(() => checkArchiveSource({ revision, dirty: true, workflow }), /clean web checkout/)
  assert.throws(() => checkArchiveSource({ revision, workflow }), /clean web checkout/)
  assert.throws(() => checkArchiveSource({ revision: '2'.repeat(40), dirty: false, workflow }), /revision pinned in CI/)
  for (const invalid of ['', '  WEB_REVISION: main\n', '  WEB_REVISION: 1234567\n', workflow + workflow]) {
    assert.throws(() => checkArchiveSource({ revision, dirty: false, workflow: invalid }), /exactly one full web revision/)
  }
})

test('the real bundle script fails unsafe archives before reading a web checkout or generating resources', () => {
  const result = spawnSync(process.execPath, [join(project, 'Scripts/build-room.mjs')], {
    cwd: project,
    env: {
      ...process.env, ...settings, ACTION: 'install', ROOMLINGS_API_HOST: 'localhost:4311',
      ROOMLINGS_WEB_ROOT: join(project, 'does-not-exist'),
    },
    encoding: 'utf8',
  })
  assert.equal(result.status, 1, result.stderr)
  assert.match(result.stderr, /Cannot archive Roomlings/)
  assert.match(result.stderr, /ROOMLINGS_API_HOST/)
  assert.doesNotMatch(result.stderr, /ENOENT|does-not-exist/)
})

test('Release has independent local overrides and both plist versions use build settings', async () => {
  const [release, debug, shared, plist, projectFile, ignore, bundleScript] = await Promise.all([
    'Configuration/Release.xcconfig', 'Configuration/Debug.xcconfig', 'Configuration/Shared.xcconfig',
    'Roomlings/Info.plist', 'Roomlings.xcodeproj/project.pbxproj', '.gitignore', 'Scripts/build-room.mjs',
  ].map((path) => readFile(join(project, path), 'utf8')))
  assert.match(debug, /#include\? "Local\.xcconfig"/)
  assert.match(release, /#include\? "Release\.local\.xcconfig"/)
  assert.doesNotMatch(release, /#include\? "Local\.xcconfig"/)
  assert.match(ignore, /^Configuration\/Release\.local\.xcconfig$/m)
  assert.match(shared, /^MARKETING_VERSION = \d+\.\d+\.\d+$/m)
  assert.match(shared, /^CURRENT_PROJECT_VERSION = \d+(?:\.\d+){0,2}$/m)
  assert.doesNotMatch(projectFile, /(?:MARKETING_VERSION|CURRENT_PROJECT_VERSION) =/)
  assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>\$\(MARKETING_VERSION\)<\/string>/)
  assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>\$\(CURRENT_PROJECT_VERSION\)<\/string>/)
  assert.match(projectFile, /Scripts\/build-room\.mjs/)
  assert.match(bundleScript, /process\.env\.ACTION === 'install'/)
  assert.match(bundleScript, /--untracked-files=normal/)
  assert.match(bundleScript, /checkBrandAssets\(\{ source, project, requireWeb \}\)/)
})
