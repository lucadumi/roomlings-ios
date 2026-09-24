import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { invitationAssociation, writeInvitationAssociation } from '../../Scripts/invitation-links.mjs'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const settings = {
  ROOMLINGS_UNIVERSAL_LINKS: 'YES',
  ROOMLINGS_INVITATION_SCHEME: 'https',
  ROOMLINGS_INVITATION_HOST: 'invites.roomlings.app',
  ROOMLINGS_APP_ID_PREFIX: 'A1B2C3D4E5',
  DEVELOPMENT_TEAM: 'Z9Y8X7W6V5',
  PRODUCT_BUNDLE_IDENTIFIER: 'com.roomlings.app',
}

test('Universal Links are opt-in and local or missing origins still work when disabled', () => {
  for (const disabled of [
    {}, { ROOMLINGS_UNIVERSAL_LINKS: 'NO' },
    { ...settings, ROOMLINGS_UNIVERSAL_LINKS: 'NO', ROOMLINGS_INVITATION_SCHEME: 'http', ROOMLINGS_INVITATION_HOST: 'localhost:5173' },
  ]) {
    assert.equal(invitationAssociation(disabled), null)
  }
  for (const invalid of ['', 'yes', 'true', '1', 'NO ', '$(inherited)']) {
    assert.throws(() => invitationAssociation({ ...settings, ROOMLINGS_UNIVERSAL_LINKS: invalid }), /YES or NO/)
  }
})

test('the association uses the explicit App ID prefix, not the team, and only root invitation fragments', () => {
  const original = { ...settings }
  assert.deepEqual(invitationAssociation(settings), {
    applinks: {
      details: [{
        appIDs: ['A1B2C3D4E5.com.roomlings.app'],
        components: [{ '/': '/', '?': '', '#': 'account-invite=roomlings-invite-' + '?'.repeat(43) }],
      }],
    },
  })
  assert.deepEqual(settings, original)
  assert.throws(() => invitationAssociation({ ...settings, ROOMLINGS_APP_ID_PREFIX: undefined }), /ROOMLINGS_APP_ID_PREFIX/)
})

test('link setup refuses nonpublic hosts, ports, wildcard domains and incomplete identifiers', () => {
  for (const host of [
    undefined, '', 'localhost', 'localhost:5173', '127.0.0.1', '127.1', '[::1]', '10.0.0.1',
    'app.local', 'app.internal', 'app.test', 'app.invalid', 'example.com', 'app.example.org',
    'invites.roomlings.app:443', 'invites.roomlings.app:8443', '*.roomlings.app',
    'https://invites.roomlings.app', 'invites.roomlings.app/', 'invites.roomlings.app/path',
    'invites.roomlings.app?private', 'invites.roomlings.app#private', 'private@invites.roomlings.app',
    'invites.roomlings.app?mode=developer', ' invites.roomlings.app',
  ]) {
    assert.throws(() => invitationAssociation({ ...settings, ROOMLINGS_INVITATION_HOST: host }), /ROOMLINGS_INVITATION_HOST/)
  }
  for (const scheme of [undefined, '', 'http', 'https ']) {
    assert.throws(() => invitationAssociation({ ...settings, ROOMLINGS_INVITATION_SCHEME: scheme }), /ROOMLINGS_INVITATION_SCHEME/)
  }
  for (const prefix of ['', 'A1B2C3D4E5.', 'a1b2c3d4e5', 'APP_ID_PREFIX', '$(AppIdentifierPrefix)']) {
    assert.throws(() => invitationAssociation({ ...settings, ROOMLINGS_APP_ID_PREFIX: prefix }), /ROOMLINGS_APP_ID_PREFIX/)
  }
  for (const bundle of [undefined, '', 'com.roomlings.*', 'com.roomlings_app', '$(PRODUCT_BUNDLE_IDENTIFIER)']) {
    assert.throws(() => invitationAssociation({ ...settings, PRODUCT_BUNDLE_IDENTIFIER: bundle }), /PRODUCT_BUNDLE_IDENTIFIER/)
  }
})

test('setup errors identify the settings without disclosing supplied URLs or credentials', () => {
  assert.throws(() => invitationAssociation({
    ...settings, ROOMLINGS_INVITATION_HOST: 'private-user:private-password@roomlings.app',
    ROOMLINGS_APP_ID_PREFIX: 'private-prefix', PRODUCT_BUNDLE_IDENTIFIER: 'private-identifier',
  }), (error) => {
    assert.match(error.message, /ROOMLINGS_INVITATION_HOST/)
    assert.match(error.message, /ROOMLINGS_APP_ID_PREFIX/)
    assert.match(error.message, /PRODUCT_BUNDLE_IDENTIFIER/)
    assert.doesNotMatch(error.message, /private-user|private-password|private-prefix|private-identifier/)
    return true
  })
})

