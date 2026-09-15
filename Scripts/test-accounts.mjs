import { randomUUID } from 'node:crypto'
import { execFileSync, spawn } from 'node:child_process'
import { once } from 'node:events'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const web = resolve(project, process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings')
const requireWeb = createRequire(join(web, 'package.json'))
const { values } = parseArgs({ options: { destination: { type: 'string' }, 'include-room': { type: 'boolean' } } })
const { createApp } = await import(pathToFileURL(join(web, 'server/app.ts')).href)
const { Store } = await import(pathToFileURL(join(web, 'server/store.ts')).href)
const { ApiError } = await import(pathToFileURL(join(web, 'server/errors.ts')).href)
const { getRoomComponents } = await import(pathToFileURL(join(web, 'shared/roomComponents.ts')).href)
const { accountEmailSchema } = await import(pathToFileURL(join(web, 'shared/accounts.ts')).href)
const express = requireWeb('express')
const { z } = requireWeb('zod')
const store = new Store(':memory:')
const identities = new Map()
const pendingCodes = new Set()
let failDelivery = false
const identity = (email) => {
  if (!identities.has(email)) identities.set(email, randomUUID())
  return { providerId: identities.get(email), email }
}
const provider = {
  async sendCode(email) {
    if (failDelivery) throw new ApiError(503, 'Test delivery unavailable', 'AUTH_PROVIDER_UNAVAILABLE')
    pendingCodes.add(email)
  },
  async verifyCode(email, code) {
    if (!pendingCodes.has(email) || code !== '123456') throw new ApiError(401, 'Invalid test code')
    pendingCodes.delete(email)
    return identity(email)
  },
  async deleteUser(providerId) {
    for (const [email, id] of identities) if (id === providerId) identities.delete(email)
  },
}
const app = createApp(store, { provider, appOrigin: 'http://localhost:5173' })
app.get('/_fixture', (_request, response) => response.json({ roomlingsTest: true }))
app.post('/_fixture/seed', express.json(), async (request, response) => {
  const email = accountEmailSchema.parse(request.body.email)
  failDelivery = false
  const issued = await store.accounts.signIn(identity(email), 'Ada', 'Fixture setup')
  const homes = []
  let invitation
  for (const [name, style, kettle] of [['Cedar House', 'clay', false], ['Willow House', 'coastal', true]]) {
    const state = await store.accounts.createHousehold(issued.session, {
      name, memberName: 'Ada', currency: 'EUR', budget: 25000,
    })
    const household = state.session.household
    household.roomStyle = style
    household.roomComponents = getRoomComponents(household).map((component) =>
      !kettle && component.slotId === 'kitchen-kettle' ? { ...component, installed: false } : component)
    household.version++
    await store.save(household)
    if (!invitation) invitation = (await store.accounts.invite(issued.session, household.id, household.version, 7)).code
    homes.push({ id: household.id, name })
  }
  const recovery = await store.accounts.generateRecoveryCodes(issued.session, 0)
  await store.accounts.logout(issued.session, false)
  response.json({ homes, invitation, recoveryCode: recovery.codes[0] })
})
app.post('/_fixture/delivery', express.json(), (request, response) => {
  failDelivery = z.object({ fail: z.boolean() }).parse(request.body).fail
  response.json({ configured: true })
})
app.use((error, _request, response, _next) => {
  console.error('Account fixture failed:', error.message)
  response.status(500).json({ error: 'Account fixture failed' })
})
const server = app.listen(0, '127.0.0.1')
try {
  await once(server, 'listening')
  const origin = `http://127.0.0.1:${server.address().port}`
  const destination = values.destination ?? 'platform=iOS Simulator,name=iPhone 17 Pro'
  const result = join(project, 'Build', `Account-flows-${Date.now()}.xcresult`)
  console.log(`Using an isolated account API at ${origin}.`)
  const child = spawn('caffeinate', ['-i', 'xcodebuild',
    '-project', join(project, 'Roomlings.xcodeproj'), '-scheme', 'Roomlings',
    '-destination', destination, '-derivedDataPath', join(project, 'Build', 'DerivedData'),
    '-resultBundlePath', result, '-only-testing:RoomlingsTests', '-only-testing:RoomlingsUITests/AccountUITests',
    ...(values['include-room'] ? ['-only-testing:RoomlingsUITests/RoomlingsUITests'] : []),
    '-parallel-testing-enabled', 'NO',
    ...(process.env.CI ? [
      '-destination-timeout', '60',
      '-test-timeouts-enabled', 'YES',
      '-default-test-execution-time-allowance', '300',
      '-maximum-test-execution-time-allowance', '360',
    ] : ['-quiet']),
    'test', `ROOMLINGS_TEST_API_ORIGIN=${origin}`,
    `NODE_BINARY=${process.execPath}`, `ROOMLINGS_WEB_ROOT=${web}`,
  ], { stdio: 'inherit' })
  const [code, signal] = await once(child, 'exit')
  if (code !== 0) {
    console.error(`Account device flows failed${signal ? ` (${signal})` : ''}. Results: ${result}`)
    process.exitCode = code ?? 1
  } else {
    const summary = JSON.parse(execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', result], { encoding: 'utf8' }))
    const expected = values['include-room'] ? 9 : 8
    if (summary.result !== 'Passed' || summary.passedTests < expected || summary.skippedTests !== 0) {
      throw new Error(`Account flows did not all execute. Results: ${result}`)
    }
  }
} finally {
  const closed = once(server, 'close')
  server.close()
  await closed
  await store.close()
}
