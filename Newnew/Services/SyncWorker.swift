import Foundation
import SwiftData

/// The store's side of a sync, on its own context off the main actor: storing new articles,
/// embedding, regrouping, topics and the save. The feed only hears the one save at the end, so
/// scrolling never waits on a sync. Not a `@ModelActor`: its executor runs the work on whichever
/// thread calls it (the main one, measured), so this actor has its own serial queue and makes its
/// context there.
actor SyncWorker {
  private let queue = DispatchSerialQueue(label: "newnew.sync", qos: .utility)
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  private let container: ModelContainer
  private lazy var modelContext: ModelContext = {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return context
  }()
  private let engine = OnDeviceVectorEngine.shared
  /// The mean article vector, taken away before comparing (see `Vec.centred`).
  private var corpusMean: [Float]?
  private var dimension = 0
  private var kind: OnDeviceVectorEngine.Kind = .none

  init(container: ModelContainer) {
    self.container = container
  }

  /// What a sync left: stories shown, and the new articles per story (muted ones left out).
  struct Result: Sendable {
    var stories = 0
    var new: [UUID: Int] = [:]
  }

  // MARK: Sync

  /// Clears the stored articles when where they come from changed (the sample's invented stories
  /// shouldn't mix with real ones), or when there are none.
  func clear(unless source: String, stored: String?) throws -> Bool {
    let articles = (try? modelContext.fetch(FetchDescriptor<ArticleItem>())) ?? []
    // The sample's links all go to example.com; none of them belong next to real news.
    let hasSample = source != "sample" && articles.contains { $0.url.hasPrefix("https://example.com/") }
    guard stored != source || hasSample || articles.isEmpty else { return false }
    // One by one: the bulk delete fails silently on the article–story relationship.
    for cluster in (try? modelContext.fetch(FetchDescriptor<StoryCluster>())) ?? [] { modelContext.delete(cluster) }
    for article in articles { modelContext.delete(article) }
    try modelContext.save()
    return true
  }

  /// HD video thumbnails already checked (link → picture).
  func pictures() -> [String: String] {
    let stored = (try? modelContext.fetch(FetchDescriptor<ArticleItem>(predicate: #Predicate { $0.videoID != nil }))) ?? []
    return Dictionary(stored.compactMap { a in a.imageURL.map { (a.url, $0) } }, uniquingKeysWith: { a, _ in a })
  }

  /// Everything after the download: store, embed, regroup, topics, one save. `inStages` (with
  /// the app closed, where iOS can stop the run at any moment): the articles are saved as soon as
  /// they're stored and the vectors as far as they got, so a run cut short still keeps what it
  /// read; the next one (or the next open, `regroup`) finishes it.
  func ingest(
    _ incoming: [FeedArticleDTO], since: Date, inStages: Bool = false, phase: @escaping @Sendable (SyncPhase) async -> Void
  ) async throws -> Result {
    let added = upsert(incoming)
    prune()
    tagRegions(added)
    if inStages { try modelContext.save() }
    await embedMissing(phase: phase)
    if Task.isCancelled {
      try modelContext.save()
      throw CancellationError()
    }
    await phase(.grouping)
    await recluster()
    applyTopics()
    try modelContext.save()
    return result(since: since)
  }

  /// Regroups and applies the topics to what's stored, then saves. Articles a background run
  /// stored but didn't get to embed are read first.
  func regroup() async throws -> Result {
    await embedMissing { _ in }
    await recluster()
    applyTopics()
    try modelContext.save()
    return result(since: .distantFuture)
  }

  /// After a topic was added or removed (and saved): its examples read, the stories matched.
  func retopic() async throws {
    await prepare()
    await embedTopics()
    applyTopics()
    try modelContext.save()
  }

  private func result(since: Date) -> Result {
    var result = Result()
    for cluster in (try? modelContext.fetch(FetchDescriptor<StoryCluster>())) ?? [] where !cluster.isMuted {
      let articles = cluster.articles
      guard !articles.isEmpty else { continue }
      result.stories += 1
      let new = articles.filter { $0.fetchedAt >= since }.count
      if new > 0 { result.new[cluster.id] = new }
    }
    return result
  }

  /// Inserts the articles not stored yet and returns them; updates the ones that changed (a
  /// picture found later, a corrected headline), and reads changed text again.
  private func upsert(_ incoming: [FeedArticleDTO]) -> [ArticleItem] {
    let stored = Dictionary(((try? modelContext.fetch(FetchDescriptor<ArticleItem>())) ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    let now = Date.now
    var added: [ArticleItem] = []
    for dto in incoming {
      if let article = stored[dto.url] {
        article.update(from: dto)
        continue
      }
      let article = ArticleItem(dto, fetchedAt: now)
      modelContext.insert(article)
      added.append(article)
    }
    return added
  }

  /// Tags the new articles' regions (a word list). Only new ones; a word-list fix applies as
  /// articles come in.
  private func tagRegions(_ articles: [ArticleItem]) {
    for article in articles {
      article.regionsRaw = RegionTagger.regions(title: article.title, snippet: article.snippet)
        .map(\.rawValue).sorted().joined(separator: ",")
    }
  }

  private func prune() {
    let cutoff = Date.now.addingTimeInterval(-FeedSyncPipeline.retention)
    let chartCutoff = Date.now.addingTimeInterval(-FeedSyncPipeline.chartRetention)
    let episodeCutoff = Date.now.addingTimeInterval(-FeedFetcher.podcastMaxAge)
    // One by one: the bulk delete fails on the article–story relationship (and nothing went).
    let old = FetchDescriptor<ArticleItem>(predicate: #Predicate {
      $0.publishedAt < chartCutoff || ($0.publishedAt < cutoff && !$0.isChart && $0.audioURL == nil)
        || ($0.publishedAt < episodeCutoff && $0.audioURL != nil)
    })
    for article in (try? modelContext.fetch(old)) ?? [] { modelContext.delete(article) }
  }

  /// Loads the vector model while the feeds download, so reading the articles can start at once.
  func warmUp() async {
    await prepare()
  }

  // MARK: Vectors

  private func prepare() async {
    guard dimension == 0 else { return }
    await engine.prepare()
    kind = await engine.kind
    dimension = await engine.dimension
  }

  private func embedMissing(phase: @Sendable (SyncPhase) async -> Void) async {
    await prepare()
    guard dimension > 0 else { return }
    let bytes = dimension * MemoryLayout<Float>.size

    let articles = (try? modelContext.fetch(FetchDescriptor<ArticleItem>())) ?? []
    let missing = articles.filter { $0.embedding?.count != bytes }
    // In batches, so the loader can count articles as they're read.
    for start in stride(from: 0, to: missing.count, by: 40) {
      // Out of background time: keep the vectors read so far.
      if Task.isCancelled { return }
      await phase(.embedding(done: start, total: missing.count))
      let batch = Array(missing[start..<min(start + 40, missing.count)])
      let vectors = await engine.embed(batch.map(\.text))
      for (article, vector) in zip(batch, vectors) { article.embedding = vector.map(Vec.data) }
    }
    corpusMean = Vec.mean(articles.compactMap { Vec.vector($0.embedding) }.filter { $0.count == dimension })
    await embedTopics()
  }

  private func embedTopics() async {
    guard dimension > 0 else { return }
    let bytes = dimension * MemoryLayout<Float>.size
    for topic in (try? modelContext.fetch(FetchDescriptor<SemanticTopic>())) ?? []
    where topic.exampleEmbeddings?.count != topic.exampleHeadlines.count * bytes {
      let vectors = await engine.embed(topic.exampleHeadlines.map { $0.hasSuffix(".") ? $0 : $0 + "." })
      let flat = vectors.compactMap { $0 }.flatMap { $0 }
      topic.exampleEmbeddings = flat.isEmpty ? nil : Vec.data(flat)
    }
  }

  private func centredVector(_ data: Data?) -> [Float]? {
    guard let vector = Vec.vector(data), vector.count == dimension else { return nil }
    return Vec.centred(vector, mean: corpusMean)
  }

  // MARK: Stories

  /// Regroups every article and keeps each story's identity (and its cached brief) where most
  /// of its articles stay together. Also runs `StoryClusterSanitizer` so articles that only share
  /// a country/demonym (e.g. "Japan" / "Japanese") are never merged into the same story.
  private func recluster() async {
    let articles = (try? modelContext.fetch(FetchDescriptor<ArticleItem>(sortBy: [SortDescriptor(\.publishedAt)]))) ?? []
    guard !articles.isEmpty else { return }

    if corpusMean == nil {
      let rawVectors = articles.compactMap { Vec.vector($0.embedding) }
      if let firstLen = rawVectors.first?.count, firstLen > 0 {
        dimension = firstLen
        corpusMean = Vec.mean(rawVectors.filter { $0.count == firstLen })
      }
    }

    let inputs = articles.map {
      StoryClusterer.Input(
        text: $0.text, outlet: $0.outlet, publishedAt: $0.publishedAt, vector: centredVector($0.embedding), terms: $0.terms)
    }
    let meta = articles.map {
      StoryClusterSanitizer.ItemMeta(title: $0.title, snippet: $0.snippet, outlet: $0.outlet)
    }
    let groups = StoryClusterSanitizer.sanitize(groups: StoryClusterer.groups(inputs), meta: meta)

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
        modelContext.insert(cluster)
      }
      kept.insert(cluster.id)
      for item in items where item.cluster?.id != cluster.id { item.cluster = cluster }
      // Only what changed, so the save leaves the rest (a story read meanwhile) alone.
      let updatedAt = items.map(\.publishedAt).max() ?? cluster.updatedAt
      if cluster.updatedAt != updatedAt { cluster.updatedAt = updatedAt }
      let leadIsChart = cluster.lead?.isChart == true
      if cluster.leadIsChart != leadIsChart { cluster.leadIsChart = leadIsChart }
      let pillarRaw = cluster.pillar.rawValue
      if cluster.pillarRaw != pillarRaw { cluster.pillarRaw = pillarRaw }
    }
    for cluster in (try? modelContext.fetch(FetchDescriptor<StoryCluster>())) ?? [] where !kept.contains(cluster.id) {
      modelContext.delete(cluster)
    }
  }

  // MARK: Topics

  /// Example headline vs story ("Headline. Snippet") on centred vectors. Measured on a real
  /// feed (1,063 articles): with the contextual model, true matches for "space" reach 0.60, but
  /// a supervolcano and the Dead Sea sit at 0.51–0.53 and a weather story at 0.49; the older
  /// sentence model ranks a cricket story first for "AI". So meaning alone only counts when it
  /// is very close, and only with the contextual model; otherwise a topic word must appear too.
  private var meaningAloneThreshold: Float? { kind == .contextual ? 0.55 : nil }
  /// Meaning needed alongside one topic word. Among articles that say "satellite", "moon" or
  /// "space", real space stories score ≥ 0.40 (contextual) and an oil spill seen in "satellite
  /// images" 0.36; the sentence model separates them less well (0.32 for the spill).
  private var meaningWithWordThreshold: Float { kind == .contextual ? 0.38 : 0.40 }

  /// A story matches a topic when at least a third of its articles do, so one stray article
  /// doesn't hide or raise a big story. Muting wins over following.
  private func applyTopics() {
    let topics = (try? modelContext.fetch(FetchDescriptor<SemanticTopic>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    let corpus = (try? modelContext.fetch(FetchDescriptor<ArticleItem>())) ?? []
    let prepared = topics.map { topic in
      (topic, Vec.vectors(topic.exampleEmbeddings, dimension: dimension).map { Vec.centred($0, mean: corpusMean) }, TopicMatch.words(topic, corpus: corpus))
    }
    for cluster in (try? modelContext.fetch(FetchDescriptor<StoryCluster>())) ?? [] {
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

  private func matches(_ article: ArticleItem, words: TopicMatch.Words, _ examples: [[Float]]) -> Bool {
    let typedAnywhere = !words.typed.isEmpty && words.typed.allSatisfy { TopicMatch.contains(article.text, $0) }
    let typedInHeadline = typedAnywhere && words.typed.contains { TopicMatch.contains(article.title, $0) }
    let nameInHeadline = words.names.contains { TopicMatch.contains(article.title, $0) }
    let nameAnywhere = nameInHeadline || words.names.contains { TopicMatch.contains(article.snippet, $0) }
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

/// A topic's words and how they're found in an article.
nonisolated enum TopicMatch {
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
  struct Words {
    var typed: [String]
    var names: Set<String>
  }

  static func words(_ topic: SemanticTopic, corpus: [ArticleItem]) -> Words {
    // "Stories like this": nothing typed; the names its coverage shared are the words.
    if topic.phrase.hasPrefix("Like “") { return Words(typed: [], names: Set(topic.keywords)) }
    let phrase = topic.phrase.lowercased()
    let own = phrase.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let kept = own.filter { $0.count > 1 && !broadWords.contains($0) }
    let typed = kept.isEmpty ? [phrase] : kept
    let suggested = Set(topic.keywords.filter { !broadWords.contains($0) && !typed.contains($0) })
    return Words(typed: typed, names: suggested.filter { isName($0, in: corpus, with: typed) })
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
}
