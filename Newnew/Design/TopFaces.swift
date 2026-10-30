import SwiftUI

// Today's top in other faces, chosen in Settings › Look (Figma: Explorations · LCD, P and V).
// Blocks is the default.

/// How Today's top is drawn.
enum TopLook: String, CaseIterable, Identifiable {
  /// What's new in a heavy block face across the full width, a one-size mono rebus around it
  /// (Figma V and AE). The default.
  case blocks
  /// The dot board on its tile (Figma: Explorations · header, C).
  case dots
  /// The same board in a 14-segment LCD face, unlit segments showing (Figma P).
  case lcd

  static let key = "topLook"
  var id: String { rawValue }
  var label: String {
    switch self {
    case .dots: "Dots"
    case .lcd: "LCD"
    case .blocks: "Blocks"
    }
  }
  var detail: String {
    switch self {
    case .dots: "A small departures board: the day, the count and what's new in dots."
    case .lcd: "The same board as a liquid-crystal display, the unlit segments faintly showing."
    case .blocks: "What's new in big blocks across the top, the rest as a rebus in mono."
    }
  }
}

/// What `DotText` draws its cells as.
enum BoardFace { case dots, lcd }

extension EnvironmentValues {
  @Entry var boardFace: BoardFace = .dots
}

// MARK: LCD

/// A 14-segment LCD face drawn in the dot face's cells (5 × 7 pitches), so a board keeps its
/// layout and its departures-board timing when it changes face. Segments: a top, b c right,
/// d bottom, e f left, g1 g2 the middle, h j the upper diagonals, i l the centre verticals,
/// k m the lower diagonals; U L the colon's dots, C a centre dot, P a full stop.
enum LCDFont {
  enum Segment: CaseIterable { case a, b, c, d, e, f, g1, g2, h, i, j, k, l, m, upper, lower, centre, stop }

  static let bars: [Segment] = [.a, .b, .c, .d, .e, .f, .g1, .g2, .h, .i, .j, .k, .l, .m]

  private static let source: [Character: String] = [
    "0": "abcdefjk", "1": "bcj", "2": "abdeg1g2", "3": "abcdg2", "4": "bcfg1g2", "5": "acdfg1g2", "6": "acdefg1g2",
    "7": "abc", "8": "abcdefg1g2", "9": "abcdfg1g2",
    "A": "abcefg1g2", "B": "abcdg2il", "C": "adef", "D": "abcdil", "E": "adefg1", "F": "aefg1", "G": "acdefg2",
    "H": "bcefg1g2", "I": "adil", "J": "bcde", "K": "efg1jm", "L": "def", "M": "bcefhj", "N": "bcefhm", "O": "abcdef",
    "P": "abefg1g2", "Q": "abcdefm", "R": "abefg1g2m", "S": "acdfg1g2", "T": "ail", "U": "bcdef", "V": "efjk",
    "W": "bcefkm", "X": "hjkm", "Y": "hjl", "Z": "adjk",
    ":": "UL", "·": "C", ".": "P", ",": "k", "/": "jk", "%": "cfjk", "-": "g1g2", "+": "g1g2il", "?": "abg2l",
    "!": "iP", "'": "i",
  ]

  static let glyphs: [Character: Set<Segment>] = source.mapValues { code in
    var out: Set<Segment> = []
    var chars = Array(code)[...]
    while let first = chars.popFirst() {
      switch first {
      case "g": out.insert(chars.popFirst() == "1" ? .g1 : .g2)
      case "U": out.insert(.upper)
      case "L": out.insert(.lower)
      case "C": out.insert(.centre)
      case "P": out.insert(.stop)
      default:
        if let segment = Segment.allCases.first(where: { "\($0)" == String(first) }) { out.insert(segment) }
      }
    }
    return out
  }

  static func segments(_ character: Character) -> Set<Segment> {
    glyphs[character] ?? glyphs[Character(character.uppercased())] ?? []
  }

