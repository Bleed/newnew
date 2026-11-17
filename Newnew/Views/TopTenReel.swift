import SwiftUI

// MARK: The deck

/// Top 10 (Figma: Top 10 · sketch, "Top 10 reel · v5" and "v5 dark"): the most important stories
/// across every pillar right now, then what you follow that is new. A pillar takes part only
/// when something is happening in it (`isActive`); the quiet ones are named on the cover. Built
/// once when the reel opens, so it holds still while you read.
struct TopTen: Identifiable {
  struct Entry: Identifiable {
    let cluster: StoryCluster
    let rank: Int
    /// Read before, with this many articles since ("Back · 2 new"); nil when unread.
    let backNew: Int?
    /// What arrived since you read it, newest first.
    let unseen: [ArticleItem]
    /// Its time on screen, worked out once (`duration`).
    let seconds: Double
    var id: UUID { cluster.id }
  }

  let id = UUID()
  let made: Date
  let entries: [Entry]
  /// Pillars with stories in the deck, in the deck's order.
  let pillars: [Pillar]
  /// Pillars with nothing much happening, left out.
  let quiet: [Pillar]
  /// New since `since`: podcast episodes, videos, and posts from your own feeds.
  let episodes: [ArticleItem]
  let videos: [ArticleItem]
  let posts: [ArticleItem]
  let since: Date

  static let size = 10
  /// When the reel was last read to the end: updates count from then (a day at most).
  static let finishedKey = "top10.finishedAt"
  /// An update page's time on screen.
  static let updateSeconds = 8.0

  var updateCount: Int { episodes.count + videos.count + posts.count }

  /// "Updates · since 08:10", or the last day when you haven't finished one since yesterday.
  var sinceLine: String {
    made.timeIntervalSince(since) >= 23 * 3600
      ? "Updates · last 24 hours"
      : "Updates · since \(since.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
  }

  /// About how long it takes, in minutes: every slide's time, rounded up.
  var minutes: Int {
    let seconds = entries.reduce(0) { $0 + $1.seconds }
      + (episodes.isEmpty ? 0 : Self.updateSeconds) + (videos.isEmpty && posts.isEmpty ? 0 : Self.updateSeconds)
    return max(1, Int((seconds / 60).rounded(.up)))
  }

  /// A story's time on screen: 6 s, plus a little for a long headline and extract, 10 s at most.
  static func duration(_ lead: ArticleItem?) -> Double {
    let words = ((lead?.title ?? "") + " " + (lead?.shortSnippet ?? "")).split(separator: " ").count
    return min(10, 6 + Double(words) / 15)
  }

  /// Built when the reel opens. Every fact about a story (its outlets, whether it's breaking,
  /// its pillar) is worked out once: SwiftData relationships are slow to walk again and again.
  @MainActor static func make(from clusters: [StoryCluster], now: Date = .now) -> TopTen {
    struct Facts {
      let cluster: StoryCluster
      let pillar: Pillar
      let outlets: Int
      let outletsToday: Int
      let breaking: Bool
    }
    var facts: [Facts] = []
    for cluster in clusters where !cluster.isMuted && !cluster.leadIsChart && now.timeIntervalSince(cluster.updatedAt) < 36 * 3600 {
      let articles = cluster.articles
      guard !articles.isEmpty, !articles.allSatisfy(\.isMedia) else { continue }
      let outlets = Set(articles.map(\.outlet)).count
      let today = Set(articles.filter { now.timeIntervalSince($0.publishedAt) < 24 * 3600 }.map(\.outlet)).count
      facts.append(Facts(cluster: cluster, pillar: cluster.storedPillar, outlets: outlets, outletsToday: today, breaking: Alerts.isBreaking(cluster)))
    }
    // A pillar takes part when one of its stories has at least 3 outlets in the last day.
    let active = Set(facts.filter { $0.outletsToday >= 3 }.map(\.pillar))
    // Several outlets, in an active pillar, and not read with nothing new since.
    let candidates = facts.filter { fact in
      guard active.contains(fact.pillar), fact.outlets >= 2 else { return false }
      if case .settledRead = ReadLedger.status(for: fact.cluster) { return false }
      return true
    }
    let scored = candidates.map { ($0, FeedSections.importance($0.cluster, outlets: $0.outlets, now: now, sinksRead: false)) }
    // Breaking news first, then by importance across every pillar.
    let ranked = scored.sorted { a, b in a.0.breaking != b.0.breaking ? a.0.breaking : a.1 > b.1 }.map(\.0)
    let entries = ranked.prefix(size).enumerated().map { index, fact in
      var backNew: Int?
      var unseen: [ArticleItem] = []
      if case .updated(let count, _) = ReadLedger.status(for: fact.cluster) {
        backNew = count
        unseen = ReadLedger.unseenArticles(in: fact.cluster)
      }
      return Entry(cluster: fact.cluster, rank: index + 1, backNew: backNew, unseen: unseen, seconds: duration(fact.cluster.lead))
    }
    var pillars: [Pillar] = []
    for entry in entries where !pillars.contains(entry.cluster.storedPillar) { pillars.append(entry.cluster.storedPillar) }

    // What you follow: podcasts and channels are chosen one by one; own feeds are yours.
    let finished = UserDefaults.standard.double(forKey: finishedKey)
    let since = max(Date(timeIntervalSince1970: finished), now.addingTimeInterval(-24 * 3600))
    let own = Set(OutletStore.shared.customFeeds.map(\.title))
    let fresh = clusters.flatMap(\.articles).filter { $0.publishedAt > since && $0.publishedAt <= now.addingTimeInterval(300) }
      .sorted { $0.publishedAt > $1.publishedAt }
    let episodes = Array(fresh.filter { $0.audioURL != nil }.prefix(3))
    let videos = Array(fresh.filter { $0.videoID != nil }.prefix(2))
    let posts = Array(fresh.filter { !$0.isMedia && own.contains($0.outlet) }.prefix(3))

    return TopTen(
      made: now, entries: Array(entries), pillars: pillars,
      // Quiet: read, but little happened. A category turned off isn't named.
      quiet: Pillar.allCases.filter { !active.contains($0) && OutletStore.shared.shows($0) },
      episodes: episodes, videos: videos, posts: posts, since: since)
  }
}

