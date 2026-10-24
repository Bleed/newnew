import SwiftUI

// From Atelier CRM. The one-sentence top of a page: the day, the page's figure as the biggest word, what it
// is, and one key message, read top to bottom like a rebus. Words are SF Mono caps; numbers sit
// in ink pills in the 5×7 dot face; labels in outline pills; small glyphs for talk, time, go.
// Warnings stay in red words, never dots.

enum RebusToken: Hashable {
  case word(String)
  case grey(String)
  /// A number in an ink pill, in dots.
  case number(String)
  /// A word in an outline pill.
  case pill(String)
  /// Red dot and red words: act now.
  case nudge(String)
  /// "18 MIN" in an underline bracket.
  case minutes(String)
  case arrow
  case talk
  case clock
  case check
}

/// One line of tokens; wraps on narrow screens.
struct RebusLine: View {
  let tokens: [RebusToken]
  var size: CGFloat
  /// Seconds before this line's words start typing in (nil: no entrance).
  var delay: Double?
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var body: some View {
    FlowLayout(spacing: size * 0.3) {
      ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
        RebusTokenView(token: token, size: size)
          .opacity(shown || delay == nil ? 1 : 0)
          .offset(y: shown || delay == nil || reduceMotion ? 0 : size * 0.4)
          .animation(.spring(response: 0.38, dampingFraction: 0.78).delay((delay ?? 0) + Double(index) * 0.06), value: shown)
      }
    }
    .afterLaunch { shown = true }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tokens.map(\.spoken).joined(separator: " "))
  }
}

extension RebusToken {
  var spoken: String {
    switch self {
    case .word(let s), .grey(let s), .number(let s), .pill(let s), .nudge(let s), .minutes(let s): s.lowercased()
    case .arrow, .talk, .clock, .check: ""
    }
  }
}

struct RebusTokenView: View {
  let token: RebusToken
  var size: CGFloat

  var mono: Font { .system(size: size, weight: .regular, design: .monospaced) }
  var height: CGFloat { size * 1.18 }
  var stroke: CGFloat { max(1.3, size / 14) }

  var body: some View {
    switch token {
    case .word(let s): Text(s).font(mono).foregroundStyle(Swiss.ink)
    case .grey(let s): Text(s).font(mono).foregroundStyle(Swiss.muted)
    case .number(let s):
      DotText(s, pitch: max(1.5, size * 0.1), motion: .roll, rollsIn: true)
        .foregroundStyle(Swiss.onInk)
        .padding(.horizontal, size * 0.38)
        .frame(height: height)
        .background(Swiss.ink, in: Capsule())
    case .pill(let s):
      Text(s).font(mono).foregroundStyle(Swiss.ink)
        .padding(.horizontal, size * 0.4)
        .frame(height: height)
        .overlay(Capsule().strokeBorder(Swiss.ink, lineWidth: stroke))
    case .nudge(let s):
      HStack(spacing: size * 0.25) {
        Circle().fill(Swiss.alert).frame(width: size * 0.32, height: size * 0.32)
        Text(s).font(mono).foregroundStyle(Swiss.alert)
      }
    case .minutes(let s):
      Text(s).font(.system(size: size * 0.78, design: .monospaced)).foregroundStyle(Swiss.ink)
        .contentTransition(.numericText(countsDown: true))
        .padding(.horizontal, size * 0.18)
        .padding(.bottom, size * 0.08)
        .overlay(Bracket(radius: size * 0.3).stroke(Swiss.ink, lineWidth: stroke))
    case .arrow:
      Image(systemName: "arrow.right").font(.system(size: size * 0.7, weight: .medium))
        .foregroundStyle(Swiss.onInk)
        .padding(.horizontal, size * 0.32)
        .frame(height: height)
        .background(Swiss.ink, in: Capsule())
    case .talk:
      Capsule().strokeBorder(Swiss.ink, lineWidth: stroke)
        .frame(width: size * 1.25, height: size * 0.9)
        .overlay {
          HStack(spacing: size * 0.12) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Swiss.ink).frame(width: size * 0.13) } }
        }
    case .clock:
      ClockGlyph().stroke(Swiss.ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        .frame(width: size * 0.9, height: size * 0.9)
    case .check:
      Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: height, height: height)
        .background(Swiss.signal, in: Circle())
    }
  }
}