  /// One segment in a cell `width` × `height`, bars `t` thick, chamfered ends.
  static func path(_ segment: Segment, width w: CGFloat, height h: CGFloat, thickness t: CGFloat) -> Path {
    let g = t * 0.32
    let xm = w / 2, ym = h / 2
    func horizontal(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) -> Path {
      Path { p in
        p.addLines([CGPoint(x: x0, y: y), CGPoint(x: x0 + t / 2, y: y - t / 2), CGPoint(x: x1 - t / 2, y: y - t / 2),
                    CGPoint(x: x1, y: y), CGPoint(x: x1 - t / 2, y: y + t / 2), CGPoint(x: x0 + t / 2, y: y + t / 2)])
        p.closeSubpath()
      }
    }
    func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
      Path { p in
        p.addLines([CGPoint(x: x, y: y0), CGPoint(x: x + t / 2, y: y0 + t / 2), CGPoint(x: x + t / 2, y: y1 - t / 2),
                    CGPoint(x: x, y: y1), CGPoint(x: x - t / 2, y: y1 - t / 2), CGPoint(x: x - t / 2, y: y0 + t / 2)])
        p.closeSubpath()
      }
    }
    func diagonal(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
      Path { p in p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1)) }
        .strokedPath(StrokeStyle(lineWidth: t * 0.8, lineCap: .butt))
    }
    func dot(_ y: CGFloat) -> Path { Path(CGRect(x: xm - t / 2, y: y - t / 2, width: t, height: t)) }
    let left = t / 2, right = w - t / 2, top = t / 2, bottom = h - t / 2
    let inner = t * 1.25
    switch segment {
    case .a: return horizontal(top, left + g, right - g)
    case .d: return horizontal(bottom, left + g, right - g)
    case .g1: return horizontal(ym, left + g, xm - g)
    case .g2: return horizontal(ym, xm + g, right - g)
    case .f: return vertical(left, top + g, ym - g)
    case .e: return vertical(left, ym + g, bottom - g)
    case .b: return vertical(right, top + g, ym - g)
    case .c: return vertical(right, ym + g, bottom - g)
    case .i: return vertical(xm, top + g, ym - g)
    case .l: return vertical(xm, ym + g, bottom - g)
    case .h: return diagonal(inner, inner, xm - t * 0.75, ym - t * 0.75)
    case .j: return diagonal(w - inner, inner, xm + t * 0.75, ym - t * 0.75)
    case .k: return diagonal(xm - t * 0.75, ym + t * 0.75, inner, h - inner)
    case .m: return diagonal(xm + t * 0.75, ym + t * 0.75, w - inner, h - inner)
    case .upper: return dot(h * 0.3)
    case .lower: return dot(h * 0.7)
    case .centre: return dot(ym)
    case .stop: return dot(bottom)
    }
  }

  /// One glyph's lit segments (and the unlit bars, faint), at `origin` in a cell.
  static func draw(
    _ character: Character, in ctx: inout GraphicsContext, origin: CGPoint, width: CGFloat, height: CGFloat, unlit: Double
  ) {
    let t = max(width * 0.17, 0.9)
    let lit = segments(character)
    var on = Path(), off = Path()
    for segment in Segment.allCases {
      let shape = path(segment, width: width, height: height, thickness: t)
        .applying(CGAffineTransform(translationX: origin.x, y: origin.y))
      if lit.contains(segment) { on.addPath(shape) } else if bars.contains(segment) { off.addPath(shape) }
    }
    if unlit > 0 {
      var faint = ctx
      faint.opacity = unlit
      faint.fill(off, with: .foreground)
    }
    ctx.fill(on, with: .foreground)
  }
}

// MARK: Blocks

/// A heavy display face: every glyph a solid square cut by hairline slits and notches (Figma:
/// "Block face · specimen"). Units: a 10 × 10 cell, I and 1 narrower. Big only: below about
/// 40 pt the slits close up.
enum BlockFont {
  enum Cut {
    case rect(CGFloat, CGFloat, CGFloat, CGFloat)
    case polygon([CGPoint])
  }

