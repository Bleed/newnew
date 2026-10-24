import SwiftData
import SwiftUI

/// Topics you don't want to see. Each is matched by idea, not just by its words.
struct MuteSheet: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.dismiss) var dismiss
  @Query(sort: \SemanticMuteFilter.createdAt, order: .reverse) var filters: [SemanticMuteFilter]
  @Query var clusters: [StoryCluster]
  @State private var phrase = ""
  @State private var isAdding = false
  @FocusState private var fieldFocused: Bool

  static let suggestions = ["Celebrity gossip", "Football transfers", "Crypto", "Royal family", "Reality TV", "Horoscopes"]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          SwissHeader("Muted", subtitle: "Topics you'd rather not see")
            .padding(.top, 4)

          field

          let unused = Self.suggestions.filter { s in !filters.contains { $0.phrase.caseInsensitiveCompare(s) == .orderedSame } }
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

          if !filters.isEmpty {
            Eyebrow("Hidden now").padding(.top, 10)
            ForEach(filters) { filter in
              FilterRow(filter: filter, hides: clusters.filter { $0.mutedBy == filter.phrase }.count) {
                withAnimation(.snappy) { pipeline.remove(filter) }
              }
            }
          }

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
      .swissNavigationTitle("Muted")
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
      TextField("A topic, like “election polls”", text: $phrase)
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
        Button("Mute") { Task { await add(phrase) } }
          .buttonStyle(.swissPrimary)
          .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  var explanation: String {
    IntelligenceService.isAvailable
      ? "Each topic is turned into a few example headlines on this iPhone, and stories that read like them are hidden, even when they use other words. Long-press a story to mute stories like it."
      : "\(IntelligenceService.unavailableReason), so topics match their own words and stories close in meaning. Long-press a story to mute stories like it."
  }

  func add(_ text: String) async {
    guard !isAdding else { return }
    isAdding = true
    await pipeline.addMuteTopic(text)
    isAdding = false
    phrase = ""
    fieldFocused = false
  }
}

struct FilterRow: View {
  let filter: SemanticMuteFilter
  let hides: Int
  var remove: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(filter.phrase).font(.body.weight(.medium)).lineLimit(2)
        Text(hides == 0 ? "Nothing hidden today" : "Hides \(hides) \(hides == 1 ? "story" : "stories")")
          .font(.footnote)
          .tileSecondary()
        if !filter.keywords.isEmpty {
          Text(filter.keywords.joined(separator: " · "))
            .font(.caption)
            .tileSecondary()
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      Button("Remove \(filter.phrase)", systemImage: "xmark", action: remove)
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
