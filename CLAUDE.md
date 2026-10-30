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
`nonisolated`). **Phone-first:** each iPhone fetches its chosen outlets' RSS feeds itself
(`FeedFetcher`); no news passes through a newnew server. `NEWNEW_FEED_URL` in `project.yml`
(https://bleed.github.io/newnew/index.json, repo github.com/Bleed/newnew) only names the folder
that holds `outlets.json` (the outlets and their feed addresses). Set it empty to use
`Newnew/Resources/sample_news.json` instead (invented outlets; times moved up to "now").
Switching source clears stored articles (`storedSource` "phone-1" wiped what builds ≤ 32
downloaded). Feed health: https://bleed.github.io/newnew/status.json. Builds ≤ 32 read
index.json, which is no longer published: they show no new news.

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
| `github-scraper/` | Node job → `public/outlets.json`, `status.json`, `privacy.html`, breaking pushes; feeds in `feeds.json` |
| `.github/workflows/update_feed.yml` | Runs the job at :07 and :37 and deploys `public/` to GitHub Pages |

## Reading feeds (on the iPhone)

- `FeedFetcher` reads the chosen outlets' feeds (`OutletStore.chosenFeeds`), 12 at a time, each
  up to 1.5 MB (podcast feeds run to 20 MB; the newest episodes come first) and at most 60
  items, through a URLSession whose cache revalidates (ETag / Last-Modified). Same rules the
  server had: last 48 h (charts 14 days), 30 per news feed, 8 per light-pillar feed, 15 per
  light category with outlets taking turns (Technology uncapped), deduped by link and by outlet
  + headline, snippets ≤ 150 characters at a word, tracking parameters stripped, BBC
  thumbnails upgraded to 976 wide, galleries from light-pillar items, YouTube titles without
  channel tags, HD thumbnail (`maxresdefault`, HEAD-checked once per video, else `hqdefault`),
  podcasts with audio and length and no picture, for 7 days (most are weekly; the store keeps
  episodes 7 days too). Megaphone episodes have no page: their audio URL is the link. Items with no picture get one from the page
  later (LinkPresentation, as before).
- Measured in the Simulator: 95+ default feeds answer in ~6 s. Podcasts are off by default
  (each chosen on its own); without them a full refresh is a few MB.
- `FeedParser` (in Outlets.swift) is shared with own feeds (`CustomFeedReader`).
- Own feeds are named after the site their articles link to (`CustomFeedReader.named`): the
  feed's title, or its part, when it names that site ("World | The Guardian" → "The Guardian",
  "NYT > Top Stories" → "NYT", initials count: "Financial Times" for ft.com); else the site's
  page name (og:site_name, application-name, the page title's part, never a bot-check page's)
  when it names the site or agrees with the feed's title ("Hacker News"); else the domain,
  capitalised ("ft.com" → "FT", "bbc.co.uk" → "BBC", "x.substack.com" → "X"). Existing feeds
  are checked once per launch when the outlet list refreshes.
