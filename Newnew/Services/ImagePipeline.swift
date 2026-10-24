import Foundation
import ImageIO
import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// News pictures, decoded at the size they're shown. Publishers often put 4K photos in
/// og:image; decoding one whole costs ~35 MB of GPU memory per row, so every picture goes
/// through `CGImageSourceCreateThumbnailAtIndex` and never `UIImage(data:)` or `AsyncImage`.
///
/// Where the feed has no picture (the publisher blocked the scraper), the page's own preview
/// is fetched from this iPhone with LinkPresentation.
@MainActor final class ImagePipeline {
  static let shared = ImagePipeline()

  private let cache = NSCache<NSString, CGImageBox>()
  private var failed: Set<String> = []
  private var inFlight: [String: Task<CGImage?, Never>] = [:]

  final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  init() {
    cache.totalCostLimit = 60 * 1024 * 1024
  }

  func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

  static func key(remote: URL?, article: URL, maxPixel: Int) -> String {
    "\((remote ?? article).absoluteString)@\(maxPixel)"
  }

  /// `maxPixel` is the longest side in pixels (points × display scale).
  func image(remote: URL?, article: URL, maxPixel: Int) async -> CGImage? {
    let key = Self.key(remote: remote, article: article, maxPixel: maxPixel)
    if let hit = cached(key) { return hit }
    guard !failed.contains(key) else { return nil }
    if let running = inFlight[key] { return await running.value }
    let task = Task<CGImage?, Never> {
      let data: Data?
      if let remote {
        data = await Self.download(remote)
      } else {
        data = await Self.previewImageData(for: article)
      }
      guard let data else { return nil }
      return await Task.detached(priority: .utility) { Self.downsample(data, maxPixel: maxPixel) }.value
    }
    inFlight[key] = task
    let image = await task.value
    inFlight[key] = nil
    if let image {
      cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    } else {
      failed.insert(key)
    }
    return image
  }

  nonisolated static func download(_ url: URL) async -> Data? {
    guard let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
    else { return nil }
    return data
  }

  /// Tier 3: the page's preview image, fetched from the phone's own connection.
  static func previewImageData(for article: URL) async -> Data? {
    let provider = LPMetadataProvider()
    provider.timeout = 8
    guard let metadata = try? await provider.startFetchingMetadata(for: article),
      let item = metadata.imageProvider
    else { return nil }
    return await withCheckedContinuation { continuation in
      _ = item.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
    }
  }

  /// Decodes straight to a thumbnail no larger than `maxPixel` on its longest side.
  nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }
}
