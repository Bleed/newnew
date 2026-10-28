import SwiftData
import SwiftUI

/// Topics you follow (raised to the top of the feed) and topics you mute (hidden), plus
/// feed time-window, alert settings, and publisher/privacy disclosures.
struct TopicsSheet: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.dismiss) var dismiss
  @Query(sort: \SemanticTopic.createdAt, order: .reverse) var topics: [SemanticTopic]
  @Query var clusters: [StoryCluster]
  @State var kind: TopicKind
  @State private var phrase = ""
  @State private var isAdding = false
  @FocusState private var fieldFocused: Bool

  init(kind: TopicKind = .follow) {
    _kind = State(initialValue: kind)
  }

  static let suggestions: [TopicKind: [String]] = [
    .follow: ["Climate", "Artificial intelligence", "Space", "Design", "Formula 1", "Architecture"],
    .mute: ["Celebrity gossip", "Football transfers", "Crypto", "Royal family", "Reality TV", "Horoscopes"],
  ]

  var shown: [SemanticTopic] { topics.filter { $0.kind == kind } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          // One line, one colour: what this sheet is for.
          Text("Follow and mute topics")
            .font(.system(size: 30, weight: .regular))
            .tracking(-0.6)
            .foregroundStyle(Swiss.ink)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 4)

          Picker("Topics", selection: $kind.animation(.snappy(duration: 0.2))) {
            Text("Following").tag(TopicKind.follow)
            Text("Muted").tag(TopicKind.mute)
          }
          .pickerStyle(.segmented)
          .labelsHidden()

          field

          let unused = (Self.suggestions[kind] ?? []).filter { s in !topics.contains { $0.phrase.caseInsensitiveCompare(s) == .orderedSame } }
          if !unused.isEmpty {
            FlowLayout(spacing: 8) {
              ForEach(unused, id: \.self) { suggestion in
                Button {
                  Task { await add(suggestion) }
                } label: {
                  Label(suggestion, systemImage: "plus")
                }
                .buttonStyle(.swissSecondary)
                .disabled(isAdding)
              }
            }
          }

          if !shown.isEmpty {
            Eyebrow(kind == .follow ? "Following" : "Hidden now").padding(.top, 10)
            ForEach(shown) { topic in
              TopicRow(topic: topic, matches: matchCount(topic)) {
                withAnimation(.snappy) { pipeline.remove(topic) }
              }
            }
          }

          FeedWindowSettings().padding(.top, 10)

          AlertSettings().padding(.top, 10)

          Text(explanation)
            .font(.footnote)
            .foregroundStyle(Swiss.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)

          LegalFooterSection().padding(.top, 12)
        }
        .padding(.horizontal, Swiss.pageInset)
        .padding(.bottom, 32)
      }
      .swissCanvas()
      .swissNavigationTitle("Topics")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
    }
    .tint(Swiss.ink)
  }

  var field: some View {
    HStack(spacing: 10) {
      TextField(kind == .follow ? "A topic, like “electric cars”" : "A topic, like “election polls”", text: $phrase)
        .font(.body)
        .focused($fieldFocused)
        .submitLabel(.done)
        .onSubmit { Task { await add(phrase) } }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Swiss.tile, in: Capsule())
      if isAdding {
        DotChip("LEARNING", label: "Learning the topic")
      } else {
        Button(kind == .follow ? "Follow" : "Mute") { Task { await add(phrase) } }
          .buttonStyle(.swissPrimary)
          .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  func matchCount(_ topic: SemanticTopic) -> Int {
    clusters.filter { (topic.kind == .follow ? $0.followedBy : $0.mutedBy) == topic.phrase }.count
  }

  var explanation: String {
    let effect = kind == .follow ? "raised to the top of Today" : "hidden"
    let action = kind == .follow ? "follow" : "mute"
    return IntelligenceService.isAvailable
      ? "Each topic is turned into a few example headlines and telling words on this iPhone. Stories that use those words and read like the examples are \(effect). Long-press a story to \(action) stories like it."
      : "\(IntelligenceService.unavailableReason), so topics match stories that use their own words. Long-press a story to \(action) stories like it."
  }

  func add(_ text: String) async {
    guard !isAdding else { return }
    isAdding = true
    await pipeline.addTopic(text, kind: kind)
    isAdding = false
    phrase = ""
    fieldFocused = false
  }
}

struct TopicRow: View {
  let topic: SemanticTopic
  let matches: Int
  var remove: () -> Void

  var summary: String {
    switch (topic.kind, matches) {
    case (.follow, 0): "Nothing today yet"
    case (.follow, _): "\(matches) \(matches == 1 ? "story" : "stories") today"
    case (.mute, 0): "Nothing hidden today"
    case (.mute, _): "Hides \(matches) \(matches == 1 ? "story" : "stories")"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(topic.phrase).font(.body.weight(.medium)).lineLimit(2)
        Text(summary)
          .font(.footnote)
          .tileSecondary()
        if !topic.keywords.isEmpty {
          Text(topic.keywords.joined(separator: " · "))
            .font(.caption)
            .tileSecondary()
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      Button("Remove \(topic.phrase)", systemImage: "xmark", action: remove)
        .labelStyle(.iconOnly)
        .font(.footnote.weight(.semibold))
        .frame(width: 30, height: 30)
        .background(Swiss.ink.opacity(0.07), in: Circle())
        .buttonStyle(.plain)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tile(.plain, radius: 16)
  }
}

/// Edition window setting: how far back news is served in the feed (12h, 24h default, 48h, or 72h).
struct FeedWindowSettings: View {
  @AppStorage("newsWindowHours") private var newsWindowHours: Int = NewsWindow.h24.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Edition window")
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("News time span").font(.body.weight(.medium))
          Text("How far back stories are shown in Today. Weekly charts stay for two weeks.")
            .font(.footnote)
            .tileSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
          ForEach(NewsWindow.allCases) { option in
            let isSelected = newsWindowHours == option.rawValue
            Button {
              withAnimation(.snappy(duration: 0.2)) {
                newsWindowHours = option.rawValue
              }
            } label: {
              Text(option.shortLabel)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(Swiss.ink)
                .background(isSelected ? Color.clear : Swiss.ink.opacity(0.07), in: Capsule())
                .overlay {
                  if isSelected {
                    Capsule().strokeBorder(Swiss.ink, lineWidth: 1.5)
                  }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.menuLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
          }
        }
      }
      .padding(14)
      .tile(.plain, radius: 16)
    }
  }
}

/// Alerts: breaking news and new stories on followed topics. Both off until switched on; the
/// first one switched on asks for permission.
struct AlertSettings: View {
  @AppStorage(Alerts.breakingKey) var breaking = false
  @AppStorage(Alerts.followingKey) var following = false
  @AppStorage(Alerts.pushStatusKey) var pushStatus: String?
  @State private var denied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Alerts")
      row("Breaking news", detail: "A story five or more outlets are covering within the hour. A few a day at most.", isOn: $breaking)
      if breaking, let pushStatus, !pushStatus.hasPrefix("on:") {
        // Why push isn't working, in CloudKit's words; selectable so it can be copied.
        Text(pushStatus)
          .font(.footnote)
          .foregroundStyle(Swiss.alert)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      row("Topics you follow", detail: "A new story on something you follow. Decided on this iPhone; your topics never leave it.", isOn: $following)
      if denied {
        Text("Notifications are off for newnew. Turn them on in Settings › Notifications.")
          .font(.footnote)
          .foregroundStyle(Swiss.alert)
      }
    }
  }

  func row(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { on in
      isOn.wrappedValue = on
      Task { await apply(on, isOn: isOn) }
    })) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.footnote).tileSecondary().fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.swiss)
    .padding(14)
    .tile(.plain, radius: 16)
  }

  func apply(_ on: Bool, isOn: Binding<Bool>) async {
    if on, !(await Alerts.requestPermission()) {
      isOn.wrappedValue = false
      denied = true
      return
    }
    denied = false
    Alerts.scheduleRefresh()
    await Alerts.updateSubscriptions()
  }
}

/// Publisher attribution, on-device privacy disclosure, and RSS opt-out notice.
struct LegalFooterSection: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow("Publishers & privacy")
      VStack(alignment: .leading, spacing: 8) {
        Text("newnew indexes public RSS feeds, displays headlines and very short extracts (EU DSM Directive Art. 15), and links directly to each publisher's website. All headlines, preview images, and trademarks belong to their respective publishers.")
          .font(.caption)
          .tileSecondary()
          .fixedSize(horizontal: false, vertical: true)

        Text("Your followed topics, muted topics, reading history, and Apple Intelligence summaries are computed locally on this iPhone and never leave your device.")
          .font(.caption)
          .tileSecondary()
          .fixedSize(horizontal: false, vertical: true)

        Button {
          if let url = URL(string: "mailto:publishers@newnew.news?subject=Publisher%20RSS%20Inquiry") {
            openURL(url)
          }
        } label: {
          HStack(spacing: 4) {
            Text("Publisher inquiry or feed opt-out")
            Image(systemName: "arrow.up.right")
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(Swiss.ink)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain, radius: 16)
    }
  }
}