extension Pillar {
  /// One word for the rebus: QUIET (GAMING) (LIFESTYLE).
  var rebusWord: String {
    switch self {
    case .briefing: "NEWS"
    case .business: "BUSINESS"
    case .sports: "SPORTS"
    case .health: "HEALTH"
    case .travel: "TRAVEL"
    case .design: "DESIGN"
    case .tech: "TECH"
    case .fashion: "FASHION"
    case .entertainment: "CULTURE"
    case .music: "MUSIC"
    case .gaming: "GAMING"
    case .lifestyle: "LIFESTYLE"
    }
  }
}

// MARK: The reel

/// The Top 10 reel, light or dark with the system (Figma: Top 10 reel · v8): a cover with TOP10TOP10 in the
/// block face and its rebus, the stories one at a time like a front page, then what you follow,
/// then DONEDONE. Stories and updates run on a timer (one bar each, the time scaled to the
/// text); tap the right to go on, the left to go back, hold to pause, pull up for more.
struct TopTenReel: View {
  let deck: TopTen
  var openStory: (StoryCluster) -> Void

  @Environment(FeedSyncPipeline.self) private var pipeline
  @Environment(\.dismiss) private var dismiss

  enum Page: Hashable {
    case cover, story(Int), episodes, media, done
  }

  @State private var index = 0
  /// The running page's time. Only the dot timer reads it, so the pages don't redraw as it
  /// ticks (they did, 33 times a second, and their entrances and dot faces stalled).
  @State private var clock = ReelClock()
  @State private var held = false
  @State private var more: StoryCluster?
  @State private var startedAt: Date?

  var pages: [Page] {
    var out: [Page] = [.cover]
    out += deck.entries.indices.map { Page.story($0) }
    if !deck.episodes.isEmpty { out.append(.episodes) }
    if !deck.videos.isEmpty || !deck.posts.isEmpty { out.append(.media) }
    out.append(.done)
    return out
  }

  /// Pages with a bar: the stories and the updates.
  var timed: [Page] { pages.filter { if case .cover = $0 { return false }; if case .done = $0 { return false }; return true } }

  var page: Page { pages[min(index, pages.count - 1)] }

  var duration: Double {
    switch page {
    case .story(let i): deck.entries[i].seconds
    case .episodes, .media: TopTen.updateSeconds
    case .cover, .done: .infinity
    }
  }

  var isPaused: Bool { held || more != nil }

  var body: some View {
    GeometryReader { geo in
      // On iPad the reel is a card with no status bar above it: a little room for the timer.
      let inCard = geo.safeAreaInsets.top < 1
      // The dot timer lies over the page: a story's picture runs up under it.
      ZStack(alignment: .top) {
        Arrives { content(topInset: inCard ? 22 : geo.safeAreaInsets.top) }
          .id(index)
          .transition(.opacity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Just under the Dynamic Island (the status bar is hidden), the top line close under it.
        if timed.contains(page) { timer.padding(.horizontal, Swiss.pageInset).padding(.top, inCard ? 12 : -6) }
      }
      .contentShape(Rectangle())
      .onTapGesture(coordinateSpace: .local) { location in
        switch page {
        case .cover: go(to: 1)
        case .done: if location.x < geo.size.width * 0.35 { go(to: index - 1) }
        default: location.x < geo.size.width * 0.35 ? back() : next()
        }
      }
      .onLongPressGesture(minimumDuration: 10, pressing: { pressing in
        held = pressing
      }, perform: {})
      .simultaneousGesture(
        DragGesture(minimumDistance: 30).onEnded { value in
          if value.translation.height < -60, case .story(let i) = page { more = deck.entries[i].cluster }
          if value.translation.height > 120 { dismiss() }
        }
      )
    }
    .background(Swiss.canvas.ignoresSafeArea())
    .statusBarHidden(true)
    .sheet(item: $more) { cluster in
      MoreOnThis(cluster: cluster) { more = nil }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .accessibilityActions {
      Button("Next") { next() }
      Button("Previous") { back() }
      Button(held ? "Resume" : "Pause") { held.toggle() }
    }
    .onAppear {
      if UIAccessibility.isVoiceOverRunning { held = true }
    }
    // The pictures once the cover is up, so their work doesn't hold up its entrance.
    .task {
      try? await Task.sleep(for: .milliseconds(600))
      CatchupImagePreloader.shared.preload(clusters: deck.entries.map(\.cluster))
    }
    .task {
      var last = Date.now
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(33))
        let now = Date.now
        defer { last = now }
        guard !isPaused, duration.isFinite else { continue }
        clock.elapsed += min(now.timeIntervalSince(last), 0.1)
        if clock.elapsed >= duration { next() }
      }
    }
  }

