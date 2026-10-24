import SwiftData
import SwiftUI

/// Today: the one-sentence top (what's new since you last looked, and the top story), then
/// stories covered widely, then stories in brief.
struct FeedView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \StoryCluster.updatedAt, order: .reverse) var clusters: [StoryCluster]
  @AppStorage("lastLookedAt") var lastLookedAt: Double = 0
  @Environment(\.scenePhase) var scenePhase
  @State private var showsMutes = false
  @State private var path: [StoryCluster] = []
  /// Held while the page is open, so the count doesn't drop to zero as you read.
  @State private var since: Date?

  var visible: [StoryCluster] { clusters.filter { !$0.isMuted && !$0.articles.isEmpty } }
  var wide: [StoryCluster] {
    visible.filter { $0.outlets.count > 1 }
      .sorted { ($0.outlets.count, $0.updatedAt) > ($1.outlets.count, $1.updatedAt) }
  }
  var brief: [StoryCluster] { visible.filter { $0.outlets.count <= 1 } }
  var hiddenCount: Int { clusters.filter(\.isMuted).count }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          NewsTop(since: since ?? .distantPast, visible: visible, top: wide.first, hiddenCount: hiddenCount) {
            path.append($0)
          } showMutes: {
            showsMutes = true
          }
          .padding(.top, 8)
          .padding(.bottom, 20)

          if clusters.isEmpty {
            emptyState
          }
          if !wide.isEmpty {
            Eyebrow("Covered widely").padding(.top, 4)
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
            Button("\(hiddenCount) \(hiddenCount == 1 ? "story" : "stories") hidden by your topics") { showsMutes = true }
              .font(.footnote)
              .foregroundStyle(Swiss.muted)
              .padding(.top, 12)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(.horizontal, Swiss.pageInset)
        .padding(.bottom, 32)
      }
      .swissCanvas()
      .swissNavigationTitle("Today")
      .refreshable { await pipeline.sync() }
      .navigationDestination(for: StoryCluster.self) { StoryDetailView(cluster: $0) }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Muted topics", systemImage: "line.3.horizontal.decrease") { showsMutes = true }
        }
      }
      .sheet(isPresented: $showsMutes) { MuteSheet() }
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
    Button("Mute stories like this", systemImage: "speaker.slash") {
      Task { await pipeline.muteStoriesLike(cluster) }
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
/// The last line takes turns with how many stories your topics hide.
struct NewsTop: View {
  let since: Date
  let visible: [StoryCluster]
  let top: StoryCluster?
  let hiddenCount: Int
  var open: (StoryCluster) -> Void
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
