import SafariServices
import SwiftData
import SwiftUI

extension ArticleItem {
  /// EU Article 15 safe-harbor extract: caps snippets at ~150 characters on a word boundary
  /// and suppresses snippets that merely duplicate the headline.
  var shortSnippet: String {
    let clean = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return "" }
    if clean.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
      return ""
    }
    let maxChars = 150
    guard clean.count > maxChars else { return clean }
    let prefix = clean.prefix(maxChars)
    if let lastSpace = prefix.lastIndex(of: " ") {
      return String(prefix[..<lastSpace]).trimmingCharacters(in: .punctuationCharacters) + "…"
    }
    return String(prefix) + "…"
  }
}

/// Opens a link in the app that claims it (universal links: YouTube, The New York Times, The
/// Guardian and most publishers with an app), or runs `otherwise` when no app does.
enum LinkOpener {
  /// The publisher's app if one claims the link, trying the other forms of the address too
  /// (with or without "www", and bbc.co.uk ↔ bbc.com: the international BBC News app may
  /// claim only one); `otherwise` when none does.
  static func open(_ url: URL, otherwise: @escaping @MainActor () -> Void) {
    attempt([url] + alternates(url), otherwise: otherwise)
  }

  private static func attempt(_ urls: [URL], otherwise: @escaping @MainActor () -> Void) {
    guard let url = urls.first else {
      Task { @MainActor in otherwise() }
      return
    }
    UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
      if !opened { attempt(Array(urls.dropFirst()), otherwise: otherwise) }
    }
  }

  /// Other addresses for the same page, most likely first.
  static func alternates(_ url: URL) -> [URL] {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else { return [] }
    var hosts: [String] = []
    // Domains a publisher runs under two names.
    let twins = [("bbc.co.uk", "bbc.com")]
    for (a, b) in twins {
      if host.hasSuffix(a) { hosts.append(host.replacingOccurrences(of: a, with: b)) }
      if host.hasSuffix(b) { hosts.append(host.replacingOccurrences(of: b, with: a)) }
    }
    for h in [host] + hosts {
      hosts.append(h.hasPrefix("www.") ? String(h.dropFirst(4)) : "www." + h)
    }
    var seen: Set<String> = [host]
    return hosts.compactMap { h in
      guard seen.insert(h).inserted else { return nil }
      parts.host = h
      return parts.url
    }
  }
}

/// Wrapper so a `URL` can drive a sheet or split pane.
private struct ActiveWebURL: Identifiable, Equatable {
  let url: URL
  var id: String { url.absoluteString }
}

