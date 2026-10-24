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
      let articles = (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []
      // The sample's links all go to example.com; none of them belong next to real news.
      let hasSample = source != "sample" && articles.contains { $0.url.hasPrefix("https://example.com/") }
      if storedSource != source || hasSample {
        // One by one: the bulk delete fails silently on the article–story relationship.
        for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] { context.delete(cluster) }
        for article in articles { context.delete(article) }
        try context.save()
        storedSource = source
      }
      upsert(feed.articles)
      prune()
      tagRegions()
      await embedMissing()
      await recluster()
      applyTopics()
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

  /// Cheap (a word list), so every article is tagged again each sync and word-list fixes apply
  /// at once.
  func tagRegions() {
    let local = RegionTagger.localCountry
    for article in (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? [] {
      let raw = RegionTagger.regions(title: article.title, snippet: article.snippet, country: article.country, local: local)
        .map(\.rawValue).sorted().joined(separator: ",")
      if article.regionsRaw != raw { article.regionsRaw = raw }
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

    let topics = (try? context.fetch(FetchDescriptor<SemanticTopic>())) ?? []
    for topic in topics where topic.exampleEmbeddings?.count != topic.exampleHeadlines.count * bytes {
      await embedExamples(topic)
    }
  }

  private func embedExamples(_ topic: SemanticTopic) async {
    let vectors = await engine.embed(topic.exampleHeadlines.map { $0.hasSuffix(".") ? $0 : $0 + "." })
    let flat = vectors.compactMap { $0 }.flatMap { $0 }
    topic.exampleEmbeddings = flat.isEmpty ? nil : Vec.data(flat)
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

  // MARK: Topics

  /// Example headline vs story ("Headline. Snippet") on centred vectors. Measured on a real
  /// feed (1,063 articles): with the contextual model, true matches for "space" reach 0.60, but
  /// a supervolcano and the Dead Sea sit at 0.51–0.53 and a weather story at 0.49; the older
  /// sentence model ranks a cricket story first for "AI". So meaning alone only counts when it
  /// is very close, and only with the contextual model; otherwise a topic word must appear too.
  var meaningAloneThreshold: Float? { kind == .contextual ? 0.55 : nil }
  /// Meaning needed alongside one topic word. Among articles that say "satellite", "moon" or
  /// "space", real space stories score ≥ 0.40 (contextual) and an oil spill seen in "satellite
  /// images" 0.36; the sentence model separates them less well (0.32 for the spill).
  var meaningWithWordThreshold: Float { kind == .contextual ? 0.38 : 0.40 }

  func addTopic(_ phrase: String, kind topicKind: TopicKind) async {
    let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return }
    let examples = await IntelligenceService.topicExamples(phrase)
    let topic = SemanticTopic(phrase: phrase, kind: topicKind, exampleHeadlines: examples.headlines, keywords: examples.keywords)
    context.insert(topic)
    await embedExamples(topic)
    applyTopics()
    try? context.save()
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
    await embedExamples(topic)
    applyTopics()
    try? context.save()
  }

  func remove(_ topic: SemanticTopic) {
    context.delete(topic)
    applyTopics()
    try? context.save()
  }

  /// A story matches a topic when at least a third of its articles do, so one stray article
  /// doesn't hide or raise a big story. Muting wins over following.
  func applyTopics() {
    let topics = (try? context.fetch(FetchDescriptor<SemanticTopic>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    let prepared = topics.map { topic in
      (topic, Vec.vectors(topic.exampleEmbeddings, dimension: dimension).map { Vec.centred($0, mean: corpusMean) })
    }
    for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] {
      let articles = cluster.articles
      func first(_ topicKind: TopicKind) -> String? {
        prepared.first { topic, examples in
          guard topic.kind == topicKind else { return false }
          let hits = articles.filter { matches($0, topic, examples) }.count
          return hits > 0 && Double(hits) / Double(articles.count) >= 0.34
        }?.0.phrase
      }
      let mutedBy = first(.mute)
      let followedBy = mutedBy == nil ? first(.follow) : nil
      if cluster.mutedBy != mutedBy { cluster.mutedBy = mutedBy }
      if cluster.followedBy != followedBy { cluster.followedBy = followedBy }
    }
  }

  private func matches(_ article: ArticleItem, _ topic: SemanticTopic, _ examples: [[Float]]) -> Bool {
    let text = article.text.lowercased()
    // The phrase counts as one of the topic's words, as a whole word ("space", not "spaceport").
    let words = Set(topic.keywords + [topic.phrase.lowercased()])
    let wordHits = words.filter { text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }.count
    let score = centredVector(article.embedding).map { vector in examples.map { Vec.cosine(vector, $0) }.max() ?? 0 } ?? 0
    // Two topic words; one word and close in meaning; or, with the contextual model only, very
    // close in meaning alone.
    return wordHits >= 2 || (wordHits == 1 && score > meaningWithWordThreshold)
      || meaningAloneThreshold.map { score > $0 } == true
  }

}
