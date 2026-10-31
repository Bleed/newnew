import SwiftUI

/// Today in zen mode (Figma: Zen mode): the edition's cover, then its stories one at a time,
/// then "You're caught up" until the next edition. No feed, no counts, nothing to scroll.
struct EditionView: View {
  let clusters: [StoryCluster]
  var open: (StoryCluster) -> Void
  var showEverything: () -> Void
  @Environment(FeedSyncPipeline.self) var pipeline
  var edition = Edition.shared

  var stories: [StoryCluster] {
    let byID = Dictionary(clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return (edition.current?.ids ?? []).compactMap { byID[$0] }
  }

  var body: some View {
    let stories = stories
    Group {
      if let current = edition.current, current.finished != nil || (!stories.isEmpty && current.position >= stories.count) {
        EditionEnd(stories: stories, current: current, showEverything: showEverything)
      } else if let current = edition.current, current.reading, !stories.isEmpty {
        EditionReader(stories: stories, position: min(current.position, stories.count - 1), back: Set(current.back), open: open)
      } else {
        EditionCover(stories: stories, current: edition.current, showEverything: showEverything)
      }
    }
    .animation(.snappy(duration: 0.3), value: edition.current?.position)
    .animation(.snappy(duration: 0.3), value: edition.current?.reading)
    .onAppear { edition.refresh(from: clusters, syncing: pipeline.isSyncing) }
    .onChange(of: pipeline.isSyncing) { edition.refresh(from: clusters, syncing: pipeline.isSyncing) }
    .onChange(of: clusters.count) { edition.refresh(from: clusters, syncing: pipeline.isSyncing) }
  }
}

/// "Ten stories, then you're done." with the first four listed.
struct EditionCover: View {
  let stories: [StoryCluster]
  let current: Edition.Stored?
  var showEverything: () -> Void
  var edition = Edition.shared

  var outlets: Int { Set(stories.flatMap(\.outlets)).count }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        MiniDotBoard(fill: 1, first: true, second: true, pitch: 2)
          .padding(.top, 8)
          .padding(.bottom, 6)
          .accessibilityHidden(true)
        if let current {
          Eyebrow("\(Edition.name(current.slot)) · \(current.slot.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
          if stories.isEmpty {
            OnboardingHeadline("Nothing widely covered yet.", size: 38)
            OnboardingDeck("No story has been covered by enough of your outlets since the last edition. The next one is at \(Edition.next(current.slot).formatted(date: .omitted, time: .shortened)).")
          } else {
            OnboardingHeadline("\(Self.count(stories.count)) \(stories.count == 1 ? "story" : "stories"), then you're done.", size: 38)
            OnboardingDeck("The most covered news since \(Edition.isMorning(current.slot) ? "last night" : "this morning"), from \(outlets) outlets. About \(max(1, stories.count * 70 / 60)) minutes.")
            contents
          }
        } else {
          OnboardingHeadline("Your first edition is being made.", size: 38)
          OnboardingDeck("It's made from what your outlets cover most, once the news has been read.")
        }
        if !stories.isEmpty {
          Button(current?.started == nil ? "Begin reading" : "Go on reading") { edition.begin() }
            .buttonStyle(.swissPrimary)
            .padding(.top, 10)
        }
        Button("Show everything instead", action: showEverything)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Swiss.muted)
          .padding(.top, 4)
      }
      .padding(.horizontal, Swiss.pageInset)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  var contents: some View {
    VStack(alignment: .leading, spacing: 12) {
      Eyebrow("In this edition")
      ForEach(Array(stories.prefix(4).enumerated()), id: \.element.id) { index, story in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("\(index + 1)")
            .font(.footnote.weight(.medium))
            .frame(width: 24, height: 24)
            .background(Swiss.card, in: Circle())
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
          VStack(alignment: .leading, spacing: 2) {
            Text(story.lead?.title ?? "").font(Swiss.headline(18, relativeTo: .body)).foregroundStyle(Swiss.ink)
              .fixedSize(horizontal: false, vertical: true)
            Text(current?.back.contains(story.id) == true ? "Back · \(story.newSinceRead) new since you read it" : "\(story.outlets.count) sources")
              .font(.footnote).foregroundStyle(Swiss.muted)
          }
        }
      }
      if stories.count > 4 {
        Text("and \(Self.count(stories.count - 4).lowercased()) more").font(.footnote).foregroundStyle(Swiss.muted)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain)
  }

  /// "Ten", "Six".
  static func count(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = Locale(identifier: "en")
    let words = formatter.string(from: n as NSNumber) ?? "\(n)"
    return words.prefix(1).uppercased() + words.dropFirst()
  }
}

/// One story at a time: progress, the story's card, Next story and Read.
struct EditionReader: View {
  let stories: [StoryCluster]
  let position: Int
  let back: Set<UUID>
  var open: (StoryCluster) -> Void
  @Environment(FeedSyncPipeline.self) var pipeline
  var edition = Edition.shared

