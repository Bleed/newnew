import SwiftUI

/// A news picture that fills its frame, decoded at that size by `ImagePipeline`.
///
/// With a feed picture it holds its space with a grey tile while loading. Without one it asks
/// the page itself (LinkPresentation) and takes no space unless that finds something.
struct HeroImage: View {
  let remote: URL?
  let article: URL
  var height: CGFloat
  var width: CGFloat?
  var radius: CGFloat = 14
  @Environment(\.displayScale) var displayScale
  @State private var image: CGImage?
  @State private var failed = false

  init(remote: String?, article: String, height: CGFloat, width: CGFloat? = nil, radius: CGFloat = 14) {
    self.remote = remote.flatMap(URL.init(string:))
    self.article = URL(string: article) ?? URL(string: "about:blank")!
    self.height = height
    self.width = width
    self.radius = radius
  }

  var showsSpace: Bool { image != nil || (remote != nil && !failed) }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Swiss.tileQuiet
        if let image {
          Image(decorative: image, scale: displayScale)
            .resizable()
            .scaledToFill()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .transition(.opacity)
        }
      }
      .task(id: proxy.size.width) { await load(width: proxy.size.width) }
    }
    .frame(width: width, height: showsSpace ? height : 0)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .accessibilityHidden(true)
  }

  func load(width: CGFloat) async {
    guard width > 0, image == nil else { return }
    // Filling the frame with a 16:9 photo needs its width to cover the frame's height too.
    let maxPixel = Int((max(width, height * 16 / 9) * displayScale).rounded(.up))
    if let hit = ImagePipeline.shared.cached(ImagePipeline.key(remote: remote, article: article, maxPixel: maxPixel)) {
      image = hit
      return
    }
    let loaded = await ImagePipeline.shared.image(remote: remote, article: article, maxPixel: maxPixel)
    withAnimation(.easeOut(duration: 0.2)) {
      image = loaded
      failed = loaded == nil
    }
  }
}

extension Date {
  /// "4m", "3h", "2d": short, for beside a headline in mono.
  var shortAgo: String {
    let seconds = max(Date.now.timeIntervalSince(self), 0)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
  }
}