/// The left and bottom edges of a box with a rounded corner: "⌊18 MIN".
nonisolated struct Bracket: Shape {
  var radius: CGFloat
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return p
  }
}

nonisolated struct ClockGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5))
    let c = CGPoint(x: rect.midX, y: rect.midY)
    p.move(to: c); p.addLine(to: CGPoint(x: c.x, y: rect.minY + rect.height * 0.2))
    p.move(to: c); p.addLine(to: CGPoint(x: c.x + rect.width * 0.24, y: c.y))
    return p
  }
}

/// A key message the dashboard can show in its last line, with where a tap goes.
struct KeyMessage: Identifiable, Equatable {
  let id: String
  let tokens: [RebusToken]
  var action: (() -> Void)?
  static func == (a: KeyMessage, b: KeyMessage) -> Bool { a.id == b.id && a.tokens == b.tokens }
}

/// The top of a dashboard: the day, the figure, what it is and a key message.
struct OneSentenceTop: View {
  let figure: String
  let detail: [RebusToken]
  var messages: [KeyMessage] = []
  var lead: [RebusToken]?
  /// Off when the page shows the date elsewhere (the feed has it in its top bar).
  var showsDate = true
  @ScaledMetric var size: CGFloat
  @ScaledMetric var figureSize: CGFloat
  @State private var messageIndex = 0
  @State private var figureShown = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  init(
    figure: String, detail: [RebusToken], messages: [KeyMessage] = [], lead: [RebusToken]? = nil, showsDate: Bool = true,
    size: CGFloat, figureSize: CGFloat
  ) {
    self.showsDate = showsDate
    self.figure = figure
    self.detail = detail
    self.messages = messages
    self.lead = lead
    _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    _figureSize = ScaledMetric(wrappedValue: figureSize, relativeTo: .largeTitle)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: size * 0.5) {
      if let lead {
        RebusLine(tokens: lead, size: size, delay: 0.2)
      } else if showsDate {
        TimelineView(.everyMinute) { context in
          RebusLine(tokens: Self.dateTokens(context.date), size: size, delay: 0.2)
        }
      }
      figureText
        .font(.system(size: figureSize, weight: .light, design: .monospaced))
        .tracking(-figureSize * 0.03)
        .foregroundStyle(Swiss.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentTransition(.numericText())
        .opacity(figureShown ? 1 : 0)
        .offset(y: figureShown || reduceMotion ? 0 : figureSize * 0.3)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.5), value: figureShown)
        .afterLaunch { figureShown = true }
      RebusLine(tokens: detail, size: size, delay: 0.9)
      if let message = messages.isEmpty ? nil : messages[messageIndex % messages.count] {
        Group {
          // Only messages that open something are buttons; the rest are plain words.
          if let action = message.action {
            Button(action: action) { RebusLine(tokens: message.tokens, size: size, delay: 1.3) }
              .buttonStyle(.plain)
          } else {
            RebusLine(tokens: message.tokens, size: size, delay: 1.3)
          }
        }
        .id(message.id)
        .transition(
          reduceMotion ? .opacity
            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
      }
    }
    .clipped()
    .animation(.easeInOut(duration: 0.35), value: messageIndex)
    // Several messages take turns in the last line.
    .task(id: messages.map(\.id)) {
      guard messages.count > 1 else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(7))
        messageIndex += 1
      }
    }
  }

  /// The figure in mono with narrower gaps: a full mono space between digit groups reads as a
  /// hole, so the groups sit in a row with a fixed gap instead.
  var figureText: some View {
    let parts = figure.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
    return HStack(alignment: .firstTextBaseline, spacing: figureSize * 0.24) {
      ForEach(Array(parts.enumerated()), id: \.offset) { index, part in BoardRollText(text: part, delay: 0.5 + Double(index) * 0.08) }
    }
  }

  /// "MON (19) (OCT) 11:42"
  static func dateTokens(_ date: Date) -> [RebusToken] {
    let weekday = date.formatted(.dateTime.weekday(.abbreviated)).uppercased().replacingOccurrences(of: ".", with: "")
    let day = date.formatted(.dateTime.day())
    let month = date.formatted(.dateTime.month(.abbreviated)).uppercased().replacingOccurrences(of: ".", with: "")
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    return [.word(weekday), .number(day), .pill(month), .word(time)]
  }
}

