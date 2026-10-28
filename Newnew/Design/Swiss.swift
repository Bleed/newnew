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
  nonisolated static let canvas = Color.adaptive(light: 0xFAFAFA, dark: 0x000000)
  nonisolated static let tile = Color.adaptive(light: 0xF1F1F1, dark: 0x1A1A1A)
  nonisolated static let tileQuiet = Color.adaptive(light: 0xE8E8E8, dark: 0x2A2A2A)
  nonisolated static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x161616)
  nonisolated static let ink = Color.adaptive(light: 0x000000, dark: 0xF5F5F5)
  /// Text on an ink tile.
  nonisolated static let onInk = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
  nonisolated static let muted = Color.adaptive(light: 0x828282, dark: 0x8E8E8E)

  /// Attention: developing stories, new sources since you read one. Black text.
  nonisolated static let signal = Color(rgb: 0xBAECB7)
  /// Act now: breaking.
  nonisolated static let alert = Color(rgb: 0xFF4D3A)
  /// Small marks, as Atelier's stage dots.
  nonisolated static let mint = Color(rgb: 0x7FD6B0)
  nonisolated static let orange = Color(rgb: 0xF4A86B)

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
  nonisolated init(rgb: UInt32) {
    self.init(
      .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255)
  }

  /// Marked `nonisolated` so SwiftUI's off-main `com.apple.SwiftUI.AsyncRenderer` thread can
  /// resolve light/dark dynamic colors during animations without triggering a Swift 6
  /// `_dispatch_assert_queue_fail` main-actor trap.
  nonisolated static func adaptive(light: UInt32, dark: UInt32) -> Color {
    let lightColor = UIColor(rgb: light)
    let darkColor = UIColor(rgb: dark)
    return Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? darkColor : lightColor
    })
  }
}

extension UIColor {
  nonisolated convenience init(rgb: UInt32) {
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
    .pillHeight()
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

/// A coloured list bullet, centred on the first line's lowercase letters (its x-height), so it
/// sits level with the words at any text size. Use in an `HStack(alignment: .firstTextBaseline)`.
struct BulletDot: View {
  let color: Color
  var textStyle: UIFont.TextStyle = .subheadline
  var size: CGFloat = 7
  /// Re-measures the font when the text size changes.
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let xHeight = UIFont.preferredFont(forTextStyle: textStyle).xHeight
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      // The text's baseline lies half an x-height below the dot's centre.
      .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + xHeight / 2 }
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

/// A section heading with a pill in the top-right corner (a badge, an update pill). Side by side
/// when both fit; otherwise the pill keeps the top-right corner on its own line and the heading
/// goes under it, so a wide pill never squeezes the heading into a hyphenated column
/// ("Cover- age spec- trum").
struct EyebrowRow<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing

  init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        Eyebrow(title).fixedSize()
        Spacer(minLength: 0)
        trailing.fixedSize()
      }
      VStack(alignment: .leading, spacing: 8) {
        trailing.frame(maxWidth: .infinity, alignment: .trailing)
        Eyebrow(title)
      }
    }
  }
}

/// One height for the small pills that sit side by side on a card (signal, sources, listen),
/// following the text size.
private struct PillHeight: ViewModifier {
  @ScaledMetric(relativeTo: .caption) var height: CGFloat = 24
  func body(content: Content) -> some View { content.frame(height: height) }
}

extension View {
  func pillHeight() -> some View { modifier(PillHeight()) }
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
      .pillHeight()
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

/// A choice among pills (filters, settings): the chosen one is an ink outline, the rest quiet
/// 7 % pills. An outline always means "selected", never an action. Small pills (the region row)
/// have smaller text but the same height, so the rows line up.
struct SelectablePillStyle: ButtonStyle {
  var isOn: Bool
  var small = false
  /// Settings rows: the pills share the width.
  var fillsWidth = false
  @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 36

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(small ? .subheadline.weight(.medium) : .callout.weight(.medium))
      .lineLimit(1)
      .frame(maxWidth: fillsWidth ? .infinity : 200)
      .padding(.horizontal, small ? 12 : 14)
      .frame(minHeight: height)
      .foregroundStyle(Swiss.ink)
      .background(isOn ? Color.clear : Swiss.ink.opacity(0.07), in: Capsule())
      .overlay { if isOn { Capsule().strokeBorder(Swiss.ink, lineWidth: 1.5) } }
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(Capsule())
      .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A round icon button (close, remove): a 32 pt circle, the icon at medium weight, and a 44 pt
/// touch area around it.
struct RoundIconButtonStyle: ButtonStyle {
  var foreground: Color = Swiss.ink
  var background: AnyShapeStyle = AnyShapeStyle(Swiss.ink.opacity(0.07))

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.footnote.weight(.medium))
      .foregroundStyle(foreground)
      .frame(width: 32, height: 32)
      .background(background, in: Circle())
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.6 : 1)
  }
}

extension ButtonStyle where Self == RoundIconButtonStyle {
  static var roundIcon: RoundIconButtonStyle { RoundIconButtonStyle() }
}

/// Switches in ink, reversed in dark mode like the ink pills: on is an ink track with a knob
/// in the page colour, so the knob never melts into a white track. Off is a quiet grey track.
struct SwissToggleStyle: ToggleStyle {
  nonisolated static let offKnob = Color.adaptive(light: 0xFFFFFF, dark: 0x8E8E8E)

  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 12) {
        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        Capsule()
          .fill(configuration.isOn ? Swiss.ink : Swiss.ink.opacity(0.12))
          .frame(width: 51, height: 31)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(configuration.isOn ? Swiss.onInk : Self.offKnob)
              .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
              .padding(2)
          }
          .animation(.snappy(duration: 0.2), value: configuration.isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
  }
}

extension ToggleStyle where Self == SwissToggleStyle {
  static var swiss: SwissToggleStyle { SwissToggleStyle() }
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
      // The gap before it counts too, or the last item on a full line sticks out by one gap.
      if rows[rows.count - 1].width + spacing + size.width > maxWidth, !rows[rows.count - 1].indices.isEmpty {
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
