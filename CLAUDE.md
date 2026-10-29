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
bundle ID com.svein.newnew, SKU newnew-ios. The build number lives in `project.yml`
(`CURRENT_PROJECT_VERSION`); `Newnew.xcodeproj` is generated and git-ignored, so a build number
or setting changed in Xcode is lost at the next `xcodegen generate` (which `release.sh` runs).
Builds 27 and 28 were archived from Xcode on 2026-10-25; bump past 28. Internal TestFlight
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
  threshold **0.12**, 36 h window. A pair is only compared when it shares **2 telling words**
  (words ≤ 1.5 % of the day's articles use; a name counts as its words): one rare word had
  paired Dezeen's Dutch Design Week with a Dutch researcher's electric planes, and two common
  ones ("police", "dies") unrelated crime stories. On the 2026-10-25 feed (1,027 articles)
  that cut small stray groups from ~40 of 101 to a handful; requiring 3 words lost real
  stories (Musk/Starlink, the MotoGP washout). Tuned on a real run (897 articles): 161 multi-outlet stories,
  almost all single events. At 0.08 broad themes chained into 40-article blobs. The tiny sample
  splits one story at 0.12; that's expected. On the Mac it takes 0.6 s for 900 articles;
  embedding them takes ~9 s (first sync only).
- **Topics** (`SemanticTopic`, kind follow or mute): Apple Intelligence turns the phrase into 4
  example headlines + keywords, once, when it's added. What the person typed decides: all its
  words (less broad ones like "news", plural s optional) must appear, and in the headline that
  alone is a match. The model's keywords are close to random ("device, service, forum" for
  "Apple news", "jordan" for Space, invented drivers for F1), so one counts only as a name the
  feed ties to the typed words (capitalised mid-sentence in snippets, and used in articles that
  also use the typed words): it matches in the headline with cosine > 0.22. Either one only in
  the snippet needs cosine > 0.38 (passing mentions); cosine > 0.55 alone (contextual model)
  also matches. Meaning is a weak signal against the model's examples: real Apple stories
  scored −0.1 to 0.4, an unrelated Jordan story 0.37. A story matches when ≥ ⅓ of its
  articles do; muting wins over following. Tested with a temporary launch-argument probe on
  the live feed (Apple news, Space, electric cars, Ukraine).
- **Pillars** (`Pillar`, from the feed's category): Briefing (World, Business, Science,
  Politics, US, Local, Sport, Data, news podcasts) 25 %, Tech & Gear 20 %, Fashion & Style,
  Entertainment and Gaming 15 % each, Lifestyle & Food 10 %. A story's pillar is its articles'
  majority. On All, top stories are the pillars interleaved by share (smooth weighted
  round-robin, `FeedSections.balanced`), most important first within each; breaking news
  (`Alerts.isBreaking`) leads regardless. News reaches the top only with several outlets; a
  lighter pillar's single-outlet piece counts. Asked for "balanced by importance" over a strict
  round-robin (2026-10-25), since the user earlier wanted importance order. Fashion pictures
  are 4:5, cropped from the top; an item with `galleryURLs` swipes as a gallery. The story
  page's Apple Intelligence read follows `Pillar.briefMode`: perspective (news, needs several
  outlets), verdict (tech, entertainment, gaming: praised / criticised) or trend (fashion,
  lifestyle: the shift, names, why it matters, takeaways); the last two also run on one
  outlet, where "why it matters" can be the model's guess. The scraper caps the lighter
  pillars (8 per feed; 15 per category, outlets taking turns; Technology uncapped by category)
  and leaves news whole, because the clusterer needs every outlet. The brief's suggested
  0.72 cosine clustering threshold was not adopted: the tuned 0.12 linkage above is stricter.