  // MARK: Navigation

  func go(to newIndex: Int) {
    let target = min(max(newIndex, 0), pages.count - 1)
    if startedAt == nil, target > 0 { startedAt = .now }
    clock.elapsed = 0
    withAnimation(.easeOut(duration: 0.2)) { index = target }
    switch pages[target] {
    case .story(let i): pipeline.markRead(deck.entries[i].cluster)
    case .done: UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: TopTen.finishedKey)
    default: break
    }
  }

  func next() { go(to: index + 1) }

  /// Back to the start of this slide, or to the one before if it has only just begun.
  func back() {
    if clock.elapsed > 1.2 || index <= 1 {
      clock.elapsed = 0
    } else {
      go(to: index - 1)
    }
  }

  func openFull(_ cluster: StoryCluster) {
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { openStory(cluster) }
  }

  // MARK: Pages

  @ViewBuilder func content(topInset: CGFloat) -> some View {
    switch page {
    case .cover: TopCoverPage(deck: deck) { go(to: 1) } close: { dismiss() }
    case .story(let i):
      TopStoryPage(entry: deck.entries[i], total: deck.entries.count, made: deck.made, topInset: topInset) {
        more = deck.entries[i].cluster
      } close: { dismiss() }
    case .episodes:
      TopEpisodesPage(deck: deck, counter: counter) { dismiss() }.padding(.top, -4)
    case .media:
      TopMediaPage(deck: deck, counter: counter) { dismiss() }.padding(.top, -4)
    case .done:
      TopDonePage(deck: deck, minutes: startedAt.map { max(1, Int((Date.now.timeIntervalSince($0) / 60).rounded(.up))) } ?? deck.minutes) {
        openFull($0)
      } close: { dismiss() }
    }
  }

  /// "16/17" on the update pages: their place among all the timed pages.
  var counter: String {
    let position = (timed.firstIndex(of: page) ?? 0) + 1
    return String(format: "%02d/%02d", position, timed.count)
  }

  /// The timer in dots: one run per timed page, the done ones lit, this one lighting dot by dot.
  var timer: some View {
    ReelTimer(clock: clock, count: timed.count, current: timed.firstIndex(of: page) ?? -1, duration: duration)
      .accessibilityHidden(true)
  }
}

// MARK: Shared pieces

/// The slide's top line: its place in a dot chip on ink, the edition in regular SF, close.
private struct Folio: View {
  let counter: String
  let line: String
  /// Over the story's picture: the line in ink (it sits on the blur), the close button on glass.
  var onPicture = false
  var close: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      DotText(counter, pitch: 1.4)
        .foregroundStyle(Swiss.onInk)
        .padding(.horizontal, 9)
        .pillHeight()
        .background(Swiss.ink, in: Capsule())
        .fixedSize()
        .accessibilityLabel(counter.replacingOccurrences(of: "/", with: " of "))
      Text(line).font(.footnote).foregroundStyle(onPicture ? Swiss.ink : Swiss.muted).lineLimit(1)
      Spacer(minLength: 8)
      CloseButton(onPicture: onPicture, close: close)
    }
  }
}

private struct CloseButton: View {
  var onPicture = false
  var close: () -> Void
  var body: some View {
    if onPicture {
      Button("Close", systemImage: "xmark", action: close)
        .buttonStyle(RoundIconButtonStyle(background: AnyShapeStyle(.ultraThinMaterial)))
    } else {
      Button("Close", systemImage: "xmark", action: close).buttonStyle(.roundIcon)
    }
  }
}

/// A page's contents arrive a beat after the page: the entrances timed by the clock (the
/// block's flap, the rebus, the dot faces) start when they're added, and the first frame of a
/// new page can come well after that. Added once the main thread is free, they start on screen.
private struct Arrives<Content: View>: View {
  @ViewBuilder var content: () -> Content
  @State private var ready = false

  var body: some View {
    ZStack {
      if ready { content() } else { Color.clear }
    }
    .task {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(40))
      ready = true
    }
  }
}

/// The running page's time, kept apart from the reel's state (see `TopTenReel.clock`).
@MainActor @Observable final class ReelClock {
  var elapsed: Double = 0
}

/// The dot timer, the only view that reads the clock.
private struct ReelTimer: View {
  let clock: ReelClock
  let count: Int
  let current: Int
  let duration: Double

  var body: some View {
    DotTimer(count: count, current: current, fraction: duration.isFinite ? min(max(clock.elapsed / duration, 0), 1) : 0)
  }
}

