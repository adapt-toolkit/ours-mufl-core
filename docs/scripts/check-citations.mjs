// Validates docs/citations.json: every cited file exists in the repo,
// every cited symbol greps in that file, every cited page exists,
// and every non-stub content page has at least one citation entry.
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const docsRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = join(docsRoot, '..')
const manifest = JSON.parse(readFileSync(join(docsRoot, 'citations.json'), 'utf8'))
const errors = []

for (const [page, cites] of Object.entries(manifest)) {
  if (!existsSync(join(docsRoot, page))) errors.push(`cited page missing: ${page}`)
  for (const { file, symbol } of cites) {
    const target = join(repoRoot, file)
    if (!existsSync(target)) { errors.push(`${page}: cited file missing: ${file}`); continue }
    if (symbol && !readFileSync(target, 'utf8').includes(symbol))
      errors.push(`${page}: symbol "${symbol}" not found in ${file}`)
  }
}

// coverage: every how-it-works/ page that is no longer a stub must be in the manifest
const stubMarker = '*(content lands in Tasks'
for (const f of readdirSync(join(docsRoot, 'how-it-works'))) {
  if (!f.endsWith('.md')) continue
  const rel = `how-it-works/${f}`
  const body = readFileSync(join(docsRoot, rel), 'utf8')
  if (!body.includes(stubMarker) && !(rel in manifest))
    errors.push(`content page has no citations registered: ${rel}`)
}

if (errors.length) { console.error('CITATION CHECK FAILED\n' + errors.join('\n')); process.exit(1) }
console.log('citation check OK:', Object.keys(manifest).length, 'pages')