/// Embeds Safari directly inside the right 50% of the unfolded inside screen (or a sheet on compact screens).
private struct InAppSafariView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let config = SFSafariViewController.Configuration()
    config.entersReaderIfAvailable = false
    config.barCollapsingEnabled = true
    let safari = SFSafariViewController(url: url, configuration: config)
    safari.dismissButtonStyle = .close
    return safari
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// One story: its coverage compared (on a tap, by Apple Intelligence), then every outlet's
/// headline linking out to the publisher. On a wide/unfolded screen, links open in a 50%
/// side-by-side split pane.
struct StoryDetailView: View {
  let cluster: StoryCluster
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.openURL) var openURL
  @State private var isWriting = false
  @State private var failure: String?
  /// Snapshots any newly-arrived update articles on entry before `markRead` clears them.
  @State private var updatesSinceLastRead: [ArticleItem] = []
  /// Currently opened article URL for the 50% split pane (wide screen) or sheet (compact screen).
  @State private var activeWebURL: ActiveWebURL?
  /// Allows the user to hide/report an inaccurate AI summary in the current session.
  @State private var briefDismissed = false

  var body: some View {
    GeometryReader { geo in
      let isWideScreen = geo.size.width >= 600

      HStack(spacing: 0) {
        // Left 50% (or 100% when no link is open): Story detail & coverage list
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let lead = cluster.lead {
              // Single social-preview HeroImage only (no multi-photo gallery scraping)
              HeroImage(
                remote: lead.imageURL,
                article: lead.url,
                radius: 20,
                aspect: cluster.pillar.isPortrait ? 4 / 5 : 5 / 4,
                fits: lead.isChart,
                isVideo: lead.videoID != nil,
                topAligned: cluster.pillar.isPortrait
              )

              // Single unified Text expression on the left so baselines never break or stack in columns
              HStack(alignment: .center, spacing: 8) {
                metaLine(lead)
                Spacer(minLength: 6)
                DotChip("\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "SOURCE" : "SOURCES")")
              }
              .foregroundStyle(Swiss.muted)

              // The headline is the lead outlet's; the pill under it links to that article. The
              // headline itself isn't a button: swipes that started on it opened the article.
              Text(lead.title)
                .font(Swiss.headline(34, relativeTo: .title))
                .foregroundStyle(Swiss.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

              Button { openArticleURL(lead.url) } label: {
                HStack(spacing: 5) {
                  Text("Headline from").foregroundStyle(Swiss.muted)
                  Text(lead.outlet).fontWeight(.medium).foregroundStyle(Swiss.ink)
                  Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold)).foregroundStyle(Swiss.ink)
                }
                .font(.footnote)
                .padding(.horizontal, 10)
                .pillHeight()
                .background(Swiss.ink.opacity(0.07), in: Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Headline from \(lead.outlet)")
              .accessibilityAddTraits(.isLink)
            }

            if !updatesSinceLastRead.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Eyebrow("New since you read")
                ForEach(updatesSinceLastRead.prefix(3)) { item in
                  Button {
                    openArticleURL(item.url)
                  } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                      BulletDot(color: Swiss.mint)
                      Text("\(Text("\(item.outlet): ").fontWeight(.medium))\(item.title)")
                        .font(.subheadline)
                        .foregroundStyle(Swiss.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                  .buttonStyle(.plain)
                }
              }
              .padding(.top, 4)
            }

            // Videos and podcast episodes, folded into one row under the headline; opened, each links
            // out to where it plays.
            let media = cluster.sortedArticles.filter(\.isMedia)
            if !media.isEmpty {
              MediaFold(media: media) { chosenURL in
                openResolvedURL(chosenURL)
              }
              .padding(.top, 6)
            }

            if cluster.outlets.count > 1 {
              CoverageSpectrumCard(cluster: cluster)
                .padding(.top, 6)
            }

            if cluster.outlets.count > 1 || cluster.briefMode != .perspective {
              perspective.padding(.top, 6)
            }

            Eyebrow("Coverage").padding(.top, 14)
            ForEach(cluster.sortedArticles.filter { !$0.isMedia }) { article in
              ArticleRow(
                article: article,
                isSelected: activeWebURL?.url.absoluteString == article.url
              ) {
                openArticleURL(article.url)
              }
            }
            Text("Headlines and short extracts from each outlet's RSS feed. Tap any outlet to read the full article on the publisher's site.")
              .font(.footnote)
              .foregroundStyle(Swiss.muted)
              .padding(.top, 4)
          }
          .padding(.horizontal, Swiss.pageInset)
          .padding(.bottom, 32)
        }
        .frame(width: isWideScreen && activeWebURL != nil ? geo.size.width * 0.5 : geo.size.width)

        // Right 50%: In-app publisher split pane on wide/unfolded inside screens
        if isWideScreen, let active = activeWebURL {
          Divider()
            .overlay(Swiss.ink.opacity(0.15))

          VStack(spacing: 0) {
            HStack(spacing: 10) {
              Text(active.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Article")
                .font(.caption.monospaced())
                .foregroundStyle(Swiss.ink)
                .lineLimit(1)
              Spacer()
              Button {
                openURL(active.url)
              } label: {
                Label("Safari", systemImage: "safari")
                  .font(.footnote.weight(.medium))
                  .foregroundStyle(Swiss.muted)
              }
              .buttonStyle(.plain)

              Button("Close article pane", systemImage: "xmark") {
                withAnimation(.snappy(duration: 0.22)) { activeWebURL = nil }
              }
              .buttonStyle(.roundIcon)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Swiss.canvas)

            Divider()
              .overlay(Swiss.ink.opacity(0.1))

            InAppSafariView(url: active.url)
              .id(active.id)
              .ignoresSafeArea(edges: .bottom)
          }
          .frame(width: geo.size.width * 0.5)
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.snappy(duration: 0.24), value: activeWebURL)
      .environment(\.openURL, OpenURLAction { url in
        if isWideScreen, url.scheme == "http" || url.scheme == "https" {
          LinkOpener.open(url) {
            withAnimation(.snappy(duration: 0.24)) { activeWebURL = ActiveWebURL(url: url) }
          }
          return .handled
        }
        return .systemAction
      })
      .sheet(
        item: Binding(
          get: { isWideScreen ? nil : activeWebURL },
          set: { activeWebURL = $0 }
        )
      ) { active in
        InAppSafariView(url: active.url)
          .ignoresSafeArea()
      }
    }
    .swissCanvas()
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis") {
          Button("Follow stories like this", systemImage: "plus.circle") {
            Task { await pipeline.addTopic(like: cluster, kind: .follow) }
          }
          Button("Mute stories like this", systemImage: "speaker.slash") {
            Task { await pipeline.addTopic(like: cluster, kind: .mute) }
          }
          if cluster.brief != nil && !briefDismissed {
            Divider()
            Button("Hide AI summary", systemImage: "eye.slash") {
              withAnimation(.snappy) {
                briefDismissed = true
              }
            }
          }
        }
      }
    }
    .onAppear {
      if updatesSinceLastRead.isEmpty {
        updatesSinceLastRead = ReadLedger.unseenArticles(in: cluster)
      }
      pipeline.markRead(cluster)
      ReadLedger.record(cluster)
    }
  }

  /// Concatenates category and update time into one single Text block so it stays on one line
  /// (or wraps cleanly as a single sentence under large Dynamic Type without breaking baselines).
  @ViewBuilder
  private func metaLine(_ lead: ArticleItem) -> some View {
    let timeText = Text("Updated \(Text(cluster.updatedAt.shortAgo).font(Swiss.smallFigure)) ago")
    if let category = lead.category, !category.isEmpty {
      Text("\(Text(category).fontWeight(.medium))  \(timeText)")
        .font(.footnote)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      timeText
        .font(.footnote)
        .lineLimit(1)
    }
  }

  private func openArticleURL(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    openResolvedURL(url)
  }

  /// The publisher's own app first (YouTube, The New York Times, The Guardian…: any app that
  /// claims its links), else the in-app browser.
  private func openResolvedURL(_ url: URL) {
    LinkOpener.open(url) {
      withAnimation(.snappy(duration: 0.24)) { activeWebURL = ActiveWebURL(url: url) }
    }
  }

  // MARK: Perspective

  @ViewBuilder var perspective: some View {
    if let brief = cluster.brief, !briefDismissed {
      BriefPanel(
        brief: brief, newSources: max(cluster.articles.count - brief.sourceCount, 0),
        refresh: { Task { await write() } },
        outletArticle: { outlet in
          // The model writes the names; match the story's outlets ignoring case. Its newest
          // written article, else anything it has.
          let articles = cluster.sortedArticles.filter { $0.outlet.caseInsensitiveCompare(outlet) == .orderedSame }
          return articles.first(where: { !$0.isMedia }) ?? articles.first
        },
        open: { openArticleURL($0) })
      .opacity(isWriting ? 0.5 : 1)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text(invitation)
          .font(.subheadline)
          .foregroundStyle(Swiss.muted)
        HStack(spacing: 10) {
          Button {
            briefDismissed = false
            Task { await write() }
          } label: {
            switch mode {
            case .perspective: Label("Compare coverage", systemImage: "square.split.2x1")
            case .verdict: Label("Sum up the reviews", systemImage: "star.leadinghalf.filled")
            case .trend: Label("Read the trend", systemImage: "sparkles")
            }
          }
          .buttonStyle(.swissPrimary)
          .disabled(isWriting)
          if isWriting { WritingChip() }
        }
        .fixedSize(horizontal: false, vertical: true)
        if let failure {
          Text(failure).font(.footnote).foregroundStyle(Swiss.alert)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
    }
  }

  var mode: BriefMode { cluster.briefMode }

  var invitation: String {
    let count = cluster.outlets.count
    switch mode {
    case .perspective:
      return "See how \(count) outlets tell this story: what they agree on, and where they differ."
    case .verdict:
      return count == 1
        ? "What \(cluster.outlets[0]) makes of it: what's good, what isn't, and the verdict."
        : "What \(count) outlets make of it: what they praise, what they criticise, and the verdict."
    case .trend:
      return "The look and the moment: the shift, the names and pieces, why it matters and what to take from it."
    }
  }

  func write() async {
    guard !isWriting else { return }
    isWriting = true
    failure = nil
    defer { isWriting = false }
    let sources = cluster.sortedArticles.map {
      IntelligenceService.Source(outlet: $0.outlet, title: $0.title, snippet: $0.shortSnippet)
    }
    do {
      let brief = try await IntelligenceService.brief(for: sources, mode: mode)
      withAnimation(.snappy) { pipeline.saveBrief(brief, for: cluster) }
    } catch {
      failure = "Couldn't write it: \(error.localizedDescription)"
    }
  }
}