/// The timer in the dot face's own dots (the 01/10 chip's pitch, snapped to whole pixels like
/// `DotText`): one run of dots per page, two dots apart. Done pages are lit, this one lights dot
/// by dot, the next dot fading up with the time, the rest faint.
private struct DotTimer: View {
  let count: Int
  let current: Int
  let fraction: Double
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Canvas { ctx, size in
      let scale = max(displayScale, 1)
      let pitch = max(2, (1.4 * scale).rounded()) / scale
      let dot = max(1, (pitch * scale * 0.7).rounded()) / scale
      let gap = 2
      let total = Int(size.width / pitch)
      let per = max(2, (total - gap * max(count - 1, 0)) / max(count, 1))
      let filled = Double(per) * fraction
      let whole = Int(filled.rounded(.down))
      var lit = Path(), off = Path(), lead = Path()
      for run in 0..<count {
        for k in 0..<per {
          let i = run * (per + gap) + k
          let rect = CGRect(x: CGFloat(i) * pitch, y: (size.height - dot) / 2, width: dot, height: dot)
          if run < current || (run == current && k < whole) {
            lit.addEllipse(in: rect)
          } else if run == current && k == whole {
            lead.addEllipse(in: rect)
          } else {
            off.addEllipse(in: rect)
          }
        }
      }
      ctx.fill(off, with: .color(Swiss.ink.opacity(0.2)))
      ctx.fill(lit, with: .color(Swiss.ink))
      ctx.fill(lead, with: .color(Swiss.ink.opacity(0.2 + 0.8 * (filled - Double(whole)))))
    }
    .frame(height: 4)
  }
}

/// A blur that melts down into the picture: frosted at the top edge, gone at the bottom, with a
/// little of the page's tint, so the timer and the top line read on any photo.
private struct TopBlur: View {
  /// Fully blurred down to here (half the top safe area: the Dynamic Island's middle), fading
  /// out below it; the whole blur ends near the island's bottom.
  var solid: CGFloat
  var height: CGFloat

  var body: some View {
    let edge = height > 0 ? min(max(solid / height, 0), 1) : 0
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: edge), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
      LinearGradient(stops: [.init(color: Swiss.canvas.opacity(0.35), location: 0), .init(color: Swiss.canvas.opacity(0.2), location: edge), .init(color: Swiss.canvas.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
    }
    .frame(height: height)
    .allowsHitTesting(false)
  }
}

/// The page's one main action, across the width: ink, reversed in the dark reel.
private struct WideAction: View {
  let title: String
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(Swiss.onInk)
        .background(Swiss.ink, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

extension Date {
  /// "Mon 16 Nov", for a slide's top line.
  var editionDay: String {
    "\(formatted(.dateTime.weekday(.abbreviated))) \(formatted(.dateTime.day())) \(formatted(.dateTime.month(.abbreviated)))"
      .replacingOccurrences(of: ".", with: "")
  }
}

/// The rebus's date line, as on Today: MON [16] (NOV) clock 18:11.

/// Slide elements rise in one after another, `Entrance.step`-ish apart, each time a slide shows.
private extension View {
  func slideIn(_ order: Int) -> some View { entrance(0.08 + Double(order) * 0.07, quick: false) }
}

// MARK: Cover

private struct TopCoverPage: View {
  let deck: TopTen
  var start: () -> Void
  var close: () -> Void
  /// Today's rebus size.
  @ScaledMetric(relativeTo: .body) private var rebusSize: CGFloat = 19

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack { Spacer(); CloseButton(close: close) }
      // Today's header, the same sizes and order: the day, the block, what it counts.
      // In the reader's look (Settings › Look), like Today's top.
      LookTop(date: deck.made, block: "TOP10TOP10", rollsFrom: "NEWNEW", figure: "TOP 10", lines: coverLines)
      if deck.entries.isEmpty {
        Text("Nothing is big enough yet. Pull to refresh Today, or come back in a while.")
          .font(.body).foregroundStyle(Swiss.muted).padding(.top, Rhythm.section).slideIn(4)
      } else {
        index.padding(.top, Rhythm.section)
      }
      Spacer(minLength: Rhythm.section)
      if !deck.entries.isEmpty {
        WideAction(title: "Start reading", action: start).slideIn(9)
        Text("Tap to move on · hold to pause · pull up for more")
          .font(.footnote).foregroundStyle(Swiss.muted)
          .frame(maxWidth: .infinity).padding(.top, Rhythm.beat - 10).slideIn(10)
      }
    }
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .padding(.horizontal, Swiss.pageInset)
    .padding(.bottom, 12)
    .accessibilityElement(children: .contain)
  }

  var coverLines: [LookLine] {
    var out = [LookLine(tokens: countTokens, delay: 0.3)]
    if !deck.quiet.isEmpty {
      out.append(LookLine(tokens: [.word("QUIET")] + deck.quiet.map { .outline($0.rebusWord) }, delay: 0.45))
    }
    if deck.updateCount > 0 {
      out.append(LookLine(tokens: [.word("+"), .filled("\(deck.updateCount)"), .word("UPDATES"), .word("AT"), .word("THE"), .word("END"), .go], delay: 0.6))
    }
    return out
  }

  var countTokens: [BlockToken] {
    var out: [BlockToken] = []
    if deck.entries.count < TopTen.size { out += [.filled("\(deck.entries.count)"), .word(deck.entries.count == 1 ? "STORY" : "STORIES")] }
    out += [.word("IN"), .filled("\(deck.pillars.count)"), .word(deck.pillars.count == 1 ? "PILLAR" : "PILLARS"), .word("ABOUT"), .filled("\(deck.minutes)"), .word("MIN")]
    return out
  }

