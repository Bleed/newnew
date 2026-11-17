import SwiftUI
import UIKit

/// The Top 10 reel's pictures, ready before each slide shows. They come from the feed's own picture
/// for the story (the lead's first, then any article's), through `ImagePipeline`, so they are
/// downsampled to the screen and share its cache; only a story with no picture at all asks the
/// lead's page for its preview. Only the current deck is kept.
@MainActor
final class CatchupImagePreloader {
  static let shared = CatchupImagePreloader()

  private var cache: [UUID: UIImage] = [:]
  private var inFlight: [UUID: Task<UIImage?, Never>] = [:]

  func cachedImage(for clusterID: UUID) -> UIImage? {
    cache[clusterID]
  }

  /// Starts loading the deck's pictures and lets go of pictures from earlier decks.
  func preload(clusters: [StoryCluster]) {
    let ids = Set(clusters.map(\.id))
    cache = cache.filter { ids.contains($0.key) }
    for cluster in clusters {
      _ = load(for: cluster)
    }
  }

  func load(for cluster: StoryCluster) -> Task<UIImage?, Never> {
    let id = cluster.id
    if let existing = cache[id] {
      return Task { existing }
    }
    if let task = inFlight[id] {
      return task
    }
    let candidates = Self.candidates(in: cluster)
    let task = Task<UIImage?, Never> {
      let image = await Self.firstImage(candidates)
      self.cache[id] = image
      self.inFlight[id] = nil
      return image
    }
    inFlight[id] = task
    return task
  }

  /// (picture, article) pairs: articles with a feed picture, lead first; then the lead's page
  /// with no picture, which `ImagePipeline` reads with LinkPresentation.
  private static func candidates(in cluster: StoryCluster) -> [(remote: URL?, article: URL)] {
    let articles = ([cluster.lead].compactMap { $0 } + cluster.sortedArticles)
    var seen = Set<String>()
    var out: [(remote: URL?, article: URL)] = []
    for article in articles {
      guard let page = URL(string: article.url),
        let raw = article.imageURL, let remote = URL(string: raw), seen.insert(raw).inserted
      else { continue }
      out.append((remote, page))
    }
    if out.isEmpty, let page = cluster.lead.flatMap({ URL(string: $0.url) }) {
      out.append((nil, page))
    }
    return Array(out.prefix(3))
  }

  private static func firstImage(_ candidates: [(remote: URL?, article: URL)]) async -> UIImage? {
    // A full-screen slide: an iPhone screen's longest side in pixels (2,868 on a Pro Max).
    let maxPixel = 2_868
    // Across the full width of a phone (1,320 px on a Pro Max): a smaller picture tries the next.
    let frame = CGSize(width: 1_206, height: 0)
    for candidate in candidates {
      if let image = await ImagePipeline.shared.image(remote: candidate.remote, article: candidate.article, maxPixel: maxPixel, frame: frame) {
        return UIImage(cgImage: image)
      }
    }
    return nil
  }
}
