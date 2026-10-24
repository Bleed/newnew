import SwiftData
import SwiftUI

/// Today: the one-sentence top (what's new since you last looked, and the top story), the
/// region switch, then stories on topics you follow, stories covered widely, and stories in
/// brief.
struct FeedView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \StoryCluster.updatedAt, order: .reverse) var clusters: [StoryCluster]
  @AppStorage("lastLookedAt") var lastLookedAt: Double = 0
  @Environment(\.scenePhase) var scenePhase
  @State private var topicsKind: TopicKind?
  @State private var path: [StoryCluster] = []
  @AppStorage("region") var regionRaw = Region.world.rawValue
  /// Held while the page is open, so the count doesn't drop to zero as you read.
  @State private var since: Date?

  var region: Region { Region(rawValue: regionRaw) ?? .world }
  var visible: [StoryCluster] {
    clusters.filter { !$0.isMuted && !$0.articles.isEmpty && (region == .world || $0.regions.contains(region)) }
  }
  /// Stories on topics you follow, newest first; shown once, above the rest.
  var following: [StoryCluster] { visible.filter(\.isFollowed) }
  var wide: [StoryCluster] {
    visible.filter { !$0.isFollowed && $0.outlets.count > 1 }
      .sorted { ($0.outlets.count, $0.updatedAt) > ($1.outlets.count, $1.updatedAt) }
  }
  var brief: [StoryCluster] { visible.filter { !$0.isFollowed && $0.outlets.count <= 1 } }
  var hiddenCount: Int { clusters.filter(\.isMuted).count }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollViewReader { scroller in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          NewsTop(
            since: since ?? .distantPast, visible: visible, top: wide.first, followingCount: following.count,
            hiddenCount: hiddenCount
          ) {
            path.append($0)
          } showFollowing: {
            withAnimation(.snappy) { scroller.scrollTo("following", anchor: .top) }
          } showMutes: {
            topicsKind = .mute
          }
          .padding(.top, 8)
          .padding(.bottom, 14)

          RegionBar(selection: Binding(get: { region }, set: { regionRaw = $0.rawValue }))
            .padding(.bottom, 10)

          if clusters.isEmpty {
            emptyState
          } else if visible.isEmpty {
            Text("Nothing about \(region == .local ? Locale(identifier: "en").localizedString(forRegionCode: RegionTagger.localCountry) ?? "here" : region.title) right now.")
              .font(.subheadline)
              .foregroundStyle(Swiss.muted)
          }
          if !following.isEmpty {
            HStack {
              Eyebrow("Following")
              Spacer()
              Button("Edit") { topicsKind = .follow }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Swiss.muted)
            }
            .id("following")
            ForEach(following) { cluster in
              NavigationLink(value: cluster) { StoryCard(cluster: cluster) }
                .buttonStyle(.plain)
                .contextMenu { menu(cluster) }
            }
          }
          if !wide.isEmpty {
            Eyebrow("Covered widely").padding(.top, following.isEmpty ? 4 : 16)
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
      .swissNavigationTitle("Today")
      .refreshable { await pipeline.sync() }
      .navigationDestination(for: StoryCluster.self) { StoryDetailView(cluster: $0) }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Topics", systemImage: "line.3.horizontal.decrease") { topicsKind = .follow }
        }
      }
      .sheet(item: $topicsKind) { TopicsSheet(kind: $0) }
    }
    .tint(Swiss.ink)
    .onAppear { if since == nil { since = Date(timeIntervalSince1970: lastLookedAt) } }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: lastLookedAt = Date.now.timeIntervalSince1970
      case .active: since = Date(timeIntervalSince1970: lastLookedAt)
      default: break
      }
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
/// The last line takes turns with the stories on topics you follow and how many your mutes
/// hide.
struct NewsTop: View {
  let since: Date
  let visible: [StoryCluster]
  let top: StoryCluster?
  let followingCount: Int
  let hiddenCount: Int
  var open: (StoryCluster) -> Void
  var showFollowing: () -> Void
  var showMutes: () -> Void

  var articles: [ArticleItem] { visible.flatMap(\.articles) }
  var fresh: [ArticleItem] { articles.filter { $0.publishedAt > since } }

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
      return [.word("IN"), .number("\(visible.count)"), .word("STORIES"), .grey("·"), .word("NOTHING"), .pill("NEW")]
    }
    let stories = Set(fresh.compactMap { $0.cluster?.id }).count
    return [.word(fresh.count == 1 ? "IS" : "ARE"), .pill("NEW"), .word("IN"), .number("\(stories)"), .word(stories == 1 ? "STORY" : "STORIES")]
  }

  var messages: [KeyMessage] {
    var messages: [KeyMessage] = []
    if let top, let lead = top.lead {
      messages.append(KeyMessage(
        id: "top-\(top.id)",
        tokens: [.pill("TOP"), .name(lead.title, max: 20), .clock, .minutes(Self.age(top.updatedAt)), .arrow],
        action: { open(top) }))
    }
    if followingCount > 0 {
      messages.append(KeyMessage(
        id: "following-\(followingCount)",
        tokens: [.number("\(followingCount)"), .word(followingCount == 1 ? "STORY ON" : "STORIES ON"), .pill("TOPICS YOU FOLLOW"), .arrow],
        action: showFollowing))
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
    OneSentenceTop(figure: figure, detail: detail, messages: messages, size: 15, figureSize: 38)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension TopicKind: Identifiable {
  var id: String { rawValue }
}

/// World · Europe · US · Asia · Local. The chosen region is an ink outline (selection never
/// reads as the black primary action); the rest are quiet pills.
struct RegionBar: View {
  @Binding var selection: Region

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(Region.allCases) { region in
          let isOn = region == selection
          Button {
            withAnimation(.snappy(duration: 0.2)) { selection = region }
          } label: {
            Text(region.title)
              .font(.callout.weight(.medium))
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
    }
    .scrollIndicators(.hidden)
    .scrollClipDisabled()
  }
}
