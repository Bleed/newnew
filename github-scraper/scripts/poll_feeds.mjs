// Polls the curated RSS feeds in feeds.json and writes one static file, public/latest_news.json,
// that the Newnew app downloads. Runs every 30 minutes in GitHub Actions; costs nothing.
//
// What goes out per article: headline, a short snippet (≤ 280 characters), outlet, link, picture,
// time, category and, for local-news feeds, the country. Never the article body: the app links
// out to the publisher.
//
// Pictures come from a waterfall:
//   1. The feed itself: <media:content>, <media:thumbnail>, <enclosure>, or an <img> in the item.
//   2. The article page's first 25 KB (an HTTP Range request), read for og:image / twitter:image.
//   3. Left empty: the app asks the page itself from the phone (LinkPresentation), which works
//      for publishers that block data-centre IPs.
//
//   node scripts/poll_feeds.mjs                 writes public/latest_news.json
//   PREVIOUS_FEED_URL=https://… node …          reuses pictures already found in the last run

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import Parser from 'rss-parser'
import * as cheerio from 'cheerio'
import { findStories, selectNew, cloudKitConfig, sendToCloudKit } from './alerts.mjs'

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const OUT_DIR = path.resolve(process.env.OUT_DIR ?? path.join(root, 'public'))
const OUT_FILE = path.join(OUT_DIR, 'latest_news.json')

const USER_AGENT = 'NewnewBot/1.0 (headline aggregator; links to publishers)'
const MAX_AGE_HOURS = 48
const PER_FEED = 30
const TOTAL = 1200
const SNIPPET_LENGTH = 280
const FEED_TIMEOUT = 15_000
const PAGE_TIMEOUT = 6_000
const PAGE_BYTES = 25_000
/// Tier 2 is the slow part; keep each run well inside its schedule.
const MAX_PAGE_FETCHES = 400

const parser = new Parser({
  customFields: {
    item: [
      ['media:content', 'mediaContent', { keepArray: true }],
      ['media:thumbnail', 'mediaThumbnail', { keepArray: true }],
      ['media:group', 'mediaGroup'],
      ['content:encoded', 'contentEncoded'],
      ['dc:date', 'dcDate'],
    ],
  },
})

// MARK: Fetching

async function fetchWithTimeout(url, { timeout, headers = {} }) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeout)
  try {
    return await fetch(url, {
      headers: { 'User-Agent': USER_AGENT, ...headers },
      redirect: 'follow',
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timer)
  }
}