  static let slit: CGFloat = 0.5
  static func across(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) -> Cut { .rect(x0, y - slit / 2, x1, y + slit / 2) }
  static func down(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Cut { .rect(x - slit / 2, y0, x + slit / 2, y1) }
  static func poly(_ points: (CGFloat, CGFloat)...) -> Cut { .polygon(points.map { CGPoint(x: $0.0, y: $0.1) }) }

  static let glyphs: [Character: [Cut]] = [
    "A": [across(4, 3, 7), down(5, 6.5, 10), poly((0, 0), (2, 0), (0, 2))], "B": [across(3.3, 3, 7.5), across(6.7, 3, 7.5)],
    "C": [across(5, 4, 10)], "D": [across(5, 3, 7)], "E": [across(3.3, 4, 10), across(6.7, 4, 10)],
    "F": [across(3.3, 4, 10), .rect(4, 6.5, 10, 10)], "G": [across(3.5, 4, 10), across(6.5, 4.5, 7.5)],
    "H": [down(5, 0, 3.6), down(5, 6.4, 10)], "I": [], "J": [across(6.5, 0, 6), .rect(0, 0, 3, 3.5)],
    "K": [poly((10, 2.6), (5.6, 5), (10, 7.4)), down(5, 0, 2.5)], "L": [.rect(4, 0, 10, 6.5)],
    "M": [down(3.3, 4, 10), down(6.7, 4, 10)], "N": [down(6, 0, 6), down(4, 4, 10)], "O": [down(5, 3, 7)],
    "P": [across(3.3, 3, 7), .rect(4, 6.7, 10, 10)], "Q": [down(5, 3, 6.5), poly((10, 7), (7, 10), (10, 10))],
    "R": [across(3.3, 3, 7), down(5, 6.7, 10), poly((10, 7.5), (8, 10), (10, 10))], "S": [across(3.3, 3, 10), across(6.7, 0, 7)],
    "T": [.rect(0, 3.6, 3.6, 10), .rect(6.4, 3.6, 10, 10)], "U": [down(5, 0, 7)],
    "V": [down(5, 0, 6), poly((0, 7), (3, 10), (0, 10)), poly((10, 7), (7, 10), (10, 10))], "W": [down(3.3, 0, 6), down(6.7, 0, 6)],
    "X": [poly((3.6, 0), (5, 2.8), (6.4, 0)), poly((3.6, 10), (5, 7.2), (6.4, 10)), poly((0, 3.6), (2.8, 5), (0, 6.4)), poly((10, 3.6), (7.2, 5), (10, 6.4))],
    "Y": [down(5, 0, 3.6), .rect(0, 6.4, 3.6, 10), .rect(6.4, 6.4, 10, 10)], "Z": [across(3.3, 0, 7), across(6.7, 3, 10)],
    // The 1 carries a foot on the right, so it doesn't read as a J.
    "0": [down(5, 3, 7), poly((3.5, 7), (4, 7), (6.5, 3), (6, 3))], "1": [.rect(0, 0, 2.5, 7.5), .rect(0, 7.5, 1.5, 10)],
    "2": [across(3.3, 0, 7), across(6.7, 3, 10)], "3": [across(3.3, 0, 7), across(6.7, 0, 7)], "4": [down(5, 0, 4), .rect(0, 6.5, 6, 10)],
    "5": [across(3.3, 3, 10), across(6.7, 0, 7)], "6": [across(3.3, 3, 10), across(6.7, 3, 7)], "7": [.rect(0, 3.6, 5, 10)],
    "8": [across(3.3, 3, 7), across(6.7, 3, 7)], "9": [across(3.3, 3, 7), across(6.7, 0, 7)],
  ]
  static let letters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
  static let digits = Array("0234567890")
  static let gap: CGFloat = 0.35
  static let space: CGFloat = 3

  static func width(_ character: Character) -> CGFloat {
    character == " " ? space : character == "I" ? 4 : character == "1" ? 6 : 10
  }

  /// The whole text's width in cell units.
  static func width(_ text: [Character]) -> CGFloat {
    text.isEmpty ? 10 : text.map(width).reduce(0, +) + gap * CGFloat(text.count - 1)
  }

  /// One glyph, `unit` points per cell unit, at `x`.
  static func path(_ character: Character, x: CGFloat, unit: CGFloat) -> Path {
    guard character != " " else { return Path() }
    let w = width(character), scale = w / 10
    var path = Path(CGRect(x: 0, y: 0, width: w, height: 10))
    for cut in glyphs[character] ?? [] {
      switch cut {
      case .rect(let x0, let y0, let x1, let y1): path.addRect(CGRect(x: x0 * scale, y: y0, width: (x1 - x0) * scale, height: y1 - y0))
      case .polygon(let points): path.addLines(points.map { CGPoint(x: $0.x * scale, y: $0.y) }); path.closeSubpath()
      }
    }
    return path.applying(CGAffineTransform(scaleX: unit, y: unit).concatenating(CGAffineTransform(translationX: x, y: 0)))
  }
}

/// Text in the block face, as wide as it's given (up to `maxHeight` tall). It arrives like the
/// dot face: a departures board, cells 0.025 s apart left to right, each rolling through
/// random blocks (a new one every 0.06 s) before it settles; a new text arrives the same way.
struct BlockText: View {
  let text: String
  var maxHeight: CGFloat = 120
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start: Date?
  @State private var launched = false

