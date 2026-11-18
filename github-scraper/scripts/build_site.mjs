// Cloudflare Pages build for newnew.news (project "newnew-site", root github-scraper/site,
// build command `node ../scripts/build_site.mjs`). No network, no dependencies.
//  1. Writes site/outlets.json from feeds.json, so the outlet list is published with every push.
//  2. Stamps the pages' links to style.css and site.js with a fingerprint of each file
//     (?v=…): Cloudflare lets browsers keep those for 4 hours, so a changed file needs a new
//     address to reach visitors at once. Pages and outlets.json are revalidated on every visit.
import { readFile, writeFile, readdir } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { outletCatalog } from './outlets.mjs'

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const site = path.join(root, 'site')

const feeds = JSON.parse(await readFile(path.join(root, 'feeds.json'), 'utf8'))
const catalog = outletCatalog(feeds)
await writeFile(path.join(site, 'outlets.json'), JSON.stringify(catalog))
console.log(`outlets.json: ${catalog.outlets.length} outlets, ${feeds.length} feeds`)

const stamps = {}
for (const asset of ['style.css', 'site.js']) {
  stamps[asset] = createHash('sha256').update(await readFile(path.join(site, asset))).digest('hex').slice(0, 10)
}
for (const page of (await readdir(site)).filter(f => f.endsWith('.html'))) {
  const file = path.join(site, page)
  let html = await readFile(file, 'utf8')
  for (const [asset, stamp] of Object.entries(stamps)) html = html.replaceAll(`"/${asset}"`, `"/${asset}?v=${stamp}"`)
  await writeFile(file, html)
}
console.log(`stamped: ${Object.entries(stamps).map(([a, s]) => `${a}?v=${s}`).join(', ')}`)