// MARK: - Coverage Spectrum Bar (Visualizing Outlet Blindspots)

enum EditorialLens: String, CaseIterable, Identifiable {
  case wire = "WIRE & GLOBAL"
  case markets = "MARKETS"
  case tech = "TECH & SCIENCE"
  case culture = "CULTURE & STYLE"

  var id: String { rawValue }

  var shortLabel: String {
    switch self {
    case .wire: "WIRE"
    case .markets: "MARKETS"
    case .tech: "TECH"
    case .culture: "CULTURE"
    }
  }

  static func classify(outlet: String, pillar: Pillar) -> EditorialLens {
    let lower = outlet.lowercased()

    let marketKeywords = [
      "financial", "bloomberg", "economist", "wall street", "wsj", "cnbc",
      "forbes", "fortune", "business", "market", "nikkei", "reuters business", "ft"
    ]
    if marketKeywords.contains(where: { lower.contains($0) }) {
      return .markets
    }

    let techKeywords = [
      "verge", "wired", "ars technica", "techcrunch", "engadget", "9to5", "macrumors",
      "register", "hacker", "mit", "nature", "science", "new scientist", "eurogamer",
      "polygon", "ign", "kotaku", "pc gamer", "digital foundry", "anandtech", "tom's"
    ]
    if techKeywords.contains(where: { lower.contains($0) }) {
      return .tech
    }

    let cultureKeywords = [
      "hypebeast", "highsnobiety", "gq", "vogue", "wwd", "dazed", "i-d", "pitchfork",
      "rolling stone", "variety", "hollywood", "deadline", "indiewire", "empire",
      "eater", "bon appétit", "monocle", "wallpaper", "dezeen", "architectural", "nme"
    ]
    if cultureKeywords.contains(where: { lower.contains($0) }) {
      return .culture
    }

    let wireKeywords = [
      "reuters", "associated press", "ap", "bbc", "guardian", "times", "post",
      "dw", "france 24", "al jazeera", "nrk", "politico", "axios", "npr", "cnn", "sky"
    ]
    if wireKeywords.contains(where: { lower.contains($0) }) {
      return .wire
    }

    switch pillar {
    case .briefing: return .wire
    case .tech: return .tech
    default: return .culture
    }
  }
}

