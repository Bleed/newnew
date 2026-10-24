import SwiftUI
import UIKit

// Atelier's look, carried over (Atelier CRM, AtelierKit/UI/Swiss.swift):
//
// - A near-white page, soft grey tiles, black text in a small calm grotesk, lots of air.
//   Quiet 7 % grey pills; one black pill for the main action.
// - Signals, loudest first: red = act now (a dot and words), mint = attention (a pill).
//   Signals never fill a whole card.
// - Play comes in dashes: the 5×7 dot face for live details inside pills and chips, one
//   orange panel at the top of the page.
// - Numbers are SF Mono, light or regular, never heavier.
// - Liquid Glass stays on navigation (toolbar); content is flat.
// - Every size is a text style or @ScaledMetric, so it follows the system text size.

enum Swiss {
  static let canvas = Color.adaptive(light: 0xFAFAFA, dark: 0x000000)
  static let tile = Color.adaptive(light: 0xF1F1F1, dark: 0x1A1A1A)
  static let tileQuiet = Color.adaptive(light: 0xE8E8E8, dark: 0x2A2A2A)
  static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x161616)
  static let ink = Color.adaptive(light: 0x000000, dark: 0xF5F5F5)
  /// Text on an ink tile.
  static let onInk = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
  static let muted = Color.adaptive(light: 0x828282, dark: 0x8E8E8E)

  /// Attention: developing stories, new sources since you read one. Black text.
  static let signal = Color(rgb: 0xBAECB7)
  /// Act now: breaking.
  static let alert = Color(rgb: 0xFF4D3A)
  /// Small marks, as Atelier's stage dots.
  static let mint = Color(rgb: 0x7FD6B0)
  static let orange = Color(rgb: 0xF4A86B)

  /// Figures: SF Mono at regular weight. `size` is already scaled for Dynamic Type.
  static func figure(_ size: CGFloat) -> Font { .system(size: size.rounded(), weight: .regular, design: .monospaced) }
  /// Small figures beside text (times, counts).
  static let smallFigure = Font.footnote.monospaced().weight(.regular)

  /// News headlines: Times New Roman, the newspaper voice against the app's SF and SF Mono. It
  /// sets smaller than SF at the same size, so headlines run a few points larger than the SF
  /// text they'd otherwise match. Scales with `style` for Dynamic Type.
  static func headline(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
    .custom("Times New Roman", size: size, relativeTo: style)
  }

  static let tileRadius: CGFloat = 20
  /// Side margin of every page, so headers and cards line up.
  static let pageInset: CGFloat = 20
}

extension Color {
  init(rgb: UInt32) {
    self.init(
      .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255)
  }

  static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
  }
}

extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(
      red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}

// MARK: - Signals

enum SignalLevel {
  case actNow, attention
  var color: Color { self == .actNow ? Swiss.alert : Swiss.signal }
}

/// A signal on top of whatever it sits on: a small pill with a dot and words.
struct SignalBadge: View {
  let level: SignalLevel
  let text: String

  init(_ level: SignalLevel, _ text: String) {
    self.level = level
    self.text = text
  }

