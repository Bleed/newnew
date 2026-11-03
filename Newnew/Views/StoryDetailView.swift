import SafariServices
import SwiftData
import SwiftUI

extension ArticleItem {
  /// EU Article 15 safe-harbor extract: caps snippets at ~150 characters on a word boundary,
  /// decodes HTML entities, and suppresses snippets that merely duplicate the headline.
  var shortSnippet: String {
    var clean = snippet
    var cleanTitle = title
    if clean.contains("&") || cleanTitle.contains("&") {
      let entities: [(String, String)] = [
        ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&#8217;", "’"), ("&#8216;", "‘"),
        ("&#039;", "'"), ("&#39;", "'"), ("&apos;", "'"),
        ("&ldquo;", "“"), ("&rdquo;", "”"), ("&#8220;", "“"), ("&#8221;", "”"),
        ("&quot;", "\""), ("&#34;", "\""),
        ("&ndash;", "–"), ("&mdash;", "—"), ("&#8211;", "–"), ("&#8212;", "—"),
        ("&nbsp;", " "), ("&#160;", " "), ("&hellip;", "…"), ("&amp;", "&")
      ]
      for (entity, replacement) in entities {
        clean = clean.replacingOccurrences(of: entity, with: replacement)
        cleanTitle = cleanTitle.replacingOccurrences(of: entity, with: replacement)
      }
    }
    clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return "" }
    if clean.caseInsensitiveCompare(cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
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

/// Wrapper so a `URL` can drive the in-window browser view.
private struct ActiveWebURL: Identifiable, Equatable {
  let url: URL
  var id: String { url.absoluteString }
}

/// Embeds Safari directly inside the same story window edge-to-edge.
private struct InAppSafariView: UIViewControllerRepresentable {
  let url: URL
  var onFinish: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onFinish: onFinish)
  }

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let config = SFSafariViewController.Configuration()
    config.entersReaderIfAvailable = false
    config.barCollapsingEnabled = true
    let safari = SFSafariViewController(url: url, configuration: config)
    safari.dismissButtonStyle = .done
    safari.delegate = context.coordinator
    return safari
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

  final class Coordinator: NSObject, SFSafariViewControllerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
      Task { @MainActor in onFinish() }
    }
  }
}

/// One story: on wide windows (iPad / unfolded Duo), laid out in two independent scrolling
/// columns (54% lead story, updates & interactive coverage spectrum on the left; 46% videos/podcasts,
/// AI perspective & filterable outlet coverage list on the right). When an article link is tapped,
/// `InAppSafariView` opens across 100% of the window edge-to-edge without any side menu.
struct StoryDetailView: View {
  let cluster: StoryCluster
  @Environment(FeedSyncPipeline.self) var pipeline
  @State private var isWriting = false
  @State private var failure: String?
  /// Snapshots any newly-arrived update articles on entry before `markRead` clears them.
  @State private var updatesSinceLastRead: [ArticleItem] = []
  /// Currently opened article URL, shown directly inside this same window across its full width.
  @State private var activeWebURL: ActiveWebURL?
  /// Allows the user to hide/report an inaccurate AI summary in the current session.
  @State private var briefDismissed = false
  /// Interactive lens filter toggled from `CoverageSpectrumCard`.
  @State private var selectedLens: EditorialLens?
  /// Cross-highlights an outlet when hovering over its angle in `BriefPanel` or its `ArticleRow`.
  @State private var highlightedOutlet: String?

  private var nonMediaArticles: [ArticleItem] {
    cluster.sortedArticles.filter { !$0.isMedia }
  }

  private var filteredCoverageArticles: [ArticleItem] {
    guard let selectedLens else { return nonMediaArticles }
    return nonMediaArticles.filter {
      EditorialLens.classify(outlet: $0.outlet, pillar: cluster.pillar) == selectedLens
    }
  }