/** Runs `work` over `items`, at most `limit` at a time. */
async function pool(items, limit, work) {
  const results = new Array(items.length)
  let next = 0
  async function worker() {
    while (next < items.length) {
      const index = next++
      results[index] = await work(items[index], index)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return results
}

async function pollFeed(feed) {
  const started = Date.now()
  try {
    const response = await fetchWithTimeout(feed.url, { timeout: FEED_TIMEOUT, headers: { Accept: 'application/rss+xml, application/xml, text/xml, */*' } })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const parsed = await parser.parseString(await response.text())
    const cutoff = Date.now() - MAX_AGE_HOURS * 3600_000
    const articles = []
    for (const item of parsed.items ?? []) {
      const article = toArticle(item, feed)
      if (article && Date.parse(article.publishedAt) >= cutoff) articles.push(article)
      if (articles.length >= PER_FEED) break
    }
    return { feed, articles, ms: Date.now() - started }
  } catch (error) {
    return { feed, articles: [], error: String(error.message ?? error), ms: Date.now() - started }
  }
}

// MARK: Items

function toArticle(item, feed) {
  const title = clean(item.title)
  const url = canonicalURL(item.link ?? item.guid)
  const date = Date.parse(item.isoDate ?? item.pubDate ?? item.dcDate ?? '')
  if (!title || !url || Number.isNaN(date)) return null
  const body = item.contentSnippet || item.summary || item.content || item.contentEncoded || ''
  return {
    title,
    snippet: truncate(clean(body), SNIPPET_LENGTH),
    outlet: feed.outlet,
    url,
    imageURL: feedImage(item, url),
    // Never in the future: some feeds stamp tomorrow's print date.
    publishedAt: new Date(Math.min(date, Date.now())).toISOString(),
    category: feed.category ?? null,
    // Only on local-news feeds (The Local Norway → "NO"): the app's Local region.
    country: feed.country ?? null,
  }
}

/** Plain text: tags and entities gone, whitespace collapsed. */
function clean(text) {
  if (!text) return ''
  const plain = /[<&]/.test(text) ? cheerio.load(`<div>${text}</div>`)('div').text() : text
  return plain.replace(/\s+/g, ' ').trim()
}

function truncate(text, length) {
  if (text.length <= length) return text
  const cut = text.slice(0, length)
  return cut.slice(0, Math.max(cut.lastIndexOf(' '), length * 0.6)).replace(/[\s,.;:–-]+$/, '') + '…'
}

const TRACKING = /^(utm_|fbclid$|gclid$|mc_|cmpid$|at_|ns_|ocid$|smid$|partner$|traffic_source$)/

function canonicalURL(raw) {
  if (typeof raw !== 'string') return null
  try {
    const url = new URL(raw.trim())
    if (!/^https?:$/.test(url.protocol)) return null
    for (const key of [...url.searchParams.keys()]) if (TRACKING.test(key)) url.searchParams.delete(key)
    url.hash = ''
    return url.toString()
  } catch {
    return null
  }
}

// MARK: Pictures

/** Tier 1: the largest picture the feed offers. */
function feedImage(item, articleURL) {
  const candidates = []
  const add = (url, width = 0, type = '', medium = '') => {
    if (!url || (type && !type.startsWith('image')) || (medium && medium !== 'image')) return
    candidates.push({ url, width: Number(width) || 0 })
  }
  for (const media of [...(item.mediaContent ?? []), ...(item.mediaGroup?.['media:content'] ?? [])]) {
    const a = media?.$ ?? {}
    add(a.url, a.width, a.type, a.medium)
  }
  for (const thumb of [...(item.mediaThumbnail ?? []), ...(item.mediaGroup?.['media:thumbnail'] ?? [])]) {
    const a = thumb?.$ ?? {}
    add(a.url, a.width)
  }
  if (item.enclosure?.url) add(item.enclosure.url, 0, item.enclosure.type ?? 'image')
  if (!candidates.length) {
    const html = item.contentEncoded ?? item.content ?? ''
    const src = /<img[^>]+src=["']([^"']+)["']/i.exec(html)?.[1]
    if (src) add(src)
  }
  const best = candidates.sort((a, b) => b.width - a.width)[0]
  return best ? upgrade(absolute(best.url, articleURL)) : null
}

/** Feeds often carry a small thumbnail where a larger rendition exists at a known address. */
function upgrade(url) {
  if (!url) return url
  // BBC: ichef.bbci.co.uk/ace/standard/240/… → 976 wide.
  if (url.includes('ichef.bbci.co.uk')) return url.replace(/\/(standard|branded_news|news)\/\d{2,4}\//, '/$1/976/')
  return url
}

function absolute(url, base) {
  try {
    return new URL(url, base).toString()
  } catch {
    return null
  }
}

/** Tier 2: og:image from the first 25 KB of the page; the rest is never downloaded. */
async function pageImage(articleURL) {
  try {
    const response = await fetchWithTimeout(articleURL, {
      timeout: PAGE_TIMEOUT,
      headers: { Range: `bytes=0-${PAGE_BYTES}`, Accept: 'text/html' },
    })
    if (!response.ok || !response.body) return null
    // Servers that ignore Range send the whole page: stop reading after 25 KB either way.
    const reader = response.body.getReader()
    const chunks = []
    let size = 0
    while (size < PAGE_BYTES) {
      const { done, value } = await reader.read()
      if (done) break
      chunks.push(value)
      size += value.length
    }
    reader.cancel().catch(() => {})
    const $ = cheerio.load(Buffer.concat(chunks).toString('utf8'))
    const found =
      $('meta[property="og:image:secure_url"]').attr('content') ||
      $('meta[property="og:image"]').attr('content') ||
      $('meta[name="og:image"]').attr('content') ||
      $('meta[name="twitter:image"]').attr('content') ||
      $('meta[name="twitter:image:src"]').attr('content') ||
      $('link[rel="image_src"]').attr('href')
    return found ? upgrade(absolute(found, response.url || articleURL)) : null
  } catch {
    return null
  }
}

/** Pictures found by the previous run, so tier 2 only looks at new articles. */
async function previousImages() {
  const images = new Map()
  try {
    const source = process.env.PREVIOUS_FEED_URL
    const text = source
      ? await (await fetchWithTimeout(source, { timeout: FEED_TIMEOUT })).text()
      : await readFile(OUT_FILE, 'utf8')
    for (const article of JSON.parse(text).articles ?? []) {
      if (article.imageURL) images.set(article.url, article.imageURL)
    }
  } catch {
    // First run, or the last file isn't reachable: look everything up.
  }
  return images
}

// MARK: Run

async function main() {
  const feeds = JSON.parse(await readFile(path.join(root, 'feeds.json'), 'utf8'))
  const known = await previousImages()

  const results = await pool(feeds, 12, pollFeed)

  // One entry per link, and per outlet and headline (outlets repeat stories across sections).
  const seenURLs = new Set()
  const seenTitles = new Set()
  let articles = []
  for (const article of results.flatMap((r) => r.articles)) {
    const titleKey = `${article.outlet}|${article.title.toLowerCase()}`
    if (seenURLs.has(article.url) || seenTitles.has(titleKey)) continue
    seenURLs.add(article.url)
    seenTitles.add(titleKey)
    articles.push(article)
  }
  articles.sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt))
  articles = articles.slice(0, TOTAL)

  // Waterfall: feed picture, then last run's, then the page's own (newest first, capped).
  let reused = 0
  const missing = []
  for (const article of articles) {
    if (article.imageURL) continue
    const previous = known.get(article.url)
    if (previous) {
      article.imageURL = previous
      reused++
    } else {
      missing.push(article)
    }
  }
  const lookups = missing.slice(0, MAX_PAGE_FETCHES)
  const found = await pool(lookups, 16, (article) => pageImage(article.url))
  lookups.forEach((article, i) => (article.imageURL = found[i]))

  const generatedAt = new Date().toISOString()
  const status = {
    generatedAt,
    articles: articles.length,
    pictures: {
      fromFeed: articles.length - missing.length - reused,
      reused,
      fromPage: found.filter(Boolean).length,
      leftToPhone: articles.filter((a) => !a.imageURL).length,
    },
    feeds: results.map((r) => ({ outlet: r.feed.outlet, url: r.feed.url, articles: r.articles.length, ms: r.ms, error: r.error })),
  }

  await mkdir(OUT_DIR, { recursive: true })
  await writeFile(OUT_FILE, JSON.stringify({ generatedAt, articles }))
  await writeFile(path.join(OUT_DIR, 'status.json'), JSON.stringify(status, null, 2))
  await writeFile(path.join(OUT_DIR, '.nojekyll'), '')

  const failed = results.filter((r) => r.error)
  console.log(`${articles.length} articles from ${results.length - failed.length}/${results.length} feeds`)
  console.log(`pictures: ${JSON.stringify(status.pictures)}`)
  for (const r of failed) console.log(`  failed: ${r.feed.outlet} ${r.feed.url} (${r.error})`)

  // Don't publish a near-empty feed over a good one.
  if (results.length - failed.length < Math.ceil(results.length / 2)) {
    console.error('Fewer than half the feeds answered; not publishing.')
    process.exit(1)
  }

  await sendBreaking(articles)
}

/** Breaking-news pushes (see alerts.mjs). A failure here never stops the feed publishing. */
async function sendBreaking(articles) {
  const statePath = path.join(OUT_DIR, 'alerts.json')
  let previous = null
  try {
    const source = process.env.PREVIOUS_FEED_URL?.replace(/latest_news\.json$/, 'alerts.json')
    previous = JSON.parse(source ? await (await fetchWithTimeout(source, { timeout: FEED_TIMEOUT })).text() : await readFile(statePath, 'utf8'))
  } catch {
    // First run: nothing sent yet.
  }
  const stories = findStories(articles)
  const { send, state } = selectNew(stories, previous)
  const config = cloudKitConfig()
  for (const s of send) console.log(`breaking: ${s.outlets} outlets | ${s.headline}${config ? '' : ' (not sent: no CloudKit key)'}`)
  try {
    if (config && send.length) console.log(`CloudKit: ${(await sendToCloudKit(send, config)).created} sent`)
    await writeFile(statePath, JSON.stringify(config ? state : previous ?? { sent: [] }, null, 2))
  } catch (error) {
    console.error(`Breaking alerts failed: ${error.message}`)
    await writeFile(statePath, JSON.stringify(previous ?? { sent: [] }, null, 2))
  }
}

await main()
