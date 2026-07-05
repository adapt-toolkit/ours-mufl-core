// Emits llms.txt (annotated index) and llms-full.txt (all pages concatenated)
// into .vitepress/dist after a build. Order follows the sidebar sections.
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const docsRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const dist = join(docsRoot, '.vitepress/dist')
const SITE = 'https://adapt-toolkit.github.io/ours-mufl-core'
const ORDER = ['index.md',
  ...['overview','identity','invites-and-contacts','messaging','capabilities-and-control',
      'cluster','monitoring-and-config','versioning'].map(p => `how-it-works/${p}.md`),
  ...['index','contact-exchange','messaging','contact-restore','monitoring',
      'control-verbs','introductions','cluster'].map(p => `workflows/${p}.md`),
  ...['index','01-vendor-the-core','02-configure-and-compile','03-wire-the-host',
      '04-connect-and-message','05-test-your-app'].map(p => `guide/${p}.md`),
  ...['modules','implementations','glossary','contributing'].map(p => `reference/${p}.md`)]

let index = `# ours-mufl-core — agent docs index\n\n`
let full = ''
for (const rel of ORDER) {
  const p = join(docsRoot, rel)
  if (!existsSync(p)) continue
  const body = readFileSync(p, 'utf8')
  const title = (body.match(/^#\s+(.+)$/m) ?? [,rel])[1]
  const url = `${SITE}/${rel.replace(/index\.md$/, '').replace(/\.md$/, '')}`
  index += `- [${title}](${url})\n`
  full += `\n\n----- ${rel} -----\n\n${body}`
}
writeFileSync(join(dist, 'llms.txt'), index)
writeFileSync(join(dist, 'llms-full.txt'), full.trimStart())
console.log('llms.txt + llms-full.txt written')
