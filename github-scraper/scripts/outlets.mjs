// The outlets readers choose from in the app (onboarding, Settings › Outlets), built from
// feeds.json alone. Used by poll_feeds.mjs (GitHub Pages, for builds ≤ 64) and by
// build_site.mjs (newnew.news on Cloudflare Pages). No dependencies.

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
