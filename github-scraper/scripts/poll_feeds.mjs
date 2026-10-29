// Polls the curated RSS feeds in feeds.json and writes one static file, public/latest_news.json,
// that the Newnew app downloads. Runs every 30 minutes in GitHub Actions; costs nothing.
//
// What goes out per article: headline, a short snippet (≤ 280 characters), outlet, link, picture,
// time, category and, for local-news feeds, the country. Never the article body: the app links
// out to the publisher.
//
// Besides articles, feeds.json can mark a feed with "kind":
//   "video"    a YouTube channel's public feed: the video ID and its HD thumbnail (Shorts are
//              skipped; they're vertical).
//   "podcast"  a daily news podcast: the episode's audio URL and length, no picture.
//   "chart"    a data-journalism feed: the picture is a chart, to be shown whole, not cropped;
//              charts come weekly, so they're kept for 14 days instead of 48 hours.
//
// The editorial mix: news (World, Business, Science, Politics, …) is kept whole, because the
// app groups it into stories across outlets. The lighter pillars (Technology, Entertainment,
// Fashion & Style, Gaming, Lifestyle & Food) publish many small items, so each of their feeds
// gives its newest 8, and each of those categories but Technology at most 15 in all (Technology
// keeps more: gadget launches are covered across outlets, like news). The app mixes the
// pillars on the page. Their articles also carry `galleryURLs`: up to 6 pictures from the item
// (lookbooks, interiors, recipes), when it has more than one.
//
// Output, so the app downloads little (GitHub Pages replaces the whole site each run, so the
// small files are rebuilt from the snapshot every time):
//   latest_news.json   the snapshot: every article of the last 48 h, each stamped `changedAt`
//                      with the run it was new or last changed in (first launch; builds 1–6)
//   chunks/<run>.json  the articles whose `changedAt` is that run
//   index.json         the runs that have a chunk, newest last: the app fetches this (~2 KB),
//                      then only the chunks newer than the last one it has
//
// Pictures come from a waterfall:
//   1. The feed itself: <media:content>, <media:thumbnail>, <enclosure>, or an <img> in the item.
//   2. The article page's first 25 KB (an HTTP Range request), read for og:image / twitter:image.
//   3. Left empty: the app asks the page itself from the phone (LinkPresentation), which works
//      for publishers that block data-centre IPs.
//
//   node scripts/poll_feeds.mjs                 writes public/ (see "Output" below)
//   PREVIOUS_FEED_URL=https://… node …          reuses pictures already found in the last run

import { readFile, writeFile, mkdir, rm } from 'node:fs/promises'
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
const TOTAL = 1600
const SNIPPET_LENGTH = 280
const FEED_TIMEOUT = 15_000
const PAGE_TIMEOUT = 6_000
const PAGE_BYTES = 25_000
/// Tier 2 is the slow part; keep each run well inside its schedule.
const MAX_PAGE_FETCHES = 400
/// The lighter pillars (see the top): per-feed and per-category caps.
const LIGHT_CATEGORIES = new Set(['Technology', 'Entertainment', 'Fashion & Style', 'Gaming', 'Lifestyle & Food'])
const LIGHT_PER_FEED = 8
const LIGHT_PER_CATEGORY = 15
const UNCAPPED_CATEGORIES = new Set(['Technology'])
const GALLERY_SIZE = 6