  /// "In this edition": the first four, two columns, set apart by space alone.
  var index: some View {
    VStack(alignment: .leading, spacing: 0) {
      Eyebrow("In this edition").slideIn(4)
      let first = Array(deck.entries.prefix(4))
      ForEach(Array(stride(from: 0, to: first.count, by: 2)), id: \.self) { row in
        HStack(alignment: .top, spacing: Rhythm.section) {
          ForEach(first[row..<min(row + 2, first.count)]) { entry in
            VStack(alignment: .leading, spacing: Rhythm.tight) {
              // As the card's meta line: the rank in mono (a figure), the section in medium.
              HStack(spacing: Rhythm.tight) {
                Text(String(format: "%02d", entry.rank)).font(Swiss.smallFigure)
                Text(entry.cluster.lead?.category ?? entry.cluster.storedPillar.title).font(.footnote.weight(.medium))
              }
              .foregroundStyle(Swiss.muted).lineLimit(1)
              Text(entry.cluster.lead?.title ?? "")
                .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          if row + 1 >= first.count { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
        .padding(.top, row == 0 ? Rhythm.beat : Rhythm.row)
        .slideIn(5 + row / 2)
      }
      if deck.entries.count > 4 {
        Text("…and \(deck.entries.count - 4) more").font(.footnote).foregroundStyle(Swiss.muted)
          .padding(.top, Rhythm.beat).slideIn(7)
      }
    }
  }
}

// MARK: Story

/// One story as a front-page lead: the publisher's picture across the full width and up to the
/// top edge, the timer and top line on a blur over it; then the card's meta line, the Times
/// headline and its credit, the extract, the outlets, two other outlets' headlines side by side
/// (one alone takes the full width; or what's new since you read it), and the bar that pulls up
/// more.
private struct TopStoryPage: View {
  let entry: TopTen.Entry
  let total: Int
  let made: Date
  let topInset: CGFloat
  var more: () -> Void
  var close: () -> Void

  var cluster: StoryCluster { entry.cluster }
  var hasPicture: Bool { cluster.articles.contains { $0.imageURL != nil } }

  var body: some View {
    if let lead = cluster.lead {
      // `Rhythm`: tight inside the headline block, a beat between meta, headline, extract and
      // outlets, a section break before how it's told and before the bar.
      VStack(alignment: .leading, spacing: 0) {
        header.slideIn(0)
        VStack(alignment: .leading, spacing: 0) {
          meta(lead).slideIn(1)
            .padding(.top, Rhythm.section)
          VStack(alignment: .leading, spacing: Rhythm.tight) {
            Text(lead.title)
              .font(Swiss.headline(34, relativeTo: .largeTitle))
              .foregroundStyle(Swiss.ink)
              .lineLimit(4)
              .minimumScaleFactor(0.8)
              .fixedSize(horizontal: false, vertical: true)
            HeadlineCredit(article: lead)
          }
          .padding(.top, Rhythm.beat)
          .slideIn(2)
          if !lead.shortSnippet.isEmpty {
            Text(lead.shortSnippet)
              .font(.body).foregroundStyle(Swiss.muted)
              .lineLimit(2).fixedSize(horizontal: false, vertical: true)
              .padding(.top, Rhythm.beat)
              .slideIn(3)
          }
          OutletPills(outlets: cluster.outlets).padding(.top, Rhythm.beat).slideIn(4)
          Group { if entry.unseen.isEmpty { told } else { newSince } }
            .padding(.top, Rhythm.section)
            .slideIn(5)
          Spacer(minLength: Rhythm.section)
          moreBar.slideIn(6)
        }
        .padding(.horizontal, Swiss.pageInset)
        .padding(.bottom, 12)
      }
      .ignoresSafeArea(edges: .top)
    }
  }

  var folio: some View {
    Folio(counter: String(format: "%02d/%02d", entry.rank, total), line: "Top 10 · \(made.editionDay)", onPicture: hasPicture, close: close)
      .padding(.horizontal, Swiss.pageInset)
      .padding(.top, topInset + 6)
  }

  /// The picture to the edges and the top (about 40 % of the screen at most, giving up height
  /// first when the page is full), the blur and the top line over it. No picture: the top line.
  @ViewBuilder var header: some View {
    if hasPicture {
      ReelPicture(cluster: cluster)
        .frame(maxWidth: .infinity, minHeight: topInset + 200, maxHeight: topInset + 360)
        .clipped()
        // Only behind the timer and the top line: the photo is sharp from just under them.
        .overlay(alignment: .top) { TopBlur(solid: topInset / 2, height: (topInset + 84) / 2) }
        .overlay(alignment: .top) { folio }
        // Ahead of the spacer under the text: the picture takes its height first, and gives
        // it back only when the words need the room.
        .layoutPriority(1)
    } else {
      folio
    }
  }

  var moreBar: some View {
    Button(action: more) {
      VStack(spacing: 8) {
        Capsule().fill(Swiss.ink.opacity(0.3)).frame(width: 36, height: 4)
        HStack(spacing: 8) {
          Text("More on this").font(.subheadline.weight(.medium))
          Spacer(minLength: 6)
          Text(moreSummary).font(.footnote).lineLimit(1)
          Image(systemName: "arrow.up").font(.footnote.weight(.medium))
        }
      }
      .foregroundStyle(Swiss.ink)
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 12)
      .background(Swiss.tile, in: RoundedRectangle(cornerRadius: Swiss.tileRadius, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("More on this: \(moreSummary)")
  }

  /// The card's meta line: section and age, then the signal and the sources count.
  func meta(_ lead: ArticleItem) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Text(lead.category ?? cluster.storedPillar.title).font(.footnote.weight(.medium))
        Text(cluster.updatedAt.shortAgo).font(Swiss.smallFigure)
      }
      .foregroundStyle(Swiss.muted)
      .lineLimit(1)
      Spacer(minLength: 6)
      if let back = entry.backNew {
        SignalBadge(.attention, "Back · \(back) new")
      } else if isDeveloping {
        SignalBadge(.attention, "Developing")
      }
      DotChip("\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "SOURCE" : "SOURCES")")
    }
  }

  var isDeveloping: Bool {
    cluster.articles.filter { Date.now.timeIntervalSince($0.publishedAt) < 30 * 60 }.count >= 2
  }

  var moreSummary: String {
    var parts = ["The read"]
    if !entry.unseen.isEmpty { parts.append("\(entry.unseen.count) new") }
    let videos = cluster.articles.filter { $0.videoID != nil }.count
    if videos > 0 { parts.append(videos == 1 ? "1 video" : "\(videos) videos") }
    if cluster.episode != nil { parts.append("1 episode") }
    return parts.joined(separator: " · ")
  }

  var others: [ArticleItem] {
    var seen: Set<String> = [cluster.lead?.outlet ?? ""]
    return Array(cluster.sortedArticles.filter { !$0.isMedia && seen.insert($0.outlet).inserted }.prefix(2))
  }

  /// Two other outlets' own headlines side by side, space between; one alone takes the width.
  @ViewBuilder var told: some View {
    let others = others
    if !others.isEmpty {
      VStack(alignment: .leading, spacing: Rhythm.beat) {
        Eyebrow("How it's told")
        HStack(alignment: .top, spacing: Rhythm.section) {
          ForEach(others) { article in
            VStack(alignment: .leading, spacing: Rhythm.tight) {
              Text(article.title)
                .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
              HeadlineCredit(article: article)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }
      }
    }
  }

  /// Read before: what arrived since, newest first.
  var newSince: some View {
    VStack(alignment: .leading, spacing: Rhythm.beat) {
      Eyebrow("New since you read it")
      VStack(alignment: .leading, spacing: Rhythm.row) {
      ForEach(entry.unseen.prefix(2)) { article in
        HStack(alignment: .firstTextBaseline, spacing: Rhythm.beat) {
          Text(article.publishedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
            .font(Swiss.smallFigure).foregroundStyle(Swiss.muted)
          VStack(alignment: .leading, spacing: Rhythm.tight) {
            Text(article.title)
              .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
              .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HeadlineCredit(article: article)
          }
        }
      }
    }
  }
}

/// The publisher's picture, filling the frame it's given (cropped from the middle); grey while
/// it loads.
private struct ReelPicture: View {
  let cluster: StoryCluster
  @State private var image: UIImage?

  init(cluster: StoryCluster) {
    self.cluster = cluster
    _image = State(initialValue: CatchupImagePreloader.shared.cachedImage(for: cluster.id))
  }

  var body: some View {
    Color.clear
      .overlay {
        if let image {
          Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
        } else {
          Swiss.tileQuiet
        }
      }
      .clipped()
      .accessibilityHidden(true)
      .task(id: cluster.id) {
        guard image == nil else { return }
        let loaded = await CatchupImagePreloader.shared.load(for: cluster).value
        withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
  }
}

// MARK: More on this

/// Pulled up from a story: the timer waits. Opening it is the tap that starts the read: Apple
/// Intelligence compares the coverage at once (cached after, so it's instant the next time;
/// the headline preview where it isn't available). Every outlet's headline with its credit,
/// videos and episodes, and two ways out that say where they go: Continue, and the lead
/// article at its publisher.
private struct MoreOnThis: View {
  let cluster: StoryCluster
  var resume: () -> Void
  @Environment(FeedSyncPipeline.self) private var pipeline
  @Environment(\.openURL) private var openURL
  @State private var writing = false
  @State private var failed = false
  /// A lens tapped in the spectrum narrows the outlets below to it, as on the story page.
  @State private var lens: EditorialLens?

  var sources: [IntelligenceService.Source] {
    cluster.sortedArticles.map { IntelligenceService.Source(outlet: $0.outlet, title: $0.title, snippet: $0.shortSnippet) }
  }

  /// Each outlet's newest article.
  var perOutlet: [ArticleItem] {
    var seen = Set<String>()
    return cluster.sortedArticles.filter { !$0.isMedia && seen.insert($0.outlet).inserted }
  }

  /// The outlets the chosen lens keeps (all of them without one).
  var listed: [ArticleItem] {
    guard let lens else { return perOutlet }
    return perOutlet.filter { EditorialLens.classify(outlet: $0.outlet, pillar: cluster.pillar) == lens }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Rhythm.section) {
        HStack(spacing: 8) {
          // A quiet chip like N SOURCES: a state, not an action.
          DotChip("PAUSED", decodeDelay: 0.35).fixedSize()
          Text("The timer waits while this is open").font(.footnote).foregroundStyle(Swiss.muted)
            .lineLimit(1)
          Spacer(minLength: 8)
          // The one place an article is shared from: here, in More on this.
          if let lead = cluster.lead, let url = URL(string: lead.url) {
            ShareLink(item: url, subject: Text(lead.title), message: Text("\(lead.title) · \(lead.outlet)")) {
              Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.roundIcon)
            .accessibilityLabel("Share \(lead.outlet)'s article")
          }
        }
        .entrance(0.05)
        // Who covers it, by kind of outlet, above how they cover it, as on the story page;
        // shows only with two or more outlets.
        CoverageSpectrumCard(cluster: cluster, selectedLens: $lens).entrance(0.12)
        read.entrance(0.16)
        VStack(alignment: .leading, spacing: Rhythm.beat) {
          Eyebrow(lens.map { "Every outlet's headline · \($0.shortLabel)" } ?? "Every outlet's headline")
          VStack(alignment: .leading, spacing: Rhythm.row) {
            ForEach(listed) { article in
              HStack(alignment: .firstTextBaseline, spacing: Rhythm.beat) {
                Text(article.publishedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                  .font(Swiss.smallFigure).foregroundStyle(Swiss.muted)
                VStack(alignment: .leading, spacing: Rhythm.tight) {
                  Text(article.title)
                    .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
                    .fixedSize(horizontal: false, vertical: true)
                  HeadlineCredit(article: article)
                }
              }
            }
          }
          MediaPills(episode: cluster.episode, video: cluster.video).padding(.top, Rhythm.tight)
        }
        .entrance(0.2)
        // Side by side when they fit; a long outlet name ("South China Morning Post") stacks
        // them, or the row widens the whole sheet past the screen's edges.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Rhythm.beat) { exits }
          VStack(alignment: .leading, spacing: Rhythm.beat) { exits }
        }
        .entrance(0.3)
      }
      .padding(.horizontal, Swiss.pageInset)
      .padding(.top, Rhythm.section)
      .padding(.bottom, Rhythm.section)
    }
    .background(Swiss.canvas)
    // Opening it was the tap: the read starts now, once.
    .task { await write() }
  }

  /// Continue, and the lead article at its publisher.
  @ViewBuilder var exits: some View {
    Button("Continue", action: resume).buttonStyle(.swissPrimary)
    if let lead = cluster.lead, let url = URL(string: lead.url) {
      Button {
        LinkOpener.open(url) { openURL(url) }
      } label: {
        Label("Read at \(lead.outlet)", systemImage: "arrow.up.right").labelStyle(TrailingIcon())
      }
      .buttonStyle(.swissSecondary)
      .accessibilityHint("Opens the article")
    }
  }

  /// The saved read; while it writes, the writing chip; without Apple Intelligence (or if it
  /// couldn't), the headline preview.
  @ViewBuilder var read: some View {
    if let brief = cluster.brief {
      BriefPanel(brief: brief, newSources: 0, refresh: {}, outletArticle: { name in
        perOutlet.first { $0.outlet.caseInsensitiveCompare(name) == .orderedSame }
      }, open: { link in
        guard let url = URL(string: link) else { return }
        LinkOpener.open(url) { openURL(url) }
      })
    } else if IntelligenceService.isAvailable && !failed {
      VStack(alignment: .leading, spacing: Rhythm.beat) {
        Eyebrow("The read · Apple Intelligence")
        WritingChip().frame(height: 32)
        Text("Comparing how \(cluster.outlets.count) outlets tell this story.")
          .font(.subheadline).foregroundStyle(Swiss.muted).fixedSize(horizontal: false, vertical: true)
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
    } else {
      BriefPanel(brief: IntelligenceService.previewBrief(sources, mode: cluster.briefMode), newSources: 0, refresh: {})
    }
  }

  func write() async {
    guard cluster.brief == nil, IntelligenceService.isAvailable, !writing else { return }
    writing = true
    defer { writing = false }
    do {
      let brief = try await IntelligenceService.brief(for: sources, mode: cluster.briefMode)
      withAnimation(.snappy) { pipeline.saveBrief(brief, for: cluster) }
    } catch {
      withAnimation(.snappy) { failed = true }
    }
  }
}

/// "Read at BBC News ↗": the words first, the arrow after.
private struct TrailingIcon: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
  }
}

// MARK: Updates

/// "Two new episodes": counts as words up to twelve, like a headline.
private func countWord(_ n: Int) -> String {
  let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
  return n < words.count ? words[n] : "\(n)"
}

/// A meta line as on the cards: the name in medium, the age in mono.
private struct MetaLine: View {
  let name: String
  let date: Date
  var body: some View {
    HStack(spacing: Rhythm.tight) {
      Text(name).font(.footnote.weight(.medium))
      Text(date.shortAgo).font(Swiss.smallFigure)
    }
    .foregroundStyle(Swiss.muted)
    .lineLimit(1)
  }
}

private struct TopEpisodesPage: View {
  let deck: TopTen
  let counter: String
  var close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Folio(counter: counter, line: deck.sinceLine, close: close)
        .slideIn(0)
      Text("\(countWord(deck.episodes.count)) new \(deck.episodes.count == 1 ? "episode" : "episodes")")
        .font(Swiss.headline(34, relativeTo: .largeTitle)).foregroundStyle(Swiss.ink)
        .padding(.top, Rhythm.section)
        .slideIn(1)
      ForEach(Array(deck.episodes.enumerated()), id: \.element.id) { i, episode in
        VStack(alignment: .leading, spacing: Rhythm.tight) {
          MetaLine(name: episode.outlet, date: episode.publishedAt)
          Text(episode.title)
            .font(Swiss.headline(24, relativeTo: .title3)).foregroundStyle(Swiss.ink)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
          ListenPill(episode: episode).padding(.top, Rhythm.tight)
        }
        .padding(.top, i == 0 ? Rhythm.section : Rhythm.row)
        .slideIn(2 + i)
      }
      Text("Opens in Apple Podcasts when it's there; otherwise it plays here, also from the Lock Screen.")
        .font(.footnote).foregroundStyle(Swiss.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Rhythm.section)
        .slideIn(2 + deck.episodes.count)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Swiss.pageInset)
    .padding(.top, 10)
  }
}

private struct TopMediaPage: View {
  let deck: TopTen
  let counter: String
  var close: () -> Void
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Folio(counter: counter, line: deck.sinceLine, close: close)
        .slideIn(0)
      if let video = deck.videos.first {
        VStack(alignment: .leading, spacing: 0) {
          Eyebrow("From your channels")
          HeroImage(remote: video.imageURL, article: video.url, radius: 16, aspect: 16 / 9, isVideo: true)
            .frame(maxHeight: 210)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, Rhythm.beat)
          MetaLine(name: "\(video.outlet) · YouTube", date: video.publishedAt).padding(.top, Rhythm.beat)
          Text(video.title)
            .font(Swiss.headline(24, relativeTo: .title3)).foregroundStyle(Swiss.ink)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            .padding(.top, Rhythm.tight)
          if let url = video.videoURL {
            Button { openURL(url) } label: { Label("Watch on YouTube", systemImage: "play.rectangle.fill") }
              .buttonStyle(MediaPillStyle())
              .padding(.top, Rhythm.beat)
          }
        }
        .padding(.top, Rhythm.section)
        .slideIn(1)
        ForEach(Array(deck.videos.dropFirst().enumerated()), id: \.element.id) { i, more in
          VStack(alignment: .leading, spacing: Rhythm.tight) {
            Text(more.title).font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink).lineLimit(2)
            HeadlineCredit(article: more)
          }
          .padding(.top, Rhythm.row)
          .slideIn(2 + i)
        }
      }
      if !deck.posts.isEmpty {
        VStack(alignment: .leading, spacing: Rhythm.beat) {
          Eyebrow("From your feeds")
          VStack(alignment: .leading, spacing: Rhythm.row) {
            ForEach(deck.posts) { post in
              VStack(alignment: .leading, spacing: Rhythm.tight) {
                Text(post.title)
                  .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
                  .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Rhythm.tight) {
                  HeadlineCredit(article: post)
                  Text(post.publishedAt.shortAgo).font(Swiss.smallFigure).foregroundStyle(Swiss.muted)
                }
              }
            }
          }
        }
        .padding(.top, Rhythm.section)
        .slideIn(4)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Swiss.pageInset)
    .padding(.top, 10)
  }
}

