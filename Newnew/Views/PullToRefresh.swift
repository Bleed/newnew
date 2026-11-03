import SwiftUI
import UIKit

/// Pull to refresh with nothing of its own on screen: pull past `threshold` and let go, and the
/// feeds are read; the block NEWNEW in Today's top rolls while they are (`NewsTop`), as it does
/// for every sync. A light tap when the pull is far enough.
struct PullToRefresh: ViewModifier {
  var action: @MainActor () async -> Void
  @State private var pull: CGFloat = 0
  @State private var running = false

  static let threshold: CGFloat = 72

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        -(geometry.contentOffset.y + geometry.contentInsets.top)
      } action: { _, overscroll in
        pull = max(0, overscroll)
      }
      .onScrollPhaseChange { old, new in
        if old == .interacting, new != .interacting, pull >= Self.threshold { run() }
      }
      .sensoryFeedback(.impact(weight: .light), trigger: pull >= Self.threshold) { _, full in full }
      .accessibilityAction(named: "Refresh") { run() }
  }

  func run() {
    guard !running else { return }
    running = true
    Task {
      await action()
      running = false
    }
  }
}

extension View {
  func pullToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
    modifier(PullToRefresh(action: action))
  }
}

/// A small dot board around "new" over "new": 19 × 13 dots, one dot of margin round the words. Faint dots fill to `fill` from the left; each line rolls in when it turns
/// on and rolls out when it turns off.
struct MiniDotBoard: View {
  var fill: CGFloat
  var first: Bool
  var second: Bool
  /// Onboarding and the edition draw it at their own sizes.
  var pitch: CGFloat = 4
  static let cols = StackedWords.cols + 2
  static let rows = StackedWords.rows + 2

  var body: some View {
    let p = pitch, d = p * 0.82
    let filled = Int((CGFloat(Self.cols) * fill).rounded())
    ZStack(alignment: .topLeading) {
      Canvas { ctx, _ in
        var dots = Path()
        for r in 0..<Self.rows { for c in 0..<min(filled, Self.cols) {
          dots.addEllipse(in: CGRect(x: CGFloat(c) * p + (p - d) / 2, y: CGFloat(r) * p + (p - d) / 2, width: d, height: d))
        } }
        ctx.fill(dots, with: .color(Swiss.ink.opacity(0.1)))
      }
      StackedWords(first: first, second: second, pitch: p)
        .foregroundStyle(Swiss.ink)
        .offset(x: p, y: p)
    }
    .frame(width: CGFloat(Self.cols) * p, height: CGFloat(Self.rows) * p, alignment: .topLeading)
    .accessibilityHidden(true)
  }
}
