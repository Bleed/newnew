import SwiftData
import SwiftUI

/// What happens to a story once you've read it (settings pane): it leaves Today, or it stays in
/// place, greyed out and sunk below what's new.
enum ReadStories: String, CaseIterable, Identifiable {
  case disappear, stay

  static let key = "readStories"
  var id: String { rawValue }

  var label: String {
    switch self {
    case .disappear: "Disappear"
    case .stay: "Stay, greyed out"
    }
  }
}

/// Selectable time window for how far back news is served in the feed.
enum NewsWindow: Int, CaseIterable, Identifiable {
  case h12 = 12
  case h24 = 24
  case h48 = 48
  case h72 = 72

  var id: Int { rawValue }

  var shortLabel: String { "\(rawValue)h" }

  var menuLabel: String {
    switch self {
    case .h12: "12 hours"
    case .h24: "24 hours"
    case .h48: "48 hours"
    case .h72: "72 hours"
    }
  }

  var interval: TimeInterval { TimeInterval(rawValue * 3600) }
}

/// Persistent read & update tracker that writes immediately to UserDefaults and flushes SwiftData
/// so quitting or backgrounding the app never loses which stories (and which articles) you've seen.
///
/// Read once into memory: `status(for:)` runs for every story on each feed refresh and every
/// card, and decoding UserDefaults each time got slower as the lists grew. Entries older than a
/// week are let go (articles themselves go after 72 hours).
@MainActor @Observable final class ReadLedger {
  static let shared = ReadLedger()

  private static let readTimesKey = "persistedClusterReadTimes_v1"
  /// URL → when it was seen; v1 kept a plain list with no times, so it could never be pruned.
  private static let seenURLsKey = "persistedSeenArticleURLs_v2"
  private static let legacySeenURLsKey = "persistedSeenArticleURLs_v1"
  private static let keep: TimeInterval = 7 * 24 * 3600

  /// Increments every time a cluster is marked read so `FeedView` always recomputes `sections`.
  var revision: Int = 0

  private static var readTimes: [String: Double] = loadReadTimes()
  private static var seenURLs: [String: Double] = loadSeenURLs()

  private static func loadReadTimes() -> [String: Double] {
    let stored = (UserDefaults.standard.dictionary(forKey: readTimesKey) as? [String: Double]) ?? [:]
    let pruned = stored.filter { Date.now.timeIntervalSince1970 - $0.value < keep }
    if pruned.count != stored.count { UserDefaults.standard.set(pruned, forKey: readTimesKey) }
    return pruned
  }

  private static func loadSeenURLs() -> [String: Double] {
    let defaults = UserDefaults.standard
    var stored = (defaults.dictionary(forKey: seenURLsKey) as? [String: Double]) ?? [:]
    // From v1: the URLs count as seen now, and age out a week from now.
    if let legacy = defaults.stringArray(forKey: legacySeenURLsKey) {
      let now = Date.now.timeIntervalSince1970
      for url in legacy where stored[url] == nil { stored[url] = now }
      defaults.removeObject(forKey: legacySeenURLsKey)
    }
    let pruned = stored.filter { Date.now.timeIntervalSince1970 - $0.value < keep }
    defaults.set(pruned, forKey: seenURLsKey)
    return pruned
  }

  static func record(_ cluster: StoryCluster) {
    let now = Date.now
    let nowStamp = now.timeIntervalSince1970

    // Ensure SwiftData model's own readAt and article flags are updated too
    cluster.readAt = now
    for article in cluster.articles {
      article.isRead = true
    }

    readTimes[cluster.id.uuidString] = nowStamp
    if let leadURL = cluster.lead?.url {
      readTimes[leadURL] = nowStamp
    }
    UserDefaults.standard.set(readTimes, forKey: readTimesKey)

    for article in cluster.articles where seenURLs[article.url] == nil {
      seenURLs[article.url] = nowStamp
    }
    UserDefaults.standard.set(seenURLs, forKey: seenURLsKey)

    try? cluster.modelContext?.save()
    shared.revision &+= 1
  }

  /// Returns the most recent time the user read this cluster across both SwiftData and UserDefaults.
  static func lastReadDate(for cluster: StoryCluster) -> Date? {
    var latest: Date? = cluster.readAt
    let times = readTimes
    if let t = times[cluster.id.uuidString] {
      let d = Date(timeIntervalSince1970: t)
      if latest == nil || d > latest! { latest = d }
    }
    if let leadURL = cluster.lead?.url, let t = times[leadURL] {
      let d = Date(timeIntervalSince1970: t)
      if latest == nil || d > latest! { latest = d }
    }
    return latest
  }

  /// Articles that arrived in this cluster *after* you last read it.
  static func unseenArticles(in cluster: StoryCluster) -> [ArticleItem] {
    guard let readDate = lastReadDate(for: cluster) else { return [] }
    return cluster.sortedArticles.filter { article in
      seenURLs[article.url] == nil && article.publishedAt > readDate && article.fetchedAt > readDate
    }
  }

  /// The newest article that triggered the "Updated" state.
  static func latestUpdateArticle(in cluster: StoryCluster) -> ArticleItem? {
    unseenArticles(in: cluster).first
  }

  enum Status {
    case unread
    case updated(newCount: Int, latest: ArticleItem)
    case settledRead
  }

  static func status(for cluster: StoryCluster) -> Status {
    guard lastReadDate(for: cluster) != nil else { return .unread }
    let unseen = unseenArticles(in: cluster)
    if let latest = unseen.first {
      return .updated(newCount: unseen.count, latest: latest)
    }
    return .settledRead
  }
}

