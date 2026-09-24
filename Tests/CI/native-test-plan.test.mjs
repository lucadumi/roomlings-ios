import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseShard, planNativeShard, requireCompleteShard } from '../../Scripts/native-test-plan.mjs'

const inventory = {
  errors: [],
  values: [{
    testPlan: 'Roomlings',
    disabledTests: [],
    enabledTests: [
      { identifier: 'RoomlingsTests/ModelTests/testAccount()' },
      { identifier: 'RoomlingsTests/ModelTests/testPrivacy()' },
      { identifier: 'RoomlingsUITests/AccountUITests/testC()' },
      { identifier: 'RoomlingsUITests/AccountUITests/testA()' },
      { identifier: 'RoomlingsUITests/AccountUITests/testB()' },
      { identifier: 'RoomlingsUITests/RoomlingsUITests/testRoom()' },
    ],
  }],
}

test('every compiled test belongs to exactly one shard, including models and room flows', () => {
  const first = planNativeShard(inventory, parseShard('1/2'))
  const second = planNativeShard(inventory, parseShard('2/2'))
  const tests = [...first.tests, ...second.tests]
  assert.equal(first.modelTests, 2)
  assert.equal(second.modelTests, 0)
  assert.equal(first.uiTests, 2)
  assert.equal(second.uiTests, 2)
  assert.equal(new Set(tests).size, tests.length)
  assert.deepEqual(tests.sort(), inventory.values[0].enabledTests.map(({ identifier }) => identifier.slice(0, -2)).sort())
  assert.deepEqual(first.tests, [
    'RoomlingsTests/ModelTests/testAccount', 'RoomlingsTests/ModelTests/testPrivacy',
    'RoomlingsUITests/AccountUITests/testA', 'RoomlingsUITests/AccountUITests/testC',
  ])
})

test('shards remain deterministic when enumeration order changes and when new tests are added', () => {
  const reordered = structuredClone(inventory)
  reordered.values[0].enabledTests.reverse()
  assert.deepEqual(planNativeShard(reordered, parseShard('1/2')), planNativeShard(inventory, parseShard('1/2')))
  reordered.values[0].enabledTests.push({ identifier: 'RoomlingsUITests/FutureTests/testNewFeature()' })
  const shards = [1, 2].map((index) => planNativeShard(reordered, parseShard(`${index}/2`)))
  assert.equal(shards[0].uiTests - shards[1].uiTests, 1)
  assert.equal(shards.flatMap((shard) => shard.tests).filter((id) => id.endsWith('/testNewFeature')).length, 1)
})

test('invalid shard specifications fail before execution', () => {
  for (const input of ['', '1', '0/2', '1/0', '3/2', '-1/2', '1.5/2', '01/2', '1/2 ', '1/999999999999999999999']) {
    assert.throws(() => parseShard(input), /shard/)
  }
  assert.deepEqual(parseShard('1/1'), { index: 1, count: 1 })
  assert.throws(() => planNativeShard(inventory, { index: 0, count: 2 }), /shard/)
  assert.throws(() => planNativeShard(inventory, { index: 3, count: 2 }), /shard/)
  assert.throws(() => planNativeShard(inventory, parseShard('1/5')), /Every shard needs UI coverage/)
})

test('enumeration errors, disabled tests and multiple plans cannot look like completed coverage', () => {
  for (const change of ['errors', 'missing-errors', 'plans', 'disabled', 'missing-enabled', 'duplicate', 'unknown', 'no-models', 'no-ui']) {
    const bad = structuredClone(inventory)
    switch (change) {
    case 'errors': bad.errors = ['Failed to enumerate']; break
    case 'missing-errors': delete bad.errors; break
    case 'plans': bad.values.push(structuredClone(bad.values[0])); break
    case 'disabled': bad.values[0].disabledTests.push(bad.values[0].enabledTests.pop()); break
    case 'missing-enabled': delete bad.values[0].enabledTests; break
    case 'duplicate': bad.values[0].enabledTests.push(bad.values[0].enabledTests[0]); break
    case 'unknown': bad.values[0].enabledTests[0].identifier = 'OtherTarget/testUnknown'; break
    case 'no-models': bad.values[0].enabledTests = bad.values[0].enabledTests.filter(({ identifier }) => identifier.startsWith('RoomlingsUITests/')); break
    case 'no-ui': bad.values[0].enabledTests = bad.values[0].enabledTests.filter(({ identifier }) => identifier.startsWith('RoomlingsTests/')); break
    }
    assert.throws(() => planNativeShard(bad, parseShard('1/2')), Error, change)
  }
})

test('a green summary must still contain every assigned test and no skips or unexpected extras', () => {
  const passed = { result: 'Passed', passedTests: 4, totalTestCount: 4, failedTests: 0, skippedTests: 0 }
  const expected = planNativeShard(inventory, parseShard('1/2')).tests
  const results = { testNodes: [{
    nodeType: 'Test Plan',
    children: expected.map((id) => ({
      nodeType: 'Test Case', nodeIdentifierURL: `test://com.apple.xcode/Roomlings/${id}`, result: 'Passed',
    })),
  }] }
  requireCompleteShard(passed, expected, results)
  for (const change of [
    { passedTests: 3 }, { passedTests: 5 }, { totalTestCount: 3 }, { totalTestCount: 5 },
    { failedTests: 1 }, { skippedTests: 1 }, { result: 'Failed' },
  ]) {
    assert.throws(() => requireCompleteShard({ ...passed, ...change }, expected, results), /exactly its 4 enumerated tests/)
  }
  const wrongTests = structuredClone(results)
  wrongTests.testNodes[0].children[0].nodeIdentifierURL = 'test://com.apple.xcode/Roomlings/RoomlingsTests/ModelTests/testUnassigned'
  assert.throws(() => requireCompleteShard(passed, expected, wrongTests), /exactly the test identifiers assigned/)
  const duplicate = structuredClone(results)
  duplicate.testNodes[0].children[0] = duplicate.testNodes[0].children[1]
  assert.throws(() => requireCompleteShard(passed, expected, duplicate), /exactly the test identifiers assigned/)
  assert.throws(() => requireCompleteShard(passed, expected, {}), /exactly the test identifiers assigned/)
})
