import Foundation
import SwiftData

/// One headline and snippet from one outlet. We never store or show the full article: the
/// card links out to the publisher.
@Model final class ArticleItem {
  @Attribute(.unique) var url: String
  var title: String
  var snippet: String
  var outlet: String
  var imageURL: String?
  var category: String?
  var publishedAt: Date
  var fetchedAt: Date
  /// L2-normalised "Headline. Snippet" vector (Float32), as the engine made it. Centred against
  /// the corpus mean when compared; see `Vec.centred`.
  var embedding: Data?
  var isRead = false
  /// The outlet's country when the scraper knows it ("NO"), for Local.
  var country: String?
  /// `Region` raw values, comma-separated (see `RegionTagger`).
  var regionsRaw: String = ""
  var cluster: StoryCluster?

  init(_ dto: FeedArticleDTO, fetchedAt: Date) {
    url = dto.url
    title = dto.title
    snippet = dto.snippet
    outlet = dto.outlet
    imageURL = dto.imageURL
    category = dto.category
    country = dto.country
    publishedAt = dto.publishedAt
    self.fetchedAt = fetchedAt
  }

  var text: String { "\(title). \(snippet)" }

  var regions: Set<Region> { Set(regionsRaw.split(separator: ",").compactMap { Region(rawValue: String($0)) }) }
}

/// Articles from different outlets about the same event.
@Model final class StoryCluster {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  /// The newest article's time.
  var updatedAt: Date
  @Relationship(deleteRule: .nullify, inverse: \ArticleItem.cluster) var articles: [ArticleItem] = []
  /// When you last opened it; sources that arrive later are "new since you read".
  var readAt: Date?
  /// The mute topic that hides it, if any.
  var mutedBy: String?
  /// The followed topic that raises it, if any (never set while muted).
  var followedBy: String?
  /// `ClusterPerspectiveBrief` as JSON, made on demand and kept.
  var cachedPerspectiveBriefJSON: Data?

  init(updatedAt: Date) {
    id = UUID()
    createdAt = .now
    self.updatedAt = updatedAt
  }

  var isMuted: Bool { mutedBy != nil }
  var isFollowed: Bool { followedBy != nil }

  /// Newest first.
  var sortedArticles: [ArticleItem] { articles.sorted { $0.publishedAt > $1.publishedAt } }

  /// The article that fronts the card: the newest one with a picture, else the newest.
  var lead: ArticleItem? { sortedArticles.first { $0.imageURL != nil } ?? sortedArticles.first }

  var outlets: [String] {
    var seen = Set<String>()
    return sortedArticles.map(\.outlet).filter { seen.insert($0).inserted }
  }

  /// The regions at least a third of its articles are about (any, for one article). World is
  /// always included.
  var regions: Set<Region> {
    var counts: [Region: Int] = [:]
    for article in articles { for region in article.regions { counts[region, default: 0] += 1 } }
    let needed = max(1, Int((Double(articles.count) / 3).rounded(.up)))
    return Set(counts.filter { $0.value >= needed }.keys).union([.world])
  }

  var newSinceRead: Int {
    guard let readAt else { return 0 }
    return articles.filter { $0.fetchedAt > readAt }.count
  }

  var brief: ClusterPerspectiveBrief? {
    get { cachedPerspectiveBriefJSON.flatMap { try? JSONDecoder().decode(ClusterPerspectiveBrief.self, from: $0) } }
    set { cachedPerspectiveBriefJSON = newValue.flatMap { try? JSONEncoder().encode($0) } }
  }
}

/// What a topic does to the stories that match it.
nonisolated enum TopicKind: String, Codable, CaseIterable {
  /// Raised into "Following" at the top of the feed.
  case follow
  /// Hidden.
  case mute
}

/// A topic you follow or mute, matched by idea rather than by word: it's kept as a few example
/// headlines (written on device when you add it), and stories that read like them are raised
/// or hidden.
@Model final class SemanticTopic {
  var phrase: String
  /// `TopicKind`, as text.
  var kindRaw: String = TopicKind.mute.rawValue
  var exampleHeadlines: [String]
  var keywords: [String]
  /// The example headlines' vectors, one after another (Float32).
  var exampleEmbeddings: Data?
  var createdAt: Date

  init(phrase: String, kind: TopicKind, exampleHeadlines: [String], keywords: [String]) {
    self.phrase = phrase
    kindRaw = kind.rawValue
    self.exampleHeadlines = exampleHeadlines
    self.keywords = keywords
    createdAt = .now
  }

  var kind: TopicKind { TopicKind(rawValue: kindRaw) ?? .mute }
}

// MARK: - Transfer

/// `latest_news.json`, as the scraper publishes it.
nonisolated struct FeedDTO: Decodable {
  var generatedAt: Date
  var articles: [FeedArticleDTO]
}

nonisolated struct FeedArticleDTO: Decodable {
  var title: String
  var snippet: String
  var outlet: String
  var url: String
  var imageURL: String?
  var publishedAt: Date
  var category: String?
  /// The outlet's country (ISO code), when the scraper's feed list says.
  var country: String?
}

/// What Apple Intelligence says about how outlets covered one story.
nonisolated struct ClusterPerspectiveBrief: Codable, Equatable {
  struct Angle: Codable, Equatable, Hashable {
    var outlet: String
    var focus: String
  }

  var summary: String
  var sharedFacts: [String]
  var differences: [String]
  var angles: [Angle]
  /// How many articles it was written from, so newer sources can be noticed.
  var sourceCount: Int
  /// False for the preview shown where Apple Intelligence isn't available.
  var isGenerated: Bool
  var createdAt: Date
}