struct CoverageSpectrum {
  struct Segment: Identifiable {
    let lens: EditorialLens
    let outlets: [String]
    let share: Double
    var id: String { lens.id }
  }

  let segments: [Segment]
  let totalOutlets: Int
  let blindspotBadge: String?
  let insightLine: String

  init(cluster: StoryCluster) {
    var seen = Set<String>()
    var grouped: [EditorialLens: [String]] = [:]

    for article in cluster.sortedArticles {
      guard seen.insert(article.outlet).inserted else { continue }
      let lens = EditorialLens.classify(outlet: article.outlet, pillar: cluster.pillar)
      grouped[lens, default: []].append(article.outlet)
    }

    let total = max(seen.count, 1)
    self.totalOutlets = seen.count
    self.segments = EditorialLens.allCases.compactMap { lens in
      guard let list = grouped[lens], !list.isEmpty else { return nil }
      return Segment(lens: lens, outlets: list, share: Double(list.count) / Double(total))
    }
    .sorted { $0.outlets.count > $1.outlets.count }

    let hasWire = !(grouped[.wire] ?? []).isEmpty
    let hasMarkets = !(grouped[.markets] ?? []).isEmpty
    let hasTech = !(grouped[.tech] ?? []).isEmpty
    let hasCulture = !(grouped[.culture] ?? []).isEmpty

    if seen.count >= 3 && !hasWire {
      self.blindspotBadge = "SPECIALIST PRESS"
      if hasTech && hasMarkets {
        self.insightLine = "Covered by tech and financial outlets; none of the general news outlets here has it yet."
      } else if hasTech {
        self.insightLine = "Covered by tech outlets; none of the general news outlets here has it yet."
      } else {
        self.insightLine = "Covered by specialist outlets; none of the general news outlets here has it yet."
      }
    } else if seen.count >= 3 && hasWire && !hasMarkets && !hasTech && !hasCulture {
      self.blindspotBadge = "GENERAL NEWS"
      self.insightLine = "Covered by general news outlets (\(seen.count) outlets)."
    } else if segments.count >= 3 {
      self.blindspotBadge = "MANY DESKS"
      self.insightLine = "Cross-desk story spanning \(segments.map { $0.lens.shortLabel.lowercased() }.joined(separator: ", ")) outlets."
    } else if let dominant = segments.first {
      self.blindspotBadge = nil
      self.insightLine = "Primarily covered by \(dominant.lens.shortLabel.lowercased()) outlets (\(dominant.outlets.prefix(2).joined(separator: ", ")))."
    } else {
      self.blindspotBadge = nil
      self.insightLine = ""
    }
  }
}