  var glyphs: [Character] { Array(DotFont.boardText(text).filter { $0 == " " || BlockFont.glyphs[$0] != nil }) }

  var duration: Double {
    let last = max(glyphs.count - 1, 0)
    return Double(last) * DotText.decodeStagger + Double(steps(last)) * DotText.decodeStepTime + 0.05
  }
  func steps(_ index: Int) -> Int { 4 + Int(Double(index) * 0.4) }

  var body: some View {
    let glyphs = glyphs
    let units = BlockFont.width(glyphs)
    Group {
      if let start {
        TimelineView(.animation) { context in
          Canvas { ctx, size in draw(&ctx, size: size, glyphs: glyphs, elapsed: context.date.timeIntervalSince(start)) }
        }
      } else {
        Canvas { ctx, size in draw(&ctx, size: size, glyphs: glyphs, elapsed: launched || reduceMotion ? nil : -1) }
      }
    }
    .aspectRatio(units / 10, contentMode: .fit)
    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
    .afterLaunch {
      guard !launched else { return }
      launched = true
      if !reduceMotion { start = .now }
    }
    .onChange(of: text) {
      if !reduceMotion { start = .now }
    }
    .task(id: start) {
      guard start != nil else { return }
      try? await Task.sleep(for: .seconds(duration))
      start = nil
    }
    .accessibilityElement()
    .accessibilityLabel(text.lowercased())
  }

  /// `elapsed` nil: settled; negative: before the entrance, nothing shown.
  func draw(_ ctx: inout GraphicsContext, size: CGSize, glyphs: [Character], elapsed: Double?) {
    let unit = size.height / 10
    var x: CGFloat = 0
    var path = Path()
    for (index, character) in glyphs.enumerated() {
      var shown: Character? = character
      if let elapsed, character != " " {
        let t = elapsed - Double(index) * DotText.decodeStagger
        if t < 0 { shown = nil } else {
          let round = Int(t / DotText.decodeStepTime)
          if round < steps(index) {
            let pool = character.isNumber ? BlockFont.digits : BlockFont.letters
            let hash = (index &* 7919 &+ round &* 104_729 &+ 31) % 9973
            let pick = pool[hash % pool.count]
            shown = pick == character ? pool[(hash + 1) % pool.count] : pick
          }
        }
      }
      // A rolling cell keeps its own width, so the word doesn't shift as it settles.
      if let shown {
        let cell = BlockFont.width(character), drawn = BlockFont.width(shown)
        var glyph = BlockFont.path(shown, x: 0, unit: unit)
        if drawn != cell { glyph = glyph.applying(CGAffineTransform(scaleX: cell / drawn, y: 1)) }
        path.addPath(glyph.applying(CGAffineTransform(translationX: x, y: 0)))
      }
      x += (BlockFont.width(character) + BlockFont.gap) * unit
    }
    ctx.fill(path, with: .foreground, style: FillStyle(eoFill: true))
  }
}

// MARK: Rebus around the block

/// The block top's words and signs (Figma: Explorations · LCD, AE): SF Mono caps at one size,
/// numbers in pills (filled, or outlined), small glyphs (clock, stack, a speaking head), an age
/// in a corner bracket, the arrow in a filled pill. Every token is one height.
enum BlockToken: Hashable {
  case word(String)
  case filled(String)
  case outline(String)
  case bracket(String)
  case clock, stack, head, go, listen, watch

