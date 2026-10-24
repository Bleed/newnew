import SwiftUI

// Atelier's 5×7 dot-matrix face (from Atelier CRM) for live details: the clock, source counts
// and the new-stories figure. It flips like an airport board when its value changes.
//
// Only inside a container (a pill, a key chip, a colour panel), never loose on the page and
// never for warnings: those stay in SF Pro.

enum DotFont {
  /// Rows top to bottom, five columns each.
  private static let source: [Character: String] = [
    "0": "01110100011001110101110011000101110", "1": "00100011000010000100001000010001110",
    "2": "01110100010000100010001000100011111", "3": "11111000100010000010000011000101110",
    "4": "00010001100101010010111110001000010", "5": "11111100001111000001000011000101110",
    "6": "00110010001000011110100011000101110", "7": "11111000010001000100010000100001000",
    "8": "01110100011000101110100011000101110", "9": "01110100011000101111000010001001100",
    "A": "01110100011000111111100011000110001", "B": "11110100011000111110100011000111110",
    "C": "01110100011000010000100001000101110", "D": "11100100101000110001100011001011100",
    "E": "11111100001000011110100001000011111", "F": "11111100001000011110100001000010000",
    "G": "01110100011000010111100011000101111", "H": "10001100011000111111100011000110001",
    "I": "01110001000010000100001000010001110", "J": "00111000100001000010000101001001100",
    "K": "10001100101010011000101001001010001", "L": "10000100001000010000100001000011111",
    "M": "10001110111010110101100011000110001", "N": "10001110011010110011100011000110001",
    "O": "01110100011000110001100011000101110", "P": "11110100011000111110100001000010000",
    "Q": "01110100011000110001101011001001101", "R": "11110100011000111110101001001010001",
    "S": "01111100001000001110000010000111110", "T": "11111001000010000100001000010000100",
    "U": "10001100011000110001100011000101110", "V": "10001100011000110001100010101000100",
    "W": "10001100011000110101101011010101010", "X": "10001100010101000100010101000110001",
    "Y": "10001100010101000100001000010000100", "Z": "11111000010001000100010001000011111",
    ":": "00000011000110000000011000110000000", "·": "00000000000000000100000000000000000",
    ".": "00000000000000000000000000110001100", ",": "00000000000000000000001100010001000",
    "/": "00001000010001000100010001000010000", "%": "11000110010001000100010001001100011",
    "-": "00000000000000011111000000000000000", "+": "00000001000010011111001000010000000",
    "?": "01110100010000100010001000000000100", "!": "00100001000010000100001000000000100",
    "'": "00100001000100000000000000000000000",
    // Lower case for the wordmark ("newnew").
    "a": "00000000000111000001011111000101111", "t": "01000010001110001000010000100100110",
    "e": "00000000000111010001111111000001110", "l": "01100001000010000100001000010001110",
    "i": "00100000000110000100001000010001110", "r": "00000000001011011001100001000010000",
    "s": "00000000000111010000011100000111110", "u": "00000000001000110001100011001101101",
    "d": "00001000010110110011100011000101111", "o": "00000000000111010001100011000101110",
    "n": "00000000001011011001100011000110001", "w": "00000000001000110001101011010101010",
  ]

  static let glyphs: [Character: [Bool]] = source.mapValues { $0.map { $0 == "1" } }
  static let digits = Array("0123456789")
  static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  /// The lower-case letters drawn here, for words that roll in lower case.
  static let lowercase = Array("atelirsudonw")

  /// Upper case, with any space (including the narrow no-break space in "550 000") as a gap.
  /// Upper case, except a word written all in the lower-case letters drawn here ("newnew").
  static func normalized(_ text: String) -> [Character] {
    let keepsCase = text.contains(where: \.isLetter) && text.allSatisfy { !$0.isLetter || ($0.isLowercase && glyphs[$0] != nil) }
    return (keepsCase ? text : text.uppercased()).map { $0.isWhitespace || $0 == "_" ? " " : $0 }
  }

  static func isLit(_ character: Character, row: Int, column: Int) -> Bool {
    glyphs[character]?[row * 5 + column] ?? false
  }
}

