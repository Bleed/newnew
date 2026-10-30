import SwiftUI

/// A story covered by several outlets: a grey tile with the lead picture, the headline, the
/// outlets as quiet pills and the source count in the dot face.
struct StoryCard: View {
  let cluster: StoryCluster

  var body: some View {
    if let lead = cluster.lead {
      let extract = lead.shortSnippet
      VStack(alignment: .leading, spacing: 12) {
        picture(lead)
        HStack(alignment: .center, spacing: 8) {
          meta(lead)
          Spacer(minLength: 6)
          signal
          DotChip("\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "SOURCE" : "SOURCES")")
        }
        Text(lead.title)
          .font(Swiss.headline(24, relativeTo: .title3))
          .foregroundStyle(isSettled ? Swiss.muted : Swiss.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if !extract.isEmpty {
          Text(extract)
            .font(.subheadline)
            .foregroundStyle(Swiss.muted)
            .lineLimit(2)
        }
        OutletPills(outlets: cluster.outlets)
        MediaPills(episode: cluster.episode, video: cluster.video)
      }
      .padding(14)
      .padding(.bottom, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
      .contentShape(RoundedRectangle(cornerRadius: Swiss.tileRadius, style: .continuous))
      // One element for VoiceOver: the headline first, then what the card shows around it.
      // Watch and Listen stay reachable as actions.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(StoryAccessibility.label(cluster, lead: lead, signal: signalText))
      .storyMediaActions(cluster)
    }
  }

  /// The signal pill's words, for VoiceOver.
  var signalText: String? {
    if case .updated(let count, _) = ReadLedger.status(for: cluster) { return "\(count) new" }
    if cluster.newSinceRead > 0 { return "\(cluster.newSinceRead) new" }
    if case .unread = ReadLedger.status(for: cluster), isDeveloping { return "developing" }
    return nil
  }

  /// Single social-preview image (`og:image` / RSS enclosure) linking to the lead article.
  @ViewBuilder func picture(_ lead: ArticleItem) -> some View {
    let portrait = cluster.pillar.isPortrait
    let aspect: CGFloat = portrait ? 4 / 5 : 5 / 4
    HeroImage(
      remote: lead.imageURL,
      article: lead.url,
      aspect: aspect,
      fits: lead.isChart,
      isVideo: lead.videoID != nil,
      topAligned: portrait
    )
  }

  /// Two or more outlets in the last half hour. Kept rare, so it means something.
  var isDeveloping: Bool {
    cluster.articles.filter { Date.now.timeIntervalSince($0.publishedAt) < 30 * 60 }.count >= 2
  }

  /// Read, and nothing new since.
  var isSettled: Bool {
    if case .settledRead = ReadLedger.status(for: cluster) { return true }
    return false
  }

  func meta(_ lead: ArticleItem) -> some View {
    HStack(spacing: 6) {
      // A followed story says which topic brought it up, in ink; others their section.
      if let topic = cluster.followedBy {
        Text(topic).font(.footnote.weight(.medium)).foregroundStyle(Swiss.ink)
      } else if let category = lead.category {
        Text(category).font(.footnote.weight(.medium))
      }
      Text(cluster.updatedAt.shortAgo).font(Swiss.smallFigure)
    }
    .foregroundStyle(Swiss.muted)
    .lineLimit(1)
  }

  @ViewBuilder var signal: some View {
    if case .updated(let count, _) = ReadLedger.status(for: cluster) {
      SignalBadge(.attention, "\(count) new")
    } else if cluster.newSinceRead > 0 {
      SignalBadge(.attention, "\(cluster.newSinceRead) new")
    } else if case .unread = ReadLedger.status(for: cluster), isDeveloping {
      SignalBadge(.attention, "Developing")
    }
  }
}

/// The outlets, newest first, as quiet pills; past four, a count.
struct OutletPills: View {
  let outlets: [String]
  var limit = 4

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(outlets.prefix(limit), id: \.self) { QuietPill($0) }
      if outlets.count > limit { QuietPill("+\(outlets.count - limit)") }
    }
    .foregroundStyle(Swiss.ink)
  }
}

/// A story only one outlet has: a compact row.
struct BriefRow: View {
  let cluster: StoryCluster

  private var isSettled: Bool {
    if case .settledRead = ReadLedger.status(for: cluster) { return true }
    return false
  }