@MainActor extension StoryCluster {
  /// Compact label for the green `SignalBadge` pill on `StoryCard` (e.g., "6 new · The New York Times").
  var updatePillLabel: String? {
    guard case .updated(let count, let latest) = ReadLedger.status(for: self) else {
      return nil
    }
    return "\(count) new · \(latest.outlet)"
  }

  /// The headline of the newest update article, if this story has new coverage since it was read.
  var latestUpdateHeadline: String? {
    guard case .updated(_, let latest) = ReadLedger.status(for: self) else { return nil }
    return latest.title
  }
}

/// Today: the one-sentence top (what's new since you last looked, and the top story), the
/// filter bar (All, the pillars, then the topics you follow; regions inside Briefing), then top
/// stories and stories in brief. On All the top stories mix the pillars by share, most
/// important first within each (see `FeedSections.balanced`).
struct FeedView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \StoryCluster.updatedAt, order: .reverse) var clusters: [StoryCluster]
  @AppStorage("lastLookedAt") var lastLookedAt: Double = 0
  /// Read stories disappear (the default) or stay greyed out; see `ReadStories`.
  @AppStorage(ReadStories.key) var readStoriesRaw = ReadStories.disappear.rawValue
  /// With read stories set to disappear: starts `true` so they leave cleanly and trigger the
  /// Edition Complete card. Temporarily flips to `false` only when you tap "Review read stories"
  /// or the "Read" pill. Ignored when they stay.
  @State private var hideRead = true
  var readStoriesDisappear: Bool { ReadStories(rawValue: readStoriesRaw) != .stay }
  /// Whether read stories are out of the feed right now.
  var hidingRead: Bool { readStoriesDisappear && hideRead }
  /// How far back news is served (12, 24, 48, or 72 hours), configured in the settings pane. Defaults to 24 hours.
  @AppStorage("newsWindowHours") var newsWindowHours: Int = NewsWindow.h24.rawValue
  @Environment(\.scenePhase) var scenePhase
  @State private var topicsKind: TopicKind?
  @State private var showingCatchup = false
  @State private var path: [StoryCluster] = []
  @AppStorage("feedFilter") var filterRaw = FeedFilter.all.raw
  @Query(sort: \SemanticTopic.createdAt) var topics: [SemanticTopic]
  /// Held while the page is open, so the count doesn't drop to zero as you read.
  @State private var since: Date?

  /// Cached feed sections so scrolling or geometry changes never re-sort 400+ SwiftData clusters.
  @State private var sections = FeedSections()

  var newsWindow: NewsWindow {
    NewsWindow(rawValue: newsWindowHours) ?? .h24
  }

  var followedTopics: [String] { topics.filter { $0.kind == .follow }.map(\.phrase) }
  /// The chosen filter; a topic you've since unfollowed falls back to All.
  var filter: FeedFilter {
    let filter = FeedFilter(raw: filterRaw)
    if case .topic(let phrase) = filter, !followedTopics.contains(phrase) { return .all }
    return filter
  }

  static let headerTop: CGFloat = 24
  static let headerBelowBand: CGFloat = 42
  /// Where Today is scrolled, to start a filter at its top.
  @State private var scrollPosition = ScrollPosition()
  /// The filter bar's frame on screen: a sideways swipe that starts on it scrolls its pills,
  /// not the filters.
  @State private var barFrame: CGRect = .zero
  /// A sideways swipe is under way: the card under the finger mustn't open on release.
  @State private var swiping = false
  /// Where the bar pins, counted from the top of the page.
  var pinOffset: CGFloat { topHeight + 12 }
  @State private var boardShowing = false
  @State private var barPinned = false
  /// The top's height with its padding: the filter bar pins once the page has scrolled this far
  /// (plus the stack's 12 pt spacing). Measured, so it holds on every iPhone and text size.
  @State private var topHeight: CGFloat = 0

  private var sectionsCacheKey: Int {
    var hasher = Hasher()
    hasher.combine(filterRaw)
    hasher.combine(hidingRead)
    hasher.combine(newsWindowHours)
    hasher.combine(ReadLedger.shared.revision)
    hasher.combine(clusters.count)
    hasher.combine(clusters.first?.updatedAt)
    hasher.combine(topics.count)
    for c in clusters.prefix(120) {
      hasher.combine(c.id)
      hasher.combine(c.isMuted)
      hasher.combine(c.readAt)
      hasher.combine(c.followedBy)
    }
    return hasher.finalize()
  }

  var body: some View {
    let visible = sections.visible, wide = sections.wide
    let brief = sections.brief, hiddenCount = sections.hiddenCount
    let readHiddenCount = sections.readHiddenCount
    let settledReadTotal = sections.settledReadTotal

    NavigationStack(path: $path) {
      ScrollViewReader { _ in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
            NewsTop(
              since: since ?? .distantPast,
              visible: visible,
              top: wide.first,
              catchupCount: min(wide.count, 8),
              hiddenCount: hiddenCount,
              readHiddenCount: readHiddenCount
            ) {
              path.append($0)
            } openCatchup: {
              showingCatchup = true
            } showMutes: {
              topicsKind = .mute
            } showRead: {
              withAnimation(.snappy(duration: 0.2)) { hideRead = false }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, boardShowing ? Self.headerBelowBand : Self.headerTop)
            .padding(.bottom, 18)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }

            // Stays at the top while the stories scroll under it.
            Section {
              if clusters.isEmpty {
                emptyState
              } else if visible.isEmpty {
                if readHiddenCount > 0 {
                  allRead.padding(.top, 6)
                } else {
                  Text("Nothing on \(filter.title) right now.")
                    .font(.subheadline)
                    .foregroundStyle(Swiss.muted)
                }
              }
              if !wide.isEmpty {
                Eyebrow("Top stories").padding(.top, 4)
                ForEach(wide) { cluster in
                  Button { open(cluster) } label: { StoryCard(cluster: cluster) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(cluster) }
                }
              }
              if !brief.isEmpty {
                Eyebrow("In brief").padding(.top, 16)
                ForEach(brief) { cluster in
                  Button { open(cluster) } label: { BriefRow(cluster: cluster) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(cluster) }
                }
              }
              if !visible.isEmpty && (hiddenCount > 0 || readHiddenCount > 0 || (readStoriesDisappear && !hideRead)) {
                VStack(spacing: 8) {
                  if readHiddenCount > 0 {
                    Button("\(readHiddenCount) read \(readHiddenCount == 1 ? "story" : "stories") hidden · Show") {
                      withAnimation(.snappy(duration: 0.2)) { hideRead = false }
                    }
                    .font(.footnote)
                    .foregroundStyle(Swiss.muted)
                  } else if readStoriesDisappear && !hideRead && settledReadTotal > 0 {
                    Button("Showing \(settledReadTotal) read \(settledReadTotal == 1 ? "story" : "stories") · Hide read") {
                      withAnimation(.snappy(duration: 0.2)) { hideRead = true }
                    }
                    .font(.footnote)
                    .foregroundStyle(Swiss.muted)
                  }
                  if hiddenCount > 0 {
                    Button("\(hiddenCount) \(hiddenCount == 1 ? "story" : "stories") hidden by your topics") {
                      topicsKind = .mute
                    }
                    .font(.footnote)
                    .foregroundStyle(Swiss.muted)
                  }
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
              }
            } header: {
              FilterBar(
                selection: Binding(get: { filter }, set: { choose($0) }),
                hideRead: $hideRead,
                // The Read pill shows or hides read stories; with them staying there is nothing to toggle.
                readCount: readStoriesDisappear ? settledReadTotal : 0,
                showsReadToggle: readStoriesDisappear,
                topics: followedTopics
              )
              .padding(.vertical, 10)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.feedSpace)) } action: { barFrame = $0 }
              .background(alignment: .bottom) {
                if barPinned {
                  Swiss.canvas
                    .frame(height: 400)
                    .padding(.horizontal, -Swiss.pageInset)
                    .allowsHitTesting(false)
                }
              }
            }
          }
          .padding(.horizontal, Swiss.pageInset)
          .padding(.bottom, 32)
        }
        // Pinned once the page has scrolled past the top. Offset plus the top inset is the
        // distance from rest, with or without the loading band. Reported as a Bool, so the page
        // only redraws when the bar pins or unpins, not on every frame of a scroll.
        .onScrollGeometryChange(for: Bool.self) { geometry in
          topHeight > 0 && geometry.contentOffset.y + geometry.contentInsets.top >= topHeight + 12 - 1
        } action: { _, isPinned in
          barPinned = isPinned
        }
        .coordinateSpace(.named(Self.feedSpace))
        // Sideways: the next or previous filter, as in the bar.
        .scrollPosition($scrollPosition)
        .simultaneousGesture(
          DragGesture(minimumDistance: 20, coordinateSpace: .named(Self.feedSpace))
            .onChanged { value in
              if !swiping, !barFrame.contains(value.startLocation), abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                swiping = true
              }
            }
            .onEnded { value in
              let dx = value.translation.width, dy = value.translation.height
              // After the card's button has seen the release.
              Task { @MainActor in swiping = false }
              guard !barFrame.contains(value.startLocation), abs(dx) > 70, abs(dx) > abs(dy) * 2.2 else { return }
              step(dx < 0 ? 1 : -1)
            }
        )
        .sensoryFeedback(.selection, trigger: filterRaw)
        .onChange(of: filterRaw) {
          recomputeSections()
          // A filter starts at its top: the bar pinned, its first story under it. From higher
          // up the page the top of the list is already in view. A frame later, once the new
          // list (and the top above it, whose lines change with the filter) is laid out.
          if barPinned {
            Task { @MainActor in
              await Task.yield()
              scrollPosition.scrollTo(y: pinOffset)
            }
          }
        }
      }
      .swissCanvas()
      .navigationTitle("Today")
      .navigationBarTitleDisplayMode(.inline)
      // No fade at the top: the pinned filter bar covers what scrolls under it.
      .scrollEdgeEffectHidden(true, for: .top)
      .dotRefreshable(isSyncing: pipeline.isSyncing, isShowing: $boardShowing) { await pipeline.sync() }
      .navigationDestination(for: StoryCluster.self) { initialCluster in
        StoryPagerView(
          initialCluster: initialCluster,
          orderedClusters: wide + brief
        )
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Catchup", systemImage: "rectangle.portrait.on.rectangle.portrait.angled") {
            showingCatchup = true
          }
          .disabled(wide.isEmpty)
        }
        // Nothing in the middle: the page's own top is the title.
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
          .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
          Button("Topics", systemImage: "line.3.horizontal.decrease") { topicsKind = .follow }
        }
      }
      .sheet(item: $topicsKind) { TopicsSheet(kind: $0) }
      .fullScreenCover(isPresented: $showingCatchup) {
        CatchupReelView(stories: Array(wide.prefix(8))) { chosenCluster in
          path.append(chosenCluster)
        }
      }
    }
    .tint(Swiss.ink)
    .onAppear {
      if since == nil { since = Date(timeIntervalSince1970: lastLookedAt) }
      recomputeSections()
      CatchupImagePreloader.shared.preload(clusters: Array(sections.wide.prefix(8)))
      openRoutedStory()
    }
    .onChange(of: readStoriesRaw) {
      hideRead = true
      recomputeSections()
    }
    .onChange(of: hideRead) {
      recomputeSections()
    }
    .onChange(of: sectionsCacheKey) {
      if path.isEmpty {
        recomputeSections()
        CatchupImagePreloader.shared.preload(clusters: Array(sections.wide.prefix(8)))
      }
    }
    .onChange(of: path) { _, newPath in
      if newPath.isEmpty {
        recomputeSections()
      }
    }
    .onChange(of: Router.shared.storyID) { openRoutedStory() }
    .onChange(of: Router.shared.articleURL) { openRoutedStory() }
    // A pushed story may only be grouped after the sync it triggered.
    .onChange(of: clusters.count) { openRoutedStory() }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        lastLookedAt = Date.now.timeIntervalSince1970
      case .active:
        since = Date(timeIntervalSince1970: lastLookedAt)
        recomputeSections()
      default: break
      }
    }
  }

  private func recomputeSections() {
    withAnimation(.snappy(duration: 0.22)) {
      sections = FeedSections(clusters: clusters, filter: filter, hideRead: hidingRead, window: newsWindow)
    }
  }

  /// A tapped alert: open its story.
  func openRoutedStory() {
    #if DEBUG
      // Debug builds only: launch with -openLastStory to land on the last story, one swipe from
      // the end-of-run page.
      if ProcessInfo.processInfo.arguments.contains("-openLastStory"), path.isEmpty,
        let last = (sections.wide + sections.brief).last
      {
        path = [last]
        return
      }
    #endif
    let router = Router.shared
    if let id = router.storyID, let cluster = clusters.first(where: { $0.id == id }) {
      router.storyID = nil
      path = [cluster]
    } else if let url = router.articleURL, let cluster = clusters.first(where: { $0.articles.contains { $0.url == url } }) {
      router.articleURL = nil
      path = [cluster]
    }
  }

  static let feedSpace = "feed"

  func open(_ cluster: StoryCluster) {
    guard !swiping else { return }
    path.append(cluster)
  }

  /// The filters in the bar's order, for swiping: All, the pillars, the topics you follow.
  var swipeOrder: [FeedFilter] { [.all] + Pillar.allCases.map { .pillar($0) } + followedTopics.map { .topic($0) } }

  func choose(_ next: FeedFilter) {
    // Switching filters always hides read stories so the feed is fresh
    if !hideRead { hideRead = true }
    filterRaw = next.raw
  }

  /// One filter on (1) or back (-1); a region counts as Briefing.
  func step(_ by: Int) {
    let current: FeedFilter = if case .region = filter { .pillar(.briefing) } else { filter }
    guard let index = swipeOrder.firstIndex(of: current), swipeOrder.indices.contains(index + by) else { return }
    withAnimation(.snappy(duration: 0.2)) { choose(swipeOrder[index + by]) }
  }

  /// Everything here read: the same summary as at the end of a swipe run.
  var allRead: some View {
    ReadSummary(stories: sections.readClusters, minutes: sections.readingMinutes) {
      Button("Show read stories") {
        withAnimation(.snappy(duration: 0.2)) { hideRead = false }
      }
      .buttonStyle(.swissPrimary)
    }
  }

  var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(pipeline.isSyncing ? "Reading the feed…" : "Nothing here yet")
        .font(.body.weight(.medium))
      if let error = pipeline.lastError {
        Text(error).font(.footnote).foregroundStyle(Swiss.alert)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
  }

  @ViewBuilder func menu(_ cluster: StoryCluster) -> some View {
    Button("Mark as read", systemImage: "checkmark.circle") {
      pipeline.markRead(cluster)
      ReadLedger.record(cluster)
      recomputeSections()
    }
    Button("Follow stories like this", systemImage: "plus.circle") {
      Task {
        await pipeline.addTopic(like: cluster, kind: .follow)
        recomputeSections()
      }
    }
    Button("Mute stories like this", systemImage: "speaker.slash") {
      Task {
        await pipeline.addTopic(like: cluster, kind: .mute)
        recomputeSections()
      }
    }
  }
}

