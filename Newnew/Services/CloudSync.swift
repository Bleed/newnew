import CryptoKit
import Foundation
import SwiftData

/// What the reader chose, kept the same on their iPhone and iPad through iCloud's key-value store
/// (`NSUbiquitousKeyValueStore`): the outlets and own feeds, the topics followed or muted, what's
/// been read, and the look. The news itself isn't synced: each device reads the feeds and groups
/// the stories on its own, so a read story is shared by its articles' links, not by the story.
/// Alerts and background refresh stay per device.
///
/// Each change is written to iCloud as it's made; changes from another device arrive as
/// `didChangeExternallyNotification` and are applied here. Without iCloud nothing syncs and
/// everything works as before.
@MainActor final class CloudSync {
  static let shared = CloudSync()

  private let cloud = NSUbiquitousKeyValueStore.default
  private weak var pipeline: FeedSyncPipeline?

  /// Kept as they are on both devices.
  static let settingKeys = ["topLook", "readStories", "newsWindowHours"]
  static let chosenKey = "outlets.chosen"
  static let customKey = "outlets.custom"
  static let onboardedKey = "outlets.onboarded"
  static var mirroredKeys: [String] { settingKeys + [chosenKey, customKey, onboardedKey] }
  /// Read articles: a short fingerprint of each link → when it was read.
  static let readKey = "cloud.read"
  static let topicsKey = "cloud.topics"
  /// This device has joined what's in iCloud once (its own choices merged in, not overwritten).
  private static let joinedKey = "cloud.joined"
  /// Reads older than this are let go (articles go after 72 hours).
  static let keepReads: TimeInterval = 4 * 24 * 3600

  /// Link → fingerprint, so stored articles aren't hashed again on every change.
  private var fingerprints: [String: String] = [:]