  var spoken: String {
    switch self {
    case .word(let s), .filled(let s), .outline(let s): s.lowercased()
    case .bracket(let s): s.lowercased().replacing(/^1h/, with: "1 hour").replacing(/(\d)h/, with: { "\($0.1) hours" }).replacing(/(\d)m/, with: { "\($0.1) minutes" })
    case .clock, .stack, .head, .go, .listen, .watch: ""
    }
  }
}

/// One rebus line that wraps at tokens. It arrives like the dot face's departures board, read
/// left to right: cells (characters; a glyph or a pill's ends count as cells too) start
/// `DotText.decodeStagger` apart, each letter rolls through random ones (a new one every
/// `DotText.decodeStepTime`) before it settles; pills and glyphs pop in (scale 0.6 → 1, fading
/// up) on their turn. It plays when the launch board has gone, after `delay`, and again
/// whenever `replay` changes.
struct BlockRebusLine: View {
  let tokens: [BlockToken]
  let size: CGFloat
  var delay: Double = 0
  /// A new value replays the entrance (a new message).
  var replay: AnyHashable = 0
  @State private var start: Date?
  @State private var launched = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Tight: wrapped lines sit close, like one block of type.
  static func lineGap(_ size: CGFloat) -> CGFloat { size * 0.12 }
  static let rollSteps = 4

  /// The first cell of each token, in reading order.
  var cells: [Int] {
    var out: [Int] = [], cell = 0
    for token in tokens { out.append(cell); cell += token.cells + 1 }
    return out
  }
  var duration: Double {
    Double((cells.last ?? 0) + (tokens.last?.cells ?? 0)) * DotText.decodeStagger + Double(Self.rollSteps) * DotText.decodeStepTime + 0.2
  }

  var body: some View {
    Group {
      if let start {
        TimelineView(.animation) { context in line(elapsed: context.date.timeIntervalSince(start)) }
      } else {
        // Blank until the entrance first plays; settled after it.
        line(elapsed: launched || reduceMotion ? nil : -1)
      }
    }
    .afterLaunch {
      guard !launched else { return }
      launched = true
      play(after: delay)
    }
    // A new message replays at once; `delay` only staggers the first arrival.
    .onChange(of: replay) { play(after: 0) }
    .task(id: start) {
      guard let start else { return }
      try? await Task.sleep(for: .seconds(start.timeIntervalSinceNow + duration))
      self.start = nil
    }
  }

  func play(after wait: Double) {
    guard !reduceMotion else { return }
    start = Date.now.addingTimeInterval(wait)
  }

  func line(elapsed: Double?) -> some View {
    let cells = cells
    return FlowLayout(spacing: size * 0.38, lineSpacing: Self.lineGap(size)) {
      ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
        BlockTokenView(token: token, size: size, elapsed: elapsed.map { $0 - Double(cells[index]) * DotText.decodeStagger })
      }
    }
  }
}

extension BlockToken {
  /// How many cells of the departures board it takes.
  var cells: Int {
    switch self {
    case .word(let s): s.count
    case .filled(let s), .outline(let s), .bracket(let s): s.count + 2
    case .clock, .stack, .head, .go, .listen, .watch: 2
    }
  }
}

struct BlockTokenView: View {
  let token: BlockToken
  let size: CGFloat
  /// Seconds since this token's first cell started (negative: not yet; nil: settled).
  var elapsed: Double?
  /// Just room for a pill around the caps.
  static func height(_ size: CGFloat) -> CGFloat { size * 1.2 }
  var height: CGFloat { Self.height(size) }
  var mono: Font { .system(size: size, weight: .regular, design: .monospaced) }

  /// The text as it shows: letters not yet started are blank (the width stays), started ones
  /// roll through random letters or digits, then settle.
  func rolled(_ text: String, from cell: Int = 0) -> String {
    guard let elapsed else { return text }
    let pool = Array("ABCDEFGHJKLMNOPRSTUVWXYZ"), digits = Array("0123456789")
    return String(text.enumerated().map { index, ch in
      guard ch != " ", ch != "." else { return elapsed < Double(cell + index) * DotText.decodeStagger ? " " : ch }
      let t = elapsed - Double(cell + index) * DotText.decodeStagger
      if t < 0 { return " " }
      let round = Int(t / DotText.decodeStepTime)
      guard round < BlockRebusLine.rollSteps else { return ch }
      let set = ch.isNumber ? digits : pool
      let hash = (index &* 7919 &+ round &* 104_729 &+ 31) % 9973
      let pick = set[hash % set.count]
      return pick == ch ? set[(hash + 1) % set.count] : pick
    })
  }

  /// A pill or glyph pops in over 0.18 s at its turn.
  var pop: Double {
    guard let elapsed else { return 1 }
    return min(max(elapsed / 0.18, 0), 1)
  }