const parser = new Parser({
  customFields: {
    item: [
      ['media:content', 'mediaContent', { keepArray: true }],
      ['media:thumbnail', 'mediaThumbnail', { keepArray: true }],
      ['media:group', 'mediaGroup'],
      ['content:encoded', 'contentEncoded'],
      ['dc:date', 'dcDate'],
      ['yt:videoId', 'videoId'],
      ['itunes:duration', 'duration'],
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
    const cutoff = Date.now() - (feed.maxAgeHours ?? (feed.kind === 'chart' ? 14 * 24 : MAX_AGE_HOURS)) * 3600_000
    const articles = []
    for (const item of parsed.items ?? []) {
      const article = toArticle(item, feed)
      if (article && Date.parse(article.publishedAt) >= cutoff) articles.push(article)
      if (articles.length >= (LIGHT_CATEGORIES.has(feed.category) ? LIGHT_PER_FEED : PER_FEED)) break
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
  const media = {}
  if (feed.kind === 'video') {
    if (!item.videoId || url.includes('/shorts/')) return null
    media.videoID = item.videoId
    media.imageURL = `https://i.ytimg.com/vi/${item.videoId}/maxresdefault.jpg`
  } else if (feed.kind === 'podcast') {
    const audio = item.enclosure?.url
    if (!audio || !(item.enclosure.type ?? 'audio').startsWith('audio')) return null
    media.audioURL = audio
    media.audioSeconds = seconds(item.duration)
    // The show's square logo makes a poor news picture: none.
    media.imageURL = null
  } else if (feed.kind === 'chart') {
    media.isChart = true
  }
  const description = feed.kind === 'video' ? item.mediaGroup?.['media:description']?.[0] ?? '' : body
  return {
    title: feed.kind === 'video' ? videoTitle(title, feed.outlet) : title,
    snippet: truncate(clean(description), SNIPPET_LENGTH),
    outlet: feed.outlet,
    url,
    imageURL: 'imageURL' in media ? media.imageURL : feedImage(item, url),
    galleryURLs: LIGHT_CATEGORIES.has(feed.category) && !feed.kind ? gallery(item, url) : null,
    videoID: media.videoID ?? null,
    audioURL: media.audioURL ?? null,
    audioSeconds: media.audioSeconds ?? null,
    isChart: media.isChart ?? false,
    // Never in the future: some feeds stamp tomorrow's print date.
    publishedAt: new Date(Math.min(date, Date.now())).toISOString(),
    category: feed.category ?? null,
    // Only on local-news feeds (The Local Norway → "NO"): the app's Local region.
    country: feed.country ?? null,
  }
}

/** "938", "15:38" or "1:02:03" → seconds. */
function seconds(duration) {
  if (duration == null) return null
  const parts = String(duration).split(':').map(Number)
  if (parts.some(Number.isNaN)) return null
  return parts.reduce((total, part) => total * 60 + part, 0)
}

/** YouTube titles carry channel tags: "… | DW News", "… • FRANCE 24 English", "… #BBCNews". */
function videoTitle(title, outlet) {
  const first = outlet.split(/\s+/)[0].toLowerCase()
  let out = title.replace(/(\s+#[\p{L}\p{N}_]+)+\s*$/u, '').trim()
  // A last " | x", " • x" or " - x" segment that names the channel.
  const m = out.match(/^(.*\S)\s+[|•–-]\s+([^|•–-]{1,40})$/u)
  if (m && m[2].toLowerCase().includes(first)) out = m[1].trim()
  return out
}

/** maxresdefault only exists for HD uploads; otherwise the 4:3 hqdefault (with bars). */
async function videoThumbnail(article) {
  try {
    const response = await fetchWithTimeout(article.imageURL, { timeout: PAGE_TIMEOUT, headers: {} })
    if (response.ok) return article.imageURL
  } catch {}
  return article.imageURL.replace('maxresdefault', 'hqdefault')
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

/** Up to 6 distinct pictures from the item, for a lookbook or a recipe's steps; null for
 * fewer than two. Tracking pixels, icons and avatars are skipped, and renditions of one picture
 * (the same path with other sizes) count once. */
function gallery(item, articleURL) {
  const urls = []
  for (const media of item.mediaContent ?? []) {
    const a = media?.$ ?? {}
    if (a.url && (!a.medium || a.medium === 'image') && (!a.type || a.type.startsWith('image'))) urls.push(a.url)
  }
  const html = item.contentEncoded ?? item.content ?? ''
  for (const m of html.matchAll(/<img\b[^>]*>/gi)) {
    const tag = m[0]
    const src = /\ssrc=["']([^"']+)["']/i.exec(tag)?.[1]
    const width = Number(/\swidth=["']?(\d+)/i.exec(tag)?.[1] ?? 0)
    if (src && (width === 0 || width >= 300)) urls.push(src)
  }
  const seen = new Set()
  const out = []
  for (const raw of urls) {
    const url = upgrade(absolute(raw.replace(/&amp;/g, '&'), articleURL))
    if (!url || !/^https:/.test(url) || /pixel|feedburner|gravatar|emoji|avatar|logo|icon|\.gif(\?|$)|\.svg(\?|$)/i.test(url)) continue
    // WordPress thumbnails name their size: "-300x200.jpg" is too small to swipe through.
    const named = /-(\d+)x\d+\.\w+$/.exec(url.replace(/\?.*$/, ''))
    if (named && Number(named[1]) < 600) continue
    // One picture, many sizes: "photo-1024x683.jpg", "…/w_640/…", "?w=…" all key to the same.
    const key = url.replace(/\?.*$/, '').replace(/-\d+x\d+(?=\.\w+$)/, '').replace(/\/(w|h|c)_[^/]+/g, '').toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push(url)
    if (out.length >= GALLERY_SIZE) break
  }
  return out.length > 1 ? out : null
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

/** The previous run's snapshot: its pictures (so tier 2 only looks at new articles) and its
 * articles (to tell which changed). */
async function previousFeed() {
  const images = new Map()
  const byURL = new Map()
  try {
    const source = process.env.PREVIOUS_FEED_URL
    const text = source
      ? await (await fetchWithTimeout(source, { timeout: FEED_TIMEOUT })).text()
      : await readFile(OUT_FILE, 'utf8')
    for (const article of JSON.parse(text).articles ?? []) {
      byURL.set(article.url, article)
      if (article.imageURL) images.set(article.url, article.imageURL)
    }
  } catch {
    // First run, or the last file isn't reachable: look everything up.
  }
  return { images, byURL }
}

/** What counts as a change: anything the app shows. */
const CONTENT_KEYS = ['title', 'snippet', 'imageURL', 'galleryURLs', 'videoID', 'audioURL', 'audioSeconds', 'isChart', 'category', 'country']

/** Stamps each article with the run it was new or last changed in. */
function stampChanges(articles, previous, runID) {
  for (const article of articles) {
    const before = previous.get(article.url)
    const same = before?.changedAt && CONTENT_KEYS.every(k => JSON.stringify(before[k] ?? null) === JSON.stringify(article[k] ?? null))
    article.changedAt = same ? before.changedAt : runID
  }
}

/** The chunks and the index, rebuilt from the stamped snapshot. */
async function writeChunks(articles, generatedAt) {
  const dir = path.join(OUT_DIR, 'chunks')
  await rm(dir, { recursive: true, force: true })
  await mkdir(dir, { recursive: true })
  const byRun = new Map()
  for (const article of articles) byRun.set(article.changedAt, [...(byRun.get(article.changedAt) ?? []), article])
  const runs = [...byRun.keys()].sort()
  for (const run of runs) {
    await writeFile(path.join(dir, `${run}.json`), JSON.stringify({ id: run, articles: byRun.get(run) }))
  }
  const index = {
    version: 1,
    generatedAt,
    snapshot: 'latest_news.json',
    chunks: runs.map(run => ({ id: run, file: `chunks/${run}.json`, count: byRun.get(run).length })),
  }
  await writeFile(path.join(OUT_DIR, 'index.json'), JSON.stringify(index))
  return runs.length
}

/** One entry per outlet: its name, its categories, and its kinds of feed (article, video, podcast, chart). */
export function outletCatalog(feeds) {
  const byOutlet = new Map()
  for (const feed of feeds) {
    const entry = byOutlet.get(feed.outlet) ?? { outlet: feed.outlet, categories: [], kinds: [] }
    if (feed.category && !entry.categories.includes(feed.category)) entry.categories.push(feed.category)
    // "article" for an ordinary news feed, so the app can tell video-only outlets apart.
    const kind = feed.kind ?? 'article'
    if (!entry.kinds.includes(kind)) entry.kinds.push(kind)
    byOutlet.set(feed.outlet, entry)
  }
  return { outlets: [...byOutlet.values()] }
}

// MARK: Run

async function main() {
  const feeds = JSON.parse(await readFile(path.join(root, 'feeds.json'), 'utf8'))
  const previous = await previousFeed()
  const known = previous.images

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
  // The lighter pillars' caps. Outlets take turns (each one's newest, then each one's second
  // newest, …), so two busy sneaker blogs don't fill Fashion & Style on their own.
  const rankInFeed = new Map()
  const perOutlet = new Map()
  for (const article of articles) {
    const key = `${article.category}|${article.outlet}`
    const rank = perOutlet.get(key) ?? 0
    perOutlet.set(key, rank + 1)
    rankInFeed.set(article, rank)
  }
  const kept = new Set()
  for (const category of LIGHT_CATEGORIES) {
    if (UNCAPPED_CATEGORIES.has(category)) continue
    articles
      .filter(article => article.category === category)
      .sort((a, b) => rankInFeed.get(a) - rankInFeed.get(b) || Date.parse(b.publishedAt) - Date.parse(a.publishedAt))
      .slice(0, LIGHT_PER_CATEGORY)
      .forEach(article => kept.add(article))
  }
  articles = articles.filter(article => !LIGHT_CATEGORIES.has(article.category) || UNCAPPED_CATEGORIES.has(article.category) || kept.has(article))
  articles = articles.slice(0, TOTAL)

  // Video thumbnails: check the HD one exists (reusing last run's answer).
  const videos = articles.filter(a => a.videoID)
  const checked = await pool(videos, 16, a => known.get(a.url) ?? videoThumbnail(a))
  videos.forEach((a, i) => (a.imageURL = checked[i]))

  // Waterfall: feed picture, then last run's, then the page's own (newest first, capped).
  let reused = 0
  const missing = []
  for (const article of articles) {
    // Podcasts have no picture on purpose.
    if (article.imageURL || article.audioURL) continue
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
  // A run's ID is its time, safe as a file name and in order as text: 2026-10-24T18-35-58Z.
  const runID = generatedAt.replace(/\.\d+Z$/, 'Z').replace(/:/g, '-')
  stampChanges(articles, previous.byURL, runID)
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
  const chunkCount = await writeChunks(articles, generatedAt)
  await writeFile(path.join(OUT_DIR, 'status.json'), JSON.stringify(status, null, 2))
  // The outlets readers choose from in the app (onboarding, Settings › Outlets): each outlet
  // once, with the kinds of feed it has. The app ships a copy for a first launch offline.
  await writeFile(path.join(OUT_DIR, 'outlets.json'), JSON.stringify(outletCatalog(feeds)))
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