struct CoverageSpectrumCard: View {
  let cluster: StoryCluster
  var compact: Bool = false

  private var spectrum: CoverageSpectrum {
    CoverageSpectrum(cluster: cluster)
  }
  /// The entrance: the bar's segments grow left to right, then each lens label and the
  /// insight line come in. Plays once the card is on screen (after a pushed page has landed).
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private func reveal(_ index: Int) -> Animation {
    .spring(response: 0.5, dampingFraction: 0.9).delay(0.08 + Double(index) * 0.12)
  }

  var body: some View {
    if spectrum.totalOutlets > 1 {
      Group {
        if compact {
          compactBar
        } else {
          fullCard
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spokenSummary)
    }
  }

  /// "Coverage spectrum: wire 6, markets 2, tech 2. Many desks. Cross-desk story spanning…"
  private var spokenSummary: String {
    let counts = spectrum.segments.map { "\($0.lens.shortLabel.lowercased()) \($0.outlets.count)" }.joined(separator: ", ")
    var text = "Coverage spectrum: \(counts)."
    if let badge = spectrum.blindspotBadge { text += " \(badge.capitalized)." }
    if !spectrum.insightLine.isEmpty { text += " \(spectrum.insightLine)" }
    return text
  }

  private var compactBar: some View {
    VStack(alignment: .leading, spacing: 5) {
      spectrumStrip(height: 6)
      HStack(spacing: 8) {
        ForEach(spectrum.segments) { seg in
          HStack(spacing: 4) {
            lensSwatch(seg.lens, size: 7)
            Text("\(seg.lens.shortLabel) \(seg.outlets.count)")
              .font(.caption2.monospaced())
              .foregroundStyle(Swiss.muted)
          }
        }
        Spacer(minLength: 4)
        if let badge = spectrum.blindspotBadge {
          Text(badge)
            .font(.caption2.monospaced())
            .foregroundStyle(Swiss.ink)
        }
      }
    }
  }

  private var fullCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      EyebrowRow("Coverage spectrum") {
        if let badge = spectrum.blindspotBadge {
          DotChip(badge)
        }
      }

      spectrumStrip(height: 12)

      HStack(spacing: 12) {
        ForEach(Array(spectrum.segments.enumerated()), id: \.element.id) { index, seg in
          HStack(spacing: 5) {
            lensSwatch(seg.lens, size: 9)
            Text("\(seg.lens.shortLabel) · \(seg.outlets.count)")
              .font(.caption2.monospaced())
              .foregroundStyle(Swiss.ink)
          }
          .opacity(shown ? 1 : 0)
          .offset(y: shown ? 0 : 4)
          .animation(reveal(index + 1), value: shown)
        }
        Spacer(minLength: 0)
      }

      if !spectrum.insightLine.isEmpty {
        Text(spectrum.insightLine)
          .font(.footnote)
          .foregroundStyle(Swiss.muted)
          .fixedSize(horizontal: false, vertical: true)
          .opacity(shown ? 1 : 0)
          .animation(reveal(spectrum.segments.count + 1), value: shown)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
    .onGeometryChange(for: Bool.self) { [screen = DotText.screenSize] proxy in
      let frame = proxy.frame(in: .global)
      return frame.minX >= -1 && frame.maxX <= screen.width + 1 && frame.maxY > 0 && frame.minY < screen.height
    } action: { inView in
      if inView && !shown {
        if reduceMotion { shown = true } else { withAnimation { shown = true } }
      }
    }
  }

  private func spectrumStrip(height: CGFloat) -> some View {
    GeometryReader { geo in
      let spacing: CGFloat = 3
      let totalGaps = CGFloat(max(spectrum.segments.count - 1, 0)) * spacing
      let usableWidth = max(geo.size.width - totalGaps, 0)

      HStack(spacing: spacing) {
        ForEach(Array(spectrum.segments.enumerated()), id: \.element.id) { index, seg in
          let full = max(usableWidth * seg.share, 14)
          // Each segment grows from its left end, one after the other.
          SwissPatternSegment(lens: seg.lens)
            .frame(width: full, height: height)
            .clipShape(Capsule())
            .mask(alignment: .leading) {
              Capsule().frame(width: shown || compact ? full : 0)
                .animation(reveal(index), value: shown)
            }
        }
      }
    }
    .frame(height: height)
  }

  private func lensSwatch(_ lens: EditorialLens, size: CGFloat) -> some View {
    SwissPatternSegment(lens: lens)
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
  }
}

private struct SwissPatternSegment: View {
  let lens: EditorialLens

