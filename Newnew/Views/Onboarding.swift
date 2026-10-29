import SwiftUI

/// First launch: the reader chooses which outlets newnew reads, can add their own feeds, and
/// may switch on alerts (Figma: Onboarding). Legally the point is that the reader picks the
/// sources; newnew shows headlines and short extracts and links out.
struct OnboardingView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  var done: () -> Void
  @State private var step = 0
  @State private var selection = OutletStore.shared.selection

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ProgressDots(step: step, count: 4)
        .padding(.top, 24)
        .padding(.bottom, 26)
      Group {
        switch step {
        case 0: welcome
        case 1: choose
        case 2: addOwn
        default: alerts
        }
      }
      .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }
    .padding(.horizontal, Swiss.pageInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .swissCanvas()
    .animation(.snappy(duration: 0.3), value: step)
  }

  func next() { withAnimation { step += 1 } }

  // MARK: Steps

  var welcome: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        DotText("new", pitch: 5, scales: false)
        DotText("new", pitch: 5, scales: false)
      }
      .foregroundStyle(Swiss.ink)
      .padding(.top, 40)
      .padding(.bottom, 32)
      RebusLine(tokens: [.word("THE NEWS,"), .pill("GROUPED")], size: 17, delay: 0.2)
      RebusLine(tokens: [.word("FROM OUTLETS"), .pill("YOU PICK")], size: 17, delay: 0.5).padding(.top, 8)
      Text("newnew reads public RSS feeds and shows each outlet's headline and a short extract, then links to the publisher for the full story. You choose which outlets it reads, and you can add your own.")
        .font(.body)
        .foregroundStyle(Swiss.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 24)
      Spacer(minLength: 20)
      Button("Choose outlets", action: next).buttonStyle(.swissPrimary).padding(.bottom, 12)
    }
  }

  var choose: some View {
    VStack(alignment: .leading, spacing: 0) {
      ReadingCount(chosen: selection.count, total: OutletStore.shared.catalog.count)
        .padding(.bottom, 16)
      OutletPicker(selection: $selection)
      HStack(spacing: 10) {
        Button("Continue") {
          OutletStore.shared.setChosen(selection)
          next()
        }
        .buttonStyle(.swissPrimary)
        .disabled(selection.isEmpty)
        Button("Add your own") {
          OutletStore.shared.setChosen(selection)
          next()
        }
        .buttonStyle(.swissSecondary)
      }
      .padding(.vertical, 12)
    }
  }

  var addOwn: some View {
    VStack(alignment: .leading, spacing: 0) {
      RebusLine(tokens: [.word("ADD"), .pill("YOUR OWN")], size: 17, delay: 0.1)
      RebusLine(tokens: [.word("RSS FEED")], size: 17, delay: 0.3).padding(.top, 6)
      AddFeedPanel().padding(.top, 16)
      Spacer(minLength: 20)
      HStack(spacing: 10) {
        Button("Continue", action: next).buttonStyle(.swissPrimary)
        if OutletStore.shared.customFeeds.isEmpty { Button("Skip", action: next).buttonStyle(.swissSecondary) }
      }
      .padding(.bottom, 12)
    }
  }

  var alerts: some View {
    VStack(alignment: .leading, spacing: 0) {
      RebusLine(tokens: [.word("ALERTS"), .pill("IF YOU WANT")], size: 17, delay: 0.1)
      AlertSettings(showsHeading: false).padding(.top, 20)
      Spacer(minLength: 20)
      Button("Start reading") {
        OutletStore.shared.finishOnboarding()
        done()
        // Outlets left out go now; own feeds are read in the next sync.
        Task { await pipeline.applyOutletChoice(added: !OutletStore.shared.customFeeds.isEmpty) }
      }
      .buttonStyle(.swissPrimary)
      .padding(.bottom, 12)
    }
  }
}

/// "READING (58) OF (76) OUTLETS".
struct ReadingCount: View {
  let chosen: Int
  let total: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RebusLine(tokens: [.word("READING"), .number("\(chosen)"), .word("OF"), .number("\(total)")], size: 17, delay: nil)
      RebusLine(tokens: [.word("OUTLETS")], size: 17, delay: nil)
    }
  }
}

