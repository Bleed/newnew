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
  /// Where a sync is, for the loading board.
  private(set) var phase: SyncPhase = .idle
  private(set) var lastSync: Date?
  private(set) var lastError: String?
  /// The mean article vector, taken away before comparing (see `Vec.centred`).
  private var corpusMean: [Float]?
  private var dimension = 0
  private var kind: OnDeviceVectorEngine.Kind = .none

  /// Articles older than this are let go.
  static let retention: TimeInterval = 72 * 3600
  /// Charts come weekly; they stay two weeks.
  static let chartRetention: TimeInterval = 14 * 24 * 3600
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

  /// Stories with at least one article that isn't muted.
  var storyCount: Int {
    ((try? context.fetch(FetchDescriptor<StoryCluster>())) ?? []).filter { !$0.isMuted && !$0.articles.isEmpty }.count
  }

  func syncIfNeeded() async {
    if let lastSync, Date.now.timeIntervalSince(lastSync) < Self.refreshInterval { return }
    await sync()
  }

  func sync() async {
    guard !isSyncing else { return }
    isSyncing = true
    phase = .downloading
    defer { isSyncing = false }
    do {
      let source = Self.feedURL?.absoluteString ?? "sample"
      let articles = (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []
      // The sample's links all go to example.com; none of them belong next to real news.
      let hasSample = source != "sample" && articles.contains { $0.url.hasPrefix("https://example.com/") }
      if storedSource != source || hasSample || articles.isEmpty {
        // One by one: the bulk delete fails silently on the article–story relationship.
        for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] { context.delete(cluster) }
        for article in articles { context.delete(article) }
        try context.save()
        storedSource = source
        // Nothing stored: the next download is the whole snapshot.
        lastChunkID = nil
      }
      let feed = try await loadFeed()
      phase = .reading(outlets: Set(feed.articles.map(\.outlet)).count)
      let added = upsert(feed.articles)
      prune()
      tagRegions(added)
      await embedMissing()
      phase = .grouping
      await recluster()
      applyTopics()
      try context.save()
      // Only once everything is stored: a failed sync asks for the same pieces again.
      if let newest = feed.newestChunk { lastChunkID = newest }
      lastSync = .now
      lastError = nil
      phase = .done(stories: storyCount)
    } catch {
      lastError = error.localizedDescription
      phase = .failed
    }
  }

  /// The newest feed piece this iPhone has (see github-scraper/scripts/poll_feeds.mjs).
  var lastChunkID: String? {
    get { UserDefaults.standard.string(forKey: "feedLastChunk") }
    set { UserDefaults.standard.set(newValue, forKey: "feedLastChunk") }
  }

  /// What a sync brings in: articles to add or update, and the newest piece they came from.
  struct Download {
    var articles: [FeedArticleDTO]
    var newestChunk: String?
  }

  /// With an `index.json` feed, only the pieces newer than the last one this iPhone has (a
  /// typical refresh: ~2 KB of index and one or two pieces of ~10 KB); the whole snapshot on a
  /// first launch or after more than two days away. A `latest_news.json` feed is fetched whole.
  func loadFeed() async throws -> Download {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let url = Self.feedURL else { return Download(articles: try sampleArticles(decoder), newestChunk: nil) }
    guard url.lastPathComponent == "index.json" else {
      let (data, _) = try await URLSession.shared.data(from: url)
      return Download(articles: try decoder.decode(FeedDTO.self, from: data).articles, newestChunk: nil)
    }
    // Asks the server whether the index changed rather than trusting a cached copy, so a pull
    // right after a scraper run sees it.
    let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
    let index = try decoder.decode(FeedIndex.self, from: try await URLSession.shared.data(for: request).0)
    let newest = index.chunks.last?.id
    // The pieces up to `last` only ever lose articles to newer pieces, so what's after it is
    // everything new or changed. Older than the oldest piece: too long away, take it all.
    if let last = lastChunkID, let oldest = index.chunks.first?.id, last >= oldest {
      var articles: [FeedArticleDTO] = []
      for chunk in index.chunks where chunk.id > last {
        let (data, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appending(path: chunk.file))
        articles += try decoder.decode(FeedChunk.self, from: data).articles
      }
      return Download(articles: articles, newestChunk: newest)
    }
    let (data, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appending(path: index.snapshot))
    return Download(articles: try decoder.decode(FeedDTO.self, from: data).articles, newestChunk: newest)
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


  /// Inserts the articles not stored yet and returns them; updates the ones that changed (a
  /// picture found later, a corrected headline), and reads changed text again.
  @discardableResult
  func upsert(_ incoming: [FeedArticleDTO]) -> [ArticleItem] {
    let stored = Dictionary(((try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    let now = Date.now
    var added: [ArticleItem] = []
    for dto in incoming {
      if let article = stored[dto.url] {
        article.update(from: dto)
        continue
      }
      let article = ArticleItem(dto, fetchedAt: now)
      context.insert(article)
      added.append(article)
    }
    return added
  }



  /// Tags the new articles' regions (a word list). Only new ones: tagging all of them each sync
  /// held the main actor up for too long. A word-list fix applies as articles come in.
  func tagRegions(_ articles: [ArticleItem]) {
    for article in articles {
      article.regionsRaw = RegionTagger.regions(title: article.title, snippet: article.snippet)
        .map(\.rawValue).sorted().joined(separator: ",")
    }
  }


  func prune() {
    let cutoff = Date.now.addingTimeInterval(-Self.retention)
    let chartCutoff = Date.now.addingTimeInterval(-Self.chartRetention)
    try? context.delete(
      model: ArticleItem.self,
      where: #Predicate { $0.publishedAt < chartCutoff || ($0.publishedAt < cutoff && !$0.isChart) })
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
    // In batches, so the loading board can count articles as they're read.
    for start in stride(from: 0, to: missing.count, by: 40) {
      phase = .embedding(done: start, total: missing.count)
      let batch = Array(missing[start..<min(start + 40, missing.count)])
      let vectors = await engine.embed(batch.map(\.text))
      for (article, vector) in zip(batch, vectors) { article.embedding = vector.map(Vec.data) }
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
    let corpus = (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []
    let prepared = topics.map { topic in
      (topic, Vec.vectors(topic.exampleEmbeddings, dimension: dimension).map { Vec.centred($0, mean: corpusMean) }, Self.topicWords(topic, corpus: corpus))
    }
    for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] {
      let articles = cluster.articles
      func first(_ topicKind: TopicKind) -> String? {
        prepared.first { topic, examples, words in
          guard topic.kind == topicKind else { return false }
          let hits = articles.filter { matches($0, words: words, examples) }.count
          return hits > 0 && Double(hits) / Double(articles.count) >= 0.34
        }?.0.phrase
      }
      let mutedBy = first(.mute)
      let followedBy = mutedBy == nil ? first(.follow) : nil
      if cluster.mutedBy != mutedBy { cluster.mutedBy = mutedBy }
      if cluster.followedBy != followedBy { cluster.followedBy = followedBy }
    }
  }

  /// Words too broad to tell a topic apart: "tech" brought datacentre, drone and market stories
  /// into "Apple". They count only when the person typed them in the topic itself.
  static let broadWords: Set<String> = [
    "tech", "technology", "technologies", "news", "update", "updates", "latest", "business", "market",
    "markets", "company", "companies", "industry", "economy", "politics", "world", "science",
    "health", "sport", "sports", "government", "innovation", "digital", "device", "devices", "app",
    "apps", "software", "hardware", "smartphone", "smartphones", "phone", "phones", "gadget",
    "gadgets", "product", "products", "launch", "release", "stocks", "shares", "investors", "ai",
  ]

  /// The topic's words, in two kinds. What the person typed decides: all of its words (less
  /// "news" and the like) must appear, so "electric cars" isn't any story that says "electric".
  /// The on-device model's keywords are close to random ("jordan" for Space, "denver" for
  /// electric cars), so one counts only as a name the feed itself ties to the typed words.
  struct TopicWords {
    var typed: [String]
    var names: Set<String>
  }

  static func topicWords(_ topic: SemanticTopic, corpus: [ArticleItem]) -> TopicWords {
    // "Stories like this": nothing typed; the names its coverage shared are the words.
    if topic.phrase.hasPrefix("Like “") { return TopicWords(typed: [], names: Set(topic.keywords)) }
    let phrase = topic.phrase.lowercased()
    let own = phrase.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let kept = own.filter { $0.count > 1 && !broadWords.contains($0) }
    let typed = kept.isEmpty ? [phrase] : kept
    let suggested = Set(topic.keywords.filter { !broadWords.contains($0) && !typed.contains($0) })
    return TopicWords(typed: typed, names: suggested.filter { isName($0, in: corpus, with: typed) })
  }

  /// Whole word, case-insensitive, with or without a plural s ("car" finds "cars").
  static func contains(_ text: String, _ word: String) -> Bool {
    let stem = word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    return text.range(
      of: "\\b\(NSRegularExpression.escapedPattern(for: stem))s?\\b", options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// A keyword that is a name tied to the topic: the feed writes it with a capital letter
  /// mid-sentence ("iPhone", "NASA", "Tim Cook") at least two times in three (snippets only;
  /// many outlets capitalise every headline word), and articles that use it also use the
  /// typed words (two of them, or a quarter).
  static func isName(_ word: String, in corpus: [ArticleItem], with typed: [String]) -> Bool {
    guard let pattern = try? NSRegularExpression(
      pattern: "(?<![.!?:]\\s)(?<!^)\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.caseInsensitive])
    else { return false }
    var capital = 0, total = 0, using = 0, together = 0
    for article in corpus where contains(article.text, word) {
      using += 1
      if typed.allSatisfy({ contains(article.text, $0) }) { together += 1 }
      let text = article.snippet as NSString
      for match in pattern.matches(in: article.snippet, range: NSRange(location: 0, length: text.length)) {
        total += 1
        if text.substring(with: match.range).contains(where: \.isUppercase) { capital += 1 }
      }
    }
    return total > 0 && capital * 3 >= total * 2 && (together >= 2 || (together >= 1 && together * 4 >= using))
  }

  private func matches(_ article: ArticleItem, words: TopicWords, _ examples: [[Float]]) -> Bool {
    let typedAnywhere = !words.typed.isEmpty && words.typed.allSatisfy { Self.contains(article.text, $0) }
    let typedInHeadline = typedAnywhere && words.typed.contains { Self.contains(article.title, $0) }
    let nameInHeadline = words.names.contains { Self.contains(article.title, $0) }
    let nameAnywhere = nameInHeadline || words.names.contains { Self.contains(article.snippet, $0) }
    guard let vector = centredVector(article.embedding) else {
      // No vectors on this iPhone: the words in the headline.
      return typedInHeadline || nameInHeadline
    }
    let score = examples.map { Vec.cosine(vector, $0) }.max() ?? 0
    // What the person typed, in the headline, is enough. A name from the model in the headline
    // must also be roughly on topic; meaning varies with the model's made-up examples ("Apple"
    // stories scored 0.13–0.29 against them), so only roughly. Either one only in the snippet
    // is often a passing mention ("Apple, Samsung and Google wallets"), so it must be close. Or,
    // contextual model only, very close in meaning alone.
    return typedInHeadline
      || (nameInHeadline && score > meaningWithWordThreshold - 0.16)
      || ((typedAnywhere || nameAnywhere) && score > meaningWithWordThreshold)
      || meaningAloneThreshold.map { score > $0 } == true
  }

}

/// The steps of a sync, as the loading board shows them.
enum SyncPhase: Equatable {
  case idle
  case downloading
  /// The feed is in: how many outlets it has.
  case reading(outlets: Int)
  /// Articles read into vectors on the device.
  case embedding(done: Int, total: Int)
  case grouping
  case done(stories: Int)
  case failed

  /// 0…1, for the board's bottom row.
  var progress: Double {
    switch self {
    case .idle, .failed: 0
    case .downloading: 0.04
    case .reading: 0.1
    case .embedding(let done, let total): 0.1 + 0.8 * Double(done) / Double(max(total, 1))
    case .grouping: 0.94
    case .done: 1
    }
  }
}
