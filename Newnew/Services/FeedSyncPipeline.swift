import Foundation
import NaturalLanguage
import SwiftData

/// Fetches the feed, stores new articles, embeds them, regroups the stories and applies the
/// mute topics. Model changes stay on the main actor; the heavy parts (embedding, clustering)
/// run off it.
@MainActor @Observable final class FeedSyncPipeline {
  let context: ModelContext
  private let engine = OnDeviceVectorEngine.shared
  private(set) var isSyncing = false
  private(set) var lastSync: Date?
  private(set) var lastError: String?
  /// The mean article vector, taken away before comparing (see `Vec.centred`).
  private var corpusMean: [Float]?
  private var dimension = 0
  private var kind: OnDeviceVectorEngine.Kind = .none

  /// Articles older than this are let go.
  static let retention: TimeInterval = 72 * 3600
  static let refreshInterval: TimeInterval = 15 * 60

  /// The published `latest_news.json` (`NEWNEW_FEED_URL` in project.yml); until it's set the
  /// bundled sample is used. A `NEWNEW_FEED_URL` environment variable overrides it, for trying a
  /// local run of the scraper in the Simulator.
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

  // MARK: Sync

  func syncIfNeeded() async {
    if let lastSync, Date.now.timeIntervalSince(lastSync) < Self.refreshInterval { return }
    await sync()
  }

