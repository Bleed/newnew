import SwiftUI

/// One story: its coverage compared (on a tap, by Apple Intelligence), then every outlet's
/// headline linking out to the publisher.
struct StoryDetailView: View {
  let cluster: StoryCluster
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.openURL) var openURL
  @State private var isWriting = false
  @State private var failure: String?
  @ScaledMetric(relativeTo: .title) var headlineSize: CGFloat = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let lead = cluster.lead {
          HeroImage(remote: lead.imageURL, article: lead.url, height: 220, radius: 20)
          HStack(spacing: 8) {
            if let category = lead.category { Text(category).font(.footnote.weight(.medium)) }
            Text("Updated \(Text(cluster.updatedAt.shortAgo).font(Swiss.smallFigure)) ago").font(.footnote)
            Spacer(minLength: 6)
            DotChip("\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "SOURCE" : "SOURCES")")
          }
          .foregroundStyle(Swiss.muted)
          Text(lead.title)
            .font(.system(size: headlineSize, weight: .regular))
            .tracking(-headlineSize * 0.02)
            .foregroundStyle(Swiss.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }

        if cluster.outlets.count > 1 { perspective.padding(.top, 6) }

        Eyebrow("Coverage").padding(.top, 14)
        ForEach(cluster.sortedArticles) { article in
          ArticleRow(article: article) {
            if let url = URL(string: article.url) { openURL(url) }
          }
        }
        Text("Headlines and snippets from each outlet. Tap one to read it in full on their site.")
          .font(.footnote)
          .foregroundStyle(Swiss.muted)
          .padding(.top, 4)
      }
      .padding(.horizontal, Swiss.pageInset)
      .padding(.bottom, 32)
    }
    .swissCanvas()
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis") {
          Button("Mute stories like this", systemImage: "speaker.slash") {
            Task { await pipeline.muteStoriesLike(cluster) }
          }
        }
      }
    }
    .onAppear { pipeline.markRead(cluster) }
  }

  // MARK: Perspective

  @ViewBuilder var perspective: some View {
    if let brief = cluster.brief {
      BriefPanel(brief: brief, newSources: max(cluster.articles.count - brief.sourceCount, 0)) {
        Task { await write() }
      }
      .opacity(isWriting ? 0.5 : 1)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("See how \(cluster.outlets.count) outlets tell this story: what they agree on, and where they differ.")
          .font(.subheadline)
          .foregroundStyle(Swiss.muted)
        HStack(spacing: 10) {
          Button {
            Task { await write() }
          } label: {
            Label("Compare coverage", systemImage: "square.split.2x1")
          }
          .buttonStyle(.swissPrimary)
          .disabled(isWriting)
          if isWriting { WritingChip() }
        }
        if let failure {
          Text(failure).font(.footnote).foregroundStyle(Swiss.alert)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
    }
  }

  func write() async {
    guard !isWriting else { return }
    isWriting = true
    failure = nil
    defer { isWriting = false }
    let sources = cluster.sortedArticles.map {
      IntelligenceService.Source(outlet: $0.outlet, title: $0.title, snippet: $0.snippet)
    }
    do {
      let brief = try await IntelligenceService.brief(for: sources)
      withAnimation(.snappy) { pipeline.saveBrief(brief, for: cluster) }
    } catch {
      failure = "Couldn't compare the coverage: \(error.localizedDescription)"
    }
  }
}

/// "READING" in the dot face while the model writes, the dots after it counting up.
struct WritingChip: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.4)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
      DotChip("READING" + String(repeating: ".", count: step) + String(repeating: " ", count: 3 - step), label: "Reading the coverage")
    }
  }
}

/// The comparison, in one tile: the summary, what outlets agree on, where they differ and each
/// outlet's angle.
struct BriefPanel: View {
  let brief: ClusterPerspectiveBrief
  var newSources: Int
  var refresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Eyebrow(brief.isGenerated ? "How it's covered" : "Preview")
        Spacer()
        if newSources > 0 {
          Button(action: refresh) { SignalBadge(.attention, "\(newSources) new · Update") }
            .buttonStyle(.plain)
        }
      }
      if !brief.summary.isEmpty {
        Text(brief.summary).font(.body).fixedSize(horizontal: false, vertical: true)
      }
      if !brief.sharedFacts.isEmpty {
        section("They agree", brief.sharedFacts, mark: Swiss.mint)
      }
      if !brief.differences.isEmpty {
        section("They differ", brief.differences, mark: Swiss.orange)
      }
      if !brief.angles.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Eyebrow("Each outlet's angle")
          ForEach(brief.angles, id: \.self) { angle in
            VStack(alignment: .leading, spacing: 2) {
              Text(angle.outlet).font(.footnote.weight(.medium)).tileSecondary()
              Text(angle.focus).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      Text(footnote)
        .font(.caption)
        .tileSecondary()
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
  }

  var footnote: String {
    brief.isGenerated
      ? "Written on this iPhone by Apple Intelligence from \(brief.sourceCount) headlines and snippets. It can be wrong; the full stories are at each outlet."
      : "\(IntelligenceService.unavailableReason), so this preview just lists each outlet's headline."
  }

  func section(_ title: String, _ lines: [String], mark: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(title)
      ForEach(lines, id: \.self) { line in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Circle().fill(mark).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
          Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// One outlet's take: its name and time, headline and snippet, and a way out to read it.
struct ArticleRow: View {
  let article: ArticleItem
  var open: () -> Void

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(article.outlet).font(.footnote.weight(.medium)).foregroundStyle(Swiss.ink)
          Text(article.publishedAt.shortAgo).font(Swiss.smallFigure).foregroundStyle(Swiss.muted)
          Spacer(minLength: 6)
          Image(systemName: "arrow.up.right").font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted)
        }
        Text(article.title)
          .font(.body)
          .foregroundStyle(Swiss.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Text(article.snippet)
          .font(.footnote)
          .foregroundStyle(Swiss.muted)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain, radius: 16)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens \(article.outlet) in Safari")
  }
}
