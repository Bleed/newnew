import SwiftUI
import UIKit

/// Pull to refresh in the dot language (Figma: newnew › Pull to refresh), in place of the system
/// spinner: a small dot board just under the top bar, around "new" over "new" as on the icon. As you pull, its
/// faint dots fill in from the left. Let go past `threshold` and it loops like an old departures
/// board while the feed loads: the first "new" rolls in, then the second, then the first rolls
/// out, then the second, and again. It always ends with both words in, then folds away, also
/// when the feed was quicker. The same board shows when the app reads the feed by itself
/// (`isSyncing`: on opening, on coming back).
struct PullToRefresh: ViewModifier {
  var action: @MainActor () async -> Void
  /// A sync started elsewhere: show the board for it too.
  var isSyncing: Bool
  @State private var pull: CGFloat = 0
  @State private var board = BoardState()
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  static let threshold: CGFloat = 72

  /// What the running loop changes, in an object so the changes reach the screen.
  @MainActor @Observable final class BoardState {
    var isShowing = false
    var loop = WordLoop()
    var waitingForSync = false
  }

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) {
        // Just under the top bar, above the page, only while loading; folds away after.
        if board.isShowing {
          MiniDotBoard(fill: 1, first: board.loop.first, second: board.loop.second)
            .frame(maxWidth: .infinity)
            .frame(height: MiniDotBoard.slot)
            .background(Swiss.canvas)
            .transition(.opacity)
        }
      }
      .overlay(alignment: .top) {
        // While pulling, it fills in, in the gap the pull opens under the top bar.
        if !board.isShowing, pull > 2 {
          MiniDotBoard(fill: min(pull / Self.threshold, 1), first: false, second: false)
            .frame(maxWidth: .infinity)
            .frame(height: min(pull, MiniDotBoard.slot))
            .clipped()
            .allowsHitTesting(false)
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        -(geometry.contentOffset.y + geometry.contentInsets.top)
      } action: { _, overscroll in
        pull = max(0, overscroll)
      }
      .onScrollPhaseChange { old, new in
        if old == .interacting, new != .interacting, pull >= Self.threshold, !board.isShowing {
          run { await action() }
        }
      }
      .sensoryFeedback(.impact(weight: .light), trigger: pull >= Self.threshold) { _, full in full }
      .onChange(of: isSyncing, initial: true) { _, syncing in
        board.waitingForSync = syncing
        guard syncing, !board.isShowing else { return }
        let board = board
        run { while board.waitingForSync { try? await Task.sleep(for: .milliseconds(100)) } }
      }
      .accessibilityAction(named: "Refresh") { run { await action() } }
  }

  /// Shows the board and loops the words while `work` runs; ends on both words in, then folds.
  func run(_ work: @escaping @MainActor () async -> Void) {
    let board = board
    withAnimation(.snappy(duration: 0.2)) { board.isShowing = true }
    let job = Task { await work() }
    Task {
      var done = false
      Task { await job.value; done = true }
      await board.loop.run(reduceMotion: reduceMotion) { done }
      try? await Task.sleep(for: .seconds(0.15))
      withAnimation(.easeOut(duration: 0.25)) { board.isShowing = false }
      board.loop.first = false
      board.loop.second = false
    }
  }
}

extension View {
  func dotRefreshable(isSyncing: Bool, _ action: @escaping @MainActor () async -> Void) -> some View {
    modifier(PullToRefresh(action: action, isSyncing: isSyncing))
  }
}

/// A small dot board around "new" over "new": 19 × 13 dots at a 4 pt pitch, one dot of margin
/// round the words. Faint dots fill to `fill` from the left; each line rolls in when it turns
/// on and rolls out when it turns off.
struct MiniDotBoard: View {
  var fill: CGFloat
  var first: Bool
  var second: Bool

  static let pitch: CGFloat = 4
  static let cols = StackedWords.cols + 2
  static let rows = StackedWords.rows + 2
  /// The room it takes under the top bar.
  static let slot: CGFloat = 64

  var body: some View {
    let p = Self.pitch, d = p * 0.82
    let filled = Int((CGFloat(Self.cols) * fill).rounded())
    ZStack(alignment: .topLeading) {
      Canvas { ctx, _ in
        for r in 0..<Self.rows { for c in 0..<min(filled, Self.cols) {
          let rect = CGRect(x: CGFloat(c) * p + (p - d) / 2, y: CGFloat(r) * p + (p - d) / 2, width: d, height: d)
          ctx.fill(Path(ellipseIn: rect), with: .color(Swiss.ink.opacity(0.1)))
        } }
      }
      StackedWords(first: first, second: second, pitch: p)
        .foregroundStyle(Swiss.ink)
        .offset(x: p, y: p)
    }
    .frame(width: CGFloat(Self.cols) * p, height: CGFloat(Self.rows) * p, alignment: .topLeading)
    .accessibilityHidden(true)
  }
}
