// Cloudflare Pages build for newnew.news (project "newnew-site", root github-scraper/site,
// build command `node ../scripts/build_site.mjs`): writes site/outlets.json from feeds.json,
// so the outlet list is published with every push. No network, no dependencies.
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { outletCatalog } from './outlets.mjs'

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const feeds = JSON.parse(await readFile(path.join(root, 'feeds.json'), 'utf8'))
const catalog = outletCatalog(feeds)
await writeFile(path.join(root, 'site', 'outlets.json'), JSON.stringify(catalog))
console.log(`outlets.json: ${catalog.outlets.length} outlets, ${feeds.length} feeds`)
