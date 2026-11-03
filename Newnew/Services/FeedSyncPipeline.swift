import Foundation
import NaturalLanguage
import SwiftData

/// Reads the chosen outlets' feeds (`FeedFetcher`, on this iPhone) and hands them to
/// `SyncWorker`, which stores, embeds, regroups and applies the topics on its own context off the
/// main actor. What's left here is what the screen reads: whether a sync runs, where it is, and
/// what it brought. The reader's own changes (read, briefs, topics) are saved here.
@MainActor @Observable final class FeedSyncPipeline {
  let context: ModelContext
  private(set) var isSyncing = false
  /// When the running (or last) sync began: what it brought in was fetched after this.
  private(set) var syncStarted: Date?
  /// Where a sync is, for the loader.
  private(set) var phase: SyncPhase = .idle
  /// When the last sync finished; kept across launches.
  private(set) var lastSync: Date? {
    get { UserDefaults.standard.object(forKey: "lastSyncAt") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "lastSyncAt") }
  }
  private(set) var lastError: String?
  /// New articles per story from the last sync (muted stories left out).
  private(set) var lastNew: [UUID: Int] = [:]
  private var didSanitizeOnLaunch = false

  /// Articles older than this are let go.
  nonisolated static let retention: TimeInterval = 72 * 3600
  /// Charts come weekly; they stay two weeks.
  nonisolated static let chartRetention: TimeInterval = 14 * 24 * 3600
  static let refreshInterval: TimeInterval = 15 * 60

  /// Where newnew's own files are published (`NEWNEW_FEED_URL` in project.yml): its folder holds
  /// outlets.json, the outlets and their feeds. Unset, the bundled sample news is used. A
  /// `NEWNEW_FEED_URL` environment variable overrides it.
  static let feedURL: URL? = (ProcessInfo.processInfo.environment["NEWNEW_FEED_URL"]
    ?? Bundle.main.object(forInfoDictionaryKey: "NewnewFeedURL") as? String)
    .flatMap { $0.isEmpty ? nil : URL(string: $0) }

  /// Where the stored articles came from; when it changes they're cleared (the sample's
  /// invented stories shouldn't mix with real ones).
  var storedSource: String? {
    get { UserDefaults.standard.string(forKey: "feedSource") }
    set { UserDefaults.standard.set(newValue, forKey: "feedSource") }
  }

  init(context: ModelContext) {
    self.context = context
  }

  @ObservationIgnored private lazy var worker = SyncWorker(container: context.container)

  // MARK: Sync

  /// Whether anything is stored to show (a cheap count, for the first-install loader).
  var hasStories: Bool {
    ((try? context.fetchCount(FetchDescriptor<StoryCluster>())) ?? 0) > 0
  }

  func syncIfNeeded() async {
    // Nothing stored (a store started over) reads the feeds whenever the last sync was.
    if let lastSync, Date.now.timeIntervalSince(lastSync) < Self.refreshInterval, hasStories {
      // No sync due: regroup the stored stories once per launch, so a new grouping rule reaches
      // them. A sync regroups anyway, so launches that sync skip this extra pass.
      if !didSanitizeOnLaunch {
        didSanitizeOnLaunch = true
        await regroup()
      }
      return
    }
    didSanitizeOnLaunch = true
    await sync()
  }

  func sync() async {
    guard !isSyncing else { return }
    isSyncing = true
    let started = Date.now
    syncStarted = started
    phase = .downloading
    defer { isSyncing = false }
    do {
      // "phone-1": read from the feeds on this iPhone (builds up to 32 downloaded a feed newnew
      // published; those articles go once).
      let source = Self.feedURL == nil ? "sample" : "phone-1"
      if try await worker.clear(unless: source, stored: storedSource) { storedSource = source }
      var incoming = try await loadArticles(worker)
      // The reader's own feeds too.
      for custom in OutletStore.shared.customFeeds { incoming += await CustomFeedReader.articles(custom) }
      phase = .reading(outlets: Set(incoming.map(\.outlet)).count)
      let result = try await worker.ingest(incoming, since: started) { phase in
        await MainActor.run { self.phase = phase }
      }
      lastNew = result.new
      lastSync = .now
      lastError = nil
      phase = .done(stories: result.stories)
    } catch {
      lastError = error.localizedDescription
      phase = .failed
    }
  }

  /// The chosen outlets' articles, read from their feeds; the bundled sample without a
  /// `feedURL`.
  private func loadArticles(_ worker: SyncWorker) async throws -> [FeedArticleDTO] {
    guard Self.feedURL != nil else {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try sampleArticles(decoder)
    }
    let feeds = OutletStore.shared.chosenFeeds
    guard !feeds.isEmpty else { return [] }
    // HD video thumbnails already checked.
    let pictures = await worker.pictures()
    phase = .fetching(done: 0, total: feeds.count)
    let articles = await FeedFetcher.articles(feeds, pictures: pictures) { done, total in
      await MainActor.run { self.phase = .fetching(done: done, total: total) }
    }
    // Every feed silent: most likely offline.
    if articles.isEmpty { throw URLError(.notConnectedToInternet) }
    return articles
  }

  private func sampleArticles(_ decoder: JSONDecoder) throws -> [FeedArticleDTO] {
    guard let url = Bundle.main.url(forResource: "sample_news", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    var feed = try decoder.decode(FeedDTO.self, from: Data(contentsOf: url))
    // The sample's times are moved up to now, so it reads like this morning's news.
    if let newest = feed.articles.map(\.publishedAt).max() {
      let shift = Date.now.addingTimeInterval(-4 * 60).timeIntervalSince(newest)
      for index in feed.articles.indices { feed.articles[index].publishedAt.addTimeInterval(shift) }
    }
    return feed.articles
  }

  /// Regroups what's stored, off the main actor.
  private func regroup() async {
    _ = try? await worker.regroup()
  }

  /// After the reader changes their outlets: articles from outlets no longer read go now, and
  /// if any outlet was added a sync reads its feeds.
  func applyOutletChoice(added: Bool) async {
    let outlets = OutletStore.shared
    for article in (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? [] where !outlets.reads(article.outlet) {
      context.delete(article)
    }
    try? context.save()
    await regroup()
    if added { await sync() }
  }

  /// A feed the reader renamed: its stored articles (and what was read) carry the new name.
  func renameOutlet(_ old: String, to new: String) {
    for article in (try? context.fetch(FetchDescriptor<ArticleItem>(predicate: #Predicate { $0.outlet == old }))) ?? [] {
      article.outlet = new
    }
    try? context.save()
  }

  // MARK: Stories

  func markRead(_ cluster: StoryCluster) {
    cluster.readAt = .now
    for article in cluster.articles where !article.isRead { article.isRead = true }
    try? context.save()
  }

  func saveBrief(_ brief: ClusterPerspectiveBrief, for cluster: StoryCluster) {
    cluster.brief = brief
    try? context.save()
  }

  // MARK: Topics

  /// `step` hears where it is, for the sheet to show.
  func addTopic(_ phrase: String, kind topicKind: TopicKind, step: (TopicStep) -> Void = { _ in }) async {
    let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return }
    step(.examples)
    let examples = await IntelligenceService.topicExamples(phrase)
    context.insert(SemanticTopic(phrase: phrase, kind: topicKind, exampleHeadlines: examples.headlines, keywords: examples.keywords))
    try? context.save()
    step(.reading)
    // The worker reads the examples and matches the stories.
    await retopic()
  }

  /// "Follow / mute stories like this": the story's own coverage is the example, its shared
  /// names the keywords.
  func addTopic(like cluster: StoryCluster, kind topicKind: TopicKind) async {
    guard let lead = cluster.lead else { return }
    let names = cluster.articles.flatMap { StoryClusterer.terms($0.title).filter { $0.hasPrefix("#") } }
    let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
    let shared = counts.filter { $0.value >= min(2, cluster.articles.count) * 2 }.keys.map { String($0.dropFirst()) }
    let topic = SemanticTopic(
      phrase: "Like “\(lead.title)”", kind: topicKind, exampleHeadlines: cluster.sortedArticles.prefix(4).map(\.title),
      keywords: Array(shared.prefix(4)))
    context.insert(topic)
    try? context.save()
    await retopic()
  }

  func remove(_ topic: SemanticTopic) {
    context.delete(topic)
    try? context.save()
    Task { await retopic() }
  }

  private func retopic() async {
    try? await worker.retopic()
  }
}

/// Validates every multi-article cluster returned by `StoryClusterer` and splits apart articles
/// that were only grouped because they share a country/demonym (e.g. "Japan" / "Japanese") or
/// transitive single-linkage chaining.
nonisolated enum StoryClusterSanitizer {
  struct ItemMeta: Sendable {
    let title: String
    let snippet: String
    let outlet: String
  }

  /// Broad countries, regions, cities, nationalities, and demonyms that must NEVER count as the
  /// shared event anchor between two news stories.
  nonisolated private static let geoAndDemonyms: Set<String> = [
    "japan", "japanese", "tokyo", "china", "chinese", "beijing", "shanghai", "hong", "kong",
    "taiwan", "taiwanese", "korea", "korean", "seoul", "india", "indian", "delhi", "mumbai",
    "asia", "asian", "uk", "britain", "british", "england", "english", "scotland", "scottish",
    "london", "us", "usa", "america", "american", "americans", "washington", "york", "california",
    "russia", "russian", "russians", "moscow", "ukraine", "ukrainian", "kyiv", "eu", "europe",
    "european", "germany", "german", "berlin", "france", "french", "paris", "italy", "italian",
    "spain", "spanish", "norway", "norwegian", "oslo", "sweden", "swedish", "denmark", "danish",
    "nordic", "israel", "israeli", "gaza", "palestinian", "iran", "iranian", "tehran", "middle",
    "east", "australia", "australian", "sydney", "canada", "canadian", "brazil", "brazilian",
    "mexico", "mexican", "africa", "african", "world", "global", "international", "country", "countries"
  ]

  /// Common news stopwords and generic verbs/adjectives that don't identify a specific news event.
  nonisolated private static let stopwords: Set<String> = [
    "the", "and", "for", "that", "this", "with", "from", "your", "have", "more", "what",
    "when", "where", "why", "how", "who", "will", "would", "could", "should", "into", "over",
    "after", "before", "about", "amid", "says", "said", "new", "latest", "report", "reports",
    "news", "story", "stories", "year", "years", "time", "life", "work", "working", "people",
    "young", "first", "look", "gets", "make", "made", "take", "takes", "back", "down", "just",
    "like", "still", "even", "most", "some", "many", "much", "very", "real", "good", "best",
    "review", "guide", "week", "today", "month", "days", "daily", "here", "there", "their",
    "they", "them", "were", "been", "being", "also", "only", "other", "others", "between",
    "under", "while", "through", "against", "during", "without", "within", "along", "following",
    "across", "behind", "beyond", "plus", "except", "but", "not", "really", "seem", "seems",
    "show", "shows", "sign", "signs", "line", "test", "tested", "recently", "create", "creates"
  ]

  nonisolated static func sanitize(groups: [[Int]], meta: [ItemMeta]) -> [[Int]] {
    let features = meta.map { item -> (headline: Set<String>, all: Set<String>) in
      let h = specificTokens(from: item.title)
      let s = specificTokens(from: item.snippet)
      return (h, h.union(s))
    }

    var cleanGroups: [[Int]] = []

    for group in groups {
      guard group.count > 1 else {
        cleanGroups.append(group)
        continue
      }

      // Break transitive chains by partitioning `group` into sub-clusters where every member
      // genuinely shares specific non-geographic event tokens with the sub-cluster's seed article.
      var remaining = group
      while !remaining.isEmpty {
        let seed = remaining.removeFirst()
        var subcluster = [seed]
        var nextRemaining: [Int] = []

        let seedHeadline = features[seed].headline
        let seedAll = features[seed].all

        for candidate in remaining {
          let candHeadline = features[candidate].headline
          let candAll = features[candidate].all

          if isSameEvent(
            seedHeadline: seedHeadline,
            seedAll: seedAll,
            candHeadline: candHeadline,
            candAll: candAll
          ) {
            subcluster.append(candidate)
          } else {
            nextRemaining.append(candidate)
          }
        }

        cleanGroups.append(subcluster)
        remaining = nextRemaining
      }
    }

    return cleanGroups
  }

  /// Two articles already passed `StoryClusterer`'s vector threshold; this gate verifies they
  /// actually share the same specific subject/event (excluding countries/demonyms).
  nonisolated private static func isSameEvent(
    seedHeadline: Set<String>,
    seedAll: Set<String>,
    candHeadline: Set<String>,
    candAll: Set<String>
  ) -> Bool {
    let sharedHeadline = seedHeadline.intersection(candHeadline)
    let sharedAll = seedAll.intersection(candAll)

    // Rule 1: At least 2 specific (non-geo, non-stopword) words shared directly in the headlines
    if sharedHeadline.count >= 2 {
      return true
    }

    // Rule 2: 1 specific word shared in the headlines PLUS at least 2 more specific words shared
    // across the headline + snippet (total >= 3 specific non-geo tokens in common).
    if sharedHeadline.count == 1 && sharedAll.count >= 3 {
      return true
    }

    // Rule 3: Even if headlines are worded differently, if the title+snippet share at least 4
    // distinct, specific non-geographic words, allow it.
    if sharedAll.count >= 4 {
      return true
    }

    return false
  }

  nonisolated private static func specificTokens(from text: String) -> Set<String> {
    let raw = text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 3 }

    var tokens = Set<String>()
    for word in raw {
      // Allow 3-letter acronyms/numbers (like "nhk", "gdp", "ps5", "gta"), otherwise require >= 4 chars
      let hasDigit = word.contains(where: \.isNumber)
      if word.count < 4 && !hasDigit { continue }
      guard !stopwords.contains(word),
            !geoAndDemonyms.contains(word) else { continue }
      tokens.insert(stem(word))
    }
    return tokens
  }

  nonisolated private static func stem(_ word: String) -> String {
    if word.hasSuffix("ies") && word.count > 5 { return String(word.dropLast(3)) + "y" }
    if word.hasSuffix("ing") && word.count > 6 { return String(word.dropLast(3)) }
    if word.hasSuffix("ed") && word.count > 5 { return String(word.dropLast(2)) }
    if word.hasSuffix("es") && word.count > 5 { return String(word.dropLast(2)) }
    if word.hasSuffix("s") && !word.hasSuffix("ss") && word.count > 4 { return String(word.dropLast(1)) }
    return word
  }
}

/// The steps of adding a topic, as the topics sheet shows them.
enum TopicStep {
  case examples, reading, matching

  /// The dot chip's word.
  var chip: String {
    switch self {
    case .examples: "THINKING"
    case .reading: "LEARNING"
    case .matching: "MATCHING"
    }
  }

  var detail: String {
    switch self {
    case .examples: IntelligenceService.isAvailable ? "Writing example headlines…" : "Picking telling words…"
    case .reading: "Reading the examples…"
    case .matching: "Matching today's stories…"
    }
  }
}

/// The steps of a sync, as the loading board shows them.
nonisolated enum SyncPhase: Equatable, Sendable {
  case idle
  case downloading
  /// Feeds answered of those asked.
  case fetching(done: Int, total: Int)
  /// The feed is in: how many outlets it has.
  case reading(outlets: Int)
  /// Articles read into vectors on the device.
  case embedding(done: Int, total: Int)
  case grouping
  case done(stories: Int)
  case failed

  /// Done, or given up on.
  var isFinished: Bool {
    switch self {
    case .done, .failed: true
    default: false
    }
  }

  /// 0…1, for the board's bottom row.
  var progress: Double {
    switch self {
    case .idle, .failed: 0
    case .downloading: 0.02
    case .fetching(let done, let total): 0.02 + 0.28 * Double(done) / Double(max(total, 1))
    case .reading: 0.3
    case .embedding(let done, let total): 0.3 + 0.6 * Double(done) / Double(max(total, 1))
    case .grouping: 0.94
    case .done: 1
    }
  }
}
