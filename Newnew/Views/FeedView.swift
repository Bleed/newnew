import SwiftData
import SwiftUI

/// Today: the one-sentence top (what's new since you last looked, and the top story), the
/// filter switch (regions, then the topics you follow), then top stories (most important first,
/// followed or not; see `FeedSections.importance`), and stories in brief.
struct FeedView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \StoryCluster.updatedAt, order: .reverse) var clusters: [StoryCluster]
  @AppStorage("lastLookedAt") var lastLookedAt: Double = 0
  @Environment(\.scenePhase) var scenePhase
  @State private var topicsKind: TopicKind?
  @State private var path: [StoryCluster] = []
  @AppStorage("feedFilter") var filterRaw = FeedFilter.region(.world).raw
  @Query(sort: \SemanticTopic.createdAt) var topics: [SemanticTopic]
  /// Held while the page is open, so the count doesn't drop to zero as you read.
  @State private var since: Date?

  var followedTopics: [String] { topics.filter { $0.kind == .follow }.map(\.phrase) }
  /// The chosen filter; a topic you've since unfollowed falls back to World.
  var filter: FeedFilter {
    let filter = FeedFilter(raw: filterRaw)
    if case .topic(let phrase) = filter, !followedTopics.contains(phrase) { return .region(.world) }
    return filter
  }

  /// Lifts the sentence top into the top bar's row, so its date line is level with the middle
  /// of the filter button. The loading band, when it opens, pushes it down.
  static let headerTop: CGFloat = -37
  /// Below the loading band while it shows, so the band never covers the date.
  static let headerBelowBand: CGFloat = 13
  @State private var boardShowing = false

  var body: some View {
    // Worked out once per render: these were computed properties, re-run on every read, and
    // with 400+ stories that held up the main thread for seconds.
    let sections = FeedSections(clusters: clusters, filter: filter)
    let visible = sections.visible, wide = sections.wide
    let brief = sections.brief, hiddenCount = sections.hiddenCount
    NavigationStack(path: $path) {
      ScrollViewReader { _ in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          NewsTop(
            since: since ?? .distantPast, visible: visible, top: wide.first, hiddenCount: hiddenCount
          ) {
            path.append($0)
          } showMutes: {
            topicsKind = .mute
          }
          .padding(.top, boardShowing ? Self.headerBelowBand : Self.headerTop)
          .padding(.bottom, 28)

          FilterBar(selection: Binding(get: { filter }, set: { filterRaw = $0.raw }), topics: followedTopics)
            .padding(.bottom, 10)

          if clusters.isEmpty {
            emptyState
          } else if visible.isEmpty {
            Text("Nothing on \(filter.title) right now.")
              .font(.subheadline)
              .foregroundStyle(Swiss.muted)
          }
          if !wide.isEmpty {
            Eyebrow("Top stories").padding(.top, 4)
            ForEach(wide) { cluster in
              NavigationLink(value: cluster) { StoryCard(cluster: cluster) }
                .buttonStyle(.plain)
                .contextMenu { menu(cluster) }
            }
          }
          if !brief.isEmpty {
            Eyebrow("In brief").padding(.top, 16)
            ForEach(brief) { cluster in
              NavigationLink(value: cluster) { BriefRow(cluster: cluster) }
                .buttonStyle(.plain)
                .contextMenu { menu(cluster) }
            }
          }
          if hiddenCount > 0 {
            Button("\(hiddenCount) \(hiddenCount == 1 ? "story" : "stories") hidden by your topics") { topicsKind = .mute }
              .font(.footnote)
              .foregroundStyle(Swiss.muted)
              .padding(.top, 12)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(.horizontal, Swiss.pageInset)
        .padding(.bottom, 32)
      }
      }
      .swissCanvas()
      .navigationTitle("Today")
      .navigationBarTitleDisplayMode(.inline)
      // The header shares the bar's row: no fade over it.
      .scrollEdgeEffectHidden(true, for: .top)
      .dotRefreshable(isSyncing: pipeline.isSyncing, isShowing: $boardShowing) { await pipeline.sync() }
      .navigationDestination(for: StoryCluster.self) { StoryDetailView(cluster: $0) }
      .toolbar {
        // Nothing in the middle: the page's own top is the title.
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
          .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
          Button("Topics", systemImage: "line.3.horizontal.decrease") { topicsKind = .follow }
        }
      }
      .sheet(item: $topicsKind) { TopicsSheet(kind: $0) }
    }
    .tint(Swiss.ink)
    .onAppear {
      if since == nil { since = Date(timeIntervalSince1970: lastLookedAt) }
      openRoutedStory()
    }
    .onChange(of: Router.shared.storyID) { openRoutedStory() }
    .onChange(of: Router.shared.articleURL) { openRoutedStory() }
    // A pushed story may only be grouped after the sync it triggered.
    .onChange(of: clusters.count) { openRoutedStory() }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: lastLookedAt = Date.now.timeIntervalSince1970
      case .active: since = Date(timeIntervalSince1970: lastLookedAt)
      default: break
      }
    }
  }

  /// A tapped alert: open its story.
  func openRoutedStory() {
    let router = Router.shared
    if let id = router.storyID, let cluster = clusters.first(where: { $0.id == id }) {
      router.storyID = nil
      path = [cluster]
    } else if let url = router.articleURL, let cluster = clusters.first(where: { $0.articles.contains { $0.url == url } }) {
      router.articleURL = nil
      path = [cluster]
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
    Button("Mark as read", systemImage: "checkmark.circle") { pipeline.markRead(cluster) }
    Button("Follow stories like this", systemImage: "plus.circle") {
      Task { await pipeline.addTopic(like: cluster, kind: .follow) }
    }
    Button("Mute stories like this", systemImage: "speaker.slash") {
      Task { await pipeline.addTopic(like: cluster, kind: .mute) }
    }
  }
}

