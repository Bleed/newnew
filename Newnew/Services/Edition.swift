import Foundation
import UserNotifications

/// How Today opens: everything (the feed, as it always was) or an edition (zen mode).
enum TodayMode: String, CaseIterable, Identifiable {
  case everything, edition
  static let key = "todayMode"
  var id: String { rawValue }
  var label: String { self == .everything ? "Everything" : "Edition" }
}

/// Zen mode (Figma: Zen mode): twice a day an edition of the most covered new stories, at most
/// `size`, read one at a time, then "You're caught up" until the next. An edition is made once,
/// when its time has come and the feed has been read, and doesn't change while you read it.
@MainActor @Observable final class Edition {
  static let shared = Edition()

  static let sizeKey = "editionSize"
  static let readyKey = "editionReady"
  private static let storeKey = "edition.current"
  static let sizes = [5, 10, 15]
  /// When the editions are made: morning and evening.
  static let hours = [7, 18]
  /// A story you've read comes back in an edition only with this many new articles since.
  static let backAfter = 3
  /// At most this many stories from one section.
  static let perPillar = 3

  struct Stored: Codable {
    var slot: Date
    var ids: [UUID]
    /// Stories read before that came back with new coverage.
    var back: [UUID] = []
    /// The story you're on; `ids.count` once you've read them all.
    var position = 0
    var started: Date?
    var finished: Date?
    var reading = false
  }

  private(set) var current: Stored?

  init() {
    current = UserDefaults.standard.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
  }

  static var size: Int {
    let size = UserDefaults.standard.integer(forKey: sizeKey)
    return sizes.contains(size) ? size : 10
  }

  // MARK: Times

  /// The edition in force at `date`: today's 07:00 or 18:00, or last night's.
  static func slot(at date: Date = .now) -> Date {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let times = (hours.map { calendar.date(byAdding: .hour, value: $0, to: day)! } + [calendar.date(byAdding: .hour, value: hours.last! - 24, to: day)!])
    return times.filter { $0 <= date }.max()!
  }

  static func previous(_ slot: Date) -> Date { Self.slot(at: slot.addingTimeInterval(-60)) }
  static func next(_ slot: Date) -> Date {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: slot)
    let nextHour = hours.first { $0 > hour }
    let day = calendar.startOfDay(for: slot)
    return nextHour.map { calendar.date(byAdding: .hour, value: $0, to: day)! }
      ?? calendar.date(byAdding: .hour, value: hours[0] + 24, to: day)!
  }

  static func isMorning(_ slot: Date) -> Bool { Calendar.current.component(.hour, from: slot) < 12 }
  static func name(_ slot: Date) -> String { isMorning(slot) ? "Morning edition" : "Evening edition" }

  // MARK: Making it

  /// Makes this edition if its time has come and it hasn't been made yet. Waits for a feed: an
  /// edition made from nothing would stay empty until the next.
  func refresh(from clusters: [StoryCluster], syncing: Bool) {
    let slot = Self.slot()
    guard current?.slot != slot, !syncing, !clusters.isEmpty else { return }
    let since = Self.previous(slot).addingTimeInterval(-3600)
    var perPillar: [Pillar: Int] = [:]
    var chosen: [StoryCluster] = []
    var back: [UUID] = []
    let candidates = clusters.filter { cluster in
      guard !cluster.isMuted, let lead = cluster.lead, !lead.isChart, !lead.isMedia, cluster.updatedAt > since else { return false }
      return cluster.readAt == nil || cluster.newSinceRead >= Self.backAfter
    }
    // The most covered first: how many of your outlets have it, then the newest.
    for cluster in candidates.sorted(by: { a, b in
      let (x, y) = (a.outlets.count, b.outlets.count)
      return x != y ? x > y : a.updatedAt > b.updatedAt
    }) where chosen.count < Self.size {
      let pillar = cluster.pillar
      guard perPillar[pillar, default: 0] < Self.perPillar, cluster.outlets.count >= 2 else { continue }
      perPillar[pillar, default: 0] += 1
      chosen.append(cluster)
      if cluster.readAt != nil { back.append(cluster.id) }
    }
    current = Stored(slot: slot, ids: chosen.map(\.id), back: back)
    save()
  }

  // MARK: Reading it

  func begin() {
    current?.reading = true
    if current?.started == nil { current?.started = .now }
    save()
  }

  func pause() {
    current?.reading = false
    save()
  }

  func advance() {
    guard var stored = current else { return }
    stored.position += 1
    if stored.position >= stored.ids.count {
      stored.finished = .now
      stored.reading = false
    }
    current = stored
    save()
  }

  func back() {
    guard let position = current?.position, position > 0 else { return }
    current?.position = position - 1
    save()
  }

  private func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(current), forKey: Self.storeKey)
  }

  // MARK: Notification

  /// "Your evening edition is ready", at 07:00 and 18:00, when switched on (local, repeating).
  static func scheduleReady() {
    let center = UNUserNotificationCenter.current()
    let ids = hours.map { "edition.\($0)" }
    center.removePendingNotificationRequests(withIdentifiers: ids)
    let on = UserDefaults.standard.string(forKey: TodayMode.key) == TodayMode.edition.rawValue
      && UserDefaults.standard.bool(forKey: readyKey)
    guard on else { return }
    for hour in hours {
      let content = UNMutableNotificationContent()
      content.title = "newnew"
      content.body = "Your \(hour < 12 ? "morning" : "evening") edition is ready. \(size) stories at most, then you're done."
      content.sound = nil
      let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: 0), repeats: true)
      center.add(UNNotificationRequest(identifier: "edition.\(hour)", content: content, trigger: trigger))
    }
  }
}
