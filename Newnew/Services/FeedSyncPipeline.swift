import Foundation
import NaturalLanguage
import SwiftData

/// Reads the chosen outlets' feeds (`FeedFetcher`, on this iPhone), stores new articles, embeds them, regroups the stories and applies the
/// mute topics. Model changes stay on the main actor; the heavy parts (embedding, clustering)
/// run off it.
@MainActor @Observable final class FeedSyncPipeline {
  let context: ModelContext
  private let engine = OnDeviceVectorEngine.shared
  private(set) var isSyncing = false
  /// Where a sync is, for the loading board.
  private(set) var phase: SyncPhase = .idle
  /// When the last sync finished; kept across launches, for `hasALotToLoad`.
  private(set) var lastSync: Date? {
    get { UserDefaults.standard.object(forKey: "lastSyncAt") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "lastSyncAt") }
  }
  private(set) var lastError: String?
  /// The mean article vector, taken away before comparing (see `Vec.centred`).
  private var corpusMean: [Float]?
  private var dimension = 0
  private var kind: OnDeviceVectorEngine.Kind = .none
  private var didSanitizeOnLaunch = false

  /// Articles older than this are let go.
  static let retention: TimeInterval = 72 * 3600
  /// Charts come weekly; they stay two weeks.
  static let chartRetention: TimeInterval = 14 * 24 * 3600
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

  // MARK: Sync

  /// Stories with at least one article that isn't muted.
  var storyCount: Int {
    ((try? context.fetch(FetchDescriptor<StoryCluster>())) ?? []).filter { !$0.isMuted && !$0.articles.isEmpty }.count
  }

  func syncIfNeeded() async {
    if let lastSync, Date.now.timeIntervalSince(lastSync) < Self.refreshInterval {
      // No sync due: regroup the stored stories once per launch, so a new grouping rule reaches
      // them. A sync regroups anyway, so launches that sync skip this extra pass.
      if !didSanitizeOnLaunch {
        didSanitizeOnLaunch = true
        await recluster()
        applyTopics()
        try? context.save()
      }
      return
    }
    didSanitizeOnLaunch = true
    await sync()
  }

  func sync() async {
    guard !isSyncing else { return }
    isSyncing = true
    phase = .downloading
    defer { isSyncing = false }
    do {
      // "phone-1": read from the feeds on this iPhone (builds up to 32 downloaded a feed newnew
      // published; those articles go once).
      let source = Self.feedURL == nil ? "sample" : "phone-1"
      let articles = (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? []
      // The sample's links all go to example.com; none of them belong next to real news.
      let hasSample = source != "sample" && articles.contains { $0.url.hasPrefix("https://example.com/") }
      if storedSource != source || hasSample || articles.isEmpty {
        // One by one: the bulk delete fails silently on the article–story relationship.
        for cluster in (try? context.fetch(FetchDescriptor<StoryCluster>())) ?? [] { context.delete(cluster) }
        for article in articles { context.delete(article) }
        try context.save()
        storedSource = source
      }
      var incoming = try await loadArticles()
      // The reader's own feeds too.
      for custom in OutletStore.shared.customFeeds { incoming += await CustomFeedReader.articles(custom) }
      phase = .reading(outlets: Set(incoming.map(\.outlet)).count)
      let added = upsert(incoming)
      prune()
      tagRegions(added)
      await embedMissing()
      phase = .grouping
      await recluster()
      applyTopics()
      try context.save()
      lastSync = .now
      lastError = nil
      phase = .done(stories: storyCount)
    } catch {
      lastError = error.localizedDescription
      phase = .failed
    }
  }

  /// Away longer than this, opening the app is a big catch-up (hundreds of articles to read on
  /// the device): the full-screen loader stays up with its
  /// progress bar until it's done, instead of the small pull-down band.
  static let bigCatchUp: TimeInterval = 3 * 3600

  /// The loading board finishes on a done (or failed) phase; when it comes back for a catch-up
  /// the last sync's "done" must not end it before the new sync starts.
  func prepareForCatchUp() {
    if !isSyncing { phase = .downloading }
  }

  /// Whether the next sync has a lot to do: nothing stored yet, or the last sync is older than
  /// `bigCatchUp`.
  var hasALotToLoad: Bool {
    guard storyCount > 0, let lastSync else { return true }
    return Date.now.timeIntervalSince(lastSync) > Self.bigCatchUp
  }

  /// The chosen outlets' articles, read from their feeds; the bundled sample without a
  /// `feedURL`.
  func loadArticles() async throws -> [FeedArticleDTO] {
    guard Self.feedURL != nil else {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try sampleArticles(decoder)
    }
    let feeds = OutletStore.shared.chosenFeeds
    guard !feeds.isEmpty else { return [] }
    // HD video thumbnails already checked.
    let stored = (try? context.fetch(FetchDescriptor<ArticleItem>(predicate: #Predicate { $0.videoID != nil }))) ?? []
    let pictures = Dictionary(stored.compactMap { a in a.imageURL.map { (a.url, $0) } }, uniquingKeysWith: { a, _ in a })
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

  /// After the reader changes their outlets: articles from outlets no longer read go now, and
  /// if any outlet was added a sync reads its feeds.
  func applyOutletChoice(added: Bool) async {
    let outlets = OutletStore.shared
    for article in (try? context.fetch(FetchDescriptor<ArticleItem>())) ?? [] where !outlets.reads(article.outlet) {
      context.delete(article)
    }
    try? context.save()
    await recluster()
    applyTopics()
    try? context.save()
    if added { await sync() }
  }

  func prune() {
    let cutoff = Date.now.addingTimeInterval(-Self.retention)
    let chartCutoff = Date.now.addingTimeInterval(-Self.chartRetention)
    let episodeCutoff = Date.now.addingTimeInterval(-FeedFetcher.podcastMaxAge)
    try? context.delete(
      model: ArticleItem.self,
      where: #Predicate {
        $0.publishedAt < chartCutoff || ($0.publishedAt < cutoff && !$0.isChart && $0.audioURL == nil)
          || ($0.publishedAt < episodeCutoff && $0.audioURL != nil)
      })
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
  /// of its articles stay together. Also runs `StoryClusterSanitizer` so articles that only share
  /// a country/demonym (e.g. "Japan" / "Japanese") are never merged into the same story.
  func recluster() async {
    let articles = (try? context.fetch(FetchDescriptor<ArticleItem>(sortBy: [SortDescriptor(\.publishedAt)]))) ?? []
    guard !articles.isEmpty else { return }

    if corpusMean == nil {
      let rawVectors = articles.compactMap { Vec.vector($0.embedding) }
      if let firstLen = rawVectors.first?.count, firstLen > 0 {
        dimension = firstLen
        corpusMean = Vec.mean(rawVectors.filter { $0.count == firstLen })
      }
    }

    let inputs = articles.map {
      StoryClusterer.Input(text: $0.text, outlet: $0.outlet, publishedAt: $0.publishedAt, vector: centredVector($0.embedding))
    }
    let meta = articles.map {
      StoryClusterSanitizer.ItemMeta(title: $0.title, snippet: $0.snippet, outlet: $0.outlet)
    }

    let groups = await Task.detached(priority: .userInitiated) {
      let rawGroups = StoryClusterer.groups(inputs)
      return StoryClusterSanitizer.sanitize(groups: rawGroups, meta: meta)
    }.value

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

  /// `step` hears where it is, for the sheet to show.
  func addTopic(_ phrase: String, kind topicKind: TopicKind, step: (TopicStep) -> Void = { _ in }) async {
    let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return }
    step(.examples)
    let examples = await IntelligenceService.topicExamples(phrase)
    let topic = SemanticTopic(phrase: phrase, kind: topicKind, exampleHeadlines: examples.headlines, keywords: examples.keywords)
    step(.reading)
    await embedExamples(topic)
    step(.matching)
    // Matching holds the main actor for a moment: let the sheet show the step first.
    try? await Task.sleep(for: .milliseconds(60))
    context.insert(topic)
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

/// Validates every multi-article cluster returned by `StoryClusterer` and splits apart articles
/// that were only grouped because they share a country/demonym (e.g. "Japan" / "Japanese") or
/// transitive single-linkage chaining.
enum StoryClusterSanitizer {
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
enum SyncPhase: Equatable {
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