- **Outlets** (legal basis: the reader picks the sources; newnew shows headlines and short
  extracts and links out). First launch shows onboarding (`OnboardingView`, Figma page
  Onboarding): welcome, choose outlets (grouped by pillar, all checked to start, a group's
  "All"/"None"), add your own feed, alerts. `OutletStore` keeps the choice (`outlets.chosen`,
  nil = not chosen yet = read everything) and own feeds (`outlets.custom`) in UserDefaults.
  The catalog is the scraper's `outlets.json` (each outlet's categories and kinds: article,
  video, podcast, chart), with a bundled copy in Resources for an offline first launch;
  regenerate that copy when `feeds.json` changes. Sync drops articles from outlets not
  chosen; `applyOutletChoice` deletes them from the store and, when outlets were added,
  forgets the last chunk so the next sync takes the whole snapshot. Own feeds are found and
  read on the iPhone (`CustomFeedReader`: a site's `<link rel="alternate">` or the usual
  paths; RSS and Atom), never by the scraper. Settings › Outlets has the same picker and the
  add-your-own panel. YouTube channels too: their feed's `yt:videoId` makes the items videos
  (Watch, play mark, `hqdefault` thumbnail), Shorts are skipped. In the EU YouTube puts a
  cookie-consent page before channel pages, so an @handle can't be looked up from the phone;
  newnew doesn't answer it, it asks for the channel ID (`UC…`, or a /channel/ link) and builds
  `feeds/videos.xml?channel_id=` from that. Each group in the picker suggests a few YouTube
  channels (`YouTubeSuggestions`, IDs checked 2026-10-29); checking one adds it as an own feed.
  Links open the publisher's app first (`LinkOpener`: universal links only, so YouTube, NYT,
  Guardian…), falling back to the in-app browser. Breaking push still covers all outlets (the scraper doesn't know a
  reader's choice).
- **Regions** (`RegionTagger`): a word list of places, people and institutions per region
  (Europe, US, Middle East, Asia). A story is in a region when ≥ ⅓ of its articles are. The
  filter bar is All, the pillars, then the topics you follow (`FeedFilter`, pinned while
  scrolling); choosing Briefing shows a row of regions, which narrow the news. A topic filter
  shows the stories that topic raised. There is no Local region (removed on request);
  local-news outlets still carry `country` from the scraper.
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
  On a story's page videos/episodes are always folded into one row under the headline
  ("4 videos, 1 podcast episode · On YouTube… · Show", `MediaFold`); opened, each links
  out. No in-page player.
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

- The full-screen loader waits for the sync, with its progress bar, on a first launch and on a
  big catch-up: the newest stored feed piece older than 3 h (`FeedSyncPipeline.hasALotToLoad`),
  at launch or on returning to the app. Otherwise it plays once and the sync runs behind the
  pull-down band. Test: launch with `-feedLastChunk <old run ID>` (argument domain).

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
- Push is on (set up 2026-10-24): container iCloud.com.svein.newnew (team W533Y4V578), the app
  builds with Newnew/App/Newnew-CloudKit.entitlements; `Breaking` (headline String, url String,
  outlets Int64) is deployed to Production. The scraper signs with a Production
  server-to-server key ("newnew scraper (GitHub Action)"; private key at
  ~/.newnew-cloudkit/eckey.pem, never committed), via GitHub variables `CLOUDKIT_CONTAINER`,
  `CLOUDKIT_ENVIRONMENT=production` and secrets `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY`.
  Server keys belong to one environment: a Development test needs its own key.
- Breaking push first worked on 2026-10-28 (build 30). CloudKit refused every Production
  subscription with CKError 12 "attempting to create a subscription in a production container"
  until the subscription had been created once in **Development** (a Debug build run on a
  device from Xcode) and the schema was deployed again, even with "0 changes"; see Apple's
  CKSubscription docs. A Queryable index on `Breaking.recordName` was added on the way (harmless).
  Any new subscription type needs the same Development-first step. The app shows CloudKit's
  reason under the Breaking switch if a subscription fails (`Alerts.pushStatusKey`).
- SwiftData stays local (`ModelConfiguration(cloudKitDatabase: .none)`): with the iCloud
  entitlement it would otherwise try to sync and crash on launch (unique attributes).
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

## Legal care (review 2026-10-29; not legal advice)

- The public feed carries very short extracts only: 150 characters (`SNIPPET_LENGTH`), the
  same as the app shows. Pictures are links to the publisher's own files.
- Photos are never full screen: the Catchup reel shows the picture as a framed card.
- The AI read is written on the reader's iPhone, never published by newnew; it is labelled as
  Apple Intelligence and can be hidden. A report option was tried and removed (2026-10-29).
- Coverage-spectrum badges describe, not judge: SPECIALIST PRESS, GENERAL NEWS, MANY DESKS.
- Privacy policy: lives at https://newnew.news/privacypolicy (the app links there, and so
  should App Store Connect). The text is github-scraper/site/privacy.html, also published with
  the feed at https://bleed.github.io/newnew/privacy.html as a copy.
- Mailboxes the app names: feedback@newnew.news, publishers@newnew.news.

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
- All dot-face text (chips, pills, figures) arrives as a departures board, from Figma
  "Motion · Today board" (`DotText.pixelsIn`): unlit dots faintly visible (7 %), cells start
  0.025 s apart left to right, each rolls through random glyphs every 0.06 s for
  4 + 0.4 × index steps and settles, dot rows rippling 0.012 s apart; once on screen and after
  the launch board. Later value changes still roll. Not on the loading boards.
- Signals: mint pill = attention ("Developing", "2 new"), red dot and words = act now. Rare.
- Quiet 7 % grey pills for outlets; one black pill per screen for the main action.
- Type scale (design pass 2026-10-28): headlines 34 (story page, reel), 24 (cards, receipt),
  20 (brief and coverage rows). Text weights regular, medium for emphasis; no semibold or bold.
  Every size is a text style (scales with the text-size setting), mono at `.caption` or
  `.caption2` at the smallest, never a fixed point size.
- Controls: `.swissPrimary` / `.swissSecondary` for actions (the reel is dark, so its primary
  shows white). `SelectablePillStyle` for choices: an ink outline means "selected", never an
  action. `.roundIcon` for close and remove (32 pt circle, 44 pt touch area). Small pills use
  `pillHeight()`. Tile padding 14 for list tiles, 18 for content panels (AI read, receipt,
  coverage spectrum). List bullets are `BulletDot`, centred on the first line's x-height.
