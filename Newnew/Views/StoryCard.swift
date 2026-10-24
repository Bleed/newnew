import SwiftUI

/// A story covered by several outlets: a grey tile with the lead picture, the headline, the
/// outlets as quiet pills and the source count in the dot face.
struct StoryCard: View {
  let cluster: StoryCluster
  @ScaledMetric(relativeTo: .title3) var headlineSize: CGFloat = 21

  var body: some View {
    if let lead = cluster.lead {
      VStack(alignment: .leading, spacing: 12) {
        HeroImage(remote: lead.imageURL, article: lead.url, height: 188)
        HStack(alignment: .center, spacing: 8) {
          meta(lead)
          Spacer(minLength: 6)
          signal
          DotChip("\(cluster.outlets.count) SOURCES")
        }
        Text(lead.title)
          .font(.system(size: headlineSize, weight: .regular))
          .tracking(-headlineSize * 0.01)
          .foregroundStyle(isSettled ? Swiss.muted : Swiss.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Text(lead.snippet)
          .font(.subheadline)
          .foregroundStyle(Swiss.muted)
          .lineLimit(2)
        OutletPills(outlets: cluster.outlets)
      }
      .padding(14)
      .padding(.bottom, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
      .contentShape(RoundedRectangle(cornerRadius: Swiss.tileRadius, style: .continuous))
      .accessibilityElement(children: .combine)
    }
  }

  /// Two or more outlets in the last half hour. Kept rare, so it means something.
  var isDeveloping: Bool {
    cluster.articles.filter { Date.now.timeIntervalSince($0.publishedAt) < 30 * 60 }.count >= 2
  }

  /// Read, and nothing new since.
  var isSettled: Bool { cluster.readAt != nil && cluster.newSinceRead == 0 }

  func meta(_ lead: ArticleItem) -> some View {
    HStack(spacing: 6) {
      if let category = lead.category {
        Text(category).font(.footnote.weight(.medium))
      }
      Text(cluster.updatedAt.shortAgo).font(Swiss.smallFigure)
    }
    .foregroundStyle(Swiss.muted)
    .lineLimit(1)
  }

  @ViewBuilder var signal: some View {
    if cluster.newSinceRead > 0 {
      SignalBadge(.attention, "\(cluster.newSinceRead) new")
    } else if cluster.readAt == nil, isDeveloping {
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
            .font(.body)
            .foregroundStyle(cluster.readAt == nil ? Swiss.ink : Swiss.muted)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if lead.imageURL != nil {
          HeroImage(remote: lead.imageURL, article: lead.url, height: 64, width: 64, radius: 10)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain, radius: 16)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityElement(children: .combine)
    }
  }
}
