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
  var cluster: StoryCluster?

  init(_ dto: FeedArticleDTO, fetchedAt: Date) {
    url = dto.url
    title = dto.title
    snippet = dto.snippet
    outlet = dto.outlet
    imageURL = dto.imageURL
    category = dto.category
    publishedAt = dto.publishedAt
    self.fetchedAt = fetchedAt
  }

  var text: String { "\(title). \(snippet)" }
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
  /// `ClusterPerspectiveBrief` as JSON, made on demand and kept.
  var cachedPerspectiveBriefJSON: Data?

  init(updatedAt: Date) {
    id = UUID()
    createdAt = .now
    self.updatedAt = updatedAt
  }

  var isMuted: Bool { mutedBy != nil }

  /// Newest first.
  var sortedArticles: [ArticleItem] { articles.sorted { $0.publishedAt > $1.publishedAt } }

  /// The article that fronts the card: the newest one with a picture, else the newest.
  var lead: ArticleItem? { sortedArticles.first { $0.imageURL != nil } ?? sortedArticles.first }

  var outlets: [String] {
    var seen = Set<String>()
    return sortedArticles.map(\.outlet).filter { seen.insert($0).inserted }
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

/// A topic you don't want to see, matched by idea rather than by word: it's kept as a few
/// example headlines (written on device when you add it) and stories that read like them are
/// hidden.
@Model final class SemanticMuteFilter {
  var phrase: String
  var exampleHeadlines: [String]
  var keywords: [String]
  /// The example headlines' vectors, one after another (Float32).
  var exampleEmbeddings: Data?
  var createdAt: Date

  init(phrase: String, exampleHeadlines: [String], keywords: [String]) {
    self.phrase = phrase
    self.exampleHeadlines = exampleHeadlines
    self.keywords = keywords
    createdAt = .now
  }
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
