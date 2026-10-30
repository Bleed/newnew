import SwiftUI
import UIKit

/// The reel's pictures, ready before each slide shows. They come from the feed's own picture
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
    for candidate in candidates {
      if let image = await ImagePipeline.shared.image(remote: candidate.remote, article: candidate.article, maxPixel: maxPixel) {
        return UIImage(cgImage: image)
      }
    }
    return nil
  }
}

/// Full-screen Instagram Stories / TikTok style "Daily Catchup" deck:
/// - 7-second animated progress bar per slide that auto-advances
/// - Tap left (previous) / Tap right (next) + Press-and-hold to pause timer
/// - Preloads hero images across all slides so transitions are instant
struct CatchupReelView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.dismiss) private var dismiss

  let stories: [StoryCluster]
  var onOpenFullStory: (StoryCluster) -> Void

  static let slideDuration: Double = 7.0

  @State private var currentIndex: Int = 0
  @State private var elapsed: Double = 0
  @State private var isPaused: Bool = false
  @State private var lastTick: Date = .now

  private var currentCluster: StoryCluster? {
    guard stories.indices.contains(currentIndex) else { return nil }
    return stories[currentIndex]
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.ignoresSafeArea()

      if let cluster = currentCluster {
        CatchupCardPage(
          cluster: cluster,
          onTapLeft: previousSlide,
          onTapRight: nextSlide,
          onPressingChanged: { pressing in
            isPaused = pressing
            lastTick = .now
          },
          onOpenFullStory: {
            isPaused = true
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
              onOpenFullStory(cluster)
            }
          }
        )
        .id(cluster.id)
      }

      // Top HUD: 7-second animated progress bars + counter + close button
      topOverlayBar
    }
    .preferredColorScheme(.dark)
    .statusBarHidden(true)
    // VoiceOver: the tap zones and hold-to-pause as actions; slides don't move on by
    // themselves while it reads, and each new slide is announced.
    .accessibilityActions {
      Button("Next story") { nextSlide() }
      Button("Previous story") { previousSlide() }
      Button(isPaused ? "Resume" : "Pause") { isPaused.toggle(); lastTick = .now }
    }
    .onChange(of: currentIndex) { _, index in
      guard stories.indices.contains(index), let lead = stories[index].lead else { return }
      AccessibilityNotification.Announcement("Story \(index + 1) of \(stories.count). \(lead.title)").post()
    }
    .onAppear {
      if UIAccessibility.isVoiceOverRunning { isPaused = true }
      lastTick = .now
      // Ensure all stories in the deck are preloading immediately
      CatchupImagePreloader.shared.preload(clusters: stories)
      if let first = stories.first {
        pipeline.markRead(first)
      }
    }
    // High-frequency timer driving the 7-second progress bar smoothly
    .onReceive(Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()) { now in
      guard !isPaused, !stories.isEmpty else {
        lastTick = now
        return
      }
      let dt = min(now.timeIntervalSince(lastTick), 0.1)
      lastTick = now
      elapsed += dt
      if elapsed >= Self.slideDuration {
        nextSlide()
      }
    }
  }

  private func nextSlide() {
    elapsed = 0
    lastTick = .now
    if currentIndex < stories.count - 1 {
      currentIndex += 1
      pipeline.markRead(stories[currentIndex])
    } else {
      dismiss()
    }
  }

  private func previousSlide() {
    if elapsed > 1.2 || currentIndex == 0 {
      elapsed = 0
      lastTick = .now
    } else {
      elapsed = 0
      lastTick = .now
      currentIndex -= 1
      pipeline.markRead(stories[currentIndex])
    }
  }

  private func progress(for index: Int) -> CGFloat {
    if index < currentIndex { return 1.0 }
    if index > currentIndex { return 0.0 }
    return CGFloat(min(max(elapsed / Self.slideDuration, 0), 1))
  }

  private var topOverlayBar: some View {
    VStack(spacing: 12) {
      // Segmented 7-second animated progress bars across the top
      HStack(spacing: 5) {
        ForEach(stories.indices, id: \.self) { idx in
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.28))
              Capsule()
                .fill(Color.white)
                .frame(width: geo.size.width * progress(for: idx))
            }
          }
          .frame(height: 3.5)
        }
      }

      HStack {
        // Nothing-style Monospace + Counter pill
        HStack(spacing: 8) {
          Text("DAILY CATCHUP")
            .font(.caption.monospaced())
            .foregroundStyle(.white)
          Text("\(min(currentIndex + 1, max(stories.count, 1)))/\(stories.count)")
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())

        Spacer()

        Button("Close", systemImage: "xmark") { dismiss() }
          .buttonStyle(RoundIconButtonStyle(foreground: .white, background: AnyShapeStyle(.ultraThinMaterial)))
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
  }
}

/// A single full-screen story slide with left/right tap zones and hold-to-pause.
private struct CatchupCardPage: View {
  let cluster: StoryCluster
  var onTapLeft: () -> Void
  var onTapRight: () -> Void
  var onPressingChanged: (Bool) -> Void
  var onOpenFullStory: () -> Void

  @Environment(\.openURL) private var openURL

  private var lead: ArticleItem? {
    cluster.lead ?? sortedArticles.first
  }

  /// Deterministically sorted articles so SwiftData's unordered backing set never shuffles outlet pills.
  private var sortedArticles: [ArticleItem] {
    cluster.articles.sorted {
      if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
      if $0.outlet != $1.outlet { return $0.outlet < $1.outlet }
      return $0.url < $1.url
    }
  }