  var body: some View {
    let pop = pop
    let eased = 1 - pow(1 - pop, 3)
    switch token {
    case .word(let s): Text(rolled(s)).font(mono).foregroundStyle(Swiss.ink).frame(height: height)
    case .filled(let s):
      Text(rolled(s, from: 1)).font(mono).foregroundStyle(Swiss.onInk)
        .padding(.horizontal, size * 0.42).frame(height: height)
        .background(Swiss.ink.opacity(eased), in: Capsule())
        .scaleEffect(0.6 + 0.4 * eased)
    case .outline(let s):
      Text(rolled(s, from: 1)).font(mono).foregroundStyle(Swiss.ink)
        .padding(.horizontal, size * 0.42).frame(height: height)
        .overlay(Capsule().strokeBorder(Swiss.ink, lineWidth: max(1.3, size / 13)).opacity(eased))
        .scaleEffect(0.6 + 0.4 * eased)
    case .bracket(let s):
      Text(rolled(s, from: 1)).font(mono).foregroundStyle(Swiss.ink)
        .padding(.leading, size * 0.38).padding(.trailing, size * 0.3).padding(.bottom, size * 0.18)
        .frame(height: height)
        .overlay(alignment: .bottomLeading) {
          // The bracket draws itself, down then along.
          CornerBracket().trim(from: 0, to: eased).stroke(Swiss.ink, lineWidth: max(1.3, size / 13))
        }
    case .clock: glyph(Image(systemName: "clock").font(.system(size: size * 0.95)).foregroundStyle(Swiss.ink), eased)
    case .stack: glyph(Image(systemName: "square.3.layers.3d.down.right").font(.system(size: size * 0.95)).foregroundStyle(Swiss.ink), eased)
    case .listen: glyph(Image(systemName: "headphones").font(.system(size: size * 0.95)).foregroundStyle(Swiss.ink), eased)
    case .watch: glyph(Image(systemName: "play.rectangle").font(.system(size: size * 0.95)).foregroundStyle(Swiss.ink), eased)
    case .head: glyph(SpeakingHead().fill(Swiss.ink).frame(width: size * 1.35, height: size * 1.08), eased)
    case .go:
      glyph(
        Image(systemName: "arrow.right").font(.system(size: size * 0.8, weight: .medium)).foregroundStyle(Swiss.onInk)
          .offset(x: (1 - eased) * -size * 0.3)
          .padding(.horizontal, size * 0.55).frame(height: height)
          .background(Swiss.ink, in: Capsule()),
        eased)
    }
  }

  func glyph(_ view: some View, _ eased: Double) -> some View {
    view.frame(height: height).scaleEffect(0.6 + 0.4 * eased).opacity(eased)
  }
}

/// The age's bracket: a line down the left that curves into one along the bottom.
nonisolated struct CornerBracket: Shape {
  func path(in rect: CGRect) -> Path {
    let r = min(rect.height * 0.35, 10)
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY + 2))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return p
  }
}

/// A head in profile, speaking: the sign for a message (drawn on a 30 × 24 grid).
nonisolated struct SpeakingHead: Shape {
  func path(in rect: CGRect) -> Path {
    let sx = rect.width / 30, sy = rect.height / 24
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
    var p = Path()
    p.move(to: pt(9, 1))
    p.addCurve(to: pt(17.5, 8.6), control1: pt(14, 1), control2: pt(17.5, 4.4))
    p.addCurve(to: pt(18.5, 11.6), control1: pt(17.5, 9.8), control2: pt(17.8, 10.5))
    p.addLine(to: pt(19.8, 13.7))
    p.addCurve(to: pt(19.2, 15), control1: pt(20.2, 14.3), control2: pt(19.9, 14.9))
    p.addLine(to: pt(17.8, 15.2))
    p.addLine(to: pt(17.8, 17.8))
    p.addCurve(to: pt(15.1, 20.3), control1: pt(17.8, 19.3), control2: pt(16.6, 20.4))
    p.addLine(to: pt(13.1, 20.2))
    p.addLine(to: pt(13.1, 23))
    p.addLine(to: pt(3, 23))
    p.addLine(to: pt(3, 17.4))
    p.addCurve(to: pt(0.5, 11), control1: pt(1.5, 15.8), control2: pt(0.5, 13.6))
    p.addCurve(to: pt(9, 1), control1: pt(0.5, 5.4), control2: pt(4.2, 1))
    p.closeSubpath()
    var lines = Path()
    lines.move(to: pt(22, 7.5)); lines.addLine(to: pt(26.5, 5))
    lines.move(to: pt(22.5, 12)); lines.addLine(to: pt(27.5, 12))
    lines.move(to: pt(22, 16.5)); lines.addLine(to: pt(26.5, 19))
    p.addPath(lines.strokedPath(StrokeStyle(lineWidth: 2.2 * sx, lineCap: .round)))
    return p
  }
}

