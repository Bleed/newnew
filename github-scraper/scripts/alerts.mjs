// Breaking-news pushes: finds the stories many outlets are covering right now and writes each
// to the app's iCloud public database as a `Breaking` record. Every iPhone that switched
// Breaking on has a CloudKit subscription to that record type, so Apple pushes it to them; no
// server of ours keeps a list of devices. Followed-topic alerts are decided on the iPhone.
//
// A story is articles from different outlets that share rare words (names, places): the same
// signal the app clusters on, without its on-device vectors. Rare = in 2–15 of the run's
// articles. Two articles belong together when they share 3 rare words, or 2 in their headlines.
//
// Without CLOUDKIT_CONTAINER / CLOUDKIT_KEY_ID / CLOUDKIT_PRIVATE_KEY it only logs what it would
// send. State (what was sent) is public/alerts.json, read back from Pages on the next run.

import crypto from 'node:crypto'

/// Stories are found from this many outlets up…
export const MIN_OUTLETS = 3
/// …and are breaking with this many, and this many articles in the last 45 minutes.
export const BREAKING_OUTLETS = 5
export const BREAKING_RECENT = 3
const RECENT_WINDOW = 45 * 60_000
/// Only stories whose newest article is this fresh are new.
const NEW_WINDOW = 3 * 3600_000
const MAX_PER_RUN = 2
const MAX_PER_DAY = 6
const KEEP_STATE = 36 * 3600_000

const STOPWORDS = new Set(
  `about above after again against all also although among another around because been before being below between both
  could does doing down during each even every from further have having here into itself just more most much must
  near never news only other over said says same should since some still such than that their them then there these
  they this those through under until upon very what when where which while will with within would year years your
  live latest update updates video watch photos report reports first last week today yesterday tomorrow people
  told amid after over into make made says said could would year time times back like also more just make than
  according officials official government minister president leader country state city world`.split(/\s+/))

function words(text) {
  return (text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter(w => w.length >= 4 && !STOPWORDS.has(w) && !/^\d+$/.test(w))
}

/** Groups the run's fresh articles into stories covered by several outlets. */
export function findStories(articles, now = Date.now()) {
  const docs = articles.map(a => ({ a, all: new Set(words(`${a.title} ${a.snippet}`)), title: new Set(words(a.title)) }))
  const df = new Map()
  for (const d of docs) for (const w of d.all) df.set(w, (df.get(w) ?? 0) + 1)
  const rare = w => { const n = df.get(w) ?? 0; return n >= 2 && n <= 15 }

  const fresh = docs.filter(d => now - Date.parse(d.a.publishedAt) < NEW_WINDOW)
  const parent = fresh.map((_, i) => i)
  const find = i => (parent[i] === i ? i : (parent[i] = find(parent[i])))
  for (let i = 0; i < fresh.length; i++) {
    for (let j = i + 1; j < fresh.length; j++) {
      if (fresh[i].a.outlet === fresh[j].a.outlet) continue
      let shared = 0, sharedTitle = 0
      for (const w of fresh[i].all) if (rare(w) && fresh[j].all.has(w)) { shared++; if (fresh[i].title.has(w) && fresh[j].title.has(w)) sharedTitle++ }
      if (shared >= 3 || sharedTitle >= 2) parent[find(i)] = find(j)
    }
  }
  const groups = new Map()
  fresh.forEach((d, i) => { const r = find(i); groups.set(r, [...(groups.get(r) ?? []), d]) })

  const stories = []
  for (const group of groups.values()) {
    const outlets = new Set(group.map(d => d.a.outlet))
    if (outlets.size < MIN_OUTLETS) continue
    // The story's words: rare words in at least half its articles, rarest first.
    const counts = new Map()
    for (const d of group) for (const w of d.all) if (rare(w)) counts.set(w, (counts.get(w) ?? 0) + 1)
    const keywords = [...counts].filter(([, n]) => n * 2 >= group.length).sort((a, b) => df.get(a[0]) - df.get(b[0])).map(([w]) => w).slice(0, 10)
    // The headline: the article that shares most of those words, newest on a tie.
    const lead = [...group].sort((x, y) =>
      keywords.filter(w => y.all.has(w)).length - keywords.filter(w => x.all.has(w)).length || Date.parse(y.a.publishedAt) - Date.parse(x.a.publishedAt))[0].a
    const recent = group.filter(d => now - Date.parse(d.a.publishedAt) < RECENT_WINDOW).length
    stories.push({
      headline: lead.title,
      snippet: lead.snippet,
      url: lead.url,
      outlets: outlets.size,
      breaking: outlets.size >= BREAKING_OUTLETS && recent >= BREAKING_RECENT,
      keywords,
      articles: group.length,
    })
  }
  return stories.sort((a, b) => b.outlets - a.outlets)
}

/** The breaking stories not sent before (by shared words), within today's limit. */
export function selectNew(stories, previous, now = Date.now()) {
  const sent = (previous?.sent ?? []).filter(s => now - Date.parse(s.at) < KEEP_STATE)
  const today = sent.filter(s => now - Date.parse(s.at) < 86_400_000).length
  const out = []
  for (const story of stories) {
    if (!story.breaking || out.length >= MAX_PER_RUN || today + out.length >= MAX_PER_DAY) continue
    if (sent.some(s => s.keywords.filter(w => story.keywords.includes(w)).length >= 2)) continue
    out.push(story)
  }
  const state = { sent: [...sent, ...out.map(s => ({ keywords: s.keywords, at: new Date(now).toISOString() }))] }
  return { send: out, state }
}

// MARK: CloudKit Web Services (server-to-server key)

export function cloudKitConfig(env = process.env) {
  const { CLOUDKIT_CONTAINER, CLOUDKIT_KEY_ID, CLOUDKIT_PRIVATE_KEY } = env
  if (!CLOUDKIT_CONTAINER || !CLOUDKIT_KEY_ID || !CLOUDKIT_PRIVATE_KEY) return null
  return {
    container: CLOUDKIT_CONTAINER,
    keyID: CLOUDKIT_KEY_ID,
    privateKey: CLOUDKIT_PRIVATE_KEY.replace(/\\n/g, '\n'),
    environment: env.CLOUDKIT_ENVIRONMENT || 'development',
  }
}

/** Creates one `Breaking` record per story in the public database. */
export async function sendToCloudKit(stories, config) {
  if (!stories.length) return { created: 0 }
  const subpath = `/database/1/${config.container}/${config.environment}/public/records/modify`
  const body = JSON.stringify({
    operations: stories.map(s => ({
      operationType: 'create',
      record: {
        recordType: 'Breaking',
        fields: {
          headline: { value: s.headline },
          url: { value: s.url },
          outlets: { value: s.outlets },
        },
      },
    })),
  })
  const date = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  const bodyHash = crypto.createHash('sha256').update(body).digest('base64')
  const signature = crypto.sign('sha256', Buffer.from(`${date}:${bodyHash}:${subpath}`), config.privateKey).toString('base64')
  const response = await fetch(`https://api.apple-cloudkit.com${subpath}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Apple-CloudKit-Request-KeyID': config.keyID,
      'X-Apple-CloudKit-Request-ISO8601Date': date,
      'X-Apple-CloudKit-Request-SignatureV1': signature,
    },
    body,
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(`CloudKit ${response.status}: ${JSON.stringify(result).slice(0, 300)}`)
  const failed = (result.records ?? []).filter(r => r.serverErrorCode)
  if (failed.length) throw new Error(`CloudKit refused ${failed.length}: ${failed[0].serverErrorCode} ${failed[0].reason ?? ''}`)
  return { created: (result.records ?? []).length }
}