// MARK: Done

private struct TopDonePage: View {
  let deck: TopTen
  let minutes: Int
  var open: (StoryCluster) -> Void
  var close: () -> Void
  @ScaledMetric(relativeTo: .body) private var rebusSize: CGFloat = 19

  var doneLines: [LookLine] {
    var out = [LookLine(tokens: [.filled("\(deck.entries.count)"), .word(deck.entries.count == 1 ? "STORY" : "STORIES"), .word("IN"), .filled("\(minutes)"), .word("MIN")], delay: 0.3)]
    if deck.updateCount > 0 {
      out.append(LookLine(tokens: [.filled("\(deck.updateCount)"), .word(deck.updateCount == 1 ? "UPDATE" : "UPDATES"), .word("ALL"), .word("SEEN")], delay: 0.45))
    }
    return out
  }

  /// Still moving: two outlets or more in the last two hours.
  var developing: [TopTen.Entry] {
    Array(deck.entries.filter { entry in
      Set(entry.cluster.articles.filter { Date.now.timeIntervalSince($0.publishedAt) < 2 * 3600 }.map(\.outlet)).count >= 2
    }.prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack { Spacer(); CloseButton(close: close) }
      LookTop(date: .now, block: "DONEDONE", rollsFrom: "TOP10TOP10", figure: "DONE", lines: doneLines)
      if !developing.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          Eyebrow("Still developing").slideIn(4)
          ForEach(Array(developing.enumerated()), id: \.element.id) { i, entry in
            Button { open(entry.cluster) } label: {
              HStack(alignment: .top, spacing: Rhythm.beat) {
                DotChip(String(format: "%02d", entry.rank), label: "Number \(entry.rank)").padding(.top, 2)
                VStack(alignment: .leading, spacing: Rhythm.tight) {
                  Text(entry.cluster.lead?.title ?? "")
                    .font(Swiss.headline(20, relativeTo: .title3)).foregroundStyle(Swiss.ink)
                    .multilineTextAlignment(.leading).lineLimit(2)
                  Text(entry.cluster.lead?.category ?? entry.cluster.storedPillar.title)
                    .font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, i == 0 ? Rhythm.beat : Rhythm.row)
            .slideIn(5 + i)
          }
          Text("When one of them turns, it comes back into Top 10 with a mint mark.")
            .font(.footnote).foregroundStyle(Swiss.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Rhythm.section)
            .slideIn(8)
        }
        .padding(.top, Rhythm.section)
      }
      Spacer(minLength: Rhythm.section)
      WideAction(title: "Back to Today", action: close).slideIn(9)
    }
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .padding(.horizontal, Swiss.pageInset)
    .padding(.bottom, 12)
  }
}