  func start(_ pipeline: FeedSyncPipeline) {
    self.pipeline = pipeline
    let center = NotificationCenter.default
    center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { note in
      let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
      MainActor.assumeIsolated { CloudSync.shared.received(keys) }
    }
    center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { CloudSync.shared.pushSettings() }
    }
    cloud.synchronize()
    join()
  }

  // MARK: Joining

  /// The first time on this device: what's in iCloud and what's here are put together, then
  /// written back, so neither device loses what it had.
  private func join() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.joinedKey) else {
      received(Self.mirroredKeys + [Self.readKey, Self.topicsKey])
      return
    }
    // Settings and outlets: iCloud's when it has them (another device came first), else this
    // device's. Own feeds from both.
    var outletsChanged = false
    for key in Self.mirroredKeys {
      if key == Self.customKey {
        let merged = Self.feeds(cloud.data(forKey: key)) + Self.feeds(defaults.data(forKey: key))
        var seen = Set<String>()
        let union = merged.filter { seen.insert($0.url).inserted }
        let data = try? JSONEncoder().encode(union)
        if union.count != Self.feeds(defaults.data(forKey: key)).count { outletsChanged = true }
        defaults.set(data, forKey: key)
        cloud.set(data, forKey: key)
      } else if let value = cloud.object(forKey: key) {
        if key == Self.onboardedKey, defaults.bool(forKey: key) { continue }
        if !Self.same(value, defaults.object(forKey: key)) {
          defaults.set(value, forKey: key)
          if key == Self.chosenKey || key == Self.onboardedKey { outletsChanged = true }
        }
      } else if let local = defaults.object(forKey: key) {
        cloud.set(local, forKey: key)
      }
    }
    if outletsChanged { outletsArrived() }
    // Reads and topics: both devices'.
    var reads = cloudReads()
    for (url, time) in ReadLedger.seenTimes { reads[fingerprint(url)] = max(reads[fingerprint(url)] ?? 0, time) }
    writeReads(reads)
    applyReads()
    if let pipeline {
      let remote = Self.topics(cloud.data(forKey: Self.topicsKey))
      pipeline.mergeTopics(remote)
      pushTopics()
    }
    defaults.set(true, forKey: Self.joinedKey)
  }

  // MARK: From this device

  /// After any setting changed here: the synced ones go to iCloud when they differ.
  func pushSettings() {
    let defaults = UserDefaults.standard
    for key in Self.mirroredKeys {
      let local = defaults.object(forKey: key)
      guard !Self.same(local, cloud.object(forKey: key)) else { continue }
      if let local { cloud.set(local, forKey: key) } else { cloud.removeObject(forKey: key) }
    }
  }

  /// Articles read here (a story opened, swiped past in Catchup).
  func read(_ urls: [String], at time: Date = .now) {
    guard !urls.isEmpty else { return }
    var reads = cloudReads()
    let stamp = time.timeIntervalSince1970
    for url in urls { reads[fingerprint(url)] = max(reads[fingerprint(url)] ?? 0, stamp) }
    writeReads(reads)
  }

  /// The topics as they are here, after one was added or removed.
  func pushTopics() {
    guard let pipeline else { return }
    let topics = ((try? pipeline.context.fetch(FetchDescriptor<SemanticTopic>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
      .map { SyncedTopic(phrase: $0.phrase, kind: $0.kindRaw, examples: $0.exampleHeadlines, keywords: $0.keywords, created: $0.createdAt) }
    cloud.set(try? JSONEncoder().encode(topics), forKey: Self.topicsKey)
  }

  // MARK: From another device

  private func received(_ keys: [String]) {
    let defaults = UserDefaults.standard
    var outletsChanged = false
    for key in keys where Self.mirroredKeys.contains(key) {
      let value = cloud.object(forKey: key)
      guard !Self.same(value, defaults.object(forKey: key)) else { continue }
      // A device that has been set up stays set up.
      if key == Self.onboardedKey, value as? Bool != true { continue }
      defaults.set(value, forKey: key)
      if [Self.chosenKey, Self.customKey, Self.onboardedKey].contains(key) { outletsChanged = true }
    }
    if outletsChanged { outletsArrived() }
    if keys.contains(Self.readKey) { applyReads() }
    if keys.contains(Self.topicsKey), let pipeline {
      pipeline.replaceTopics(with: Self.topics(cloud.data(forKey: Self.topicsKey)))
    }
  }

  private func outletsArrived() {
    let store = OutletStore.shared
    let before = store.selection.union(store.customFeeds.map(\.title))
    store.reload()
    let after = store.selection.union(store.customFeeds.map(\.title))
    guard before != after, let pipeline else { return }
    Task { await pipeline.applyOutletChoice(added: !after.subtracting(before).isEmpty) }
  }

  /// What's been read on any device, applied to the articles stored here; also after each sync,
  /// for articles this device has only now fetched.
  func applyReads() {
    guard let pipeline else { return }
    let reads = cloudReads()
    guard !reads.isEmpty else { return }
    let articles = (try? pipeline.context.fetch(FetchDescriptor<ArticleItem>(predicate: #Predicate { !$0.isRead }))) ?? []
    var times: [String: Double] = [:]
    for article in articles {
      if let time = reads[fingerprint(article.url)] { times[article.url] = time }
    }
    guard !times.isEmpty else { return }
    pipeline.markRead(times)
  }

  // MARK: Storage

  private func cloudReads() -> [String: Double] {
    (cloud.dictionary(forKey: Self.readKey) as? [String: Double]) ?? [:]
  }

  private func writeReads(_ reads: [String: Double]) {
    let cutoff = Date.now.timeIntervalSince1970 - Self.keepReads
    cloud.set(reads.filter { $0.value > cutoff }, forKey: Self.readKey)
  }

  /// The first 9 bytes of the link's SHA-256, as 12 characters: a week of reading stays well
  /// under iCloud's 1 MB for the whole store.
  private func fingerprint(_ url: String) -> String {
    if let known = fingerprints[url] { return known }
    let digest = SHA256.hash(data: Data(url.utf8))
    let short = Data(digest.prefix(9)).base64EncodedString()
    fingerprints[url] = short
    return short
  }

  private static func feeds(_ data: Data?) -> [CustomFeed] {
    data.flatMap { try? JSONDecoder().decode([CustomFeed].self, from: $0) } ?? []
  }

  private static func topics(_ data: Data?) -> [SyncedTopic] {
    data.flatMap { try? JSONDecoder().decode([SyncedTopic].self, from: $0) } ?? []
  }

  private static func same(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): (a as AnyObject).isEqual(b)
    default: false
    }
  }
}

/// A followed or muted topic as iCloud keeps it; its vectors are made again on each device.
nonisolated struct SyncedTopic: Codable, Hashable, Sendable {
  var phrase: String
  var kind: String
  var examples: [String]
  var keywords: [String]
  var created: Date

  var key: String { kind + "|" + phrase }
}
