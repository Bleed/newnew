# Newnew

An iPhone news aggregator with $0 server cost: headlines and snippets from many outlets are grouped
into stories on the device, compared by Apple Intelligence on a tap, and always link out to the
publisher. We never store, rewrite or show full articles.

## Build

```bash
xcodegen generate
open Newnew.xcodeproj
```

iOS 26, Swift 6, default actor isolation `MainActor` (plain data types and pure math are marked
`nonisolated`). Until `NEWNEW_FEED_URL` in `project.yml` is set, the app reads
`Newnew/Resources/sample_news.json` (invented outlets; times are moved up to "now"). Switching
source clears stored articles.

To try real news in the Simulator without publishing anything:

```bash
cd github-scraper && npm install && node scripts/poll_feeds.mjs
cd public && python3 -m http.server 8765 --bind 127.0.0.1
SIMCTL_CHILD_NEWNEW_FEED_URL=http://127.0.0.1:8765/latest_news.json xcrun simctl launch --terminate-running-process booted com.svein.newnew
```

## Layout

| Path | What |
| --- | --- |
| `Newnew/Design` | Atelier CRM's look, copied: `Swiss` tokens and tiles, the 5×7 `DotMatrix` face, `Rebus` sentence top |
| `Newnew/Models` | SwiftData `ArticleItem`, `StoryCluster`, `SemanticMuteFilter`; feed DTOs; `ClusterPerspectiveBrief` |
| `Newnew/Services` | `OnDeviceVectorEngine` (embeddings), `StoryClusterer`, `FeedSyncPipeline`, `IntelligenceService` (FoundationModels), `ImagePipeline` |
| `Newnew/Views` | Feed, story card, story detail with the brief, mute sheet, hero image |
| `github-scraper/` | Node RSS poller → `public/latest_news.json` + `status.json`; feeds in `feeds.json` |
| `.github/workflows/update_feed.yml` | Runs the poller at :07 and :37 and deploys `public/` to GitHub Pages |

## Scraper

- Only headline, a ≤ 280-character snippet, outlet, link, picture, time and category leave the
  scraper. Never article bodies.
- Picture waterfall: 1) the feed's media/enclosure/img (largest; BBC thumbnails upgraded to 976
  wide), 2) last run's picture for the same link (`PREVIOUS_FEED_URL`), 3) og:image from the
  page's first 25 KB (Range request, reading stops at 25 KB even if Range is ignored), capped at
  400 lookups a run, 4) nothing: the app's LinkPresentation fallback. A real run: 896 articles
  from 46/48 feeds in ~20 s; 669 + 188 reused + 27 from pages, 12 left to the phone.
- Last 48 h, 30 per feed, 1,200 total; deduped by link and by outlet + headline.
- Refuses to publish if fewer than half the feeds answer.

## Matching: measured, not the brief's numbers

The original brief said cosine 0.75 to cluster, 0.72 to mute and 0.80 for duplicates on
mean-pooled `NLContextualEmbedding` vectors. Measured on the sample, that doesn't work: any two
headlines score ≥ 0.89 raw, so everything would merge. What the code does instead:

- **Vectors are centred** (corpus mean subtracted, then normalised) before any comparison. Stored
  vectors are raw; `Vec.centred` is applied at use.
- **Clustering** (`StoryClusterer`): 0.9 × TF-IDF over lemmas (names from `NLTagger` count double)
  + 0.1 × centred embedding, pairs from the same outlet at half weight, average linkage,
  threshold **0.12**, 36 h window. Tuned on a real run (897 articles): 161 multi-outlet stories,
  almost all single events. At 0.08 broad themes chained into 40-article blobs. The tiny sample
  splits one story at 0.12; that's expected. On the Mac it takes 0.6 s for 900 articles;
  embedding them takes ~9 s (first sync only).
- **Mute topics**: Apple Intelligence turns the phrase into 4 example headlines + keywords, once,
  when it's added. A story is hidden when ≥ ⅓ of its articles match: example-headline cosine
  > **0.40** (contextual) / 0.42 (sentence model), or 2 keyword hits, or 1 keyword + 0.30.
  Phrase-vs-article cosine alone could not tell "crypto" from a chip maker.
- **"Already read"** comes from cluster membership (`readAt`, `newSinceRead`), not a 0.80 cutoff.
- In the Simulator `NLContextualEmbedding` fails to compile its model (sandbox), so the engine
  falls back to `NLEmbedding.sentenceEmbedding`. Real devices use the contextual model.

## Rules

1. No paid cloud or AI APIs. Apple frameworks only (`NaturalLanguage`, `Accelerate`,
   `FoundationModels`, `SwiftData`, `ImageIO`, `LinkPresentation`).
2. Bulk work (every article) uses only `NaturalLanguage` + `Accelerate`. `FoundationModels` runs
   on a tap, for one story or one topic, and its result is cached (`cachedPerspectiveBriefJSON`).
3. Never read `SystemLanguageModel.default.availability` from a view body: it caused a redraw
   loop that froze the UI. Use `IntelligenceService.isAvailable` (cached, refreshed on foreground).
4. Wrap FoundationModels in `#if canImport(FoundationModels)` with the plain preview fallback.
5. News pictures go through `ImagePipeline` (`CGImageSourceCreateThumbnailAtIndex` at the shown
   size), never `AsyncImage` or `UIImage(data:)`. No blurs, shadows or live blend modes in rows.

## Look (from Atelier CRM)

- Near-white page (#FAFAFA), grey tiles (#F1F1F1), black in dark mode; type carries contrast.
- The page top is Atelier's one-sentence top (`OneSentenceTop`): date line, a big mono figure,
  a detail line, and a rotating last line with a tap target.
- SF Mono for figures, only Light or Regular, never heavier.
- The 5×7 dot face only inside pills, chips and panels, never loose and never for warnings.
- Signals: mint pill = attention ("Developing", "2 new"), red dot and words = act now. Rare.
- Quiet 7 % grey pills for outlets; one black pill per screen for the main action.
