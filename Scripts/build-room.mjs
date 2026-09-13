import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { copyFile, mkdir, readFile, realpath, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { buildTheme } from './build-theme.mjs'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values } = parseArgs({ options: { 'web-root': { type: 'string' } } })
const requestedSource = values['web-root'] ?? process.env.ROOMLINGS_WEB_ROOT ?? '../roomlings'
const source = await realpath(resolve(project, requestedSource))
const requireWeb = createRequire(join(source, 'package.json'))
const output = join(project, 'Build', 'RoomRenderer')
await buildTheme({ source, project, requireWeb })
const { build } = await import(pathToFileURL(requireWeb.resolve('vite')).href)
const react = (await import(pathToFileURL(requireWeb.resolve('@vitejs/plugin-react')).href)).default
const revision = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const dirty = execFileSync('git', ['-C', source, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' }).trim() !== ''
const lockfile = await readFile(join(source, 'package-lock.json'))
const ts = requireWeb('typescript')
const typeRoot = dirname(dirname(requireWeb.resolve('@types/react/package.json')))
const program = ts.createProgram([
  join(project, 'RoomRenderer', 'main.tsx'),
  join(dirname(requireWeb.resolve('vite/package.json')), 'client.d.ts'),
], {
  noEmit: true,
  strict: true,
  skipLibCheck: true,
  target: ts.ScriptTarget.ES2023,
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler,
  jsx: ts.JsxEmit.ReactJSX,
  allowImportingTsExtensions: true,
  types: [],
  typeRoots: [typeRoot],
  paths: {
    '@roomlings-web/*': [`${source}/*`],
    react: [`${typeRoot}/react/index.d.ts`],
    'react/*': [`${typeRoot}/react/*`],
    'react-dom/*': [`${typeRoot}/react-dom/*`],
    zod: [dirname(requireWeb.resolve('zod/package.json'))],
  },
})
const diagnostics = ts.getPreEmitDiagnostics(program)
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
    getCanonicalFileName: (path) => path,
    getCurrentDirectory: () => project,
    getNewLine: () => '\n',
  }))
  throw new Error('The shared room could not be type-checked. Use a compatible Roomlings web checkout.')
}
const aliases = ['react', 'react-dom', 'zod'].map((name) => ({
  find: name,
  replacement: dirname(requireWeb.resolve(`${name}/package.json`)),
}))

await build({
  configFile: false,
  root: project,
  base: './',
  publicDir: false,
  plugins: [react()],
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  resolve: {
    alias: [
      { find: '@roomlings-web', replacement: source },
      ...aliases,
      ...['dm-sans', 'baloo-2'].map((font) => ({
        find: `@fontsource-variable/${font}/index.css`,
        replacement: requireWeb.resolve(`@fontsource-variable/${font}`),
      })),
    ],
    dedupe: ['react', 'react-dom', 'three', 'zod'],
  },
  build: {
    target: 'safari18',
    outDir: output,
    emptyOutDir: true,
    cssCodeSplit: false,
    sourcemap: false,
    lib: {
      entry: join(project, 'RoomRenderer', 'main.tsx'),
      name: 'RoomlingsRoomBundle',
      formats: ['iife'],
      fileName: () => 'room.js',
      cssFileName: 'room',
    },
  },
  logLevel: 'warn',
})
await mkdir(output, { recursive: true })
await copyFile(join(project, 'RoomRenderer', 'index.html'), join(output, 'index.html'))
await writeFile(join(output, 'source.json'), JSON.stringify({
  bridgeVersion: 1,
  webRevision: revision,
  webWorkingTreeDirty: dirty,
  webDependencyLockSHA256: createHash('sha256').update(lockfile).digest('hex'),
}, null, 2) + '\n')
console.log(`Bundled the shared kitchen from ${revision.slice(0, 7)}${dirty ? ' with local source changes' : ''}.`)