extension RebusToken {
  /// A short upper-case name for a meeting or deal in a key message.
  static func name(_ s: String, max: Int = 24) -> RebusToken {
    let up = s.uppercased()
    return .word(up.count > max ? String(up.prefix(max - 1)) + "…" : up)
  }
}

/// The order a page comes in: the sentence types in first (0.2–1.3 s), then the page's controls,
/// its one colour panel, and the list, item by item.
enum Entrance {
  static let controls = 0.7
  static let panel = 0.85
  static let list = 1.0
  static let step = 0.05
  /// About a screenful of rows; later rows skip the entrance.
  static let rowsInWave = 8
}

private struct EntranceModifier: ViewModifier {
  let delay: Double
  var quick = false
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : (quick ? 8 : 14))
      .animation(
        (quick ? Animation.spring(response: 0.22, dampingFraction: 0.9) : .spring(response: 0.45, dampingFraction: 0.85))
          .delay(min(delay, 1.6)), value: shown)
      .afterLaunch { shown = true }
  }
}

extension View {
  /// Fades and rises in after `delay` seconds, once, when the page appears.
  func entrance(_ delay: Double, quick: Bool = false) -> some View { modifier(EntranceModifier(delay: delay, quick: quick)) }

  /// A row of a list in the opening wave: the first screenful rises in one after another.
  /// Rows further down appear as they are, so scrolling never meets rows still fading in.
  @ViewBuilder
  func entrance(row index: Int) -> some View {
    if index < Entrance.rowsInWave { entrance(Entrance.list + Double(index) * Entrance.step) } else { self }
  }

  /// A floating sheet (deal, lead, client on the Mac) slides in from the right and settles.
  func overlayEntrance(from edge: Edge = .trailing) -> some View { modifier(OverlayEntrance(edge: edge)) }
}

/// A figure whose digits roll through random digits and settle left to right, like the dot
/// board, when it first appears.
struct BoardRollText: View {
  let text: String
  var delay: Double = 0.5
  @State private var start: Date?
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  static let glyphTime = 0.05

  var body: some View {
    TimelineView(.animation(paused: start == nil)) { context in
      Text(shown(at: context.date))
    }
    .afterLaunch {
      guard !reduceMotion else { return }
      start = Date().addingTimeInterval(delay)
    }
    .task(id: start) {
      guard start != nil else { return }
      try? await Task.sleep(for: .seconds(delay + Double(rollLength(text.count)) * Self.glyphTime + 0.1))
      start = nil
    }
  }

  func rollLength(_ index: Int) -> Int { 5 + index }

  func shown(at date: Date) -> String {
    guard let start else { return text }
    let t = date.timeIntervalSince(start)
    guard t >= 0 else { return String(text.map { $0.isNumber ? "0" : $0 }) }
    var digitIndex = 0
    return String(text.map { ch -> Character in
      guard ch.isNumber else { return ch }
      defer { digitIndex += 1 }
      let step = Int(t / Self.glyphTime)
      guard step < rollLength(digitIndex) else { return ch }
      let hash = (digitIndex &* 7919 &+ step &* 104_729 &+ 31) % 9973
      return Character("\(hash % 10)")
    })
  }
}

struct OverlayEntrance: ViewModifier {
  var edge: Edge = .trailing
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(
        x: shown || reduceMotion ? 0 : edge == .trailing ? 36 : edge == .leading ? -36 : 0,
        y: shown || reduceMotion ? 0 : edge == .top ? -14 : edge == .bottom ? 14 : 0)
      .scaleEffect(shown || reduceMotion ? 1 : edge == .top ? 0.97 : 0.985, anchor: edge == .top ? .top : .trailing)
      .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true } }
  }
}

extension AnyTransition {
  /// The deal sheet leaves with a quick slide and fade; it comes in with `overlayEntrance`.
  static var overlaySheet: AnyTransition {
    .asymmetric(insertion: .identity, removal: .offset(x: 24).combined(with: .opacity))
  }
}
