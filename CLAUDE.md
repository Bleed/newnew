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
`nonisolated`). The app reads the live feed at `NEWNEW_FEED_URL` in `project.yml`
(https://bleed.github.io/newnew/latest_news.json, repo github.com/Bleed/newnew). Set it empty to
use `Newnew/Resources/sample_news.json` instead (invented outlets; times moved up to "now").
Switching source clears stored articles. Feed health: https://bleed.github.io/newnew/status.json

To try real news in the Simulator without publishing anything:

```bash
cd github-scraper && npm install && node scripts/poll_feeds.mjs
cd public && python3 -m http.server 8765 --bind 127.0.0.1
SIMCTL_CHILD_NEWNEW_FEED_URL=http://127.0.0.1:8765/latest_news.json xcrun simctl launch --terminate-running-process booted com.svein.newnew
```

## Release

```bash
Scripts/release.sh            # archive + export to build/release/iOS (nothing leaves the Mac)
Scripts/release.sh --upload   # the same, then upload to App Store Connect › TestFlight
```

Signs with the Apple Account in Xcode (team W533Y4V578, Mutiny AS). App Store Connect app:
"newnew: News, Grouped" (the name "newnew" was taken; the home-screen name is still newnew),
bundle ID com.svein.newnew, SKU newnew-ios. Build numbers are set at export. Internal TestFlight
group "Team" gets every upload automatically. The icon must stay opaque (no alpha channel).

## Layout

| Path | What |
| --- | --- |
| `Newnew/Design` | Atelier CRM's look, copied: `Swiss` tokens and tiles, the 5×7 `DotMatrix` face, `Rebus` sentence top |
| `Newnew/Models` | SwiftData `ArticleItem`, `StoryCluster`, `SemanticTopic` (followed or muted); feed DTOs; `ClusterPerspectiveBrief` |
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
- Small downloads: every article carries `changedAt`, the run it was new or last changed in
  (compared with the previous snapshot). Each run rebuilds `chunks/<run>.json` (articles by
  `changedAt`) and `index.json` (the runs, oldest first) from the snapshot, since Pages replaces
  the whole site. The app (`NEWNEW_FEED_URL` = …/index.json) fetches the index, then only chunks
  newer than `feedLastChunk`; the snapshot on first launch or when its last chunk has aged out.
  Changed articles are updated in place. Measured: index ~170 B, a run's chunk ~1 KB, against
  ~226 KB for the whole feed. `latest_news.json` stays for builds 1–6.

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
- **Topics** (`SemanticTopic`, kind follow or mute): Apple Intelligence turns the phrase into 4
  example headlines + keywords, once, when it's added. An article matches with 2 topic words
  (the phrase counts as one, whole-word), or 1 word + example-headline cosine > 0.38 (0.40 on
  the sentence model; an oil spill in "satellite images" scored 0.36), or, with
  the contextual model only, cosine > 0.55 alone. A story matches when ≥ ⅓ of its articles do;
  muting wins over following. Meaning alone was too loose on a real feed: for "space" a
  supervolcano and the Dead Sea scored 0.51–0.53; the sentence model put cricket first for "AI".
- **Regions** (`RegionTagger`): a word list of places, people and institutions per region
  (Europe, US, Middle East, Asia). A story is in a region when ≥ ⅓ of its articles are. The
  feed's filter switch is World, the regions, then the topics you follow (`FeedFilter`); a
  topic filter shows the stories that topic raised. There is no Local region (removed on
  request); local-news outlets still carry `country` from the scraper.
- **"Already read"** comes from cluster membership (`readAt`, `newSinceRead`), not a 0.80 cutoff.
- In the Simulator `NLContextualEmbedding` fails to compile its model (sandbox), so the engine
  falls back to `NLEmbedding.sentenceEmbedding`. Real devices use the contextual model.

## Ranking, media and the dot boards

- Top stories are ordered by `FeedSections.importance`: log(outlets) + 0.6·log(outlets in the
  last 2 h), times freshness (6 h half-life, floor 25 %), × 0.4 once read with nothing new.
  One order for all stories, followed or not (a followed story only keeps its topic label);
  "In brief" is newest first.
- Feeds can be `"kind": "video"` (YouTube channel feed: `videoID`, HD thumbnail, Shorts
  skipped), `"podcast"` (`audioURL`, `audioSeconds`, no picture) or `"chart"` (`isChart`: shown
  whole on white, kept 14 days). Cards get "Listen · n min" (AudioPlayer, background audio, Lock
  Screen) and "Watch · outlet" (opens YouTube) pills. Lead article prefers written articles.
  On a story's page the three newest videos/episodes come first, under the headline, as links
  out ("Watch and listen"); no in-page player.
- Hero images are 5:4. The small pills on a card share one height (`pillHeight()`).
- Launch and pull to refresh share one animation (`WordLoop`, `StackedWords`): a fine 4 pt dot
  board with a small "new" over "new"; first line rolls in, then the second, then they roll out
  in the same order, looping until loaded, always ending with both in. Pull to refresh
  (`dotRefreshable`) replaces the system spinner; for any sync the page opens a blank 96 pt band
  at its top with the small board 20 pt above its middle, and closes it after. The sentence top
  is lifted into the bar row (date level with the button's middle, `headerTop` −37) and drops
  below the band while it shows; 28 pt between it and the filters. The
  sentence top sits below the bar (figure 44 pt, words 17 pt). The launch
  sync waits until the launch board is gone; the board's dot field is an Equatable `DotGrid`
  drawn in two fills. Regions are tagged only for new articles (main-actor time).
  Keep loop state in an object: a ViewModifier's @State written from a task it started never
  reached the screen.

## Loading board and alerts

- `LoadingBoard` (Design/DotMatrix.swift; Figma › Loading animation) replaces the launch board on
  every launch: a 28-column dot board with "new" over "new" rolling in. With stories stored it
  fades after 2 s (the launch sync waits 2.4 s so it can't hold the board up). On a first launch
  it shows `FeedSyncPipeline.phase`: outlets, then articles read, then stories, with the bottom
  row of dots as progress.
- Alerts (Services/Alerts.swift), off until switched on in Topics:
  1. Background refresh (`BGAppRefreshTask` "com.svein.newnew.refresh"): sync, then a local
     alert for new stories on followed topics, and for breaking stories while push isn't set
     up. Seen stories never alert; ≤ 3 per check, ≤ 8 a day.
  2. Breaking push: the scraper (scripts/alerts.mjs) finds stories from ≥ 5 outlets with ≥ 3
     articles in 45 min and writes a `Breaking` record to the CloudKit public database; the app's
     subscription makes Apple push it. ≤ 2 per run, 6 a day; state in public/alerts.json.
- To turn on push: create the CloudKit container (e.g. iCloud.com.svein.newnew) for team
  W533Y4V578, set `NEWNEW_CLOUDKIT_CONTAINER` and `NEWNEW_ENTITLEMENTS =
  Newnew/App/Newnew-CloudKit.entitlements` in project.yml; in CloudKit Console create a
  server-to-server key and add GitHub variable `CLOUDKIT_CONTAINER` and secrets
  `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY`. Records go to the development environment unless
  `CLOUDKIT_ENVIRONMENT` is `production` (deploy the schema first).
- Feed performance: `FeedSections` works the sections out once per render. Computed
  properties re-run on every read froze the main thread for seconds with 400+ stories.

## Rules

1. No paid cloud or AI APIs. Apple frameworks only (`NaturalLanguage`, `Accelerate`,
   `FoundationModels`, `SwiftData`, `ImageIO`, `LinkPresentation`).
2. Bulk work (every article) uses only `NaturalLanguage` + `Accelerate`. `FoundationModels` runs
   on a tap, for one story or one topic, and its result is cached (`cachedPerspectiveBriefJSON`).
3. Apple's default guardrails refuse much hard news ("May contain sensitive content" on riots,
   war). Briefs then retry with `.permissiveContentTransformations` (plain text in a SUMMARY/
   AGREE/DIFFER/ANGLE line format, parsed), and only then fall back to the headline preview with
   a note. Never show the raw model error.
4. Never read `SystemLanguageModel.default.availability` from a view body: it caused a redraw
   loop that froze the UI. Use `IntelligenceService.isAvailable` (cached, refreshed on foreground).
5. Wrap FoundationModels in `#if canImport(FoundationModels)` with the plain preview fallback.
6. News pictures go through `ImagePipeline` (`CGImageSourceCreateThumbnailAtIndex` at the shown
   size), never `AsyncImage` or `UIImage(data:)`. No blurs, shadows or live blend modes in rows.

## Look (from Atelier CRM)

- The name is lower case: "newnew" (home screen, prompts, accessibility).
- Icon: "new" over "new" in the dot face, reversed (near-white dots on black), from
  `Scripts/render-app-icon.swift`.
- Near-white page (#FAFAFA), grey tiles (#F1F1F1), black in dark mode; type carries contrast.
- The page top is Atelier's one-sentence top (`OneSentenceTop`): date line, a big mono figure,
  a detail line, and a rotating last line with a tap target.
- News headlines are Times New Roman (`Swiss.headline`), everywhere a headline appears; all
  other text stays SF.
- SF Mono for figures, only Light or Regular, never heavier.
- The 5×7 dot face only inside pills, chips and panels, never loose and never for warnings.
- Signals: mint pill = attention ("Developing", "2 new"), red dot and words = act now. Rare.
- Quiet 7 % grey pills for outlets; one black pill per screen for the main action.
