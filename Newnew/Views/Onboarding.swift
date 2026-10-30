import SwiftData
import SwiftUI

/// First launch (Figma: Onboarding · editorial, sketch B): calm and classic. The loading board
/// is the masthead, "new" over "new" rolling in; then one serif headline and a grey line per
/// step, and the app's own tiles, pills and switches. Welcome, outlets, your own feeds, topics,
/// how Today begins, staying up to date, then the first edition while the first sync runs.
/// Legally the point is that the reader picks the sources; newnew shows headlines and short
/// extracts and links out.
struct OnboardingView: View {
  @Environment(FeedSyncPipeline.self) var pipeline
  var done: () -> Void
  @State private var step = Step.welcome
  @State private var selection = OutletStore.shared.selection

  enum Step: Int, CaseIterable { case welcome, outlets, own, topics, look, updates, firstEdition }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if step != .welcome && step != .firstEdition {
        // Masthead: the board small and still, the progress dots opposite.
        HStack {
          MiniDotBoard(fill: 1, first: true, second: true, pitch: 2)
          Spacer()
          ProgressDots(step: step.rawValue - 1, count: 5)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
      Group {
        switch step {
        case .welcome: welcome
        case .outlets: outlets
        case .own: own
        case .topics: OnboardingTopics(next: next)
        case .look: look
        case .updates: updates
        case .firstEdition: FirstEdition(outlets: OutletStore.shared.selection.count, finish: finish)
        }
      }
      .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }
    .padding(.horizontal, Swiss.pageInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .swissCanvas()
    .animation(.snappy(duration: 0.3), value: step)
  }

  func next() { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .firstEdition } }

  func finish() {
    OutletStore.shared.finishOnboarding()
    done()
  }

  // MARK: Steps

  var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      RollingBoard(pitch: 6)
        .padding(.top, 56)
        .padding(.bottom, 20)
      Eyebrow("Welcome to newnew")
      OnboardingHeadline("The news, from the outlets you choose.", size: 40)
      OnboardingDeck("Every story told once, with all the outlets that cover it. Read on this iPhone, no account.")
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(["You choose the outlets.", "newnew puts their coverage of each story together.", "Every headline links to the publisher."].enumerated()), id: \.offset) { index, line in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(index + 1)")
              .font(.footnote.weight(.medium))
              .frame(width: 24, height: 24)
              .background(Swiss.card, in: Circle())
              .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
            Text(line).font(.body).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tile(.plain)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 20)
      Button("Begin", action: next).buttonStyle(.swissPrimary).padding(.bottom, 12)
    }
  }

  var outlets: some View {
    VStack(alignment: .leading, spacing: 0) {
      OnboardingHeadline("Choose what you read.")
      OnboardingDeck("\(selection.count) of \(OutletStore.shared.catalog.count) outlets. Change it any time in Settings.")
        .padding(.top, 8)
        .padding(.bottom, 14)
      OutletPicker(selection: $selection)
      Button("Continue") {
        OutletStore.shared.setChosen(selection)
        next()
      }
      .buttonStyle(.swissPrimary)
      .disabled(selection.isEmpty)
      .padding(.vertical, 12)
    }
  }

  var own: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          OnboardingHeadline("Add a source of your own.")
          OnboardingDeck("A website, its feed, a YouTube channel, or a Bluesky or Mastodon account.")
          AddFeedPanel(showsHint: false)
        }
      }
      .scrollIndicators(.hidden)
      HStack(spacing: 10) {
        Button("Continue", action: next).buttonStyle(.swissPrimary)
        if OutletStore.shared.customFeeds.isEmpty { Button("Skip", action: next).buttonStyle(.swissSecondary) }
      }
      .padding(.vertical, 12)
    }
  }

  var look: some View {
    VStack(alignment: .leading, spacing: 14) {
      OnboardingHeadline("Choose how Today begins.")
      OnboardingDeck("The top of Today shows what's new since you last looked. Change it in Settings › Look.")
      LookChoice()
      Spacer(minLength: 20)
      Button("Continue", action: next).buttonStyle(.swissPrimary).padding(.bottom, 12)
    }
  }

  var updates: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          OnboardingHeadline("Stay up to date, quietly.")
          OnboardingDeck("Both optional. Both can be changed in Settings.")
          BackgroundRefreshSettings()
          AlertSettings()
        }
      }
      .scrollIndicators(.hidden)
      Button("Start reading") {
        next()
        // Outlets left out go now; own feeds are read in the next sync.
        Task { await pipeline.applyOutletChoice(added: !OutletStore.shared.customFeeds.isEmpty) }
      }
      .buttonStyle(.swissPrimary)
      .padding(.vertical, 12)
    }
  }
}

