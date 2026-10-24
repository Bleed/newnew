import SwiftData
import SwiftUI

/// Topics you follow (raised to the top of the feed) and topics you mute (hidden). Each is
/// matched by idea, not just by its words.
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
          SwissHeader("Topics", subtitle: kind == .follow ? "What you want more of" : "What you'd rather not see")
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

          AlertSettings().padding(.top, 10)

          Text(explanation)
            .font(.footnote)
            .foregroundStyle(Swiss.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
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

/// Alerts: breaking news and new stories on followed topics. Both off until switched on; the
/// first one switched on asks for permission.
struct AlertSettings: View {
  @AppStorage(Alerts.breakingKey) var breaking = false
  @AppStorage(Alerts.followingKey) var following = false
  @State private var denied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Alerts")
      row("Breaking news", detail: "A story five or more outlets are covering within the hour. A few a day at most.", isOn: $breaking)
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
    .tint(Swiss.ink)
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