  var body: some View {
    if let lead = cluster.lead {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(lead.outlet).font(.footnote.weight(.medium))
            Text(lead.publishedAt.shortAgo).font(Swiss.smallFigure)
          }
          .foregroundStyle(Swiss.muted)
          .lineLimit(1)
          Text(lead.title)
            .font(Swiss.headline(20, relativeTo: .body))
            .foregroundStyle(isSettled ? Swiss.muted : Swiss.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          MediaPills(episode: cluster.episode, video: nil)
        }
        Spacer(minLength: 0)
        if lead.imageURL != nil {
          HeroImage(
            remote: lead.imageURL, article: lead.url, height: 64, width: 64, radius: 10, fits: lead.isChart,
            isVideo: lead.videoID != nil, topAligned: cluster.pillar.isPortrait)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain, radius: 16)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(StoryAccessibility.label(cluster, lead: lead, signal: nil, outlet: lead.outlet))
      .storyMediaActions(cluster)
    }
  }
}

/// What VoiceOver reads for a story in a list: "Ukraine says at least 13 killed…. World, 42
/// minutes ago, 10 sources, developing, read."
enum StoryAccessibility {
  static func label(_ cluster: StoryCluster, lead: ArticleItem, signal: String?, outlet: String? = nil) -> String {
    var parts: [String] = []
    if let topic = cluster.followedBy { parts.append(topic) } else if let outlet { parts.append(outlet) } else if let category = lead.category { parts.append(category) }
    parts.append(cluster.updatedAt.formatted(.relative(presentation: .named)))
    if outlet == nil {
      let count = cluster.outlets.count
      parts.append("\(count) \(count == 1 ? "source" : "sources")")
    }
    if let signal { parts.append(signal) }
    if case .settledRead = ReadLedger.status(for: cluster) { parts.append("read") }
    return "\(lead.title). " + parts.joined(separator: ", ")
  }
}

extension View {
  /// Watch (opens YouTube) and Listen / Pause (plays here) as VoiceOver actions on a story.
  func storyMediaActions(_ cluster: StoryCluster) -> some View { modifier(StoryMediaActions(cluster: cluster)) }
}

private struct StoryMediaActions: ViewModifier {
  let cluster: StoryCluster
  var player = AudioPlayer.shared
  @Environment(\.openURL) var openURL

  func body(content: Content) -> some View {
    let episode = cluster.episode
    let playing = episode.map { player.isPlaying($0.audioURL ?? "") } ?? false
    content
      .accessibilityActions {
        if let video = cluster.video, let url = video.videoURL {
          Button("Watch on \(video.outlet)") { openURL(url) }
        }
        if let episode {
          Button(playing ? "Pause \(episode.outlet)" : "Listen to \(episode.outlet)") { player.toggle(episode) }
        }
      }
  }
}

/// "Listen · 15 min" for a podcast episode in the story (played here), "Watch · Reuters" for a
/// video (opens YouTube). Quiet pills, the same height as the signal and sources pills.
struct MediaPills: View {
  let episode: ArticleItem?
  let video: ArticleItem?
  @Environment(\.openURL) var openURL

  var body: some View {
    if episode != nil || video != nil {
      HStack(spacing: 6) {
        if let episode { ListenPill(episode: episode) }
        if let video, let url = video.videoURL {
          Button { openURL(url) } label: {
            Label("Watch · \(video.outlet)", systemImage: "play.rectangle.fill")
          }
          .buttonStyle(MediaPillStyle())
          .accessibilityHint("Opens the video on YouTube")
        }
      }
    }
  }
}

struct ListenPill: View {
  let episode: ArticleItem
  var player = AudioPlayer.shared

  var minutes: String {
    episode.audioSeconds.map { " · \(max(1, Int((Double($0) / 60).rounded()))) min" } ?? ""
  }

  var body: some View {
    let playing = player.isPlaying(episode.audioURL ?? "")
    Button { player.toggle(episode) } label: {
      Label(playing ? "Pause\(minutes)" : "Listen\(minutes)", systemImage: playing ? "pause.fill" : "play.fill")
    }
    .buttonStyle(MediaPillStyle())
    .accessibilityLabel(playing ? "Pause \(episode.outlet)" : "Listen to \(episode.outlet)\(minutes)")
  }
}

/// A quiet pill with a glyph, sized like the other pills on a card.
struct MediaPillStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(MediaLabelStyle())
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 10)
      .pillHeight()
      .foregroundStyle(Swiss.ink)
      .background(Swiss.ink.opacity(0.07), in: Capsule())
      .opacity(configuration.isPressed ? 0.6 : 1)
      .contentShape(Capsule())
      .fixedSize()
  }
}

private struct MediaLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}
