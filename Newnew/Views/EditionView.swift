import SwiftUI

/// Today in zen mode (Figma: Zen · calm swipe, option E): a dark glow, a small NEWNEW in the
/// corner, then the edition's stories one at a time in a vertical swipe, then "You're caught up"
/// until the next edition. No list, no counts, no cards: the stories sit straight on the glow.
struct EditionView: View {
  let clusters: [StoryCluster]
  var open: (StoryCluster) -> Void
  var showEverything: () -> Void
  @Environment(FeedSyncPipeline.self) var pipeline
  var edition = Edition.shared
  /// Where the swipe is, in stories (2.4: between the third and the fourth): the glow follows.
  @State private var progress: Double = 0
  /// Where a finger is down, in global points: a soft light gathers there.
  @State private var touch: CGPoint?

  var stories: [StoryCluster] {
    let byID = Dictionary(clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return (edition.current?.ids ?? []).compactMap { byID[$0] }
  }

  enum Stage { case cover, reading, end }

  var body: some View {
    let stories = stories
    let stage: Stage = {
      guard let current = edition.current else { return .cover }
      if current.finished != nil || (!stories.isEmpty && current.position >= stories.count) { return .end }
      return current.reading && !stories.isEmpty ? .reading : .cover
    }()
    ZStack {
      ZenGlow(progress: progress, touch: touch, resting: stage == .end)
        .ignoresSafeArea()
      switch stage {
      case .end:
        if let current = edition.current { EditionEnd(stories: stories, current: current, showEverything: showEverything) }
      case .reading:
        EditionReader(stories: stories, start: min(edition.current?.position ?? 0, stories.count - 1),
                      back: Set(edition.current?.back ?? []), open: open, progress: $progress)
      case .cover:
        EditionCover(stories: stories, current: edition.current)
      }
    }
    .overlay(alignment: .top) { header(stage, stories: stories) }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { touch = $0.location }
        .onEnded { _ in touch = nil }
    )
    .animation(.smooth(duration: 0.5), value: stage)
    .toolbar(.hidden, for: .navigationBar)
    .preferredColorScheme(.dark)
    .onAppear {
      progress = Double(edition.current?.position ?? 0)
      edition.refresh(from: clusters, syncing: pipeline.isSyncing)
    }
    .onChange(of: pipeline.isSyncing) { edition.refresh(from: clusters, syncing: pipeline.isSyncing) }
    .onChange(of: clusters.count) { edition.refresh(from: clusters, syncing: pipeline.isSyncing) }
  }

  /// The small NEWNEW in the corner (in a story, it leaves the edition for its cover), and
  /// opposite it Exit Zen on the cover, where you are while reading.
  func header(_ stage: Stage, stories: [StoryCluster]) -> some View {
    HStack {
      if stage == .reading {
        Button { withAnimation(.smooth) { edition.pause() } } label: { ZenLogo() }
          .accessibilityLabel("Leave the edition")
      } else {
        ZenLogo()
      }
      Spacer()
      switch stage {
      case .cover:
        Button("Exit Zen", action: showEverything)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.66))
      case .reading:
        let position = min(edition.current?.position ?? 0, stories.count - 1) + 1
        Text("\(position) / \(stories.count)")
          .font(.footnote)
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.85))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .glassEffect(.regular, in: .capsule)
          .accessibilityLabel("Story \(position) of \(stories.count)")
          .contentTransition(.numericText())
      case .end:
        EmptyView()
      }
    }
    .frame(height: 32)
    .padding(.horizontal, Swiss.pageInset + 8)
    .padding(.top, 8)
  }
}

/// Zen's colour (Figma: Zen · calm swipe): a night field lit at the rim, with teal, plum and coral
/// bands that breathe on a 12 s loop, move up one band for every story swiped, and lean toward a
/// finger, a soft light gathering under it. Caught up: half strength and still. Reduce Motion: no
/// breathing and no light; the bands still follow the stories.
struct ZenGlow: View {
  var progress: Double = 0
  var touch: CGPoint?
  var resting = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date.now