/// Interactive horizontal pager that moves the story page left and right with your finger,
/// while completely ignoring vertical scroll gestures so `StoryDetailView` scrolls at 120Hz.
/// The end of a run of stories swiped through: a rebus top like Today's ("3 STORIES / READ IN
/// 12 MIN / MOST FROM BBC") and a small table of the run in the dot face. Everything counts this
/// run only: the stories opened in this pager since it opened.
///
/// Entrance: the dot lines come in as a departures board (`DotText` board entrance), the table
/// rows one after another (0.12 s apart) with their leader dots drawing in, then the footer.
struct PagerEndPage: View {
  let viewed: [StoryCluster]
  let startedAt: Date
  var backToToday: () -> Void
  var startOver: () -> Void

  var body: some View {
    ScrollView {
      ReadSummary(stories: viewed, minutes: max(1, Int(Date.now.timeIntervalSince(startedAt) / 60))) {
        Button("Back to Today", action: backToToday).buttonStyle(.swissPrimary)
        Button("Start over", action: startOver).buttonStyle(.swissSecondary)
      }
      .padding(.top, 20)
      .padding(.horizontal, Swiss.pageInset)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .swissCanvas()
  }
}

/// What was read, the same at the end of a swipe run (`PagerEndPage`) and at the bottom of
/// Today when every story there is read: a rebus top ("3 STORIES / READ IN 12 MIN / MOST FROM
/// BBC"), a small table in the dot face, and the buttons. The table rows come in one after
/// another (0.12 s apart) as a departures board, then the buttons.
struct ReadSummary<Actions: View>: View {
  let stories: [StoryCluster]
  let minutes: Int
  @ViewBuilder var actions: Actions

