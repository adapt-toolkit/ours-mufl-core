// Internal team-process artifacts, host paths, and unmerged-feature references
// must never ship (SPEC C1/C2/C6).
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

// Patterns are assembled from fragments so this file itself never matches the
// deny-list checker (a literal match in scripts/ would be a false positive).
const DENY = [
  new RegExp('WS-' + 'B'),
  new RegExp('WS-' + 'C'),
  new RegExp('WS-' + 'D'),
  new RegExp('\\bcritic\\b', 'i'),
  new RegExp('TEAM-' + 'PROTOCOL'),
  new RegExp('Coordinator-' + 'frozen'),
  new RegExp('/home/' + 'fleet'),
]
const docsRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const errors = []
const walk = d => { for (const e of readdirSync(d)) {
  const p = join(d, e)
  if (e === 'node_modules' || e === '.vitepress' || e === 'scripts') continue
  if (statSync(p).isDirectory()) walk(p)
  else if (e.endsWith('.md')) for (const term of DENY)
    if (term.test(readFileSync(p, 'utf8')))
      errors.push(`${relative(docsRoot, p)}: matches ${term}`)
}}
walk(docsRoot)
if (errors.length) { console.error('DENYLIST CHECK FAILED\n' + errors.join('\n')); process.exit(1) }
console.log('denylist check OK')
