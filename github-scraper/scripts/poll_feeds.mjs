// Checks the curated feeds in feeds.json every 30 minutes in GitHub Actions and publishes, to
// GitHub Pages, only what the app needs besides the feeds themselves:
//   outlets.json   the outlets readers choose from, each with its feeds' addresses. Each iPhone
//                  fetches the feeds of its chosen outlets itself (FeedFetcher in the app); no
//                  news passes through here.
//   status.json    each feed's health (answered, items, time), for keeping the list in shape
//   privacy.html   the app's privacy policy
// and it sends breaking-news pushes (alerts.mjs): a story many outlets report within the hour.
// For that it reads the news feeds' headlines and very short extracts in memory; none are
// published, and alerts.json keeps only the pushed stories' keywords.
//
// feeds.json can mark a feed with "kind": "video" (a YouTube channel), "podcast" or "chart" (a
// data-journalism feed); the app reads them differently. Only plain news feeds count for
// breaking news.
//
//   node scripts/poll_feeds.mjs                 writes public/

import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import Parser from 'rss-parser'
import * as cheerio from 'cheerio'
import { findStories, selectNew, cloudKitConfig, sendToCloudKit } from './alerts.mjs'

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const OUT_DIR = path.resolve(process.env.OUT_DIR ?? path.join(root, 'public'))

const USER_AGENT = 'NewnewBot/1.0 (feed health check; breaking-news alerts)'
const MAX_AGE_HOURS = 48
const PER_FEED = 30
/// Light pillars, not news: no breaking alerts from them.
const LIGHT_CATEGORIES = new Set(['Technology', 'Entertainment', 'Fashion & Style', 'Gaming', 'Lifestyle & Food'])
/// Breaking detection reads the headline and the start of the extract.
const SNIPPET_LENGTH = 150
const FEED_TIMEOUT = 15_000

const parser = new Parser({
  customFields: { item: [['content:encoded', 'contentEncoded'], ['dc:date', 'dcDate']] },
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
    const items = parsed.items ?? []
    const cutoff = Date.now() - MAX_AGE_HOURS * 3600_000
    const articles = []
    // Breaking news comes from the news feeds only.
    for (const item of feed.kind || LIGHT_CATEGORIES.has(feed.category) ? [] : items) {
      const article = toArticle(item, feed)
      if (article && Date.parse(article.publishedAt) >= cutoff) articles.push(article)
      if (articles.length >= PER_FEED) break
    }
    return { feed, items: items.length, articles, ms: Date.now() - started }
  } catch (error) {
    return { feed, items: 0, articles: [], error: String(error.message ?? error), ms: Date.now() - started }
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
    // Never in the future: some feeds stamp tomorrow's print date.
    publishedAt: new Date(Math.min(date, Date.now())).toISOString(),
    category: feed.category ?? null,
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

// MARK: Outlets

/** One entry per outlet: its name, its categories, its kinds of feed (article, video, podcast, chart)
 * and the feeds themselves. */
export function outletCatalog(feeds) {
  const byOutlet = new Map()
  for (const feed of feeds) {
    const entry = byOutlet.get(feed.outlet) ?? { outlet: feed.outlet, categories: [], kinds: [] }
    if (feed.category && !entry.categories.includes(feed.category)) entry.categories.push(feed.category)
    // "article" for an ordinary news feed, so the app can tell video-only outlets apart.
    const kind = feed.kind ?? 'article'
    if (!entry.kinds.includes(kind)) entry.kinds.push(kind)
    // Each iPhone reads the feeds itself.
    entry.feeds = [...(entry.feeds ?? []), { url: feed.url, category: feed.category, kind: feed.kind, country: feed.country }]
    byOutlet.set(feed.outlet, entry)
  }
  return { outlets: [...byOutlet.values()] }
}

// MARK: Run

async function main() {
  const feeds = JSON.parse(await readFile(path.join(root, 'feeds.json'), 'utf8'))
  const results = await pool(feeds, 12, pollFeed)

  // One entry per link, and per outlet and headline (outlets repeat stories across sections).
  const seenURLs = new Set()
  const seenTitles = new Set()
  const articles = []
  for (const article of results.flatMap((r) => r.articles)) {
    const titleKey = `${article.outlet}|${article.title.toLowerCase()}`
    if (seenURLs.has(article.url) || seenTitles.has(titleKey)) continue
    seenURLs.add(article.url)
    seenTitles.add(titleKey)
    articles.push(article)
  }

  const generatedAt = new Date().toISOString()
  const status = {
    generatedAt,
    feeds: results.map((r) => ({ outlet: r.feed.outlet, url: r.feed.url, items: r.items, ms: r.ms, error: r.error })),
  }

  await mkdir(OUT_DIR, { recursive: true })
  await writeFile(path.join(OUT_DIR, 'status.json'), JSON.stringify(status, null, 2))
  // The outlets readers choose from in the app (onboarding, Settings › Outlets): each outlet
  // once, with its feeds. The app ships a copy for a first launch offline.
  await writeFile(path.join(OUT_DIR, 'outlets.json'), JSON.stringify(outletCatalog(feeds)))
  await writeFile(path.join(OUT_DIR, '.nojekyll'), '')
  // The app's privacy policy, at a stable public address (App Store Connect links to it).
  await copyFile(path.join(root, 'site', 'privacy.html'), path.join(OUT_DIR, 'privacy.html'))

  const failed = results.filter((r) => r.error)
  console.log(`${results.length - failed.length}/${results.length} feeds answered; ${articles.length} news headlines checked for breaking news`)
  for (const r of failed) console.log(`  failed: ${r.feed.outlet} ${r.feed.url} (${r.error})`)

  await sendBreaking(articles)
}

/** Breaking-news pushes (see alerts.mjs). A failure here never stops the outlet list publishing. */
async function sendBreaking(articles) {
  const statePath = path.join(OUT_DIR, 'alerts.json')
  let previous = null
  try {
    const source = process.env.PREVIOUS_ALERTS_URL
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