test('device builds cannot silently disagree with the entitlement opt-in', () => {
  for (const [enabled, entitlements] of [
    ['YES', 'Roomlings/RoomlingsLinks.entitlements'], ['NO', 'Roomlings/Roomlings.entitlements'],
  ]) {
    const device = { ...settings, ROOMLINGS_UNIVERSAL_LINKS: enabled, PLATFORM_NAME: 'iphoneos' }
    invitationAssociation({ ...device, CODE_SIGN_ENTITLEMENTS: entitlements })
    for (const incorrect of [undefined, '', 'custom.entitlements',
      enabled === 'YES' ? 'Roomlings/Roomlings.entitlements' : 'Roomlings/RoomlingsLinks.entitlements']) {
      assert.throws(() => invitationAssociation({ ...device, CODE_SIGN_ENTITLEMENTS: incorrect }), /CODE_SIGN_ENTITLEMENTS/)
    }
  }
})

test('generation writes exactly the association JSON and disabling removes only that artifact', async (context) => {
  const directory = await mkdtemp(join(tmpdir(), 'roomlings-invitation-links-'))
  context.after(() => rm(directory, { recursive: true, force: true }))
  const output = join(directory, 'apple-app-site-association')
  await writeInvitationAssociation(null, directory)
  await assert.rejects(readFile(output), { code: 'ENOENT' })
  const association = invitationAssociation(settings)
  await writeInvitationAssociation(association, directory)
  assert.equal(await readFile(output, 'utf8'), JSON.stringify(association, null, 2) + '\n')
  await writeFile(join(directory, 'unrelated'), 'keep')
  await writeInvitationAssociation(null, directory)
  await assert.rejects(readFile(output), { code: 'ENOENT' })
  assert.equal(await readFile(join(directory, 'unrelated'), 'utf8'), 'keep')
  await assert.rejects(writeInvitationAssociation(association, join(directory, 'unrelated')))
})

test('the actual room build rejects incomplete link setup before accessing shared web source', () => {
  const result = spawnSync(process.execPath, [join(project, 'Scripts/build-room.mjs')], {
    cwd: project,
    env: {
      ...process.env, ...settings, ACTION: 'build', PLATFORM_NAME: 'iphonesimulator',
      ROOMLINGS_INVITATION_HOST: '', ROOMLINGS_WEB_ROOT: join(project, 'does-not-exist'),
    },
    encoding: 'utf8',
  })
  assert.equal(result.status, 1, result.stderr)
  assert.match(result.stderr, /Cannot enable invitation Universal Links/)
  assert.doesNotMatch(result.stderr, /ENOENT|does-not-exist/)
})

test('both entitlement variants preserve APNs and the default requests no associated domains', async () => {
  const [disabled, enabled, shared, projectFile, build] = await Promise.all([
    'Roomlings/Roomlings.entitlements', 'Roomlings/RoomlingsLinks.entitlements',
    'Configuration/Shared.xcconfig', 'Roomlings.xcodeproj/project.pbxproj', 'Scripts/build-room.mjs',
  ].map((file) => readFile(join(project, file), 'utf8')))
  for (const entitlement of [disabled, enabled]) {
    assert.match(entitlement, /<key>aps-environment<\/key>\s*<string>\$\(ROOMLINGS_APNS_ENVIRONMENT\)<\/string>/)
  }
  assert.doesNotMatch(disabled, /associated-domains|applinks:/)
  assert.match(enabled, /<key>com\.apple\.developer\.associated-domains<\/key>\s*<array>\s*<string>applinks:\$\(ROOMLINGS_INVITATION_HOST\)<\/string>\s*<\/array>/)
  assert.match(shared, /^ROOMLINGS_UNIVERSAL_LINKS = NO$/m)
  assert.match(projectFile, /path = RoomlingsLinks\.entitlements/)
  assert.match(build, /invitationAssociation\(process\.env\)/)
  assert.match(build, /writeInvitationAssociation\(association, join\(project, 'Build', 'InvitationLinks'\)\)/)
})

test('Xcode resolves the actual entitlement switch for device builds and leaves simulators unchanged',
  { skip: process.platform !== 'darwin' }, () => {
    for (const [enabled, destination, expected] of [
      ['NO', 'generic/platform=iOS', 'Roomlings/Roomlings.entitlements'],
      ['YES', 'generic/platform=iOS', 'Roomlings/RoomlingsLinks.entitlements'],
      ['YES', 'generic/platform=iOS Simulator', undefined],
    ]) {
      const result = spawnSync('xcodebuild', [
        '-project', join(project, 'Roomlings.xcodeproj'), '-scheme', 'Roomlings',
        '-configuration', 'Release', '-destination', destination, '-showBuildSettings', '-json',
        'CODE_SIGNING_ALLOWED=NO', `ROOMLINGS_UNIVERSAL_LINKS=${enabled}`,
      ], { cwd: project, encoding: 'utf8' })
      assert.equal(result.status, 0, result.stderr)
      const actual = JSON.parse(result.stdout).find((target) => target.target === 'Roomlings')?.buildSettings
      assert.ok(actual)
      assert.equal(actual.CODE_SIGN_ENTITLEMENTS, expected)
    }
  })