  var body: some View {
    Canvas { context, size in
      let rect = CGRect(origin: .zero, size: size)
      switch lens {
      case .wire:
        context.fill(Path(rect), with: .color(Swiss.ink))

      case .markets:
        context.fill(Path(rect), with: .color(Swiss.ink.opacity(0.10)))
        var hatch = Path()
        let step: CGFloat = 4.5
        var x: CGFloat = -size.height
        while x < size.width + size.height {
          hatch.move(to: CGPoint(x: x, y: size.height))
          hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
          x += step
        }
        context.stroke(hatch, with: .color(Swiss.ink), lineWidth: 1.4)

      case .tech:
        context.fill(Path(rect), with: .color(Swiss.ink.opacity(0.08)))
        let pitch: CGFloat = 3.5
        let dotRadius: CGFloat = 1.0
        var y: CGFloat = pitch / 2
        var row = 0
        while y < size.height {
          var x: CGFloat = (row.isMultiple(of: 2) ? pitch / 2 : pitch)
          while x < size.width {
            let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(Swiss.ink))
            x += pitch
          }
          y += pitch
          row += 1
        }

      case .culture:
        context.fill(Path(rect), with: .color(Swiss.ink.opacity(0.24)))
        let inset = rect.insetBy(dx: 0.75, dy: 0.75)
        context.stroke(
          Path(roundedRect: inset, cornerRadius: size.height / 2),
          with: .color(Swiss.ink),
          lineWidth: 1.3
        )
      }
    }
  }
}