  @State private var actionsShown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var articles: [ArticleItem] { stories.flatMap(\.articles) }
  var outlets: Int { Set(articles.map(\.outlet)).count }
  /// The outlet with the most articles, its first word in letters the dot face has.
  var topOutlet: String {
    let counts = Dictionary(articles.map { ($0.outlet, 1) }, uniquingKeysWith: +)
    guard let top = counts.max(by: { $0.value < $1.value })?.key else { return "-" }
    // The first word ("BBC", "GUARDIAN", "VISUAL"), so it fits beside the name with room for
    // the leader dots.
    let words = top.replacingOccurrences(of: "The ", with: "").uppercased().split(separator: " ")
      .map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
    // A name that opens with a filler word goes by its initials: Our World in Data → OWID.
    if let first = words.first, ["OUR", "A", "AN", "MY"].contains(first), words.count > 2 {
      return String(words.compactMap(\.first))
    }
    return words.first.map { String($0.prefix(8)) } ?? "-"
  }

  var rows: [(name: String, value: String)] {
    [("ARTICLES", "\(articles.count)"), ("OUTLETS", "\(outlets)"), ("MOST READ", topOutlet)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      OneSentenceTop(
        figure: "\(stories.count) \(stories.count == 1 ? "STORY" : "STORIES")",
        detail: [.word("READ IN"), .minutes("\(minutes) MIN"), .check],
        messages: [KeyMessage(id: "most", tokens: [.word("MOST FROM"), .pill(topOutlet)])],
        size: 17, figureSize: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)

      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          // In place from the start (added later, rows skipped the decode); each waits its turn.
          ScoreRow(name: row.name, value: row.value, delay: 0.3 + Double(index) * 0.12)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)

      HStack(spacing: 10) { actions }
        .padding(.top, 10)
        .opacity(actionsShown ? 1 : 0)
    }
    .task {
      if reduceMotion {
        actionsShown = true
        return
      }
      try? await Task.sleep(for: .seconds(0.3 + Double(rows.count) * 0.12 + 0.4))
      withAnimation(.easeOut(duration: 0.3)) { actionsShown = true }
    }
    .accessibilityElement(children: .contain)
  }
}