/// The page's one-sentence top, as on Atelier's dashboards:
///
///     SAT (24) (OCT) 15:30
///     31 ARTICLES
///     ARE (NEW) IN (13) STORIES
///     (TOP) STORM ELIN BATTERS… (clock) ⌊20 MIN (→)
///
/// The last line takes turns with how many stories your mutes hide. The top story's headline
/// gets all the room the line has.
struct NewsTop: View {
  let since: Date
  let visible: [StoryCluster]
  let top: StoryCluster?
  let hiddenCount: Int
  var open: (StoryCluster) -> Void
  var showMutes: () -> Void
  @State private var width: CGFloat = 360
  @ScaledMetric(relativeTo: .body) var size: CGFloat = 17

  /// How many characters of the top headline fit on two lines beside (TOP), the clock,
  /// "nn MIN" and the arrow. SF Mono is 0.6 em wide; the rest takes about 7 em, and a couple of
  /// characters go to the gap where the first line breaks.
  var headlineChars: Int { max(12, Int((width * 2 - size * 7) / (size * 0.6)) - 3) }

  /// The headline as separate words, so the line can wrap onto a second line.
  func headlineWords(_ title: String) -> [RebusToken] {
    let up = title.uppercased()
    let cut = up.count > headlineChars ? String(up.prefix(headlineChars - 1)).trimmingCharacters(in: .whitespaces) + "…" : up
    return cut.split(separator: " ").map { .word(String($0)) }
  }

  var articles: [ArticleItem] { visible.flatMap(\.articles) }
  /// New to you: reached this iPhone since you last looked. Not by publish time, because
  /// articles are a median 41 minutes old by the time the scraper sees them, so nearly all of
  /// them were "published" before your last look.
  var fresh: [ArticleItem] { articles.filter { $0.fetchedAt > since } }

  var figure: String {
    // The first sync (embedding a few hundred articles) takes a while.
    if articles.isEmpty { return "READING" }
    let count = fresh.isEmpty ? articles.count : fresh.count
    return "\(count) \(count == 1 ? "ARTICLE" : "ARTICLES")"
  }

