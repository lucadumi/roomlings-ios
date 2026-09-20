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
const { values } = parseArgs({ options: {
  destination: { type: 'string' }, 'include-room': { type: 'boolean' }, 'chores-only': { type: 'boolean' },
  'ui-test': { type: 'string', multiple: true },
} })
const selectedFlows = values['ui-test'] ? [...new Set(values['ui-test'])] : null
if (selectedFlows?.some((flow) => !/^[A-Za-z_]\w*\/test\w+$/.test(flow))) {
  throw new Error('Use --ui-test TestClass/testMethod for each native UI flow.')
}
const { createApp } = await import(pathToFileURL(join(web, 'server/app.ts')).href)
const { Store } = await import(pathToFileURL(join(web, 'server/store.ts')).href)
const { ApiError } = await import(pathToFileURL(join(web, 'server/errors.ts')).href)
const { getRoomComponents, componentChoreArea } = await import(pathToFileURL(join(web, 'shared/roomComponents.ts')).href)
const { balances, billingDate, choreSchema } = await import(pathToFileURL(join(web, 'shared/domain.ts')).href)
const { accountEmailSchema } = await import(pathToFileURL(join(web, 'shared/accounts.ts')).href)
const express = requireWeb('express')
const { z } = requireWeb('zod')
const store = new Store(':memory:')
const identities = new Map()
const pendingCodes = new Set()
let failDelivery = false
let choreFailure = null
const choreRequests = []
let shoppingFailure = null
const shoppingRequests = []
const shoppingActors = new Map()
let ledgerFailure = null
const ledgerRequests = []
let invitationFailure = null
const invitationRequests = []
const invitationCodes = new Map()
const invitationBrowsers = new Map()
let nextAccountLoad = null
let activeAccountLoad = null
function releaseAccountLoad() {
  nextAccountLoad?.release()
  activeAccountLoad?.release()
  nextAccountLoad = null
}
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
const app = express()
app.use('/api/account', async (request, response, next) => {
  if (request.method !== 'GET' || request.path !== '/' || !nextAccountLoad) { next(); return }
  const load = nextAccountLoad
  nextAccountLoad = null
  activeAccountLoad = load
  await load.wait
  activeAccountLoad = null
  if (load.fail) { response.status(503).json({ error: 'Test account load unavailable' }); return }
  next()
})
function observeMutations(path, requests, consumeFailure) {
  app.use(path, express.json(), (request, response, next) => {
    if (!['POST', 'PATCH', 'DELETE'].includes(request.method)) { next(); return }
    requests.push({
      path: request.originalUrl, method: request.method, version: request.body.version, itemVersion: request.body.itemVersion,
      mutationId: request.body.mutationId, mutationVersion: request.body.mutationVersion,
      native: request.get('X-Roomlings-Client') === 'ios',
      browserHeaders: ['origin', 'cookie', 'x-csrf-token', 'sec-fetch-site'].some((name) => request.get(name) !== undefined),
    })
    const failure = consumeFailure()
    if (failure === 'unavailable') {
      response.status(503).json({ error: 'Test household save unavailable' })
      return
    }
    if (failure === 'lost-response') {
      const sendJSON = response.json
      response.json = function (body) {
        if (this.statusCode >= 200 && this.statusCode < 300) {
          this.destroy()
          return this
        }
        return sendJSON.call(this, body)
      }
    }
    next()
  })
}
observeMutations('/api/chores', choreRequests, () => {
  const failure = choreFailure
  choreFailure = null
  return failure
})
observeMutations('/api/shopping/items', shoppingRequests, () => {
  const failure = shoppingFailure
  shoppingFailure = null
  return failure
})
observeMutations('/api/shopping/checkout', ledgerRequests, () => {
  const failure = ledgerFailure
  ledgerFailure = null
  return failure
})
observeMutations('/api/expenses', ledgerRequests, () => {
  const failure = ledgerFailure
  ledgerFailure = null
  return failure
})
const invitationRoute = /^\/api\/account\/households\/[^/]+\/invitations(?:\/[^/]+)?$/
app.use(invitationRoute, (request, response, next) => {
  if (request.method === 'POST') {
    const sendJSON = response.json
    response.json = function (body) {
      if (this.statusCode === 201 && typeof body.code === 'string' && body.invitation?.id) {
        invitationCodes.set(body.invitation.id, body.code)
      }
      return sendJSON.call(this, body)
    }
  }
  next()
})
observeMutations(invitationRoute, invitationRequests, () => {
  const failure = invitationFailure
  invitationFailure = null
  return failure
})
app.use(createApp(store, { provider, appOrigin: 'http://localhost:5173' }))
app.get('/_fixture', (_request, response) => response.json({ roomlingsTest: true }))
app.post('/_fixture/loading', express.json(), (request, response) => {
  const input = z.object({ hold: z.boolean(), fail: z.boolean().default(false) }).parse(request.body)
  if (input.hold) {
    if (nextAccountLoad || activeAccountLoad) throw new Error('A fixture account load is already held.')
    let release
    const wait = new Promise((resolve) => { release = resolve })
    nextAccountLoad = { wait, release, fail: input.fail }
  } else {
    releaseAccountLoad()
  }
  response.json({ configured: true })
})
app.post('/_fixture/seed', express.json(), async (request, response) => {
  const email = accountEmailSchema.parse(request.body.email)
  releaseAccountLoad()
  failDelivery = false
  choreFailure = null
  choreRequests.length = 0
  shoppingFailure = null
  shoppingRequests.length = 0
  ledgerFailure = null
  ledgerRequests.length = 0
  invitationFailure = null
  invitationRequests.length = 0
  invitationCodes.clear()
  invitationBrowsers.clear()
  const issued = await store.accounts.signIn(identity(email), 'Ada', 'Fixture setup')
  const homes = []
  let invitation
  for (const [name, style, kettle, timeZone] of [
    ['Cedar House', 'clay', false, 'us/eastern'], ['Willow House', 'coastal', true, '+01:00'],
  ]) {
    const state = await store.accounts.createHousehold(issued.session, {
      name, memberName: 'Ada', currency: 'EUR', budget: 25000,
    })
    const household = state.session.household
    household.roomStyle = style
    household.billingTimeZone = timeZone
    household.roomComponents = getRoomComponents(household).map((component) =>
      !kettle && component.slotId === 'kitchen-kettle' ? { ...component, installed: false } : component)
    const fridge = household.roomComponents.find((component) => component.slotId === 'kitchen-fridge')
    if (!fridge) throw new Error('The chore fixture needs the saved fridge.')
    const now = new Date().toISOString()
    const chore = {
      title: 'Wipe the fridge shelves', notes: 'Use the gentle cleaner.',
      roomId: 'kitchen', area: componentChoreArea(fridge), componentId: fridge.id, componentName: fridge.name,
      dueDate: billingDate(household.billingTimeZone), repeatDays: 7,
      rotation: [state.session.memberId], turn: 0, createdBy: state.session.memberId,
      createdAt: now, updatedAt: now, version: 0, occurrence: 0, archived: false,
    }
    household.chores.items.push(choreSchema.parse({ ...chore, id: randomUUID() }))
    if (!kettle) {
      const object = household.roomComponents.find((component) => component.slotId === 'kitchen-kettle')
      if (!object) throw new Error('The chore fixture needs the saved kettle.')
      household.chores.items.push(choreSchema.parse({
        ...chore, id: randomUUID(), title: 'Clean the stored kettle', componentId: object.id,
        componentName: object.name, area: componentChoreArea(object),
      }))
    }
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
async function asInvitationOwner(email, operation) {
  const issued = await store.accounts.signIn(identity(email), 'Ada', 'Invitation fixture')
  try {
    return await operation(issued.session)
  } finally {
    await store.accounts.logout(issued.session, false)
  }
}
app.post('/_fixture/invitations/state', express.json(), async (request, response) => {
  const input = z.object({ email: accountEmailSchema, householdId: z.string().uuid() }).parse(request.body)
  const access = await asInvitationOwner(input.email, (session) => store.accounts.access(session, input.householdId))
  response.json({
    version: access.household.version,
    invitations: access.invitations.map((invitation) => ({ ...invitation, code: invitationCodes.get(invitation.id) })),
    requests: invitationRequests.filter((entry) => entry.path.startsWith(`/api/account/households/${input.householdId}/invitations`)),
  })
})
app.post('/_fixture/invitations/failure', express.json(), (request, response) => {
  invitationFailure = z.enum(['unavailable', 'lost-response']).parse(request.body.mode)
  response.json({ configured: true })
})
async function browserInvitationRequest(path, body, browser) {
  const result = await fetch(`http://127.0.0.1:${server.address().port}/api/account${path}`, {
    method: body ? 'POST' : 'GET',
    headers: {
      Origin: 'http://localhost:5173', 'X-Roomlings-Request': '1',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(browser ? { Cookie: browser.cookie, 'X-CSRF-Token': browser.csrfToken } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  if (!result.ok) throw new Error(`Browser invitation fixture request failed (${result.status}).`)
  return { result, state: await result.json() }
}
app.post('/_fixture/invitations/browser-accept', express.json(), async (request, response) => {
  const input = z.object({ email: accountEmailSchema, invitation: z.string() }).parse(request.body)
  await browserInvitationRequest('/code', { email: input.email })
  const { result, state } = await browserInvitationRequest('/verify', {
    email: input.email, code: '123456', name: 'Sam', label: 'Web invitation fixture',
  })
  const cookie = result.headers.getSetCookie().find((entry) => entry.startsWith('roomlings_session='))?.split(';')[0]
  if (!cookie || !state.csrfToken || state.accessToken !== undefined) throw new Error('The browser fixture did not receive browser-only access.')
  const browser = { cookie, csrfToken: state.csrfToken }
  const joined = await browserInvitationRequest('/invitations/accept', { code: input.invitation, memberName: 'Sam' }, browser)
  if (!joined.state.session) throw new Error('The browser fixture did not join a household.')
  invitationBrowsers.set(input.email, browser)
  response.json({ householdId: joined.state.session.household.id })
})
app.post('/_fixture/invitations/browser-state', express.json(), async (request, response) => {
  const input = z.object({ email: accountEmailSchema }).parse(request.body)
  const browser = invitationBrowsers.get(input.email)
  if (!browser) throw new Error('The invitation browser fixture is missing.')
  const { state } = await browserInvitationRequest('', undefined, browser)
  response.json({ signedIn: state.account !== null, householdId: state.session?.household.id })
})
app.post('/_fixture/chores/failure', express.json(), (request, response) => {
  choreFailure = z.enum(['unavailable', 'lost-response']).parse(request.body.mode)
  response.json({ configured: true })
})
app.post('/_fixture/chores/change', express.json(), async (request, response) => {
  const id = z.string().uuid().parse(request.body.householdId)
  await store.transaction(async () => {
    const household = await store.get(id)
    if (!household) throw new Error('The chore fixture household is missing.')
    household.version++
    await store.save(household)
  })
  response.json({ changed: true })
})
app.post('/_fixture/chores/state', express.json(), async (request, response) => {
  const id = z.string().uuid().parse(request.body.householdId)
  const household = await store.get(id)
  if (!household) throw new Error('The chore fixture household is missing.')
  response.json({ version: household.version, ...household.chores, requests: choreRequests })
})
async function shoppingRequest(householdId, path, fields, method = 'POST') {
  const actor = shoppingActors.get(householdId)
  const household = await store.get(householdId)
  if (!actor || !household) throw new Error('The shopping fixture household or roommate is missing.')
  const result = await fetch(`http://127.0.0.1:${server.address().port}/api/${path}`, {
    method,
    headers: { 'X-Roomlings-Client': 'ios', Authorization: `Bearer ${actor.token}`, 'Content-Type': 'application/json' },
    ...(method === 'GET' ? {} : { body: JSON.stringify({
      ...fields, version: household.version, mutationVersion: household.version, mutationId: randomUUID(),
    }) }),
  })
  if (!result.ok) throw new Error(`Shopping fixture request failed (${result.status}).`)
  return result.json()
}
app.post('/_fixture/shopping/seed', express.json(), async (request, response) => {
  const input = z.object({ householdId: z.string().uuid(), invitation: z.string() }).parse(request.body)
  const issued = await store.accounts.signIn(identity(`shopper-${input.householdId}@example.test`), 'Sam', 'Shopping fixture')
  const joined = await store.accounts.accept(issued.session, input.invitation, 'Sam')
  if (joined.session?.household.id !== input.householdId) throw new Error('The fixture invitation selected a different household.')
  shoppingActors.set(input.householdId, { token: issued.token, memberID: joined.session.memberId })
  const fridge = getRoomComponents(joined.session.household).find((component) => component.slotId === 'kitchen-fridge')
  const supply = fridge?.supplies[0]
  if (!fridge || !supply) throw new Error('The shopping fixture needs a configured fridge supply.')
  await shoppingRequest(input.householdId, 'shopping/items', {
    name: 'Milk', quantity: '2 cartons', notes: 'Unsweetened',
    componentSource: { componentId: fridge.id, supplyId: supply.id },
  })
  const added = await shoppingRequest(input.householdId, 'shopping/items', { name: 'Oats', quantity: '1 bag', notes: '' })
  const item = added.household.shopping.items.find((item) => item.name === 'Oats')
  if (!item) throw new Error('The shopping fixture item was not added.')
  await shoppingRequest(input.householdId, `shopping/items/${item.id}/claim`, { itemVersion: item.version, claimed: true })
  shoppingRequests.length = 0
  response.json({ memberID: joined.session.memberId })
})
app.post('/_fixture/shopping/failure', express.json(), (request, response) => {
  shoppingFailure = z.enum(['unavailable', 'lost-response']).parse(request.body.mode)
  response.json({ configured: true })
})
app.post('/_fixture/shopping/remote', express.json(), async (request, response) => {
  const input = z.object({
    householdId: z.string().uuid(), action: z.enum(['read', 'add', 'edit', 'claim', 'release', 'pick']), itemId: z.string().uuid().optional(),
  }).parse(request.body)
  if (input.action === 'read') {
    const state = await shoppingRequest(input.householdId, 'account', undefined, 'GET')
    if (state.session?.household.id !== input.householdId) throw new Error('The shopping roommate selected a different household.')
    response.json(state.session.household.shopping)
    return
  }
  if (input.action === 'add') {
    await shoppingRequest(input.householdId, 'shopping/items', { name: 'Bread', quantity: '1 loaf', notes: 'Added on another device' })
  } else {
    const household = await store.get(input.householdId)
    const item = household?.shopping.items.find((item) => item.id === input.itemId)
    if (!item) throw new Error('The shopping fixture item is missing.')
    if (input.action === 'edit') {
      await shoppingRequest(input.householdId, `shopping/items/${item.id}`,
        { itemVersion: item.version, name: item.name, quantity: '3 cartons', notes: 'Changed on another device' }, 'PATCH')
    } else {
      const picking = input.action === 'pick'
      await shoppingRequest(input.householdId, `shopping/items/${item.id}/${picking ? 'pick' : 'claim'}`,
        { itemVersion: item.version, ...(picking ? { pickedUp: true } : { claimed: input.action === 'claim' }) })
    }
  }
  response.json({ changed: true })
})
app.post('/_fixture/shopping/state', express.json(), async (request, response) => {
  const id = z.string().uuid().parse(request.body.householdId)
  const household = await store.get(id)
  if (!household) throw new Error('The shopping fixture household is missing.')
  response.json({
    version: household.version, items: household.shopping.items, requests: shoppingRequests,
    ledger: JSON.stringify({ budget: household.budget, expenses: household.expenses, settlements: household.settlements, runs: household.shopping.runs }),
  })
})
app.post('/_fixture/ledger/failure', express.json(), (request, response) => {
  ledgerFailure = z.enum(['unavailable', 'lost-response']).parse(request.body.mode)
  response.json({ configured: true })
})
app.post('/_fixture/ledger/remote', express.json(), async (request, response) => {
  const id = z.string().uuid().parse(request.body.householdId)
  const actor = shoppingActors.get(id)
  const household = await store.get(id)
  if (!actor || !household) throw new Error('The ledger fixture household or roommate is missing.')
  await shoppingRequest(id, 'expenses', {
    description: 'Recorded on another device', amount: 1_250, paidBy: actor.memberID,
    participants: [actor.memberID], category: 'other', date: billingDate(household.billingTimeZone),
  })
  response.json({ changed: true })
})
app.post('/_fixture/ledger/state', express.json(), async (request, response) => {
  const id = z.string().uuid().parse(request.body.householdId)
  const household = await store.get(id)
  if (!household) throw new Error('The ledger fixture household is missing.')
  response.json({
    version: household.version, expenses: household.expenses, runs: household.shopping.runs,
    items: household.shopping.items, settlements: household.settlements, requests: ledgerRequests,
    balances: Object.fromEntries(balances(household)),
  })
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
  const flows = selectedFlows ? selectedFlows.map((flow) => `RoomlingsUITests/${flow}`) : values['chores-only'] ? [
    'RoomlingsUITests/AccountUITests/testChoreControlsCanReturnToSystemStyling',
    'RoomlingsUITests/AccountUITests/testStyledControlsKeepBindingsAndDisabledStates',
    'RoomlingsUITests/AccountUITests/testChoresCreateAndCompleteInTheSharedHousehold',
    'RoomlingsUITests/AccountUITests/testChoresKeepFailedDraftsAndRequireConflictReview',
    'RoomlingsUITests/AccountUITests/testChoresRetryLostResponsesWithoutDuplicatingTheSave',
  ] : ['RoomlingsUITests/AccountUITests']
  const child = spawn('caffeinate', ['-i', 'xcodebuild',
    '-project', join(project, 'Roomlings.xcodeproj'), '-scheme', 'Roomlings',
    '-destination', destination, '-derivedDataPath', join(project, 'Build', 'DerivedData'),
    '-resultBundlePath', result, '-only-testing:RoomlingsTests', ...flows.map((flow) => `-only-testing:${flow}`),
    ...(values['include-room'] ? ['-only-testing:RoomlingsUITests/RoomlingsUITests'] : []),
    '-parallel-testing-enabled', 'NO',
    ...(process.env.CI ? [
      '-destination-timeout', '60',
      '-test-timeouts-enabled', 'YES',
      '-default-test-execution-time-allowance', '300',
      '-maximum-test-execution-time-allowance', '600',
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
    const expected = 49 + (selectedFlows ? selectedFlows.length : values['chores-only'] ? 5 : 24)
      + (values['include-room'] ? 2 : 0)
    if (summary.result !== 'Passed' || summary.passedTests < expected || summary.skippedTests !== 0) {
      throw new Error(`Account flows did not all execute. Results: ${result}`)
    }
  }
} finally {
  releaseAccountLoad()
  const closed = once(server, 'close')
  server.close()
  await closed
  await store.close()
}