  var body: some View {
    HStack(spacing: 5) {
      Circle().frame(width: 6, height: 6)
      Text(text).font(.caption.weight(.medium)).lineLimit(1)
    }
    // Act now is a red dot and words; attention is a mint pill.
    .foregroundStyle(level == .actNow ? Swiss.alert : .black)
    .padding(.horizontal, level == .actNow ? 0 : 9)
    .padding(.vertical, 4)
    .background(level == .actNow ? .clear : level.color, in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

// MARK: - Tiles

enum TileStyle: Equatable {
  case plain, quiet, ink, signal, outline

  var fill: Color {
    switch self {
    case .plain: Swiss.tile
    case .quiet: Swiss.tileQuiet
    case .ink: Swiss.ink
    case .signal: Swiss.signal
    case .outline: .clear
    }
  }

  var foreground: Color {
    switch self {
    case .ink: Swiss.onInk
    case .signal: .black
    default: Swiss.ink
    }
  }

  var secondary: Color {
    switch self {
    case .ink: Swiss.onInk.opacity(0.55)
    case .signal: .black.opacity(0.5)
    default: Swiss.muted
    }
  }
}

private struct TileStyleKey: EnvironmentKey {
  static let defaultValue: TileStyle = .plain
}

extension EnvironmentValues {
  /// The tile a view sits on, so nested text can pick the right contrast.
  var tileStyle: TileStyle {
    get { self[TileStyleKey.self] }
    set { self[TileStyleKey.self] = newValue }
  }
}

extension View {
  func tile(_ style: TileStyle = .plain, radius: CGFloat = Swiss.tileRadius) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return self
      .foregroundStyle(style.foreground)
      .environment(\.tileStyle, style)
      .background(style.fill, in: shape)
      .overlay {
        if style == .outline {
          shape.strokeBorder(Swiss.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
      }
  }

  func tileSecondary() -> some View { modifier(TileSecondary()) }

  /// The page behind a screen's content.
  func swissCanvas() -> some View { background(Swiss.canvas.ignoresSafeArea()) }

  /// The page's own header is the visible title; the bar keeps it for accessibility only.
  func swissNavigationTitle(_ title: String) -> some View {
    navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
          .sharedBackgroundVisibility(.hidden)
      }
  }
}

/// Secondary text that adapts to the tile it sits on.
struct TileSecondary: ViewModifier {
  @Environment(\.tileStyle) var style
  func body(content: Content) -> some View { content.foregroundStyle(style.secondary) }
}

// MARK: - Type

/// Two-line Swiss heading: an ink line over a grey line, both regular weight.
struct SwissHeader<Trailing: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder var trailing: Trailing
  @ScaledMetric(relativeTo: .largeTitle) var size: CGFloat = 40

  init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .lastTextBaseline) {
        heading.fixedSize()
        Spacer(minLength: 16)
        trailing.fixedSize()
      }
      VStack(alignment: .leading, spacing: 14) {
        heading
        trailing
      }
    }
  }

  var heading: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).foregroundStyle(Swiss.ink)
      if let subtitle { Text(subtitle).foregroundStyle(Swiss.muted) }
    }
    .font(.system(size: size, weight: .regular))
    .tracking(-size * 0.02)
    .lineSpacing(-size * 0.06)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// Small grey label above a value or a section: "Covered widely".
struct Eyebrow: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.subheadline.weight(.medium)).tileSecondary()
      .accessibilityAddTraits(.isHeader)
  }
}

/// A quiet 7 % pill with a short label: outlet names, suggestions.
struct QuietPill: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(Swiss.ink.opacity(0.07), in: Capsule())
      .fixedSize()
  }
}

/// Content actions: flat Swiss pills. One black (prominent) pill for the main action.
struct SwissButtonStyle: ButtonStyle {
  var prominent: Bool
  @Environment(\.isEnabled) var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .foregroundStyle(prominent ? Swiss.onInk : Swiss.ink)
      .background(prominent ? Swiss.ink : Swiss.ink.opacity(0.07), in: Capsule())
      .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
      .contentShape(Capsule())
      .fixedSize()
  }
}

extension ButtonStyle where Self == SwissButtonStyle {
  static var swissPrimary: SwissButtonStyle { SwissButtonStyle(prominent: true) }
  static var swissSecondary: SwissButtonStyle { SwissButtonStyle(prominent: false) }
}

/// Minimal wrapping layout for pills.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(proposal: proposal, subviews: subviews)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
    let maxWidth = proposal.width ?? .infinity
    var rows: [Row] = [Row()]
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      if rows[rows.count - 1].width + size.width > maxWidth, !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
      rows[rows.count - 1].indices.append(index)
      rows[rows.count - 1].width += size.width + gap
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows.filter { !$0.indices.isEmpty }
  }
}