/// One table row: name, leader dots drawing in, the value on the right.
private struct ScoreRow: View {
  let name: String
  let value: String
  /// When this row's turn comes, after the page has landed.
  var delay: Double = 0
  @State private var leader: CGFloat = 0

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      DotText(name, pitch: 2, decodeDelay: delay).fixedSize()
      Canvas { context, size in
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(Swiss.ink.opacity(0.18)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 5]))
      }
      .frame(height: 2)
      .mask(alignment: .leading) { GeometryReader { proxy in Rectangle().frame(width: proxy.size.width * leader) } }
      .padding(.horizontal, 8)
      DotText(value, pitch: 2, decodeDelay: delay + 0.2).fixedSize()
    }
    .foregroundStyle(Swiss.ink)
    .onAppear { withAnimation(.easeOut(duration: 0.35).delay(delay + 0.1)) { leader = 1 } }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(name.lowercased()): \(value)")
  }
}

/// Past the last story there is one more page: the end of the run (`PagerEndPage`).
struct StoryPagerView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.dismiss) private var dismiss
  @State private var stories: [StoryCluster]
  @State private var currentIndex: Int
  @State private var transitionOffset: CGFloat = 0
  @GestureState private var liveDragOffset: CGFloat = 0
  @State private var pageWidth: CGFloat = 400
  /// This run, for the end page: the stories opened since the pager opened, and when.
  @State private var viewedIDs: Set<UUID> = []
  @State private var startedAt = Date.now

  init(initialCluster: StoryCluster, orderedClusters: [StoryCluster]) {
    let list: [StoryCluster]
    if let idx = orderedClusters.firstIndex(where: { $0.id == initialCluster.id }) {
      list = orderedClusters
      _currentIndex = State(initialValue: idx)
    } else {
      list = [initialCluster] + orderedClusters
      _currentIndex = State(initialValue: 0)
    }
    _stories = State(initialValue: list)
    _viewedIDs = State(initialValue: [initialCluster.id])
  }

  private var currentCluster: StoryCluster {
    stories[min(max(currentIndex, 0), stories.count - 1)]
  }

  /// The end page's index, one past the last story.
  private var endIndex: Int { stories.count }
  private var atEnd: Bool { currentIndex >= endIndex }

  var body: some View {
    Group {
      if atEnd {
        PagerEndPage(viewed: stories.filter { viewedIDs.contains($0.id) }, startedAt: startedAt) {
          dismiss()
        } startOver: {
          viewedIDs = [stories[0].id]
          startedAt = .now
          withAnimation(.snappy(duration: 0.25)) { currentIndex = 0 }
        }
        .id("end")
      } else {
        StoryDetailView(cluster: currentCluster)
          .id(currentCluster.id)
      }
    }
      .offset(x: transitionOffset + liveDragOffset)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
        if width > 0 { pageWidth = width }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
          .updating($liveDragOffset) { value, state, _ in
            guard value.startLocation.x > 28 else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard abs(dx) > abs(dy) * 1.5 else { return }

            if (currentIndex == 0 && dx > 0) || (currentIndex == endIndex && dx < 0) {
              state = dx * 0.25
            } else {
              state = dx
            }
          }
          .onEnded { value in
            guard value.startLocation.x > 28 else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard abs(dx) > abs(dy) * 1.5 else { return }

            let predictedDx = value.predictedEndTranslation.width
            let threshold = pageWidth * 0.22

            if (dx < -threshold || predictedDx < -pageWidth * 0.45), currentIndex < endIndex {
              transitionOffset = dx
              withAnimation(.easeOut(duration: 0.14)) {
                transitionOffset = -pageWidth
              }
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                currentIndex += 1
                transitionOffset = pageWidth
                if currentIndex < endIndex {
                  viewedIDs.insert(stories[currentIndex].id)
                  pipeline.markRead(stories[currentIndex])
                  ReadLedger.record(stories[currentIndex])
                }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                  transitionOffset = 0
                }
              }
            } else if (dx > threshold || predictedDx > pageWidth * 0.45), currentIndex > 0 {
              transitionOffset = dx
              withAnimation(.easeOut(duration: 0.14)) {
                transitionOffset = pageWidth
              }
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                currentIndex -= 1
                transitionOffset = -pageWidth
                viewedIDs.insert(stories[currentIndex].id)
                pipeline.markRead(stories[currentIndex])
                ReadLedger.record(stories[currentIndex])
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                  transitionOffset = 0
                }
              }
            }
          }
      )
  }
}

