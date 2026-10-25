import SwiftData
import SwiftUI

/// Today: the one-sentence top (what's new since you last looked, and the top story), the
/// filter bar (All, the pillars, then the topics you follow; regions inside Briefing), then top
/// stories and stories in brief. On All the top stories mix the pillars by share, most
/// important first within each (see `FeedSections.balanced`).
struct FeedView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \StoryCluster.updatedAt, order: .reverse) var clusters: [StoryCluster]
  @AppStorage("lastLookedAt") var lastLookedAt: Double = 0
  @Environment(\.scenePhase) var scenePhase
  @State private var topicsKind: TopicKind?
  @State private var path: [StoryCluster] = []
  @AppStorage("feedFilter") var filterRaw = FeedFilter.all.raw
  @Query(sort: \SemanticTopic.createdAt) var topics: [SemanticTopic]
  /// Held while the page is open, so the count doesn't drop to zero as you read.
  @State private var since: Date?

  var followedTopics: [String] { topics.filter { $0.kind == .follow }.map(\.phrase) }
  /// The chosen filter; a topic you've since unfollowed falls back to All.
  var filter: FeedFilter {
    let filter = FeedFilter(raw: filterRaw)
    if case .topic(let phrase) = filter, !followedTopics.contains(phrase) { return .all }
    return filter
  }

  /// Lifts the sentence top into the top bar's row, so its date line is level with the middle
  /// of the filter button. The loading band, when it opens, pushes it down.
  static let headerTop: CGFloat = -37
  /// Below the loading band while it shows, so the band never covers the date.
  static let headerBelowBand: CGFloat = 13
  @State private var boardShowing = false
  /// Where the top's bottom and the filter bar are on screen: once the top has scrolled above
  /// the bar, the bar is pinned and its page colour reaches up over the status bar.
  @State private var topBottom: CGFloat = 0
  @State private var barTop: CGFloat = 0
  var barPinned: Bool { topBottom < barTop - 1 }

  var body: some View {
    // Worked out once per render: these were computed properties, re-run on every read, and
    // with 400+ stories that held up the main thread for seconds.
    let sections = FeedSections(clusters: clusters, filter: filter)
    let visible = sections.visible, wide = sections.wide
    let brief = sections.brief, hiddenCount = sections.hiddenCount
    NavigationStack(path: $path) {
      ScrollViewReader { _ in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
          NewsTop(
            since: since ?? .distantPast, visible: visible, top: wide.first, hiddenCount: hiddenCount
          ) {
            path.append($0)
          } showMutes: {
            topicsKind = .mute
          }
          .padding(.top, boardShowing ? Self.headerBelowBand : Self.headerTop)
          .padding(.bottom, 18)
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBottom = $0 }

          // Stays at the top while the stories scroll under it.
          Section {
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
          } header: {
            FilterBar(selection: Binding(get: { filter }, set: { filterRaw = $0.raw }), topics: followedTopics)
              .padding(.vertical, 10)
              .background(alignment: .bottom) {
                Swiss.canvas.frame(height: barPinned ? 400 : nil).padding(.horizontal, -Swiss.pageInset)
              }
              .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
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
        tokens: [.pill("TOP")] + headlineWords(lead.title, age: Self.age(top.updatedAt))
          + [.clock, .minutes(Self.age(top.updatedAt)), .arrow],
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
    var pillars: [UUID: Pillar] = [:]
    for cluster in clusters {
      if cluster.isMuted { hiddenCount += 1; continue }
      guard !cluster.articles.isEmpty else { continue }
      let pillar = cluster.pillar
      pillars[cluster.id] = pillar
      switch filter {
      case .all: visible.append(cluster)
      case .pillar(let chosen): if pillar == chosen { visible.append(cluster) }
      case .region(let region): if pillar == .briefing, cluster.regions.contains(region) { visible.append(cluster) }
      case .topic(let phrase): if cluster.followedBy == phrase { visible.append(cluster) }
      }
    }
    // Each story's outlet count and importance once, not on every comparison of the sort.
    let now = Date.now
    let outlets = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Set($0.articles.map(\.outlet)).count) })
    let importance = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, Self.importance($0, outlets: outlets[$0.id] ?? 0, now: now)) })
    let byImportance = { (a: StoryCluster, b: StoryCluster) in importance[a.id, default: 0] > importance[b.id, default: 0] }
    let newestFirst = { (a: StoryCluster, b: StoryCluster) in a.updatedAt > b.updatedAt }
    // A story on a topic you follow keeps its topic as its label but gets no head start.
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
    let settled = cluster.readAt != nil && cluster.newSinceRead == 0
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

/// All and the pillars, then the topics you follow; with Briefing chosen, a second row narrows
/// the news to a region (tap the chosen region again for all of Briefing). The chosen one is an
/// ink outline (selection never reads as the black primary action); the rest are quiet pills.
struct FilterBar: View {
  @Binding var selection: FeedFilter
  let topics: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          pill(.all)
          ForEach(Pillar.allCases) { pillar in pill(.pillar(pillar)) }
          if !topics.isEmpty {
            // A short rule between the pillars and your topics.
            Capsule().fill(Swiss.ink.opacity(0.15)).frame(width: 1.5, height: 22).padding(.horizontal, 4)
            ForEach(topics, id: \.self) { topic in pill(.topic(topic)) }
          }
        }
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

  /// `otherwise`: what tapping the chosen pill goes back to (regions back to Briefing).
  func pill(_ filter: FeedFilter, small: Bool = false, otherwise: FeedFilter? = nil) -> some View {
    let isOn = filter == selection
    return Button {
      withAnimation(.snappy(duration: 0.2)) { selection = isOn ? otherwise ?? filter : filter }
    } label: {
      Text(filter.title)
        .font(small ? .subheadline.weight(.medium) : .callout.weight(.medium))
        .lineLimit(1)
        .frame(maxWidth: 200)
        .padding(.horizontal, small ? 12 : 14)
        .padding(.vertical, small ? 6 : 8)
        .foregroundStyle(Swiss.ink)
        .background(isOn ? Color.clear : Swiss.ink.opacity(0.07), in: Capsule())
        .overlay { if isOn { Capsule().strokeBorder(Swiss.ink, lineWidth: 1.5) } }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