// MARK: - Existing Detail Subviews

/// "READING" in the dot face while the model writes, the dots after it counting up.
struct WritingChip: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.4)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
      let text = "READING" + String(repeating: ".", count: step) + String(repeating: " ", count: 3 - step)
      DotText(text, pitch: 1.5, motion: .none)
        .foregroundStyle(Swiss.ink)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Swiss.ink.opacity(0.08), in: Capsule())
        .accessibilityLabel("Reading the coverage")
    }
  }
}

/// The read, in one tile. News: the summary, what outlets agree on, where they differ and each
/// outlet's angle. Releases: the verdict, praised, criticised. Style: the shift, the names, why
/// it matters and what to take from it.
struct BriefPanel: View {
  let brief: ClusterPerspectiveBrief
  var newSources: Int
  var refresh: () -> Void
  /// The article an outlet's angle links to: its newest in the story, if the name matches one.
  var outletArticle: (String) -> ArticleItem? = { _ in nil }
  var open: (String) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      EyebrowRow(brief.isGenerated ? titles.heading : "Preview") {
        if newSources > 0 {
          Button(action: refresh) { SignalBadge(.attention, "\(newSources) new · Update") }
            .buttonStyle(.plain)
        }
      }
      if !brief.summary.isEmpty {
        Text(brief.summary).font(.body).fixedSize(horizontal: false, vertical: true)
      }
      if !brief.sharedFacts.isEmpty {
        section(titles.first, brief.sharedFacts, mark: Swiss.mint)
      }
      if !brief.differences.isEmpty {
        section(titles.second, brief.differences, mark: Swiss.orange)
      }
      if let takeaways = brief.takeaways, !takeaways.isEmpty {
        section("Take from it", takeaways, mark: Swiss.ink)
      }
      if !brief.angles.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Eyebrow(brief.angles.count == 1 ? "The outlet's angle" : "Each outlet's angle")
          ForEach(brief.angles, id: \.self) { angle in
            // Each one opens that outlet's article, like the coverage rows below.
            let article = outletArticle(angle.outlet)
            Button { if let article { open(article.url) } } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(angle.outlet).font(.footnote.weight(.medium)).tileSecondary()
                  Text(angle.focus).font(.subheadline).foregroundStyle(Swiss.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let article {
                  // As on the coverage rows: where it opens.
                  Image(systemName: article.videoID != nil ? "play.rectangle" : article.audioURL != nil ? "headphones" : "arrow.up.right")
                    .font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(article == nil)
            .accessibilityHint("Opens \(angle.outlet)'s article")
          }
        }
      }
      Text(footnote)
        .font(.caption)
        .tileSecondary()
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
  }

  var titles: (heading: String, first: String, second: String) {
    switch brief.mode ?? .perspective {
    case .perspective: ("How it's covered", "They agree", "They differ")
    case .verdict: ("The verdict", "Praised", "Criticised")
    case .trend: ("The takeaway", "Names and pieces", "Why it matters")
    }
  }

  var footnote: String {
    brief.isGenerated
      ? "Written on this iPhone by Apple Intelligence from \(brief.sourceCount) headlines and short extracts. Automated summaries can be wrong; always verify at each publisher."
      : brief.note ?? "\(IntelligenceService.unavailableReason), so this preview just lists each outlet's headline."
  }

  func section(_ title: String, _ lines: [String], mark: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(title)
      ForEach(lines, id: \.self) { line in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          BulletDot(color: mark)
          Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// One outlet's take: its name and time, headline and snippet, and a way out to read it.
struct ArticleRow: View {
  let article: ArticleItem
  var isSelected: Bool = false
  var open: () -> Void

  /// Where tapping the row goes: the video on YouTube, else the article (or episode page).
  var destination: String {
    article.videoID != nil ? "Opens the video on YouTube"
      : article.audioURL != nil ? "Opens the episode on \(article.outlet)'s site" : "Opens \(article.outlet)"
  }

  var body: some View {
    let extract = article.shortSnippet
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(article.outlet).font(.footnote.weight(.medium)).foregroundStyle(Swiss.ink)
        Text(article.publishedAt.shortAgo).font(Swiss.smallFigure).foregroundStyle(Swiss.muted)
        Spacer(minLength: 6)
        Image(systemName: article.videoID != nil ? "play.rectangle" : article.audioURL != nil ? "headphones" : "arrow.up.right")
          .font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted)
      }
      Text(article.title)
        .font(Swiss.headline(20, relativeTo: .body))
        .foregroundStyle(Swiss.ink)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      if !extract.isEmpty {
        Text(extract)
          .font(.footnote)
          .foregroundStyle(Swiss.muted)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain, radius: 16)
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Swiss.ink, lineWidth: 1.5)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onTapGesture(perform: open)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Open", open)
    .accessibilityHint(destination)
  }
}