- Podcasts: Listen (card, in brief, the story page's episodes) opens the episode in Apple
  Podcasts when the app is there: `PodcastLinks` finds the show by name in the iTunes Search
  API and the episode by its audio file's name (redirects stripped) or title, then opens
  podcasts.apple.com/podcast/id…?i=… as a universal link; otherwise it plays in newnew.
- Dot chips use pitch 1.4, the board's small size.
- `lastSyncAt` (UserDefaults) drives `hasALotToLoad` (nothing stored, or > 3 h since).
- Background refresh (`BackgroundRefresh`, Settings › Background refresh): Wi-Fi (default),
  Always, Off. The BGAppRefresh task (`Alerts.refreshTaskID`, every ≥ 30 min, iOS decides) and
  the sync a breaking push triggers both check `BackgroundRefresh.allowedNow()`: not Off, a
  network, not Low Data Mode, and not an expensive (mobile/hotspot) path unless Always.
  Estimate: a few MB a refresh with podcasts off, ~10–40 MB a day on Always.

## Server job (github-scraper)

- Publishes only `outlets.json` (each outlet: categories, kinds, `feeds` [url, category, kind,
  country]), `status.json` (each feed's health) and `privacy.html`. No news.
- Breaking push: reads the news feeds' headlines in memory (not light pillars, videos or
  podcasts), finds stories many outlets report (alerts.mjs) and sends them via CloudKit.
  `alerts.json` keeps only the pushed stories' keywords and times (`PREVIOUS_ALERTS_URL`).
- After changing `feeds.json`, copy `public/outlets.json` to `Newnew/Resources/outlets.json`
  (pretty-printed) so a first launch offline has it. The app ignores a published list without
  feed addresses.

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
  outlet, where "why it matters" can be the model's guess. `FeedFetcher` caps the lighter
  pillars (8 per feed; 15 per category, outlets taking turns; Technology uncapped by category)
  and leaves news whole, because the clusterer needs every outlet. The brief's suggested
  0.72 cosine clustering threshold was not adopted: the tuned 0.12 linkage above is stricter.
- **Outlets** (legal basis: the reader picks the sources; newnew shows headlines and short
  extracts and links out). First launch shows onboarding (`OnboardingView`, Figma page
  Onboarding): welcome, choose outlets (grouped by pillar, all checked to start except
  podcasts, a group's "All"/"None"; each pillar lists its podcasts under "Podcasts", chosen one
  by one), add your own feed, alerts. `OutletStore` keeps the choice (`outlets.chosen`,
  nil = not chosen yet = every outlet but the podcasts) and own feeds (`outlets.custom`) in UserDefaults.
  The catalog is `outlets.json` (each outlet's categories, kinds and feeds), with a bundled
  copy in Resources for an offline first launch. Only chosen outlets' feeds are fetched;
  `applyOutletChoice` deletes articles of outlets dropped and syncs when outlets were added. Own feeds are found and
  read on the iPhone (`CustomFeedReader`: a site's `<link rel="alternate">` or the usual
  paths; RSS and Atom), like every feed. Settings › Outlets has the same picker and the
  add-your-own panel. YouTube channels too: their feed's `yt:videoId` makes the items videos
  (Watch, play mark, `hqdefault` thumbnail), Shorts are skipped. In the EU YouTube puts a
  cookie-consent page before channel pages, so an @handle can't be looked up from the phone;
  newnew doesn't answer it, it asks for the channel ID (`UC…`, or a /channel/ link) and builds
  `feeds/videos.xml?channel_id=` from that. Each group in the picker suggests a few YouTube
  channels (`YouTubeSuggestions`, IDs checked 2026-10-29); checking one adds it as an own feed.
  Links open the publisher's app first (`LinkOpener`: universal links only, so YouTube, NYT,
  Guardian…), falling back to the in-app browser. Breaking push still covers all news outlets (the server job doesn't
  know a reader's choice).
- **Regions** (`RegionTagger`): a word list of places, people and institutions per region
  (Europe, US, Middle East, Asia). A story is in a region when ≥ ⅓ of its articles are. The
  filter bar is All, the pillars, then the topics you follow (`FeedFilter`, pinned while
  scrolling); choosing Briefing shows a row of regions, which narrow the news. A topic filter
  shows the stories that topic raised. There is no Local region (removed on request);
  local-news outlets still carry `country` from feeds.json.
- **Top edge of Today**: a page-coloured strip covers the status bar and toolbar area at every
  scroll position (scroll edge effect is off), so nothing shows behind the clock or buttons.
- **Filters on Today**: changing filter while the bar is pinned scrolls to `topHeight + 12` a
  frame later (and again 120 ms on if the bar didn't pin: the top's height changes with the
  filter), so the filter starts at its first story (ScrollPosition offsets count from the
  page top; scrolling to the pinned header itself is a no-op). The pill row keeps the chosen
  pill centred with `scrollPosition(id:)`, so its ForEach ids must be the filters' `raw`
  strings. A sideways swipe between filters was tried (2026-10-29) and removed: it didn't feel
  like the story pager, and measuring pill positions for it made the bar redraw endlessly.
- **Adding a topic** shows at once as a pending row ("Writing example headlines…", "Reading
  the examples…", "Matching today's stories…") while the field's dot chip rolls THINKING →
  LEARNING → MATCHING (`TopicStep`); matching holds the main actor, so the step is drawn first.
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

- newnew publishes no news: each iPhone reads the publishers' public feeds itself, like any RSS
  reader, and keeps extracts to 150 characters. Pictures are the publisher's own files.
- Photos are never full screen: the Catchup reel shows the picture as a framed card.
- The AI read is written on the reader's iPhone, never published by newnew; it is labelled as
  Apple Intelligence and can be hidden. A report option was tried and removed (2026-10-29).
- Coverage-spectrum badges describe, not judge: SPECIALIST PRESS, GENERAL NEWS, MANY DESKS.
- Privacy policy: lives at https://newnew.news/privacypolicy (the app links there, and so
  should App Store Connect). The text is github-scraper/site/privacy.html, also published with
  the outlet list at https://bleed.github.io/newnew/privacy.html as a copy.
- Mailboxes the app names: feedback@newnew.news, publishers@newnew.news.

## Look (from Atelier CRM)

- The name is lower case: "newnew" (home screen, prompts, accessibility).
- Icon: "new" over "new" in the dot face, reversed (near-white dots on black), from
  `Scripts/render-app-icon.swift`.
- Near-white page (#FAFAFA), grey tiles (#F1F1F1), black in dark mode; type carries contrast.
- Today's top is a small departures board (`NewsTop`, Figma: Explorations · header, C): one quiet
  tile with three dot-face rows, unlit dots at 7 %: the date (muted), the figure (every article
  on the page) and what's new ("18 NEW IN 17 STORIES"). Rows arrive as a departures board 0.12 s
  apart and changed values roll; the tile stops growing at xxxLarge text so rows fit. Under a
  dotted rule, inside the tile, `BoardMessageRows` shows the tap-through messages (TOP with the
  age in grey, CATCHUP, read hidden, hidden by topics) in a small dot face (pitch 1.4) on two
  rows wrapped at words, with an ink arrow; they take turns every 7 s. Each message arrives as
  one departures board read left to right across both rows (`decodesOnChange` replays the
  entrance on new text; `decodeIndexOffset` lets row 2 and the grey age carry on row 1's cell
  count, so the line settles strictly in order). Note: DotText plays its entrance only once
  per view, so views inserted later skip it; keep the views and change their text instead.
  `DotFont.boardText` makes headlines drawable (accents, curly quotes, dashes). The one-sentence top (`OneSentenceTop`) is still used by the read
  summary at the end of a swipe run.
- Settings › Look (`TopLook`, key "topLook", in TopFaces.swift) picks Today's top: Dots (the
  board above, default), LCD (Figma: Explorations · LCD, P: the same board, its cells drawn as
  14-segment glyphs by `LCDFont` through `\.boardFace`, unlit segments faint, same timing) or
  Blocks (Figma V: what's new, "32 NEW", in `BlockText` across the full width, no tile; date,
  count, detail and `MonoMessageRow` in SF Mono Regular). Blocks arrive like the dot face:
  cells 0.025 s apart roll through random blocks every 0.06 s and settle left to right.
- The story page's headline is plain text; the "Headline from X ↗" pill under it is the link
  (a headline button caught swipes).
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