struct ProgressDots: View {
  let step: Int
  let count: Int
  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(Swiss.ink.opacity(index <= step ? 1 : 0.15))
          .frame(width: index == step ? 22 : 8, height: 8)
      }
    }
    .animation(.snappy, value: step)
    .accessibilityElement()
    .accessibilityLabel("Step \(step + 1) of \(count)")
  }
}

/// Every outlet, grouped by pillar, each with a check; a group's "All" switches it as a whole.
/// The filter pills narrow the list to one group.
struct OutletPicker: View {
  @Binding var selection: Set<String>
  @State private var group: OutletGroup?
  var store = OutletStore.shared

  var groups: [OutletGroup] { OutletGroup.all.filter { !store.outlets(in: $0).isEmpty } }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          Button("All") { withAnimation(.snappy) { group = nil } }
            .buttonStyle(SelectablePillStyle(isOn: group == nil, small: true))
          ForEach(groups) { item in
            Button(item.title) { withAnimation(.snappy) { group = item } }
              .buttonStyle(SelectablePillStyle(isOn: group == item, small: true))
          }
        }
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(group.map { [$0] } ?? groups) { item in
            section(item).padding(.bottom, 8)
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }

  func section(_ item: OutletGroup) -> some View {
    let all = store.outlets(in: item)
    let outlets = all.filter { !$0.isPodcast }
    let podcasts = all.filter(\.isPodcast)
    let names = Set(outlets.map(\.outlet))
    let allOn = names.isSubset(of: selection)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Eyebrow(item.title)
        Spacer()
        if !outlets.isEmpty {
          Button(allOn ? "None" : "All \(outlets.count)") {
            if allOn { selection.subtract(names) } else { selection.formUnion(names) }
          }
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Swiss.ink)
          .buttonStyle(.plain)
        }
      }
      if !outlets.isEmpty { rows(outlets) }
      // Off until chosen, one by one: podcast feeds are large.
      if !podcasts.isEmpty {
        Text("Podcasts").font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted).padding(.top, 4)
        rows(podcasts, icon: "headphones")
      }
      channels(item)
    }
  }

  func rows(_ outlets: [OutletInfo], icon: String? = nil) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(outlets.enumerated()), id: \.element.id) { index, outlet in
        Button {
          if selection.contains(outlet.outlet) { selection.remove(outlet.outlet) } else { selection.insert(outlet.outlet) }
        } label: {
          HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.footnote).foregroundStyle(Swiss.muted) }
            Text(outlet.outlet).font(.body).foregroundStyle(Swiss.ink)
            Spacer()
            CheckMark(isOn: selection.contains(outlet.outlet))
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == nil ? outlet.outlet : "\(outlet.outlet), podcast")
        .accessibilityAddTraits(selection.contains(outlet.outlet) ? .isSelected : [])
        if index < outlets.count - 1 { Divider().overlay(Swiss.ink.opacity(0.06)).padding(.horizontal, 14) }
      }
    }
    .tile(.plain, radius: 16)
  }

  /// Suggested YouTube channels for the group: checking one follows it like an own feed.
  @ViewBuilder func channels(_ item: OutletGroup) -> some View {
    let channels = YouTubeSuggestions.channels(in: item)
    if !channels.isEmpty {
      Text("On YouTube").font(.footnote.weight(.medium)).foregroundStyle(Swiss.muted).padding(.top, 4)
      VStack(spacing: 0) {
        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
          let on = store.customFeeds.contains { $0.url == channel.url }
          Button {
            if on { store.remove(channel) } else { store.add(channel) }
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "play.rectangle.fill").font(.footnote).foregroundStyle(Swiss.muted)
              Text(channel.title.replacingOccurrences(of: " · YouTube", with: "")).font(.body).foregroundStyle(Swiss.ink)
              Spacer()
              CheckMark(isOn: on)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(channel.title), YouTube channel")
          .accessibilityAddTraits(on ? .isSelected : [])
          if index < channels.count - 1 { Divider().overlay(Swiss.ink.opacity(0.06)).padding(.horizontal, 14) }
        }
      }
      .tile(.plain, radius: 16)
    }
  }
}

/// A round check: ink and white tick when on, an outline when off.
struct CheckMark: View {
  let isOn: Bool
  var body: some View {
    ZStack {
      Circle().fill(isOn ? Swiss.ink : .clear)
      Circle().strokeBorder(Swiss.ink.opacity(isOn ? 0 : 0.25), lineWidth: 1.5)
      if isOn { Image(systemName: "checkmark").font(.caption.weight(.medium)).foregroundStyle(Swiss.onInk) }
    }
    .frame(width: 26, height: 26)
    .animation(.snappy(duration: 0.15), value: isOn)
    .accessibilityHidden(true)
  }
}