/// Videos and podcast episodes, always folded into one clearly labelled row: "4 videos, 1 podcast
/// episode · On YouTube and the podcasts' own sites · Show". Opened, each row links out.
struct MediaFold: View {
  let media: [ArticleItem]
  var openURL: (URL) -> Void
  @State private var isOpen = false

  /// "2 videos, 1 podcast episode".
  var title: String {
    let videos = media.filter { $0.videoID != nil }.count
    let episodes = media.count - videos
    var parts: [String] = []
    if videos > 0 { parts.append("\(videos) \(videos == 1 ? "video" : "videos")") }
    if episodes > 0 { parts.append("\(episodes) podcast \(episodes == 1 ? "episode" : "episodes")") }
    return parts.joined(separator: ", ")
  }

  /// Where they open.
  var summary: String {
    let hasVideo = media.contains { $0.videoID != nil }
    let hasAudio = media.contains { $0.audioURL != nil }
    return hasVideo && hasAudio ? "On YouTube and in Podcasts"
      : hasVideo ? "On YouTube" : "In Podcasts, or played here"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(.snappy(duration: 0.25)) { isOpen.toggle() }
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Swiss.ink)
            Text(summary).font(.footnote).foregroundStyle(Swiss.muted)
          }
          Spacer(minLength: 6)
          HStack(spacing: 4) {
            Text(isOpen ? "Hide" : "Show")
            Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0))
          }
          .font(.footnote.weight(.medium))
          .foregroundStyle(Swiss.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(.plain, radius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(title), \(summary)")
      .accessibilityHint(isOpen ? "Hides them" : "Shows them")
      if isOpen {
        ForEach(media) { article in
          ArticleRow(article: article) {
            if article.audioURL != nil {
              // An episode: Apple Podcasts first, else it plays here.
              AudioPlayer.shared.listen(article)
            } else if let url = article.videoURL ?? URL(string: article.url) {
              openURL(url)
            }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}