  var story: StoryCluster { stories[position] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        HStack(spacing: 5) {
          ForEach(0..<stories.count, id: \.self) { index in
            Capsule().fill(Swiss.ink.opacity(index <= position ? 1 : 0.15)).frame(width: index == position ? 20 : 7, height: 7)
          }
        }
        .accessibilityHidden(true)
        Spacer()
        DotChip("\(position + 1) OF \(stories.count)", label: "Story \(position + 1) of \(stories.count)")
        Button("Leave the edition", systemImage: "xmark") { edition.pause() }
          .buttonStyle(.roundIcon)
      }
      .padding(.top, 8)
      .padding(.bottom, 14)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if back.contains(story.id) {
            Text("Back · \(story.newSinceRead) new since you read it").font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted)
          }
          Button { open(story) } label: { StoryCard(cluster: story) }
            .buttonStyle(.plain)
        }
        .id(story.id)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
      }
      .scrollIndicators(.hidden)
      HStack(spacing: 10) {
        Button(position + 1 < stories.count ? "Next story" : "Finish") { next() }
          .buttonStyle(.swissPrimary)
        Button("Read") { open(story) }
          .buttonStyle(.swissSecondary)
      }
      .padding(.vertical, 12)
    }
    .padding(.horizontal, Swiss.pageInset)
    // Swipe left for the next story, right for the one before.
    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
      if value.translation.width < -60 { next() } else if value.translation.width > 60 { withAnimation(.snappy) { edition.back() } }
    })
    .accessibilityAction(named: "Next story") { next() }
  }

  func next() {
    pipeline.markRead(story)
    withAnimation(.snappy) { edition.advance() }
  }
}

/// "You're caught up." and when the next edition comes.
struct EditionEnd: View {
  let stories: [StoryCluster]
  let current: Edition.Stored
  var showEverything: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Spacer()
      MiniDotBoard(fill: 1, first: true, second: true, pitch: 7)
        .accessibilityHidden(true)
      OnboardingHeadline("You're caught up.", size: 38)
        .multilineTextAlignment(.center)
      Text(summary)
        .font(.body)
        .foregroundStyle(Swiss.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Show everything instead", action: showEverything)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Swiss.muted)
        .padding(.bottom, 20)
    }
    .padding(.horizontal, Swiss.pageInset)
    .frame(maxWidth: .infinity)
  }

  var summary: String {
    let outlets = Set(stories.flatMap(\.outlets)).count
    let minutes = current.started.map { max(1, Int((current.finished ?? .now).timeIntervalSince($0) / 60)) }
    let next = Edition.next(current.slot).formatted(date: .omitted, time: .shortened)
    let read = minutes.map { ", read in \($0) \($0 == 1 ? "minute" : "minutes")" } ?? ""
    return "\(EditionCover.count(stories.count)) \(stories.count == 1 ? "story" : "stories") from \(outlets) outlets\(read). The next edition is at \(next)."
  }
}

/// Settings › Today: Everything or Edition, the edition's size, and its notification.
struct TodayModeSettings: View {
  @AppStorage(TodayMode.key) private var mode = TodayMode.everything.rawValue
  @AppStorage(Edition.sizeKey) private var size = 10
  @AppStorage(Edition.readyKey) private var ready = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Today")
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("How Today opens").font(.body.weight(.medium))
          Text(mode == TodayMode.edition.rawValue
            ? "An edition of the most covered new stories at 07:00 and 18:00, read one at a time, then nothing to scroll."
            : "Every story, as it comes in.")
            .font(.footnote).tileSecondary().fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          ForEach(TodayMode.allCases) { option in
            let on = mode == option.rawValue
            Button(option.label) { withAnimation(.snappy(duration: 0.2)) { mode = option.rawValue } }
              .buttonStyle(SelectablePillStyle(isOn: on, fillsWidth: true))
              .id(on)
          }
        }
      }
      .padding(14)
      .tile(.plain, radius: 16)
      if mode == TodayMode.edition.rawValue {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Stories at most").font(.body)
            Spacer()
            ForEach(Edition.sizes, id: \.self) { value in
              let on = size == value
              Button("\(value)") { size = value }
                .buttonStyle(SelectablePillStyle(isOn: on, small: true))
                .id(on)
            }
          }
          Toggle(isOn: $ready) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Edition ready").font(.body.weight(.medium))
              Text("A notification at 07:00 and 18:00. Breaking news alerts are off while Today opens as an edition.")
                .font(.footnote).tileSecondary().fixedSize(horizontal: false, vertical: true)
            }
          }
          .toggleStyle(.swiss)
        }
        .padding(14)
        .tile(.plain, radius: 16)
      }
    }
    .onChange(of: ready) { _, on in
      Task {
        if on, !(await Alerts.requestPermission()) { ready = false }
        Edition.scheduleReady()
      }
    }
    .onChange(of: mode) {
      Edition.scheduleReady()
      Task { await Alerts.updateSubscriptions() }
    }
  }
}