/// The page's one-sentence top, as on Atelier's dashboards:
///
///     SAT (24) (OCT) 15:30
///     1043 ARTICLES
///     (31) (NEW) IN (13) STORIES
///     (TOP) STORM ELIN BATTERS… (clock) ⌊20 MIN (→)
///
/// The last line takes turns with the Catchup reel, the read stories hidden and how many
/// stories your mutes hide. The top story's headline gets all the room the line has.
struct NewsTop: View {
  let since: Date
  let visible: [StoryCluster]
  let top: StoryCluster?
  var catchupCount: Int = 0
  let hiddenCount: Int
  var readHiddenCount: Int = 0
  var open: (StoryCluster) -> Void
  var openCatchup: () -> Void = {}
  var showMutes: () -> Void
  var showRead: () -> Void = {}
  @State private var width: CGFloat = 360
  @ScaledMetric(relativeTo: .body) var size: CGFloat = 17

  /// How many characters of the top headline fit on two lines beside (TOP), the clock,
  /// "nn MIN" and the arrow. SF Mono is 0.6 em wide; the rest takes about 7 em, and a couple of
  /// characters go to the gap where the first line breaks.
  /// The 7 em fits a 3-character age ("1 H"); a longer one ("33 MIN") takes its extra
  /// characters, and one more for its wider pill.
  func headlineChars(age: String) -> Int {
    max(12, Int((width * 2 - size * 7) / (size * 0.6)) - 3 - max(age.count - 3, 0) - (age.count > 3 ? 1 : 0))
  }

  /// The headline as separate words, so the line can wrap onto a second line.
  func headlineWords(_ title: String, age: String) -> [RebusToken] {
    let up = title.uppercased()
    let budget = headlineChars(age: age)
    let cut = up.count > budget ? String(up.prefix(budget - 1)).trimmingCharacters(in: .whitespaces) + "…" : up
    return cut.split(separator: " ").map { .word(String($0)) }
  }

  var articles: [ArticleItem] { visible.flatMap(\.articles) }
  /// New to you: reached this iPhone since you last looked, and published no more than two
  /// hours before that (feeds can lag a little). The publish time keeps out articles that
  /// arrive late but aren't news: a newly chosen outlet's last two days, or everything after
  /// the store is read in afresh.
  var fresh: [ArticleItem] {
    let earliest = since.addingTimeInterval(-2 * 3600)
    return articles.filter { $0.fetchedAt > since && $0.publishedAt > earliest }
  }

  /// Every article on the page; the new ones are on the line under it.
  var figure: String {
    if articles.isEmpty { return readHiddenCount > 0 ? "CAUGHT UP" : "READING" }
    return "\(articles.count) \(articles.count == 1 ? "ARTICLE" : "ARTICLES")"
  }

  var detail: [RebusToken] {
    if articles.isEmpty {
      if readHiddenCount > 0 {
        return [.number("\(readHiddenCount)"), .word(readHiddenCount == 1 ? "STORY" : "STORIES"), .pill("READ")]
      }
      return [.word("THE NEWS, ON"), .pill("THIS IPHONE")]
    }
    if fresh.isEmpty {
      return [.word("IN"), .number("\(visible.count)"), .word(visible.count == 1 ? "STORY" : "STORIES"), .grey("·"), .word("NOTHING"), .pill("NEW")]
    }
    let stories = Set(fresh.compactMap { $0.cluster?.id }).count
    return [.number("\(fresh.count)"), .pill("NEW"), .word("IN"), .number("\(stories)"), .word(stories == 1 ? "STORY" : "STORIES")]
  }

  var messages: [KeyMessage] {
    var messages: [KeyMessage] = []
    if let top, let lead = top.lead {
      messages.append(KeyMessage(
        id: "top-\(top.id)",
        tokens: [.pill("TOP")] + headlineWords(lead.title, age: Self.age(top.updatedAt))
          + [.clock, .minutes(Self.age(top.updatedAt)), .arrow],
        action: { open(top) }))
    }
    if catchupCount > 0 {
      messages.append(KeyMessage(
        id: "catchup-\(catchupCount)",
        tokens: [.pill("CATCHUP"), .number("\(catchupCount)"), .word("TOP STORIES"), .word("REEL"), .arrow],
        action: openCatchup))
    }
    if readHiddenCount > 0 {
      messages.append(KeyMessage(
        id: "read-\(readHiddenCount)",
        tokens: [.number("\(readHiddenCount)"), .pill("READ"), .word("HIDDEN"), .grey("·"), .word("SHOW"), .arrow],
        action: showRead))
    }
    if hiddenCount > 0 {
      messages.append(KeyMessage(
        id: "hidden-\(hiddenCount)",
        tokens: [.number("\(hiddenCount)"), .word("HIDDEN BY"), .pill("YOUR TOPICS"), .arrow],
        action: showMutes))
    }
    return messages
  }

