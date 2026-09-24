export function parseShard(value) {
  const match = /^([1-9]\d*)\/([1-9]\d*)$/.exec(value ?? '')
  if (!match) throw new Error('Use --shard INDEX/COUNT, for example --shard 1/2.')
  const index = Number(match[1])
  const count = Number(match[2])
  if (!Number.isSafeInteger(index) || !Number.isSafeInteger(count) || index > count) {
    throw new Error('The shard index must be between 1 and its shard count.')
  }
  return { index, count }
}

export function planNativeShard(enumeration, shard) {
  shard = parseShard(`${shard?.index}/${shard?.count}`)
  if (!Array.isArray(enumeration?.errors) || enumeration.errors.length
      || !Array.isArray(enumeration.values) || enumeration.values.length !== 1) {
    throw new Error('Native sharding requires a successful Xcode enumeration with exactly one test plan.')
  }
  const plan = enumeration.values[0]
  if (!Array.isArray(plan.enabledTests) || !Array.isArray(plan.disabledTests) || plan.disabledTests.length) {
    throw new Error('Native CI must enumerate every test as enabled; disabled or missing test lists cannot be sharded.')
  }
  const tests = plan.enabledTests.map((test) => {
    if (typeof test?.identifier !== 'string'
        || !/^(RoomlingsTests|RoomlingsUITests)\/[A-Za-z_]\w*\/test\w+\(\)$/.test(test.identifier)) {
      throw new Error('Xcode returned an unsupported native test identifier. Review the enumeration before sharding.')
    }
    return test.identifier.slice(0, -2)
  }).sort()
  if (new Set(tests).size !== tests.length) throw new Error('Xcode enumerated duplicate native tests.')
  const models = tests.filter((test) => test.startsWith('RoomlingsTests/'))
  const ui = tests.filter((test) => test.startsWith('RoomlingsUITests/'))
  if (!models.length || !ui.length || shard.count > ui.length) {
    throw new Error('Every shard needs UI coverage, and the native model suite must not be empty.')
  }
  const selectedUI = ui.filter((_, index) => index % shard.count === shard.index - 1)
  const selectedModels = shard.index === 1 ? models : []
  return {
    testPlan: plan.testPlan,
    shard: `${shard.index}/${shard.count}`,
    totalModelTests: models.length,
    totalUITests: ui.length,
    modelTests: selectedModels.length,
    uiTests: selectedUI.length,
    tests: [...selectedModels, ...selectedUI],
  }
}

export function requireCompleteShard(summary, expected, results) {
  if (summary.result !== 'Passed' || summary.passedTests !== expected.length || summary.totalTestCount !== expected.length
      || summary.failedTests !== 0 || summary.skippedTests !== 0) {
    throw new Error(`The native shard must pass exactly its ${expected.length} enumerated tests with no failures or skips.`)
  }
  const executed = []
  const visit = (node) => {
    if (node.nodeType === 'Test Case') {
      const match = /^test:\/\/com\.apple\.xcode\/[^/]+\/((?:RoomlingsTests|RoomlingsUITests)\/[A-Za-z_]\w*\/test\w+)$/
        .exec(node.nodeIdentifierURL ?? '')
      if (!match || node.result !== 'Passed') throw new Error('The result bundle contains an unconfirmed or unsupported test result.')
      executed.push(match[1])
      return
    }
    for (const child of node.children ?? []) visit(child)
  }
  for (const node of results?.testNodes ?? []) visit(node)
  const actual = executed.sort()
  const assigned = [...expected].sort()
  if (new Set(actual).size !== actual.length || JSON.stringify(actual) !== JSON.stringify(assigned)) {
    throw new Error('The native shard did not execute exactly the test identifiers assigned by Xcode enumeration.')
  }
}