  private var outlets: [ArticleItem] {
    var seen = Set<String>()
    var result: [ArticleItem] = []
    if let lead, seen.insert(lead.outlet).inserted {
      result.append(lead)
    }
    for article in sortedArticles where seen.insert(article.outlet).inserted {
      result.append(article)
    }
    return result
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottomLeading) {
        // 1. Preloaded Full-bleed Hero Image Backdrop (or flat black + animated Newnew dot logo)
        CatchupBackdropImage(cluster: cluster, size: geo.size)

        // 2. Editorial Legibility Gradient
        LinearGradient(
          stops: [
            .init(color: .black.opacity(0.40), location: 0.0),
            .init(color: .clear, location: 0.25),
            .init(color: .black.opacity(0.55), location: 0.55),
            .init(color: .black.opacity(0.94), location: 0.85),
            .init(color: .black, location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)

        // 3. Invisible Left (35%) & Right (65%) Story Tap Zones + Hold to Pause
        HStack(spacing: 0) {
          Color.clear
            .frame(width: geo.size.width * 0.35)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapLeft)
            .onLongPressGesture(minimumDuration: 10, pressing: onPressingChanged, perform: {})

          Color.clear
            .frame(width: geo.size.width * 0.65)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapRight)
            .onLongPressGesture(minimumDuration: 10, pressing: onPressingChanged, perform: {})
        }
        .ignoresSafeArea()

        // 4. Foreground Story Snapshot Content (Animations disabled so pills never shuffle or drift)
        VStack(alignment: .leading, spacing: 14) {
          Spacer()

          // Pillar + Freshness + Source Count
          HStack(spacing: 8) {
            Text(cluster.pillar.title.uppercased())
              .font(.caption.monospaced())
              .padding(.horizontal, 10)
              .pillHeight()
              .background(.white.opacity(0.18), in: Capsule())
              .foregroundStyle(.white)

            Text(NewsTop.age(cluster.updatedAt))
              .font(.caption.monospaced())
              .foregroundStyle(.white.opacity(0.75))

            Spacer()

            Text("\(outlets.count) \(outlets.count == 1 ? "SOURCE" : "SOURCES")")
              .font(.caption.monospaced())
              .padding(.horizontal, 10)
              .pillHeight()
              .background(.white, in: Capsule())
              .foregroundStyle(.black)
          }
          .allowsHitTesting(false)

          // Big Editorial Headline
          if let lead {
            Text(lead.title)
              .font(Swiss.headline(34, relativeTo: .title))
              .foregroundStyle(.white)
              .lineLimit(4)
              .fixedSize(horizontal: false, vertical: true)
              .allowsHitTesting(false)
          }

          // Tap-to-open Outlet Pills (Locked order & zero animation)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(outlets.prefix(5), id: \.outlet) { article in
                Button {
                  if let url = URL(string: article.url) {
                    openURL(url)
                  }
                } label: {
                  HStack(spacing: 4) {
                    Text(article.outlet)
                    Image(systemName: "arrow.up.right").imageScale(.small)
                  }
                  .font(.caption.weight(.medium))
                  .padding(.horizontal, 10)
                  .pillHeight()
                  .background(.white.opacity(0.14), in: Capsule())
                  .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
              }
            }
          }

          // Bottom Action Row: Dive into full coverage
          HStack(spacing: 12) {
            // The app's primary pill; the reel is dark, so it shows white with black text.
            Button(action: onOpenFullStory) {
              HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Full coverage & brief")
                Image(systemName: "arrow.right")
              }
            }
            .buttonStyle(.swissPrimary)

            Spacer()
          }
          .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 42)
        .transaction { $0.animation = nil }
      }
    }
  }
}

/// Renders the preloaded hero image immediately from `CatchupImagePreloader.shared` on Frame 1,
/// or a flat black screen with the rolling dot-matrix `NEW / NEW` logo animation while loading.
private struct CatchupBackdropImage: View {
  let cluster: StoryCluster
  let size: CGSize

  @State private var uiImage: UIImage?

  init(cluster: StoryCluster, size: CGSize) {
    self.cluster = cluster
    self.size = size
    _uiImage = State(initialValue: CatchupImagePreloader.shared.cachedImage(for: cluster.id))
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black
      // The publisher's picture as a framed card in the upper part of the slide, never full
      // screen: a preview that links to the article, not a reproduction of the photo.
      if let uiImage {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFill()
          .frame(width: size.width - 40, height: min((size.width - 40) * 0.75, size.height * 0.38))
          .clipShape(RoundedRectangle(cornerRadius: Swiss.tileRadius, style: .continuous))
          .padding(.top, 120)
          .transition(.opacity)
      } else {
        CatchupFlatBlackLogoFallback()
      }
    }
    .frame(width: size.width, height: size.height)
    .task(id: cluster.id) {
      if uiImage == nil {
        uiImage = await CatchupImagePreloader.shared.load(for: cluster).value
      }
    }
  }
}

/// Flat black backdrop with the rolling dot-matrix "NEW / NEW" logo animation from PullToRefresh / DotMatrix.
private struct CatchupFlatBlackLogoFallback: View {
  @State private var pulse = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      VStack(spacing: 8) {
        DotText("NEW", pitch: 3.2, motion: .roll, rollsIn: true)
        DotText("NEW", pitch: 3.2, motion: .roll, rollsIn: true)
      }
      .foregroundStyle(.white.opacity(pulse ? 0.32 : 0.16))
      .offset(y: -48)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
          pulse = true
        }
      }
    }
  }
}