  var body: some View {
    GeometryReader { geo in
      let isTwoColumn = geo.size.width >= 640

      ZStack {
        Group {
          if isTwoColumn {
            twoColumnEditorialLayout(totalWidth: geo.size.width)
          } else {
            ScrollView {
              singleColumnLayout
            }
          }
        }
        .opacity(activeWebURL == nil ? 1 : 0)
        .allowsHitTesting(activeWebURL == nil)

        // Full-width, edge-to-edge browser inside the same window (no side menu or top header bar)
        if let active = activeWebURL {
          InAppSafariView(url: active.url) {
            withAnimation(.snappy(duration: 0.22)) {
              activeWebURL = nil
            }
          }
          .id(active.id)
          .ignoresSafeArea()
          .transition(.opacity)
        }
      }
      .animation(.snappy(duration: 0.22), value: activeWebURL)
      .animation(.snappy(duration: 0.2), value: selectedLens)
    }
    .environment(\.openURL, OpenURLAction { url in
      if url.scheme == "http" || url.scheme == "https" {
        openResolvedURL(url)
        return .handled
      }
      return .systemAction
    })
    .swissCanvas()
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(activeWebURL == nil ? .visible : .hidden, for: .navigationBar)
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

  // MARK: - Layouts

  /// iPhone / Compact single-column scroll layout.
  private var singleColumnLayout: some View {
    VStack(alignment: .leading, spacing: 14) {
      leadSection
      updatesSection
      mediaSection(topPadding: 6)
      spectrumSection
      perspectiveSection(topPadding: 6)
      coverageSection(topPadding: 8)
    }
    .padding(.horizontal, Swiss.pageInset)
    .padding(.bottom, 32)
  }

  /// iPad / Wide two-column broadsheet layout with independent vertical scroll panes (54% / 46%).
  private func twoColumnEditorialLayout(totalWidth: CGFloat) -> some View {
    let leftWidth = floor(totalWidth * 0.54)
    let rightWidth = max(totalWidth - leftWidth - 1, 260)

    return HStack(alignment: .top, spacing: 0) {
      // Left 54% Scroll Pane: Lead Story, Updates, and Interactive Coverage Spectrum
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          leadSection
          updatesSection
          spectrumSection
        }
        .padding(.leading, Swiss.pageInset)
        .padding(.trailing, 20)
        .padding(.bottom, 36)
      }
      .frame(width: leftWidth)

      // Subtle vertical rule separating the story from the media, comparison & sources
      Rectangle()
        .fill(Swiss.ink.opacity(0.10))
        .frame(width: 1)
        .ignoresSafeArea(edges: .bottom)

      // Right 46% Scroll Pane: Videos/Podcasts + Compare Coverage (AI Brief) + Outlet Coverage List
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          mediaSection(topPadding: 0)
          perspectiveSection(topPadding: 0)
          coverageSection(topPadding: 6)
        }
        .padding(.leading, 20)
        .padding(.trailing, Swiss.pageInset)
        .padding(.bottom, 36)
      }
      .frame(width: rightWidth)
    }
  }

  // MARK: - Modular Sections

  @ViewBuilder
  private var leadSection: some View {
    if let lead = cluster.lead {
      HeroImage(
        remote: lead.imageURL,
        article: lead.url,
        radius: 20,
        aspect: cluster.pillar.isPortrait ? 4 / 5 : 5 / 4,
        fits: lead.isChart,
        isVideo: lead.videoID != nil,
        topAligned: cluster.pillar.isPortrait
      )

      HStack(alignment: .center, spacing: 8) {
        metaLine(lead)
        Spacer(minLength: 6)
        DotChip("\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "SOURCE" : "SOURCES")")
      }
      .foregroundStyle(Swiss.muted)

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
  }

  @ViewBuilder
  private var updatesSection: some View {
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
  }

  @ViewBuilder
  private func mediaSection(topPadding: CGFloat) -> some View {
    let media = cluster.sortedArticles.filter(\.isMedia)
    if !media.isEmpty {
      MediaFold(media: media) { chosenURL in
        openResolvedURL(chosenURL)
      }
      .padding(.top, topPadding)
    }
  }

  @ViewBuilder
  private var spectrumSection: some View {
    if cluster.outlets.count > 1 {
      CoverageSpectrumCard(
        cluster: cluster,
        selectedLens: $selectedLens
      )
      .padding(.top, 6)
    }
  }

  @ViewBuilder
  private func perspectiveSection(topPadding: CGFloat) -> some View {
    if cluster.outlets.count > 1 || cluster.briefMode != .perspective {
      perspective.padding(.top, topPadding)
    }
  }

  @ViewBuilder
  private func coverageSection(topPadding: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Eyebrow(selectedLens == nil ? "Coverage" : "Coverage · \(selectedLens!.shortLabel)")
      Spacer()
      if selectedLens != nil {
        Button {
          withAnimation(.snappy(duration: 0.2)) { selectedLens = nil }
        } label: {
          Text("Show all (\(nonMediaArticles.count))")
            .font(.caption.weight(.medium))
            .foregroundStyle(Swiss.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Swiss.ink.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.top, topPadding)

    ForEach(filteredCoverageArticles) { article in
      let isHighlighted = highlightedOutlet?.caseInsensitiveCompare(article.outlet) == .orderedSame
      ArticleRow(
        article: article,
        isSelected: activeWebURL?.url.absoluteString == article.url || isHighlighted
      ) {
        openArticleURL(article.url)
      }
      .onHover { hovering in
        withAnimation(.easeOut(duration: 0.15)) {
          if hovering {
            highlightedOutlet = article.outlet
          } else if highlightedOutlet == article.outlet {
            highlightedOutlet = nil
          }
        }
      }
    }

    Text("Headlines and short extracts from each outlet's RSS feed. Tap any outlet to read the full article on the publisher's site.")
      .font(.footnote)
      .foregroundStyle(Swiss.muted)
      .padding(.top, 4)
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
  /// claims its links), else directly inside the current story window.
  private func openResolvedURL(_ url: URL) {
    LinkOpener.open(url) {
      withAnimation(.snappy(duration: 0.22)) {
        activeWebURL = ActiveWebURL(url: url)
      }
    }
  }

  // MARK: Perspective

  @ViewBuilder var perspective: some View {
    if let brief = cluster.brief, !briefDismissed {
      BriefPanel(
        brief: brief,
        newSources: max(cluster.articles.count - brief.sourceCount, 0),
        highlightedOutlet: $highlightedOutlet,
        refresh: { Task { await write() } },
        outletArticle: { outlet in
          // The model writes the names; match the story's outlets ignoring case. Its newest
          // written article, else anything it has.
          let articles = cluster.sortedArticles.filter { $0.outlet.caseInsensitiveCompare(outlet) == .orderedSame }
          return articles.first(where: { !$0.isMedia }) ?? articles.first
        },
        open: { openArticleURL($0) }
      )
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
  @Binding var selectedLens: EditorialLens?

  init(cluster: StoryCluster, compact: Bool = false, selectedLens: Binding<EditorialLens?> = .constant(nil)) {
    self.cluster = cluster
    self.compact = compact
    self._selectedLens = selectedLens
  }

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
      .accessibilityElement(children: .contain)
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
    let canFilter = spectrum.segments.count > 1

    return VStack(alignment: .leading, spacing: 12) {
      EyebrowRow("Coverage spectrum") {
        if let badge = spectrum.blindspotBadge {
          DotChip(badge)
        }
      }

      spectrumStrip(height: 12)

      HStack(spacing: 8) {
        ForEach(Array(spectrum.segments.enumerated()), id: \.element.id) { index, seg in
          let isSelected = selectedLens == seg.lens
          Button {
            guard canFilter else { return }
            withAnimation(.snappy(duration: 0.2)) {
              selectedLens = isSelected ? nil : seg.lens
            }
          } label: {
            HStack(spacing: 5) {
              lensSwatch(seg.lens, size: 9)
              Text("\(seg.lens.shortLabel) · \(seg.outlets.count)")
                .font(.caption2.monospaced())
                .foregroundStyle(Swiss.ink)
            }
            .padding(.horizontal, canFilter ? 8 : 0)
            .padding(.vertical, canFilter ? 4 : 0)
            .background(
              canFilter && isSelected ? Swiss.ink.opacity(0.09) : Color.clear,
              in: Capsule()
            )
            .overlay {
              if canFilter && isSelected {
                Capsule().strokeBorder(Swiss.ink, lineWidth: 1.2)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(!canFilter)
          .opacity(shown ? (selectedLens == nil || isSelected ? 1 : 0.45) : 0)
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
          let isDimmed = selectedLens != nil && selectedLens != seg.lens
          // Each segment grows from its left end, one after the other.
          SwissPatternSegment(lens: seg.lens)
            .frame(width: full, height: height)
            .clipShape(Capsule())
            .opacity(isDimmed ? 0.30 : 1)
            .mask(alignment: .leading) {
              Capsule().frame(width: shown || compact ? full : 0)
                .animation(reveal(index), value: shown)
            }
            .onTapGesture {
              guard !compact, spectrum.segments.count > 1 else { return }
              withAnimation(.snappy(duration: 0.2)) {
                selectedLens = (selectedLens == seg.lens) ? nil : seg.lens
              }
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
  @Binding var highlightedOutlet: String?
  var refresh: () -> Void
  /// The article an outlet's angle links to: its newest in the story, if the name matches one.
  var outletArticle: (String) -> ArticleItem? = { _ in nil }
  var open: (String) -> Void = { _ in }

  init(
    brief: ClusterPerspectiveBrief,
    newSources: Int,
    highlightedOutlet: Binding<String?> = .constant(nil),
    refresh: @escaping () -> Void,
    outletArticle: @escaping (String) -> ArticleItem? = { _ in nil },
    open: @escaping (String) -> Void = { _ in }
  ) {
    self.brief = brief
    self.newSources = newSources
    self._highlightedOutlet = highlightedOutlet
    self.refresh = refresh
    self.outletArticle = outletArticle
    self.open = open
  }

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
            let isHovered = highlightedOutlet?.caseInsensitiveCompare(angle.outlet) == .orderedSame
            Button { if let article { open(article.url) } } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(angle.outlet)
                    .font(.footnote.weight(isHovered ? .semibold : .medium))
                    .foregroundStyle(isHovered ? Swiss.ink : Swiss.muted)
                  Text(angle.focus).font(.subheadline).foregroundStyle(Swiss.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let article {
                  // As on the coverage rows: where it opens.
                  Image(systemName: article.videoID != nil ? "play.rectangle" : article.audioURL != nil ? "headphones" : "arrow.up.right")
                    .font(.footnote.weight(.medium)).foregroundStyle(isHovered ? Swiss.ink : Swiss.muted)
                }
              }
              .padding(.vertical, 3)
              .padding(.horizontal, 6)
              .background(isHovered ? Swiss.ink.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(article == nil)
            .onHover { hovering in
              withAnimation(.easeOut(duration: 0.15)) {
                if hovering {
                  highlightedOutlet = angle.outlet
                } else if highlightedOutlet?.caseInsensitiveCompare(angle.outlet) == .orderedSame {
                  highlightedOutlet = nil
                }
              }
            }
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