/// Text in the 5×7 dot face. `pitch` is the distance between dots; a glyph is 5 × 7 pitches
/// with one pitch between glyphs. `unlit` shows the dark dots faintly, like a real board.
struct DotText: View {
  enum Motion {
    /// Changes appear at once.
    case none
    /// Changed glyphs flip once, rows top to bottom: for small things (clock, counts).
    case flip
    /// Changed glyphs roll through random glyphs and settle left to right: for big figures.
    case roll
  }

  let text: String
  var unlit: Double = 0
  var motion: Motion = .flip
  /// Roll in from blank the first time it appears (big figures only).
  var rollsIn = false
  @ScaledMetric var scaledPitch: CGFloat
  /// Off when the dots must line up with a fixed grid behind them (dot boards, the launch).
  var scales = true
  /// The launch board's own clock: roll in from blank, timed from `start`, drawn at `now`, so
  /// the roll is timed from the moment the board appears.
  var clock: (start: Date, now: Date)?
  let basePitch: CGFloat
  @Environment(\.displayScale) var displayScale
  /// Small dots (key chips, clocks, counts) snap to whole pixels so they stay crisp instead of
  /// blurring into each other.
  var pitch: CGFloat {
    let raw = scales ? scaledPitch : basePitch
    guard raw < 3, displayScale > 0 else { return raw }
    return max(2, (raw * displayScale).rounded()) / displayScale
  }
  var dotSize: CGFloat {
    guard pitch < 3, displayScale > 0 else { return pitch * 0.82 }
    return max(1, (pitch * displayScale * 0.7).rounded()) / displayScale
  }
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var from: [Character] = []
  @State private var start: Date?

  init(
    _ text: String, pitch: CGFloat = 1.8, unlit: Double = 0, motion: Motion = .flip, rollsIn: Bool = false, scales: Bool = true,
    clock: (start: Date, now: Date)? = nil
  ) {
    self.scales = scales
    self.clock = clock
    self.basePitch = pitch
    self.text = text
    self.unlit = unlit
    self.motion = motion
    self.rollsIn = rollsIn
    _scaledPitch = ScaledMetric(wrappedValue: pitch, relativeTo: .body)
  }

  static let rowDelay = 0.014
  static let glyphTime = 0.06

  var target: [Character] { DotFont.normalized(text) }

  var body: some View {
    let glyphs = target
    let width = max(CGFloat(glyphs.count) * pitch * 6 - pitch, pitch)
    Group {
      if let clock {
        Canvas { ctx, _ in draw(&ctx, glyphs: glyphs, at: clock.now, since: reduceMotion ? nil : clock.start) }
      } else if let start {
        // A running timeline only while rolling: un-pausing one in place didn't start it
        // ticking on the Mac.
        TimelineView(.animation) { context in
          Canvas { ctx, _ in draw(&ctx, glyphs: glyphs, at: context.date, since: start) }
        }
      } else {
        Canvas { ctx, _ in draw(&ctx, glyphs: glyphs, at: .now, since: nil) }
      }
    }
    .frame(width: width, height: pitch * 7 - pitch * 0.18)
    .onChange(of: text) { old, _ in
      guard motion != .none, !reduceMotion else { return }
      begin(from: DotFont.normalized(old))
    }
    .afterLaunch {
      guard rollsIn, clock == nil, !reduceMotion else { return }
      begin(from: Array(repeating: " ", count: target.count))
    }
    .task(id: start) {
      guard start != nil else { return }
      try? await Task.sleep(for: .seconds(duration))
      start = nil
    }
    .accessibilityElement()
    .accessibilityLabel(text)
  }

  func begin(from old: [Character]) {
    // Right-aligned, so "980 000" → "1 020 000" lines its digits up.
    let count = target.count
    let padded = Array(repeating: Character(" "), count: max(0, count - old.count)) + old.suffix(count)
    from = padded
    start = .now
  }

  var duration: Double {
    let rows = 7 * Self.rowDelay
    switch motion {
    case .none: return 0
    case .flip: return Double(target.count) * 0.02 + rows + 0.05
    case .roll: return Double(rollLength(target.count - 1) + 1) * Self.glyphTime + rows + 0.05
    }
  }