  /// "20 MIN", "3 H".
  static func age(_ date: Date) -> String {
    let minutes = max(Int(Date.now.timeIntervalSince(date) / 60), 0)
    return minutes < 60 ? "\(minutes) MIN" : "\(minutes / 60) H"
  }

  var body: some View {
    // Larger than Atelier's phone top (15 / 38), so the lines run across the page.
    OneSentenceTop(figure: figure, detail: detail, messages: messages, size: 17, figureSize: 44)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }
}

extension TopicKind: Identifiable {
  var id: String { rawValue }
}

/// The feed's sections under the current filter and selected news time window.
struct FeedSections {
  var visible: [StoryCluster] = []
  var wide: [StoryCluster] = []
  var brief: [StoryCluster] = []
  var updatedClusters: [StoryCluster] = []
  var hiddenCount = 0
  var readHiddenCount = 0
  var settledReadTotal = 0
  /// The read stories under the filter, for the summary when all are read.
  var readClusters: [StoryCluster] = []

  /// Reading time for the read stories: first read to last, at least a minute.
  var readingMinutes: Int {
    let times = readClusters.compactMap(\.readAt)
    guard let first = times.min(), let last = times.max() else { return 1 }
    return max(1, Int(last.timeIntervalSince(first) / 60))
  }

  init() {}

  init(clusters: [StoryCluster], filter: FeedFilter, hideRead: Bool = true, window: NewsWindow = .h24) {
    var pillars: [UUID: Pillar] = [:]
    let now = Date.now
    let cutoff = now.addingTimeInterval(-window.interval)

    for cluster in clusters {
      let isChartCluster = cluster.lead?.isChart == true
      if !isChartCluster && cluster.updatedAt < cutoff {
        continue
      }

      if cluster.isMuted { hiddenCount += 1; continue }
      guard !cluster.articles.isEmpty else { continue }
      let pillar = cluster.pillar

      let matchesFilter: Bool
      switch filter {
      case .all: matchesFilter = true
      case .pillar(let chosen): matchesFilter = (pillar == chosen)
      case .region(let region): matchesFilter = (pillar == .briefing && cluster.regions.contains(region))
      case .topic(let phrase): matchesFilter = (cluster.followedBy == phrase)
      }
      guard matchesFilter else { continue }

      switch ReadLedger.status(for: cluster) {
      case .settledRead:
        settledReadTotal += 1
        readClusters.append(cluster)
        if hideRead {
          readHiddenCount += 1
          continue
        }
      case .updated:
        updatedClusters.append(cluster)
      case .unread:
        break
      }

      pillars[cluster.id] = pillar
      visible.append(cluster)
    }


    let outlets = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Set($0.articles.map(\.outlet)).count) })
    let importance = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Self.importance($0, outlets: outlets[$0.id] ?? 0, now: now)) })
    let byImportance = { (a: StoryCluster, b: StoryCluster) in importance[a.id, default: 0] > importance[b.id, default: 0] }
    let newestFirst = { (a: StoryCluster, b: StoryCluster) in a.updatedAt > b.updatedAt }

    switch filter {
    case .all:
      // News goes on top when several outlets cover it; a lighter pillar's single-outlet pieces
      // (a review, a lookbook) are its stories too.
      let top = visible.filter { pillars[$0.id] != .briefing || outlets[$0.id, default: 0] > 1 }
      let queues = Dictionary(grouping: top) { pillars[$0.id] ?? .briefing }.mapValues { $0.sorted(by: byImportance) }
      // Breaking news leads, whatever the mix.
      let breaking = (queues[.briefing] ?? []).filter(Alerts.isBreaking)
      let breakingIDs = Set(breaking.map(\.id))
      wide = breaking + Self.balanced(queues.mapValues { $0.filter { !breakingIDs.contains($0.id) } })
      let shown = Set(wide.map(\.id))
      brief = visible.filter { !shown.contains($0.id) }.sorted(by: newestFirst)
    case .pillar(let pillar) where pillar != .briefing:
      // Lighter pillars are mostly one outlet per piece: all of them as cards.
      wide = visible.sorted(by: byImportance)
    default:
      wide = visible.filter { outlets[$0.id, default: 0] > 1 }.sorted(by: byImportance)
      brief = visible.filter { outlets[$0.id, default: 0] <= 1 }.sorted(by: newestFirst)
    }
  }

  /// The pillars interleaved by share (smooth weighted round-robin), each queue most important
  /// first: Briefing, Tech & Gear, Fashion & Style, Entertainment, Gaming, Lifestyle & Food, and
  /// round again, Briefing and Tech a little more often. A pillar that runs out drops out and
  /// the others share its place.
  static func balanced(_ queues: [Pillar: [StoryCluster]]) -> [StoryCluster] {
    var queues = queues.filter { !$0.value.isEmpty }
    var credit: [Pillar: Double] = [:]
    var out: [StoryCluster] = []
    while !queues.isEmpty {
      let active = Pillar.allCases.filter { queues[$0] != nil }
      for pillar in active { credit[pillar, default: 0] += pillar.share }
      // Ties go to the earlier pillar.
      guard let next = active.max(by: { credit[$0, default: 0] < credit[$1, default: 0] }) else { break }
      credit[next, default: 0] -= active.reduce(0) { $0 + $1.share }
      out.append(queues[next]!.removeFirst())
      if queues[next]!.isEmpty { queues[next] = nil; credit[next] = nil }
    }
    return out
  }

  /// How high a story goes: how widely it's covered, how fast coverage is growing right now,
  /// and how fresh it is. Coverage counts with diminishing returns (the 18th outlet adds less
  /// than the 3rd); the story fades with a 6-hour half-life from its newest article; a story
  /// you've read, with nothing new since, sinks.
  ///
  /// So a story 12 outlets broke an hour ago beats one 18 outlets covered yesterday, and five
  /// outlets in the last hour beat ten spread over the day.
  static func importance(_ cluster: StoryCluster, outlets: Int, now: Date) -> Double {
    let recent = Set(cluster.articles.filter { now.timeIntervalSince($0.publishedAt) < 2 * 3600 }.map(\.outlet)).count
    let coverage = log(1 + Double(outlets)) + 0.6 * log(1 + Double(recent))
    let hours = max(now.timeIntervalSince(cluster.updatedAt), 0) / 3600
    let freshness = pow(0.5, hours / 6)
    let settled: Bool
    if case .settledRead = ReadLedger.status(for: cluster) {
      settled = true
    } else {
      settled = false
    }
    return coverage * (0.25 + 0.75 * freshness) * (settled ? 0.4 : 1)
  }
}