  static let night = Color(rgb: 0x08070D)
  static let rim = Color(rgb: 0x6A5AD8)
  static let bands = [Color(rgb: 0x2B8481), Color(rgb: 0x9E3C86), Color(rgb: 0xE3988C)]
  static let breath: Double = 12

  var body: some View {
    GeometryReader { proxy in
      let frame = proxy.frame(in: .global)
      let finger = touch.map { CGPoint(x: ($0.x - frame.minX) / frame.width, y: ($0.y - frame.minY) / frame.height) }
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || resting)) { context in
        let t = reduceMotion ? 0 : context.date.timeIntervalSince(start)
        MeshGradient(width: Self.xs.count, height: Self.ys.count, points: points(t, finger: reduceMotion ? nil : finger), colors: colors)
      }
      .overlay {
        if let touch, !reduceMotion, !resting {
          Circle()
            .fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 120))
            .frame(width: 240, height: 240)
            .position(x: touch.x - frame.minX, y: touch.y - frame.minY)
            .blendMode(.plusLighter)
            .transition(.opacity.animation(.easeOut(duration: 0.6)))
        }
      }
      .animation(.easeOut(duration: 0.25), value: touch == nil)
    }
    .animation(.smooth(duration: 0.8), value: resting)
    .accessibilityHidden(true)
  }

  /// The grid's columns and rows: the inner ones close to the edges, so the rim stays a rim.
  static let xs: [Double] = [0, 0.14, 0.86, 1]
  static let ys: [Double] = [0, 0.09, 0.36, 0.64, 0.91, 1]

  /// A 4 × 6 grid: the outer points hold the rim, the eight inside drift (a slow breath, each a
  /// little out of step) and lean 8% toward the finger.
  func points(_ t: Double, finger: CGPoint?) -> [SIMD2<Float>] {
    var points: [SIMD2<Float>] = []
    for row in Self.ys.indices {
      for column in Self.xs.indices {
        var x = Self.xs[column], y = Self.ys[row]
        if (1...2).contains(column), (1...4).contains(row) {
          let phase = t / Self.breath * 2 * .pi + Double(row * 4 + column)
          x += 0.05 * sin(phase)
          y += 0.035 * cos(phase * 0.8)
          if let finger {
            x += (finger.x - x) * 0.08
            y += (finger.y - y) * 0.08
          }
        }
        points.append(SIMD2(Float(x), Float(y)))
      }
    }
    return points
  }

  /// Rim on the edges (night in the corners), the bands inside: the row at the top has the colour
  /// the row below had a story ago, so swiping on hands each colour up.
  var colors: [Color] {
    let strength = resting ? 0.5 : 1
    var colors: [Color] = []
    let last = Self.ys.count - 1
    for row in Self.ys.indices {
      for column in Self.xs.indices {
        let corner = (row == 0 || row == last) && (column == 0 || column == 3)
        let edge = row == 0 || row == last || column == 0 || column == 3
        var color: Color
        if corner {
          color = Self.night
        } else if edge {
          color = Self.rim.mix(with: Self.night, by: 0.15)
        } else {
          color = band(Double(row - 1) + progress)
          // Dark just inside the rim (only the edge is lit), and one side of each row a little
          // deeper, alternating, so the bands aren't flat stripes.
          if row == 1 || row == last - 1 { color = color.mix(with: Self.night, by: 0.55) }
          if (row + column).isMultiple(of: 2) { color = color.mix(with: Self.night, by: 0.3) }
        }
        colors.append(color.mix(with: Self.night, by: 1 - strength))
      }
    }
    return colors
  }

  func band(_ x: Double) -> Color {
    let index = Int(floor(x)), fraction = x - floor(x)
    let count = Self.bands.count
    let a = Self.bands[((index % count) + count) % count], b = Self.bands[(((index + 1) % count) + count) % count]
    return a.mix(with: b, by: fraction)
  }
}