  var detail: [RebusToken] {
    if articles.isEmpty {
      return [.word("THE NEWS, ON"), .pill("THIS IPHONE")]
    }
    if fresh.isEmpty {
      return [.word("IN"), .number("\(visible.count)"), .word(visible.count == 1 ? "STORY" : "STORIES"), .grey("·"), .word("NOTHING"), .pill("NEW")]
    }
    let stories = Set(fresh.compactMap { $0.cluster?.id }).count
    return [.word(fresh.count == 1 ? "IS" : "ARE"), .pill("NEW"), .word("IN"), .number("\(stories)"), .word(stories == 1 ? "STORY" : "STORIES")]
  }

  var messages: [KeyMessage] {
    var messages: [KeyMessage] = []
    if let top, let lead = top.lead {
      messages.append(KeyMessage(
        id: "top-\(top.id)",
        tokens: [.pill("TOP")] + headlineWords(lead.title) + [.clock, .minutes(Self.age(top.updatedAt)), .arrow],
        action: { open(top) }))
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

/// The feed's sections under the current filter.
struct FeedSections {
  var visible: [StoryCluster] = []
  var wide: [StoryCluster] = []
  var brief: [StoryCluster] = []
  var hiddenCount = 0

  init(clusters: [StoryCluster], filter: FeedFilter) {
    for cluster in clusters {
      if cluster.isMuted { hiddenCount += 1; continue }
      guard !cluster.articles.isEmpty else { continue }
      switch filter {
      case .region(.world): visible.append(cluster)
      case .region(let region): if cluster.regions.contains(region) { visible.append(cluster) }
      case .topic(let phrase): if cluster.followedBy == phrase { visible.append(cluster) }
      }
    }
    // Each story's outlet count and importance once, not on every comparison of the sort.
    let now = Date.now
    let outlets = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Set($0.articles.map(\.outlet)).count) })
    let importance = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Self.importance($0, outlets: outlets[$0.id] ?? 0, now: now)) })
    let byImportance = { (a: StoryCluster, b: StoryCluster) in importance[a.id, default: 0] > importance[b.id, default: 0] }
    // One order for everything, by importance; a story on a topic you follow keeps its topic as
    // its label but gets no head start.
    let rest = visible
    wide = rest.filter { outlets[$0.id, default: 0] > 1 }.sorted(by: byImportance)
    brief = rest.filter { outlets[$0.id, default: 0] <= 1 }.sorted { $0.updatedAt > $1.updatedAt }
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
    let settled = cluster.readAt != nil && cluster.newSinceRead == 0
    return coverage * (0.25 + 0.75 * freshness) * (settled ? 0.4 : 1)
  }
}

/// What the feed shows: everything, a region, or one topic you follow.
enum FeedFilter: Hashable {
  case region(Region)
  case topic(String)

  init(raw: String) {
    if raw.hasPrefix("topic:") {
      self = .topic(String(raw.dropFirst("topic:".count)))
    } else {
      self = .region(Region(rawValue: raw) ?? .world)
    }
  }

  var raw: String {
    switch self {
    case .region(let region): region.rawValue
    case .topic(let phrase): "topic:\(phrase)"
    }
  }

  var title: String {
    switch self {
    case .region(let region): region.title
    case .topic(let phrase): phrase
    }
  }
}

/// World · Europe · US · Middle East · Asia, then the topics you follow. The chosen one is an
/// ink outline (selection never reads as the black primary action); the rest are quiet pills.
struct FilterBar: View {
  @Binding var selection: FeedFilter
  let topics: [String]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(Region.allCases) { region in pill(.region(region)) }
        if !topics.isEmpty {
          // A short rule between the regions and your topics.
          Capsule().fill(Swiss.ink.opacity(0.15)).frame(width: 1.5, height: 22).padding(.horizontal, 4)
          ForEach(topics, id: \.self) { topic in pill(.topic(topic)) }
        }
      }
    }
    .scrollIndicators(.hidden)
    .scrollClipDisabled()
  }

  func pill(_ filter: FeedFilter) -> some View {
    let isOn = filter == selection
    return Button {
      withAnimation(.snappy(duration: 0.2)) { selection = filter }
    } label: {
      Text(filter.title)
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .frame(maxWidth: 200)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(Swiss.ink)
        .background(isOn ? Color.clear : Swiss.ink.opacity(0.07), in: Capsule())
        .overlay { if isOn { Capsule().strokeBorder(Swiss.ink, lineWidth: 1.5) } }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