  func rollLength(_ index: Int) -> Int { 4 + index * 2 }

  /// What one cell shows on one row at `elapsed` seconds into the change.
  func glyph(_ index: Int, row: Int, elapsed: Double, to: Character) -> Character {
    let old = index < from.count ? from[index] : " "
    guard old != to else { return to }
    let t = elapsed - Double(row) * Self.rowDelay
    switch motion {
    case .none: return to
    case .flip: return t < Double(index) * 0.02 ? old : to
    case .roll:
      guard t >= 0 else { return old }
      let step = Int(t / Self.glyphTime)
      guard step < rollLength(index) else { return to }
      let pool = to.isNumber || to == " " ? DotFont.digits : to.isLowercase ? DotFont.lowercase : DotFont.letters
      // Stable per cell and step, so every row of a cell shows the same glyph.
      let hash = (index &* 7919 &+ step &* 104_729 &+ 31) % 9973
      return pool[hash % pool.count]
    }
  }

  func draw(_ ctx: inout GraphicsContext, glyphs: [Character], at date: Date, since start: Date?) {
    let size = dotSize
    let elapsed = start.map { date.timeIntervalSince($0) }
    for (index, character) in glyphs.enumerated() {
      let x0 = CGFloat(index) * pitch * 6
      for row in 0..<7 {
        let shown = elapsed.map { glyph(index, row: row, elapsed: $0, to: character) } ?? character
        for column in 0..<5 {
          let lit = DotFont.isLit(shown, row: row, column: column)
          guard lit || unlit > 0 else { continue }
          let rect = CGRect(x: x0 + CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: size, height: size)
          var dot = ctx
          dot.opacity = lit ? 1 : unlit
          dot.fill(Path(ellipseIn: rect), with: .foreground)
        }
      }
    }
  }
}

/// Local time in a quiet pill: "11:42 · OSLO". The colon blinks; the minute flips.
struct ClockPill: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      let date = context.date
      let blink = Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 1
      DotText(Self.text(date, colon: !blink), pitch: 1.8)
        .accessibilityLabel("Local time \(date.formatted(date: .omitted, time: .shortened)), \(Self.city)")
    }
    // Full-strength dots: grey ones vanish on glass and on dark backgrounds.
    .foregroundStyle(Swiss.ink)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Swiss.ink.opacity(0.1), in: Capsule())
    .fixedSize()
  }

  static var city: String {
    TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
  }

  static func text(_ date: Date, colon: Bool) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    let time = String(format: "%02d%@%02d", parts.hour ?? 0, colon ? ":" : " ", parts.minute ?? 0)
    return city.isEmpty ? time : "\(time) · \(city)"
  }
}

/// A dot board: the whole width is a grid of faint dots and the text's dots are lit on it,
/// rolling like a departures board when the value changes. The pitch shrinks to fit narrow
/// widths.
struct DotBoard: View {
  let text: String
  var pitch: CGFloat
  var rows = 9
  var unlit = 0.1

  var body: some View {
    GeometryReader { proxy in
      let glyphs = DotFont.normalized(text).count
      // A zero or unbounded width during layout must not divide by zero.
      let width = proxy.size.width.isFinite ? max(proxy.size.width, 0) : 0
      let fitted = max(min(pitch, width / CGFloat(max(glyphs * 6, 1))), 0.5)
      let cols = max(Int((width + fitted * 0.18) / fitted), 0)
      ZStack(alignment: .topLeading) {
        Canvas { ctx, _ in
          let d = fitted * 0.82
          var dots = ctx
          dots.opacity = unlit
          for r in 0..<rows { for c in 0..<cols {
            dots.fill(Path(ellipseIn: CGRect(x: CGFloat(c) * fitted, y: CGFloat(r) * fitted, width: d, height: d)), with: .foreground)
          } }
        }
        DotText(text, pitch: fitted, motion: .roll, rollsIn: true, scales: false)
          .offset(y: fitted)
      }
    }
    .frame(height: pitch * CGFloat(rows) - pitch * 0.18)
  }
}