/// An onboarding step's headline: the news serif, large and calm.
struct OnboardingHeadline: View {
  let text: String
  var size: CGFloat = 34
  init(_ text: String, size: CGFloat = 34) { self.text = text; self.size = size }
  var body: some View {
    Text(text)
      .font(Swiss.headline(size, relativeTo: .largeTitle))
      .foregroundStyle(Swiss.ink)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The grey line under a headline.
struct OnboardingDeck: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.body).foregroundStyle(Swiss.muted).fixedSize(horizontal: false, vertical: true)
  }
}

/// The loading board, rolling "new" over "new" in like the launch board, once (or, with
/// `loops`, until `until` says it's done, always ending with both words in).
struct RollingBoard: View {
  var pitch: CGFloat
  var loops = false
  var until: @MainActor () -> Bool = { true }
  @State private var loop = WordLoop()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    MiniDotBoard(fill: 1, first: loop.first, second: loop.second, pitch: pitch)
      .task {
        try? await Task.sleep(for: .seconds(0.3))
        await loop.run(reduceMotion: reduceMotion) { !loops || until() }
      }
      .accessibilityLabel("newnew")
  }
}

/// Topics to follow, as on the Topics sheet: suggestions as pills ("+" to follow, outlined with
/// a tick once followed) and a field for your own. Optional.
struct OnboardingTopics: View {
  var next: () -> Void
  @Environment(FeedSyncPipeline.self) var pipeline
  @Query(sort: \SemanticTopic.createdAt) var topics: [SemanticTopic]
  @State private var phrase = ""
  @State private var adding: Set<String> = []

  func followed(_ name: String) -> SemanticTopic? {
    topics.first { $0.kind == .follow && $0.phrase.caseInsensitiveCompare(name) == .orderedSame }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      OnboardingHeadline("Follow what you care about.")
      OnboardingDeck("Followed topics come first in Today and get their own pill. Optional.")
      HStack(spacing: 8) {
        TextField("A topic, like “electric cars”", text: $phrase)
          .submitLabel(.done)
          .onSubmit { follow(phrase) }
        Button("Follow") { follow(phrase) }
          .buttonStyle(.swissPrimary)
          .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(.leading, 16)
      .padding(.trailing, 8)
      .padding(.vertical, 8)
      .tile(.plain, radius: 16)
      let own = topics.filter { $0.kind == .follow }.map(\.phrase).filter { p in !(TopicsSheet.suggestions[.follow] ?? []).contains { $0.caseInsensitiveCompare(p) == .orderedSame } }
      FlowLayout(spacing: 8) {
        ForEach((TopicsSheet.suggestions[.follow] ?? []) + own + adding.filter { a in !own.contains(a) && !(TopicsSheet.suggestions[.follow] ?? []).contains(a) }.sorted(), id: \.self) { name in
          let on = followed(name) != nil || adding.contains(name)
          Button {
            if let topic = followed(name) { withAnimation(.snappy) { pipeline.remove(topic) } } else { follow(name) }
          } label: {
            Label(name, systemImage: on ? "checkmark" : "plus")
          }
          .buttonStyle(SelectablePillStyle(isOn: on))
          .id(on)
          .accessibilityValue(on ? "Following" : "")
        }
      }
      Spacer(minLength: 20)
      HStack(spacing: 10) {
        Button("Continue", action: next).buttonStyle(.swissPrimary)
        if topics.filter({ $0.kind == .follow }).isEmpty && adding.isEmpty { Button("Skip", action: next).buttonStyle(.swissSecondary) }
      }
      .padding(.bottom, 12)
    }
  }

  func follow(_ text: String) {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, followed(name) == nil, !adding.contains(name) else { return }
    phrase = ""
    withAnimation(.snappy) { _ = adding.insert(name) }
    Task {
      await pipeline.addTopic(name, kind: .follow)
      withAnimation(.snappy) { _ = adding.remove(name) }
    }
  }
}

