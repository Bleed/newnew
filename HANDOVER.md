# newnew: handover

Last updated 10 Nov 2026.

## 1. What it is and status

newnew is an iPhone and iPad news app with $0 server cost. Each device reads the chosen outlets' public RSS feeds itself. It groups headlines into stories on the device. A tap asks Apple Intelligence to compare how outlets cover a story. It always links out to the publisher and never stores or shows full articles.

Status: in TestFlight. The latest build is **51** (`CURRENT_PROJECT_VERSION` in `project.yml`, commit "Build 51", 8 Nov 2026). I could not check App Store Connect, so I do not know which build was last uploaded. The app is not shipped to the App Store as far as the repo shows.

A small Node job on GitHub Actions publishes the outlet list and feed health to GitHub Pages and sends breaking-news pushes. See `github-scraper/`.

## 2. Set up on a new Mac

**Where the code lives.** Clone it outside iCloud Drive, for example `~/Developer/Newnew`. This folder is in iCloud-synced Documents. iCloud file attributes break codesigning of build output.

**Tools**
- Xcode with the iOS 26 SDK (Swift 6, deployment target iOS 26.0).
- XcodeGen: `brew install xcodegen`.
- Node 20 or newer, only if you want to run the scraper locally (the workflow uses Node 22).
- `gh` (GitHub CLI) is handy but optional.

**Accounts and signing**
- Apple Account signed in to Xcode. Team ID `W533Y4V578` (Mutiny AS). Signing is automatic.
- Bundle ID `com.svein.newnew`. App Store Connect app: "newnew: News, Grouped", SKU `newnew-ios`.
- iCloud container `iCloud.com.svein.newnew` (CloudKit, used for breaking pushes). The app also uses iCloud key-value sync between devices (`CloudSync.swift`). Entitlements are in `Newnew/App/Newnew-CloudKit.entitlements`.
- Internal TestFlight group "Team" receives every upload automatically.

**Secrets and services (names only)**
- Private key file `~/.newnew-cloudkit/eckey.pem` on the old Mac. It is the CloudKit Production server-to-server key ("newnew scraper (GitHub Action)"). It is not in git. **Copy it to the new Mac** (or make a new key in the CloudKit Dashboard and update the GitHub secrets).
- GitHub repo secrets `CLOUDKIT_KEY_ID` and `CLOUDKIT_PRIVATE_KEY`, and variables `CLOUDKIT_CONTAINER` and `CLOUDKIT_ENVIRONMENT` (production). These live on GitHub, so nothing to move.
- GitHub Pages must have Source set to "GitHub Actions" (already a one-time setting).
- Domain `newnew.news` serves the privacy policy (`/privacypolicy`) and the mailboxes feedback@ and publishers@. Where that domain is hosted is not documented in the repo.
- No paid APIs. No API keys are needed to build the app.

**Get the project**
```bash
git clone https://github.com/Bleed/newnew.git ~/Developer/Newnew
cd ~/Developer/Newnew
xcodegen generate
open Newnew.xcodeproj
```
`Newnew.xcodeproj` is generated and git-ignored. Change settings in `project.yml`, not in Xcode.

## 3. Build, run, test, release

