import SwiftUI

/// A news picture that fills its frame, decoded at that size by `ImagePipeline`.
///
/// With a feed picture it holds its space with a grey tile while loading. Without one it asks
/// the page itself (LinkPresentation) and takes no space unless that finds something.
struct HeroImage: View {
  let remote: URL?
  let article: URL
  /// A fixed height (small thumbnails), or nil to follow `aspect`.
  var height: CGFloat?
  var width: CGFloat?
  /// Width ÷ height when the height follows the width: 5:4 for heroes.
  var aspect: CGFloat = 5 / 4
  /// Charts: the whole picture on white, never cropped, so axes and labels stay.
  var fits = false
  /// A video thumbnail: a play glyph on top.
  var isVideo = false
  var radius: CGFloat = 14
  @Environment(\.displayScale) var displayScale
  @State private var image: CGImage?
  @State private var failed = false

  init(
    remote: String?, article: String, height: CGFloat? = nil, width: CGFloat? = nil, radius: CGFloat = 14,
    fits: Bool = false, isVideo: Bool = false
  ) {
    self.fits = fits
    self.isVideo = isVideo
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
        fits && image != nil ? Color.white : Swiss.tileQuiet
        if let image {
          Image(decorative: image, scale: displayScale)
            .resizable()
            .aspectRatio(contentMode: fits ? .fit : .fill)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .transition(.opacity)
          if isVideo {
            Image(systemName: "play.fill")
              .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.16))
              .foregroundStyle(.white)
              .padding(min(proxy.size.width, proxy.size.height) * 0.1)
              .background(.black.opacity(0.55), in: Circle())
          }
        }
      }
      .task(id: proxy.size.width) { await load(width: proxy.size.width) }
    }
    .modifier(HeroFrame(width: width, height: height, aspect: aspect, showsSpace: showsSpace))
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .accessibilityHidden(true)
  }

  func load(width: CGFloat) async {
    guard width > 0, image == nil else { return }
    let frameHeight = height ?? width / aspect
    // Filling the frame with a 16:9 photo needs its width to cover the frame's height too; a
    // chart shown whole may be tall, so its longest side covers the frame's.
    let longest = fits ? max(width, frameHeight) * 1.6 : max(width, frameHeight * 16 / 9)
    let maxPixel = Int((longest * displayScale).rounded(.up))
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

/// A fixed size, or the full width at `aspect`; no space at all when there's no picture.
private struct HeroFrame: ViewModifier {
  let width: CGFloat?
  let height: CGFloat?
  let aspect: CGFloat
  let showsSpace: Bool

  func body(content: Content) -> some View {
    if !showsSpace {
      content.frame(width: width, height: 0)
    } else if let height {
      content.frame(width: width, height: height)
    } else {
      content.frame(maxWidth: .infinity).aspectRatio(aspect, contentMode: .fit)
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