/// The small solid NEWNEW in Zen's corner: the block face, 20 pt tall.
struct ZenLogo: View {
  var height: CGFloat = 20

  var body: some View {
    let glyphs = Array("NEWNEW"), unit = height / (10 * BlockText.tall)
    Canvas { ctx, _ in
      var x: CGFloat = 0
      for character in glyphs {
        ctx.fill(BlockFont.path(character, x: x, unit: unit, stretchY: BlockText.tall), with: .color(.white))
        x += (BlockFont.width(character) + BlockFont.gap) * unit
      }
    }
    .frame(width: BlockFont.width(glyphs) * unit, height: height)
    .accessibilityLabel("newnew")
  }
}

/// The edition's cover: no list. When it is, and one sentence; swipe up (or tap) to begin.
struct EditionCover: View {
  let stories: [StoryCluster]
  let current: Edition.Stored?
  var edition = Edition.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Spacer()
      if let current {
        Text("\(Edition.name(current.slot)) · \(current.slot.formatted(date: .omitted, time: .shortened))")
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.66))
        if stories.isEmpty {
          headline("Nothing widely\ncovered yet.")
          deck("No story has been covered by enough of your outlets since the last edition. The next one is at \(Edition.next(current.slot).formatted(date: .omitted, time: .shortened)).")
        } else {
          headline("\(Self.count(stories.count)) \(stories.count == 1 ? "story" : "stories"),\nthen rest.")
        }
      } else {
        headline("Your first edition\nis being made.")
        deck("It's made from what your outlets cover most, once the news has been read.")
      }
      Spacer().frame(height: 72)
      if !stories.isEmpty {
        Button { begin() } label: {
          VStack(spacing: 10) {
            Text(current?.started == nil ? "Swipe up to begin" : "Swipe up to go on")
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.66))
            Capsule().fill(.white.opacity(0.5)).frame(width: 36, height: 4)
          }
          .frame(maxWidth: .infinity)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
      }
    }
    .padding(.horizontal, Swiss.pageInset + 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .gesture(DragGesture(minimumDistance: 24).onEnded { value in
      if value.translation.height < -40, !stories.isEmpty { begin() }
    })
  }

  func begin() { withAnimation(.smooth(duration: 0.5)) { edition.begin() } }

  func headline(_ text: String) -> some View {
    Text(text)
      .font(Swiss.headline(44, relativeTo: .largeTitle))
      .foregroundStyle(.white)
      .fixedSize(horizontal: false, vertical: true)
  }

  func deck(_ text: String) -> some View {
    Text(text)
      .font(.body)
      .foregroundStyle(.white.opacity(0.66))
      .fixedSize(horizontal: false, vertical: true)
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

/// The stories, one at a time, in a vertical swipe that snaps each to the middle. No frames, no
/// blur: the one in the middle at full strength, the one before and after faded above and below.
/// Swiping past the last ends the edition. A tap opens the story page.
struct EditionReader: View {
  let stories: [StoryCluster]
  let start: Int
  let back: Set<UUID>
  var open: (StoryCluster) -> Void
  @Binding var progress: Double
  @Environment(FeedSyncPipeline.self) var pipeline
  var edition = Edition.shared
  @State private var scroll = ScrollPosition(idType: Int.self)
  var position: Int? { scroll.viewID(type: Int.self) }
  /// Until the swipe has come back to where you were, its moves aren't yours.
  @State private var restored = false

  init(stories: [StoryCluster], start: Int, back: Set<UUID>, open: @escaping (StoryCluster) -> Void, progress: Binding<Double>) {
    self.stories = stories
    self.start = start
    self.back = back
    self.open = open
    _progress = progress
  }

  var body: some View {
    GeometryReader { proxy in
      let page = (proxy.size.height * 0.62).rounded()
      ScrollView(.vertical) {
        // Not lazy: at most 15 stories, all laid out, so the swipe can open on the one you were at.
        VStack(spacing: 0) {
          ForEach(Array(stories.enumerated()), id: \.offset) { index, story in
            Button { open(story) } label: {
              ZenStory(story: story, back: back.contains(story.id) && story.newSinceRead > 0)
                .frame(height: page)
            }
            .buttonStyle(.plain)
            .id(index)
            .scrollTransition(.interactive, axis: .vertical) { content, phase in
              content.opacity(1 - 0.65 * min(abs(phase.value), 1))
            }
          }
          // Past the last story: the end.
          Color.clear.frame(height: page).id(stories.count)
        }
        .scrollTargetLayout()
      }
      .contentMargins(.vertical, (proxy.size.height - page) / 2, for: .scrollContent)
      .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
      .scrollPosition($scroll, anchor: .center)
      .scrollIndicators(.hidden)
      .onScrollGeometryChange(for: Double.self) { geometry in
        Double((geometry.contentOffset.y + geometry.contentInsets.top) / page)
      } action: { _, value in
        progress = max(0, value)
      }
      // Stories come and go softly at the top and the bottom.
      .mask {
        LinearGradient(stops: [
          .init(color: .clear, location: 0.06), .init(color: .black, location: 0.26),
          .init(color: .black, location: 0.84), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
      }
      .onChange(of: position) { old, new in moved(from: old, to: new) }
      // Open on the story you were at, once the page has its size.
      .onAppear {
        scroll.scrollTo(id: start, anchor: .center)
        if start == 0 { restored = true }
      }
      .task {
        try? await Task.sleep(for: .milliseconds(60))
        if position != start { scroll.scrollTo(id: start, anchor: .center) }
      }
    }
    .accessibilityAction(named: "Next story") {
      withAnimation(.smooth) { scroll.scrollTo(id: min((position ?? start) + 1, stories.count), anchor: .center) }
    }
  }

  /// Moving on counts the story you leave as read.
  func moved(from old: Int?, to new: Int?) {
    guard let new else { return }
    guard restored else {
      restored = new == start
      return
    }
    if let old, new > old, old < stories.count { pipeline.markRead(stories[old]) }
    withAnimation(.smooth(duration: 0.5)) { edition.go(to: new) }
  }
}

/// One story on the glow: the picture, what and how widely covered, the headline in the serif.
struct ZenStory: View {
  let story: StoryCluster
  let back: Bool

  var body: some View {
    if let lead = story.lead {
      VStack(alignment: .leading, spacing: 12) {
        HeroImage(
          remote: lead.imageURL, article: lead.url, radius: 20, aspect: 16 / 10,
          fits: lead.isChart, isVideo: lead.videoID != nil, topAligned: story.pillar.isPortrait
        )
        Text(back ? "Back · \(story.newSinceRead) new since you read it" : "\(story.pillar.title) · \(story.outlets.count) sources")
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.62))
        Text(lead.title)
          .font(Swiss.headline(26, relativeTo: .title2))
          .foregroundStyle(.white)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, Swiss.pageInset + 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .contentShape(.rect)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(lead.title)
      .accessibilityHint("\(story.outlets.count) sources. Opens the story.")
    }
  }
}

/// "You're caught up." and when the next edition comes; the glow rests at half strength.
struct EditionEnd: View {
  let stories: [StoryCluster]
  let current: Edition.Stored
  var showEverything: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Spacer()
      Text("You're caught up.")
        .font(Swiss.headline(44, relativeTo: .largeTitle))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
      Text(summary)
        .font(.body)
        .foregroundStyle(.white.opacity(0.66))
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Exit Zen and browse everything", action: showEverything)
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.66))
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
    .padding(.horizontal, Swiss.pageInset + 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var summary: String {
    let next = Edition.next(current.slot).formatted(date: .omitted, time: .shortened)
    let count = EditionCover.count(stories.count)
    return "\(count) \(stories.count == 1 ? "story" : "stories") read. The \(Edition.isMorning(Edition.next(current.slot)) ? "morning" : "evening") edition comes at \(next)."
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