/// Shown once when the app opens: a narrow dot band through the middle of a white screen, as
/// tall as the top panel's board and at the same dot density as the app's numbers, with
/// "newnew" rolling in on one line: grey dots, the letters almost black.
/// It holds a beat and fades away; a tap skips it.
struct LaunchBoard: View {
  @Binding var isShowing: Bool
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var faded = false
  @State private var start = Date()

  /// Once per launch, not every time the window is reopened.
  @MainActor static var hasPlayed = false

  static let text = Array("newnew")
  /// Board rows, as on the top panel (7 for the glyph, one above and below).
  static let rows = 9
  static let ink = Color.adaptive(light: 0x1E1E1E, dark: 0xEDEDED)
  static let boardPitch: CGFloat = 5

  var body: some View {
    GeometryReader { proxy in
      let textCols = Self.text.count * 6 - 1
      // The top panel's pitch, shrunk only if the line wouldn't fit.
      let pitch = min(proxy.size.width * 0.9 / CGFloat(textCols), Self.boardPitch)
      let cols = Int(proxy.size.width / pitch)
      let bandHeight = CGFloat(Self.rows) * pitch
      let ox = (proxy.size.width - CGFloat(cols - 1) * pitch) / 2
      let oy = (proxy.size.height - bandHeight) / 2 + pitch / 2
      let startCol = (cols - textCols) / 2
      let d = pitch * 0.82
      ZStack(alignment: .topLeading) {
        Swiss.canvas
        // The faint band; the word rolls in on it with the same roll as the numbers and the
        // onboarding welcome.
        Canvas { ctx, _ in
          for r in 0..<Self.rows { for c in 0..<cols {
            let rect = CGRect(x: ox + CGFloat(c) * pitch - d / 2, y: oy + CGFloat(r) * pitch - d / 2, width: d, height: d)
            ctx.fill(Path(ellipseIn: rect), with: .color(Swiss.ink.opacity(0.1)))
          } }
        }
        TimelineView(.animation(paused: reduceMotion)) { context in
          DotText(String(Self.text), pitch: pitch, motion: .roll, scales: false, clock: (start.addingTimeInterval(0.2), context.date))
            .foregroundStyle(Self.ink)
        }
        .offset(x: ox + CGFloat(startCol) * pitch - d / 2, y: oy + pitch - d / 2)
      }
    }
    .ignoresSafeArea()
    .opacity(faded ? 0 : 1)
    .contentShape(Rectangle())
    .onTapGesture { finish() }
    .accessibilityElement()
    .accessibilityLabel("Newnew")
    .task {
      Self.hasPlayed = true
      start = Date()
      // The roll settles in just over a second; then a short hold before fading.
      try? await Task.sleep(for: .seconds(reduceMotion ? 0.8 : 2.3))
      finish()
    }
  }

  func finish() {
    guard !faded else { return }
    withAnimation(.easeOut(duration: 0.35)) { faded = true } completion: {
      isShowing = false
      LaunchState.shared.isShowing = false
    }
  }
}

/// Whether the launch board is still up: pages hold their entrances and number rolls until it
/// has faded, so they play where you can see them.
@MainActor @Observable final class LaunchState {
  static let shared = LaunchState()
  var isShowing = false
}

extension View {
  /// Runs `action` when the view appears, or once the launch board has gone if it's still up.
  func afterLaunch(_ action: @escaping () -> Void) -> some View {
    onAppear { if !LaunchState.shared.isShowing { action() } }
      .onChange(of: LaunchState.shared.isShowing) { _, showing in if !showing { action() } }
  }
}

/// A count or short label in the dot face, inside a quiet pill: "5 SOURCES".
struct DotChip: View {
  let text: String
  var label: String?
  init(_ text: String, label: String? = nil) {
    self.text = text
    self.label = label
  }

  var body: some View {
    DotText(text, pitch: 1.6)
      // Full-strength dots: grey ones vanish on tiles and in dark mode.
      .foregroundStyle(Swiss.ink)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(Swiss.ink.opacity(0.07), in: Capsule())
      .fixedSize()
      .accessibilityLabel(label ?? text)
  }
}