  func sync() async {
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
      let feed = try await loadFeed()
      let source = Self.feedURL?.absoluteString ?? "sample"
      if storedSource != source {
        try? context.delete(model: ArticleItem.self)
        try? context.delete(model: StoryCluster.self)
        storedSource = source
      }
      upsert(feed.articles)
      prune()
      await embedMissing()
      await recluster()
      applyMutes()
      try context.save()
      lastSync = .now
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func loadFeed() async throws -> FeedDTO {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let url = Self.feedURL {
      let (data, _) = try await URLSession.shared.data(from: url)
      return try decoder.decode(FeedDTO.self, from: data)
    }
    guard let url = Bundle.main.url(forResource: "sample_news", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    var feed = try decoder.decode(FeedDTO.self, from: Data(contentsOf: url))
    // The sample's times are moved up to now, so it reads like this morning's news.
    if let newest = feed.articles.map(\.publishedAt).max() {
      let shift = Date.now.addingTimeInterval(-4 * 60).timeIntervalSince(newest)
      for index in feed.articles.indices { feed.articles[index].publishedAt.addTimeInterval(shift) }
    }
    return feed
  }

  func upsert(_ incoming: [FeedArticleDTO]) {
    let known = Set(((try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []).map(\.url))
    let now = Date.now
    for dto in incoming where !known.contains(dto.url) {
      context.insert(ArticleItem(dto, fetchedAt: now))
    }
  }

  func prune() {
    let cutoff = Date.now.addingTimeInterval(-Self.retention)
    try? context.delete(model: ArticleItem.self, where: #Predicate { $0.publishedAt < cutoff })
  }

  // MARK: Vectors

  func embedMissing() async {
    await engine.prepare()
    kind = await engine.kind
    dimension = await engine.dimension
    guard dimension > 0 else { return }
    let bytes = dimension * MemoryLayout<Float>.size

    let articles = (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []
    let missing = articles.filter { $0.embedding?.count != bytes }
    if !missing.isEmpty {
      let vectors = await engine.embed(missing.map(\.text))
      for (article, vector) in zip(missing, vectors) { article.embedding = vector.map(Vec.data) }
    }
    corpusMean = Vec.mean(articles.compactMap { Vec.vector($0.embedding) }.filter { $0.count == dimension })

    let filters = (try? context.fetch(FetchDescriptor<SemanticMuteFilter>())) ?? []
    for filter in filters where filter.exampleEmbeddings?.count != filter.exampleHeadlines.count * bytes {
      await embedExamples(filter)
    }
  }

  private func embedExamples(_ filter: SemanticMuteFilter) async {
    let vectors = await engine.embed(filter.exampleHeadlines.map { $0.hasSuffix(".") ? $0 : $0 + "." })
    let flat = vectors.compactMap { $0 }.flatMap { $0 }
    filter.exampleEmbeddings = flat.isEmpty ? nil : Vec.data(flat)
  }

  private func centredVector(_ data: Data?) -> [Float]? {
    guard let vector = Vec.vector(data), vector.count == dimension else { return nil }
    return Vec.centred(vector, mean: corpusMean)
  }

  // MARK: Stories

  /// Regroups every article and keeps each story's identity (and its cached brief) where most
  /// of its articles stay together.
  func recluster() async {
    let articles = (try? context.fetch(FetchDescriptor<ArticleItem>(sortBy: [SortDescriptor(\.publishedAt)]))) ?? []
    let inputs = articles.map {
      StoryClusterer.Input(text: $0.text, outlet: $0.outlet, publishedAt: $0.publishedAt, vector: centredVector($0.embedding))
    }
    let groups = await Task.detached(priority: .userInitiated) { StoryClusterer.groups(inputs) }.value

    var kept = Set<UUID>()
    for group in groups.sorted(by: { $0.count > $1.count }) {
      let items = group.map { articles[$0] }
      var votes: [UUID: (cluster: StoryCluster, count: Int)] = [:]
      for cluster in items.compactMap(\.cluster) where !kept.contains(cluster.id) {
        votes[cluster.id, default: (cluster, 0)].count += 1
      }
      let cluster: StoryCluster
      if let existing = votes.values.max(by: { $0.count < $1.count })?.cluster {
        cluster = existing
      } else {
        cluster = StoryCluster(updatedAt: .now)
        context.insert(cluster)
      }
      kept.insert(cluster.id)
      for item in items where item.cluster?.id != cluster.id { item.cluster = cluster }
      cluster.updatedAt = items.map(\.publishedAt).max() ?? cluster.updatedAt
    }
    for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] where !kept.contains(cluster.id) {
      context.delete(cluster)
    }
  }

  func markRead(_ cluster: StoryCluster) {
    cluster.readAt = .now
    for article in cluster.articles where !article.isRead { article.isRead = true }
    try? context.save()
  }

  func saveBrief(_ brief: ClusterPerspectiveBrief, for cluster: StoryCluster) {
    cluster.brief = brief
    try? context.save()
  }

  // MARK: Mute topics

  /// Example headline vs story ("Headline. Snippet") on centred vectors. Real matches score
  /// 0.42–0.52 on the sample; the nearest non-match about 0.38. The older sentence model
  /// spreads less, so it needs a little more.
  var muteThreshold: Float { kind == .contextual ? 0.40 : 0.42 }

  func addMuteTopic(_ phrase: String) async {
    let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return }
    let topic = await IntelligenceService.muteTopic(phrase)
    let filter = SemanticMuteFilter(phrase: phrase, exampleHeadlines: topic.headlines, keywords: topic.keywords)
    context.insert(filter)
    await embedExamples(filter)
    applyMutes()
    try? context.save()
  }

  /// "Mute stories like this": the story's own coverage is the example, its names the keywords.
  func muteStoriesLike(_ cluster: StoryCluster) async {
    guard let lead = cluster.lead else { return }
    let names = cluster.articles.flatMap { StoryClusterer.terms($0.title).filter { $0.hasPrefix("#") } }
    let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
    let shared = counts.filter { $0.value >= min(2, cluster.articles.count) * 2 }.keys.map { String($0.dropFirst()) }
    let filter = SemanticMuteFilter(
      phrase: "Like “\(lead.title)”", exampleHeadlines: cluster.sortedArticles.prefix(4).map(\.title),
      keywords: Array(shared.prefix(4)))
    context.insert(filter)
    await embedExamples(filter)
    applyMutes()
    try? context.save()
  }

  func remove(_ filter: SemanticMuteFilter) {
    context.delete(filter)
    applyMutes()
    try? context.save()
  }

  /// A story is hidden when at least a third of its articles match a topic, so one stray
  /// article doesn't take a big story with it.
  func applyMutes() {
    let filters = (try? context.fetch(FetchDescriptor<SemanticMuteFilter>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    let prepared = filters.map { filter in
      (filter, Vec.vectors(filter.exampleEmbeddings, dimension: dimension).map { Vec.centred($0, mean: corpusMean) })
    }
    for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] {
      let articles = cluster.articles
      let mutedBy = prepared.first { filter, examples in
        let hits = articles.filter { matches($0, filter, examples) }.count
        return hits > 0 && Double(hits) / Double(articles.count) >= 0.34
      }?.0.phrase
      if cluster.mutedBy != mutedBy { cluster.mutedBy = mutedBy }
    }
  }

  private func matches(_ article: ArticleItem, _ filter: SemanticMuteFilter, _ examples: [[Float]]) -> Bool {
    let text = article.text.lowercased()
    if text.contains(filter.phrase.lowercased()) { return true }
    let keywordHits = filter.keywords.filter { text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }.count
    let score = centredVector(article.embedding).map { vector in examples.map { Vec.cosine(vector, $0) }.max() ?? 0 } ?? 0
    // Two telling words, a close match by meaning, or one word with a near match.
    return keywordHits >= 2 || score > muteThreshold || (keywordHits == 1 && score > muteThreshold * 0.75)
  }
}