/// Paste a site or feed address; newnew finds the feed, shows two headlines, and adds it. Own
/// feeds are read on this iPhone only.
struct AddFeedPanel: View {
  /// After a feed is added (true) or removed (false).
  var onChange: (Bool) -> Void = { _ in }
  @State private var address = ""
  @State private var finding = false
  @State private var found: CustomFeedReader.Found?
  @State private var failure: String?
  var store = OutletStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Paste a site, its feed address, or a YouTube channel (its link or ID). newnew finds the feed, shows you what it would read, and checks it when it refreshes.")
        .font(.subheadline)
        .foregroundStyle(Swiss.muted)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        TextField("Site, feed or YouTube channel", text: $address)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.search)
          .onSubmit { Task { await find() } }
        Button(finding ? "Finding…" : "Find") { Task { await find() } }
          .buttonStyle(.swissPrimary)
          .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || finding)
      }
      .padding(.leading, 16)
      .padding(.trailing, 8)
      .padding(.vertical, 8)
      .tile(.plain, radius: 16)
      if let failure {
        Text(failure).font(.footnote).foregroundStyle(Swiss.alert)
      }
      if let found {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text(found.feed.title).font(.body.weight(.medium))
            Spacer()
            DotChip("FOUND")
          }
          let videos = found.articles.filter { $0.videoID != nil }.count
          let articles = found.articles.count
          Text(videos > 0
            ? "YouTube channel · \(videos) \(videos == 1 ? "video" : "videos") in the last three days"
            : "\(articles) \(articles == 1 ? "article" : "articles") in the last three days")
            .font(.footnote).foregroundStyle(Swiss.muted)
          ForEach(found.articles.prefix(2), id: \.url) { article in
            Text(article.title).font(Swiss.headline(20, relativeTo: .body)).fixedSize(horizontal: false, vertical: true)
          }
          Button("Add \(found.feed.title)") {
            store.add(found.feed)
            self.found = nil
            address = ""
            onChange(true)
          }
          .buttonStyle(.swissPrimary)
          .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(.plain)
      }
      if !store.customFeeds.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Eyebrow("Your feeds")
          ForEach(store.customFeeds) { feed in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(feed.title).font(.body)
                Text(feed.url.contains("youtube.com") ? "YouTube channel" : URL(string: feed.url)?.host() ?? feed.url)
                  .font(.caption).foregroundStyle(Swiss.muted)
              }
              Spacer()
              Button("Remove \(feed.title)", systemImage: "xmark") {
                store.remove(feed)
                onChange(false)
              }
                .buttonStyle(.roundIcon)
            }
            .padding(.leading, 14)
            .padding(.vertical, 4)
            .tile(.plain, radius: 16)
          }
        }
      }
      Text("Every feed, yours too, is read by this iPhone directly from the publisher.")
        .font(.footnote)
        .foregroundStyle(Swiss.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  func find() async {
    finding = true
    failure = nil
    found = nil
    defer { finding = false }
    do {
      found = try await CustomFeedReader.find(address)
    } catch {
      failure = error.localizedDescription
    }
  }
}

/// Settings › Outlets: the same choice as onboarding, any time.
struct OutletsSettingsView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  @Environment(\.dismiss) var dismiss
  @State private var selection = OutletStore.shared.selection
  @State private var feedsBefore = OutletStore.shared.customFeeds

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        ReadingCount(chosen: selection.count, total: OutletStore.shared.catalog.count)
        OutletPicker(selection: $selection)
      }
      .padding(.horizontal, Swiss.pageInset)
      .padding(.top, 8)
      .swissCanvas()
      .swissNavigationTitle("Outlets")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { save() }
            .disabled(selection.isEmpty)
        }
      }
    }
    .tint(Swiss.ink)
  }

  func save() {
    let store = OutletStore.shared
    let added = !selection.subtracting(store.selection).isEmpty || store.customFeeds != feedsBefore
    let changed = selection != store.selection || store.customFeeds != feedsBefore
    store.setChosen(selection)
    dismiss()
    if changed { Task { await pipeline.applyOutletChoice(added: added) } }
  }
}