- **Run:** open the generated project, pick the `Newnew` scheme, run on a simulator or device. Foundation Models (Apple Intelligence) needs a supported device or Mac setting. Without it the app shows a headlines-only preview.
- **Sample data:** set `NEWNEW_FEED_URL` to empty in `project.yml` to use `Newnew/Resources/sample_news.json` (invented outlets).
- **Release build, local only:** `Scripts/release.sh` archives and exports to `build/release/iOS`. Nothing leaves the Mac.
- **Upload to TestFlight:** `Scripts/release.sh --upload`. Bump `CURRENT_PROJECT_VERSION` in `project.yml` first. Only upload when asked (house rule).
- If xcodebuild says "Failed to Use Accounts", open the archive in Xcode Organizer and upload from there.
- `release.sh` keeps derived data in `$TMPDIR/newnew-release`, outside iCloud.
- **Scraper locally:** `cd github-scraper && npm ci && npm run poll` (runs `scripts/poll_feeds.mjs`, writes to `public/`).
- **App icon:** `swift Scripts/render-app-icon.swift <out.png>`, then copy to `Newnew/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. The icon must stay opaque (no alpha).
- There is no test target. Testing was done in the Simulator and with launch arguments (see CLAUDE.md).

## 4. Where things stand

**Works (per CLAUDE.md and git log):** phone-side feed reading, on-device clustering into stories, topics (follow/mute), Apple Intelligence briefs, Catchup reel, iPad front page, podcasts, background refresh, breaking push (first worked 28 Oct 2026), and iCloud sync of outlets, own feeds, topics, read stories and the look between devices (commit 5590082, 8 Nov).

**Last worked on:** iCloud key-value sync between devices, read stories staying read after a regroup, removal of Zen mode (Today always opens as the feed), builds 48 to 51.

**Open items.** The repo holds no TODO list, so these are things I noticed:
- `CLAUDE.md` still describes Zen mode, editions and the `TodayMode` setting, but the code removed them in commit 3c73017. Those paragraphs are out of date.
- Confirm in App Store Connect which build is the newest upload, and that the privacy policy URL is set there.
- The scheduled workflow pauses after 60 days without repo activity. Re-enable it under Actions if the outlet list or pushes stop.
- After changing `github-scraper/feeds.json`, copy `public/outlets.json` to `Newnew/Resources/outlets.json` (pretty-printed).

## 5. Key files

| Path | What |
| --- | --- |
| `CLAUDE.md` | Full project notes (about 400 lines). Read it first. |
| `project.yml` | XcodeGen config: build number, team, feed URL, CloudKit container |
| `Newnew/App/` | `NewnewApp.swift`, `Info.plist`, entitlements, privacy manifest |
| `Newnew/Services/FeedFetcher.swift`, `Outlets.swift` | Phone-side RSS reading, outlet list, feed parser |
| `Newnew/Services/StoryClusterer.swift`, `FeedSyncPipeline.swift` | Grouping articles into stories, sync flow |
| `Newnew/Services/IntelligenceService.swift` | Apple Intelligence briefs |
| `Newnew/Services/Alerts.swift`, `BackgroundRefresh.swift`, `CloudSync.swift` | Alerts, background refresh, iCloud sync |
| `Newnew/Models/` | SwiftData models and feed types |
| `Newnew/Views/` | Feed, story card and page, Catchup reel, iPad front page, onboarding |
| `Newnew/Design/` | Swiss tokens, 5x7 dot face, loading board |
| `Newnew/Resources/` | `outlets.json` (offline copy), `sample_news.json`, assets |
| `github-scraper/scripts/poll_feeds.mjs`, `alerts.mjs` | Feed health, `outlets.json`, breaking pushes |
| `github-scraper/feeds.json` | The outlets and their feed addresses |
| `github-scraper/site/privacy.html` | Privacy policy text |
| `.github/workflows/update_feed.yml` | Runs at :07 and :37, deploys to GitHub Pages |
| `Scripts/release.sh`, `Distribution/ExportOptions.plist` | Archive, export, upload |

## 6. Pitfalls and house rules

**Pitfalls already met**
- Building inside iCloud Drive breaks signing. Keep the clone outside it.
- A build number changed in Xcode is lost at the next `xcodegen generate`. Edit `project.yml`.
- CloudKit refused Production subscriptions (CKError 12) until the subscription was created once in Development (a Debug build run from Xcode) and the schema was deployed again. Any new subscription type needs the same step.
- Server keys belong to one CloudKit environment. A Development test needs its own key.
- SwiftData must stay local (`cloudKitDatabase: .none`). With the iCloud entitlement it otherwise tries to sync and crashes at launch.
- Never read `SystemLanguageModel.default.availability` from a view body. It caused a redraw loop. Use `IntelligenceService.isAvailable`.
- Apple's guardrails refuse much hard news. Briefs retry with permissive settings, then fall back to a headlines preview. Never show the raw model error.
- Computed properties re-run on every read froze the feed with 400+ stories. Use `FeedSections`.
- Embedding cosine scores from the brief's numbers merge everything. The code uses centred vectors and tuned thresholds (see CLAUDE.md "Matching").

**House rules (CLAUDE.md "Rules" and "Look")**
- No paid cloud or AI APIs. Apple frameworks only.
- Bulk work uses only NaturalLanguage and Accelerate. FoundationModels runs on a tap and its result is cached.
- News pictures go through `ImagePipeline`, never `AsyncImage`. No blurs or shadows in rows.
- Wrap FoundationModels in `#if canImport(FoundationModels)`.
- The name is lower case: "newnew". SF Mono figures only Light or Regular. The 5x7 dot face only inside containers, never loose and never for warnings.
- Photos are never shown full screen. Extracts stay at 150 characters.
- Do not upload TestFlight builds until Svein says so. During design rounds, change only Figma until approved.

## 7. Git

- Remote: `origin` = https://github.com/Bleed/newnew.git. Branch `main`.
- Checked 10 Nov 2026: the working tree is clean and `main` matches `origin/main`. Everything is committed and pushed (128 commits, latest "Build 51").
- Not in git, so carry it over by hand: `~/.newnew-cloudkit/eckey.pem`. The `build/` folder, the generated `Newnew.xcodeproj` and `github-scraper/node_modules` and `public` are git-ignored and can be rebuilt.
