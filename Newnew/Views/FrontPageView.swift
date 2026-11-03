import SwiftUI

/// Today on iPad & unfolded Duo: a broadsheet front page with lazy waterfall columns from the
/// very top so cards of different heights pack without row-by-row gaps and scroll at 120Hz.
struct FrontPageView<Top: View, Bar: View>: View {
  let wide: [StoryCluster]
  let brief: [StoryCluster]
  var open: (StoryCluster) -> Void
  @ViewBuilder var top: Top
  @ViewBuilder var bar: Bar

  static var inset: CGFloat { 40 }
  static var gap: CGFloat { 20 }

  var body: some View {
    GeometryReader { geo in
      let inset = geo.size.width >= 900 ? Self.inset : 24
      let width = max(geo.size.width - 2 * inset, 320)
      let columnCount = width >= 920 ? 3 : 2
      let totalGaps = Self.gap * CGFloat(columnCount - 1)
      let columnWidth = (width - totalGaps) / CGFloat(columnCount)
      let twoColumnsWidth = columnWidth * 2 + Self.gap

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          top
            .frame(width: twoColumnsWidth, alignment: .leading)
            .padding(.top, 12)

          bar

          waterfallColumns(count: columnCount)
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 40)
      }
    }
  }

  /// Distributes stories from the very top across `count` independent `LazyVStack` columns.
  /// If `brief` has stories, the `In brief` module sits at the top of the rightmost column,
  /// and regular story cards flow underneath it once the other columns catch up in height.
  /// If `brief` is empty, all columns start with regular story cards from the very top.
  @ViewBuilder
  private func waterfallColumns(count: Int) -> some View {
    let hasBrief = !brief.isEmpty
    let briefBox = hasBrief ? Array(brief.prefix(8)) : []
    let pool = wide + (hasBrief ? Array(brief.dropFirst(8)) : [])
    let buckets = Self.distribute(pool, columns: count, briefCount: briefBox.count)

    HStack(alignment: .top, spacing: Self.gap) {
      ForEach(0..<count, id: \.self) { col in
        LazyVStack(alignment: .leading, spacing: Self.gap) {
          if hasBrief && col == count - 1 {
            inBrief(briefBox)
          }
          ForEach(buckets[col]) { story in
            card(story)
          }
        }
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
  }

  /// Assigns each story to the shortest column using a fast intrinsic height estimate so
  /// `LazyVStack` never has to instantiate off-screen views to know which column they belong in.
  private static func distribute(_ stories: [StoryCluster], columns: Int, briefCount: Int) -> [[StoryCluster]] {
    let count = max(columns, 1)
    var result = Array(repeating: [StoryCluster](), count: count)
    var heights = Array(repeating: CGFloat(0), count: count)

    if briefCount > 0 {
      // Reserve estimated height for the `In brief` tile at the top of the last column
      heights[count - 1] = 64 + CGFloat(briefCount) * 68
    }

    for story in stories {
      let shortest = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
      result[shortest].append(story)
      heights[shortest] += estimatedHeight(for: story) + gap
    }
    return result
  }

  private static func estimatedHeight(for cluster: StoryCluster) -> CGFloat {
    guard let lead = cluster.lead else { return 180 }
    var h: CGFloat = 110
    if lead.imageURL != nil {
      h += cluster.pillar.isPortrait ? 310 : 210
    }
    h += CGFloat(min(max((lead.title.count + 27) / 28, 1), 4)) * 28
    if !lead.shortSnippet.isEmpty {
      h += 38
    }
    if cluster.episode != nil || cluster.video != nil {
      h += 32
    }
    return h
  }

  func card(_ story: StoryCluster) -> some View {
    Button { open(story) } label: { StoryCard(cluster: story) }
      .buttonStyle(.plain)
  }

  /// A column of headlines: where it's from, how old, the headline in the serif.
  func inBrief(_ stories: [StoryCluster]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Eyebrow("In brief")
      ForEach(stories) { story in
        if let lead = story.lead {
          let settled: Bool = {
            if case .settledRead = ReadLedger.status(for: story) { return true }
            return story.readAt != nil
          }()
          Button { open(story) } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text("\(lead.category ?? lead.pillar.title) · \(story.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))")
                .font(.footnote)
                .foregroundStyle(Swiss.muted)
              Text(lead.title)
                .font(Swiss.headline(19, relativeTo: .body))
                .foregroundStyle(settled ? Swiss.muted : Swiss.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
  }
}