/// What the feed shows: everything, a pillar, a region (of the news), or one topic you follow.
enum FeedFilter: Hashable {
  case all
  case pillar(Pillar)
  case region(Region)
  case topic(String)

  init(raw: String) {
    if raw.hasPrefix("topic:") {
      self = .topic(String(raw.dropFirst("topic:".count)))
    } else if raw.hasPrefix("pillar:"), let pillar = Pillar(rawValue: String(raw.dropFirst("pillar:".count))) {
      self = .pillar(pillar)
    } else if let region = Region(rawValue: raw), region != .world {
      self = .region(region)
    } else {
      // "all", and "world" from before the pillars.
      self = .all
    }
  }

  var raw: String {
    switch self {
    case .all: "all"
    case .pillar(let pillar): "pillar:\(pillar.rawValue)"
    case .region(let region): region.rawValue
    case .topic(let phrase): "topic:\(phrase)"
    }
  }

  var title: String {
    switch self {
    case .all: "All"
    case .pillar(let pillar): pillar.title
    case .region(let region): region.title
    case .topic(let phrase): phrase
    }
  }

  /// Briefing and its regions show the region row.
  var isNews: Bool {
    switch self {
    case .pillar(.briefing), .region: true
    default: false
    }
  }
}

/// All and the pillars, then the topics you follow, then a Read pill that shows or hides the
/// stories you've read; with Briefing chosen, a second row narrows the news to a region (tap the
/// chosen region again for all of Briefing). The chosen one is an ink outline (selection never
/// reads as the black primary action); the rest are quiet pills.
struct FilterBar: View {
  @Binding var selection: FeedFilter
  @Binding var hideRead: Bool
  var readCount: Int = 0
  var showsReadToggle = true
  let topics: [String]

  /// The pill the row is scrolled to.
  @State private var shownPill: String?

  /// The chosen pill in the top row (a region's is Briefing).
  var mainID: String { if case .region = selection { FeedFilter.pillar(.briefing).raw } else { selection.raw } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          // Each pill is known by its filter's `raw`, which is what the row scrolls to.
          pill(.all)
          ForEach(Pillar.allCases.map { FeedFilter.pillar($0).raw }, id: \.self) { raw in pill(FeedFilter(raw: raw)) }
          if !topics.isEmpty {
            divider
            ForEach(topics.map { FeedFilter.topic($0).raw }, id: \.self) { raw in pill(FeedFilter(raw: raw)) }
          }
          if showsReadToggle && (readCount > 0 || !hideRead) {
            divider
            readTogglePill
          }
        }
        .scrollTargetLayout()
      }
      // Swiping to a filter brings its pill into view.
      .scrollPosition(id: $shownPill, anchor: .center)
      // Once the row has laid out; set at once, the position is ignored.
      .task(id: mainID) {
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(.snappy(duration: 0.25)) { shownPill = mainID }
      }
      if selection.isNews {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(Region.allCases.filter { $0 != .world }) { region in
              pill(.region(region), small: true, otherwise: .pillar(.briefing))
            }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .scrollIndicators(.hidden)
    .scrollClipDisabled()
  }

  private var divider: some View {
    Capsule()
      .fill(Swiss.ink.opacity(0.15))
      .frame(width: 1.5, height: 22)
      .padding(.horizontal, 4)
  }

  private var readTogglePill: some View {
    let showingRead = !hideRead
    let label = readCount > 0 ? "Read · \(readCount)" : "Read"
    return Button(label) {
      withAnimation(.snappy(duration: 0.2)) { hideRead.toggle() }
    }
    .buttonStyle(SelectablePillStyle(isOn: showingRead))
    .accessibilityLabel(showingRead ? "Showing read stories" : "Hiding \(readCount) read stories")
  }

  /// `otherwise`: what tapping the chosen pill goes back to (regions back to Briefing).
  func pill(_ filter: FeedFilter, small: Bool = false, otherwise: FeedFilter? = nil) -> some View {
    let isOn = filter == selection
    return Button(filter.title) {
      withAnimation(.snappy(duration: 0.2)) { selection = isOn ? otherwise ?? filter : filter }
    }
    .buttonStyle(SelectablePillStyle(isOn: isOn, small: small))
    .id(filter.raw)
  }
}
