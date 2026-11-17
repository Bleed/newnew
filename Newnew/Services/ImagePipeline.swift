import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// News pictures, decoded at the size they're shown. Publishers often put 4K photos in
/// og:image; decoding one whole costs ~35 MB of GPU memory per row, so every picture goes
/// through `CGImageSourceCreateThumbnailAtIndex` and never `UIImage(data:)` or `AsyncImage`.
///
/// Only the feed's own picture is shown (2026-11-17): none is looked up on the article's page,
/// and one too small for its frame is skipped rather than blown up.
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

  /// How far a picture may be blown up to fill its frame. Past this it's a smudge (a feed's
  /// 90 px thumbnail across a card), and no picture reads better.
  nonisolated static let maxUpscale: CGFloat = 2.5

  /// `maxPixel` is the longest side in pixels (points × display scale). `frame` is the size it
  /// fills, in pixels: a picture too small for it is skipped (`maxUpscale`).
  func image(remote: URL?, article: URL, maxPixel: Int, frame: CGSize? = nil, fits: Bool = false) async -> CGImage? {
    let key = Self.key(remote: remote, article: article, maxPixel: maxPixel)
    if let hit = cached(key) { return hit }
    guard !failed.contains(key) else { return nil }
    if let running = inFlight[key] { return await running.value }
    let task = Task<CGImage?, Never> {
      guard let remote, let data = await Self.download(remote) else { return nil }
      return await Self.decode(data, maxPixel: maxPixel, frame: frame, fits: fits)
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

  private static func decode(_ data: Data, maxPixel: Int, frame: CGSize?, fits: Bool) async -> CGImage? {
    await Task.detached(priority: .utility) { downsample(data, maxPixel: maxPixel, frame: frame, fits: fits) }.value
  }

  /// Decodes straight to a thumbnail no larger than `maxPixel` on its longest side; nil when
  /// the picture would have to be blown up more than `maxUpscale` to fill `frame`.
  nonisolated static func downsample(_ data: Data, maxPixel: Int, frame: CGSize? = nil, fits: Bool = false) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
    if let frame, let size = pixelSize(source), size.width > 0, size.height > 0 {
      // Filling the frame takes the larger scale; shown whole (charts), the smaller.
      let across = frame.width / size.width, down = frame.height / size.height
      if (fits ? min(across, down) : max(across, down)) > maxUpscale { return nil }
    }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }

  /// The picture's own size, read from its header without decoding it.
  nonisolated static func pixelSize(_ source: CGImageSource) -> CGSize? {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? CGFloat, let height = props[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    // Rotated by EXIF: width and height swap.
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }
}