/// The block top's message: a rebus line, the speaking head first, numbers in pills, the age in
/// its bracket, the arrow last. Two lines high whatever it says (long headlines are cut), so
/// nothing under it moves; the messages take turns every 7 s.
struct BlockMessageRow: View {
  let messages: [BoardMessage]
  let size: CGFloat
  /// Seconds before the first message arrives.
  var delay: Double = 0
  @State private var index = 0
  @State private var lastSwitch = Date.now
  @State private var width: CGFloat = 360

  var body: some View {
    let message = messages[index % messages.count]
    Button(action: message.action) {
      // The same line stays and replays its entrance for each new message: it arrives as a
      // departures board, after the lines above it the first time.
      BlockRebusLine(tokens: Self.tokens(message, columns: Int(width / (size * 0.6))), size: size, delay: delay, replay: message.id)
        .frame(maxWidth: .infinity, minHeight: BlockTokenView.height(size) * 2 + BlockRebusLine.lineGap(size), alignment: .topLeading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .accessibilityLabel(message.spoken)
    .task(id: messages.map(\.id)) {
      guard messages.count > 1 else { return }
      while !Task.isCancelled {
        let wait = max(0.5, 7 - Date.now.timeIntervalSince(lastSwitch))
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled else { return }
        index += 1
        lastSwitch = .now
      }
    }
  }

  /// "TOP · HEADLINE" → head, the headline's words, the age bracketed, the arrow. Numbers in
  /// other messages go in filled pills. Cut with "..." to fit two lines of `columns` characters.
  static func tokens(_ message: BoardMessage, columns: Int) -> [BlockToken] {
    var text = message.text.uppercased()
    if text.hasPrefix("TOP · ") { text = String(text.dropFirst(6)) }
    // A new episode or video: its sign, the show, the length or age; the freshness line: the
    // clock and the age, nothing to tap.
    let lead: BlockToken = message.id.hasPrefix("listen-") ? .listen : message.id.hasPrefix("watch-") ? .watch : message.id == "fresh" ? .clock : .head
    let tappable = message.id != "fresh"
    let age = message.grey.isEmpty ? 0 : message.grey.count + 3
    // Two lines, less the head, the age and the arrow, with room for pills' padding and wraps.
    let budget = max(columns * 2 - 4 - age - 4 - 6, 8)
    var words: [String] = []
    var used = 0
    for word in text.split(separator: " ").map(String.init) {
      if used + word.count + 1 > budget {
        if let last = words.popLast() { words.append(last + "...") }
        break
      }
      words.append(word)
      used += word.count + 1
    }
    var out: [BlockToken] = [lead]
    out += words.map { $0.allSatisfy(\.isNumber) ? .filled($0) : .word($0) }
    if !message.grey.isEmpty { out.append(.bracket(message.grey)) }
    if tappable { out.append(.go) }
    return out
  }
}

/// Settings › Look: how Today's top is drawn.
struct LookSettings: View {
  @State private var raw = UserDefaults.standard.string(forKey: TopLook.key) ?? TopLook.blocks.rawValue
  var look: TopLook { TopLook(rawValue: raw) ?? .blocks }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow("Look")
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Today's top").font(.body.weight(.medium))
          Text(look.detail)
            .font(.footnote)
            .tileSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          ForEach(TopLook.allCases) { option in
            let isSelected = raw == option.rawValue
            Button(option.label) {
              withAnimation(.snappy(duration: 0.2)) { raw = option.rawValue }
            }
            .buttonStyle(SelectablePillStyle(isOn: isSelected, fillsWidth: true))
            .id(isSelected)
          }
        }
      }
      .padding(14)
      .tile(.plain, radius: 16)
    }
    .onChange(of: raw) { _, new in UserDefaults.standard.set(new, forKey: TopLook.key) }
  }
}