/// How Today begins: Blocks, Dots or LCD, each a tile with its own top in small, the chosen one
/// white and outlined (Settings › Look).
struct LookChoice: View {
  @AppStorage(TopLook.key) private var raw = TopLook.blocks.rawValue

  var body: some View {
    VStack(spacing: 12) {
      ForEach(TopLook.allCases) { look in
        let on = raw == look.rawValue
        Button {
          withAnimation(.snappy(duration: 0.2)) { raw = look.rawValue }
        } label: {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(look.label).font(.body)
                Text(Self.line(look)).font(.footnote).foregroundStyle(Swiss.muted)
              }
              Spacer()
              CheckMark(isOn: on)
            }
            preview(look)
              .foregroundStyle(Swiss.ink)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityHidden(true)
          }
          .padding(16)
          .background(on ? Swiss.card : Swiss.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Swiss.ink, lineWidth: on ? 1.6 : 0))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }

  static func line(_ look: TopLook) -> String {
    switch look {
    case .blocks: "Bold, the default"
    case .dots: "A small departures board"
    case .lcd: "A liquid-crystal display"
    }
  }

  @ViewBuilder func preview(_ look: TopLook) -> some View {
    switch look {
    case .blocks: BlockText(text: "21 NEW", maxHeight: 44).frame(width: 220, alignment: .leading)
    case .dots: DotText("21 NEW", pitch: 2.4, unlit: 0.07, motion: .none, scales: false)
    case .lcd: DotText("21 NEW", pitch: 2.4, unlit: 0.07, motion: .none, scales: false).environment(\.boardFace, .lcd)
    }
  }
}

/// The hand-over: the board large and centred, rolling "new" over "new" while the first sync
/// runs, with one calm sentence; then Today.
struct FirstEdition: View {
  let outlets: Int
  var finish: () -> Void
  @Environment(FeedSyncPipeline.self) var pipeline
  @State private var started = Date.now

  var body: some View {
    VStack(spacing: 18) {
      Spacer()
      // Rolls until the sync is done and the board has been seen for a moment.
      RollingBoard(pitch: 7, loops: true) { !pipeline.isSyncing && Date.now.timeIntervalSince(started) > 2 }
      OnboardingHeadline("Your first edition is being made.", size: 32)
        .multilineTextAlignment(.center)
      Text("newnew is reading \(outlets) outlets on this iPhone. It takes about a minute, the first time.")
        .font(.body)
        .foregroundStyle(Swiss.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .task {
      while pipeline.isSyncing || Date.now.timeIntervalSince(started) < 2.5 { try? await Task.sleep(for: .milliseconds(200)) }
      finish()
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

  /// Rows in one tile, apart by space (no lines between them).
  func rows(_ outlets: [OutletInfo], icon: String? = nil) -> some View {
    VStack(spacing: 0) {
      ForEach(outlets) { outlet in
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
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == nil ? outlet.outlet : "\(outlet.outlet), podcast")
        .accessibilityAddTraits(selection.contains(outlet.outlet) ? .isSelected : [])
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
        ForEach(channels) { channel in
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
  /// Off in onboarding, whose step says it in its own line.
  var showsHint = true
  @State private var address = ""
  @State private var finding = false
  @State private var found: CustomFeedReader.Found?
  @State private var failure: String?
  @State private var renaming: CustomFeed?
  @State private var newName = ""
  @Environment(FeedSyncPipeline.self) private var pipeline
  var store = OutletStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if showsHint {
        Text(verbatim: "Paste a site, its feed address, a YouTube channel (its link or ID), or a Bluesky or Mastodon account (@name.bsky.social, @name@mastodon.social, or its link). newnew finds the feed, shows you what it would read, and checks it when it refreshes.")
          .font(.subheadline)
          .foregroundStyle(Swiss.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        TextField("Site, feed, YouTube, Bluesky or Mastodon", text: $address)
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
              Button("Rename \(feed.title)", systemImage: "pencil") {
                newName = feed.title
                renaming = feed
              }
                .buttonStyle(.roundIcon)
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
    .alert("Rename feed", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let feed = renaming, let name = store.rename(feed, to: newName) { pipeline.renameOutlet(feed.title, to: name) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    } message: {
      Text("How this feed is named on its stories.")
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
