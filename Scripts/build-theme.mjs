import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export async function buildTheme({ source, project, requireWeb }) {
  const postcss = requireWeb('postcss')
  const css = postcss.parse(await readFile(join(source, 'src/style.css'), 'utf8'))
  const properties = new Map()
  css.walkRules(':root', (rule) => rule.walkDecls((declaration) => properties.set(declaration.prop, declaration.value)))
  const resolve = (name, visited = new Set()) => {
    if (visited.has(name)) throw new Error(`Circular shared theme property: ${name}`)
    const value = properties.get(name)
    if (!value) throw new Error(`Missing shared theme property: ${name}`)
    const reference = /^var\((--[\w-]+)\)$/.exec(value)
    return reference ? resolve(reference[1], new Set([...visited, name])) : value
  }
  const names = {
    paper: '--paper', ink: '--ink', muted: '--muted', sage: '--sage',
    surface: '--control-surface', border: '--control-border', hover: '--control-hover',
    fieldSurface: '--field-surface', fieldBorder: '--field-border',
    primary: '--action-fill', primaryPressed: '--action-hover', primaryInk: '--action-ink',
    primaryBorder: '--action-border', primaryShadow: '--action-shadow',
    error: '--tomato-ink', errorSoft: '--tomato-soft', errorBorder: '--tomato-border',
    leaf: '--leaf-ink', leafSoft: '--leaf-soft',
    sky: '--sky-ink', skySoft: '--sky-soft', surfaceMuted: '--surface-muted',
  }
  const values = Object.entries(names).map(([name, property]) => {
    const color = resolve(property)
    if (!/^#[\da-f]{6}$/i.test(color)) throw new Error(`Unsupported shared theme colour: ${property}`)
    return `    static let ${name}: UInt32 = 0x${color.slice(1)}`
  })
  const radius = /^([\d.]+)rem$/.exec(resolve('--control-radius'))
  if (!radius) throw new Error('The shared control radius must use rem.')
  values.push(`    static let radius: Double = ${Number(radius[1]) * 16}`)
  const directory = process.env.DERIVED_FILE_DIR ?? join(project, 'Build', 'Generated')
  await mkdir(directory, { recursive: true })
  await writeFile(join(directory, 'WebThemeValues.swift'),
    `// Generated from the web theme by Scripts/build-theme.mjs.\nenum WebThemeValues {\n${values.join('\n')}\n}\n`)
}
