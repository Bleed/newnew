import Foundation
import Network

/// Whether newnew reads the feeds while it's closed (iOS wakes it a few times a day, when it
/// chooses), so the news is fresh when it's opened. A refresh is a few MB with podcasts off;
/// unchanged feeds cost next to nothing. Low Data Mode always waits for the app to be opened.
enum BackgroundRefresh: String, CaseIterable, Identifiable {
  case wifi, always, off

  static let key = "refresh.background"
  static var current: BackgroundRefresh {
    UserDefaults.standard.string(forKey: key).flatMap(BackgroundRefresh.init(rawValue:)) ?? .wifi
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .wifi: "Wi-Fi"
    case .always: "Always"
    case .off: "Off"
    }
  }

  var detail: String {
    switch self {
    case .wifi: "Fresh news when you open newnew, read on Wi-Fi while it's closed. On mobile data it waits until you open it."
    case .always: "Fresh news when you open newnew, read on Wi-Fi or mobile data while it's closed. About 10–40 MB a day, more with podcasts."
    case .off: "newnew reads the news only when you open it. Alerts for topics you follow come only then too."
    }
  }

  /// Whether a refresh may run now, with the app closed.
  static func allowedNow() async -> Bool {
    let setting = current
    guard setting != .off else { return false }
    let path = await currentPath()
    guard path.status == .satisfied, !path.isConstrained else { return false }
    // Mobile data and personal hotspots count as expensive.
    return setting == .always || !path.isExpensive
  }

  private static func currentPath() async -> NWPath {
    await withCheckedContinuation { continuation in
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in
        monitor.cancel()
        continuation.resume(returning: path)
      }
      monitor.start(queue: DispatchQueue(label: "newnew.path"))
    }
  }
}
