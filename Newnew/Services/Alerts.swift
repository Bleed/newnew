import BackgroundTasks
import CloudKit
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Alerts, both kinds free to run:
///
/// 1. Background refresh: iOS wakes the app now and then (it decides when; often hours apart),
///    the app syncs, and posts a local alert for a new story on a topic you follow, or a
///    breaking story while push isn't set up.
/// 2. Push: the scraper spots breaking news and writes a `Breaking` record to the app's iCloud
///    public database; the app's CloudKit subscription has Apple push it to every device that
///    switched Breaking on. Needs a CloudKit container (`NEWNEW_CLOUDKIT_CONTAINER`).
///
/// What you follow and mute never leaves the iPhone: topic alerts are only ever local.
@MainActor enum Alerts {
  static let refreshTaskID = "com.svein.newnew.refresh"
  static let breakingSubscriptionID = "breaking"

  /// The settings in the Topics sheet.
  static let breakingKey = "alerts.breaking"
  static let followingKey = "alerts.following"
  /// Off while Today opens as an edition (zen mode): its only notification is "edition ready".
  static var breakingOn: Bool {
    UserDefaults.standard.bool(forKey: breakingKey) && UserDefaults.standard.string(forKey: TodayMode.key) != TodayMode.edition.rawValue
  }
  static var followingOn: Bool { UserDefaults.standard.bool(forKey: followingKey) }

  /// Breaking: covered by at least this many outlets…
  static let breakingOutlets = 5
  /// …with at least this many articles in the last 45 minutes.
  static let breakingRecentArticles = 3
  static let breakingWindow: TimeInterval = 45 * 60
  /// Never more than this many alerts per check, or per day.
  static let perCheck = 3
  static let perDay = 8

  static let cloudKitContainer: String? = (Bundle.main.object(forInfoDictionaryKey: "NewnewCloudKitContainer") as? String)
    .flatMap { $0.isEmpty ? nil : $0 }

  /// Whether `CKContainer(identifier:)` is safe to touch: it throws an uncaught Objective-C
  /// exception (`SIGABRT`) in a binary signed without the iCloud entitlement. Never in the
  /// Simulator. On a device, a development or ad hoc build carries its provisioning profile, so
  /// that is checked for the container; TestFlight and App Store installs have the profile
  /// stripped and are always signed with the entitlement, so a missing profile means yes.
  /// (Not `ubiquityIdentityToken`: that needs iCloud Drive, which public-database pushes don't.)
  private static let isCloudKitAvailable: Bool = {
    guard let container = cloudKitContainer else { return false }
    #if targetEnvironment(simulator)
      return false
    #else
      guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
        return true
      }
      guard let data = try? Data(contentsOf: profileURL), let content = String(data: data, encoding: .isoLatin1) else {
        return false
      }
      return content.contains("com.apple.developer.icloud-container-identifiers") && content.contains(container)
    #endif
  }()

  // MARK: Permission and settings

  /// Asks for permission the first time an alert is switched on.
  /// Runs the callback off `@MainActor` so `UNUserNotificationCenter`'s background XPC queue
  /// never triggers a Swift 6 `_dispatch_assert_queue_fail` crash.
  static func requestPermission() async -> Bool {
    await requestNotificationPermissionOffMainActor()
  }

  nonisolated private static func requestNotificationPermissionOffMainActor() async -> Bool {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        continuation.resume(returning: granted)
      }
    }
  }

  nonisolated private static func isAuthorizedOffMainActor() async -> Bool {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus == .authorized)
      }
    }
  }

  nonisolated private static func addNotificationOffMainActor(_ request: UNNotificationRequest) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      UNUserNotificationCenter.current().add(request) { _ in
        continuation.resume()
      }
    }
  }

  /// What the last subscription attempt came to, shown under the Breaking switch: "on", or
  /// why not, in CloudKit's own words. Saved, so a failure can be read off the phone.
  static let pushStatusKey = "alerts.pushStatus"

  /// Keeps the CloudKit subscription in step with the Breaking setting.
  ///
  /// CloudKit refused build 29's subscription with BAD_REQUEST and the error was thrown away,
  /// so nothing showed. Now each attempt is reported, and if the full alert (headline, outlet
  /// count as subtitle, background wake) is refused, simpler ones are tried in turn.
  static func updateSubscriptions() async {
    let defaults = UserDefaults.standard
    guard let cloudKitContainer, isCloudKitAvailable else {
      defaults.set(nil, forKey: pushStatusKey)
      return
    }
    let container = CKContainer(identifier: cloudKitContainer)
    let database = container.publicCloudDatabase
    guard breakingOn else {
      _ = try? await database.deleteSubscription(withID: breakingSubscriptionID)
      defaults.set(nil, forKey: pushStatusKey)
      return
    }
    if let status = try? await container.accountStatus(), status != .available {
      defaults.set("Sign in to iCloud on this iPhone to get breaking alerts.", forKey: pushStatusKey)
      return
    }
    UIApplication.shared.registerForRemoteNotifications()
    var failures: [String] = []
    for (name, info) in notificationVariants() {
      let subscription = CKQuerySubscription(
        recordType: "Breaking", predicate: NSPredicate(value: true), subscriptionID: breakingSubscriptionID,
        options: [.firesOnRecordCreation])
      subscription.notificationInfo = info
      do {
        _ = try await database.save(subscription)
        defaults.set("on:\(name)", forKey: pushStatusKey)
        return
      } catch {
        failures.append("\(name): \(describe(error))")
      }
    }
    defaults.set("Breaking alerts couldn't be set up. " + failures.joined(separator: " · "), forKey: pushStatusKey)
  }

  /// The alert, richest first.
  static func notificationVariants() -> [(String, CKSubscription.NotificationInfo)] {
    func headline(_ info: CKSubscription.NotificationInfo) {
      info.title = "Breaking"
      info.alertLocalizationKey = "%1$@"
      info.alertLocalizationArgs = ["headline"]
      info.soundName = "default"
    }
    let full = CKSubscription.NotificationInfo()
    headline(full)
    full.desiredKeys = ["headline", "url", "outlets"]
    // Wakes the app too, so the story is already grouped when the alert is opened.
    full.shouldSendContentAvailable = true
    let plainHeadline = CKSubscription.NotificationInfo()
    headline(plainHeadline)
    let fixed = CKSubscription.NotificationInfo()
    fixed.alertBody = "Breaking news on newnew"
    fixed.soundName = "default"
    return [("full", full), ("headline", plainHeadline), ("plain", fixed)]
  }

  /// CloudKit's own reason, which `localizedDescription` alone often leaves out.
  static func describe(_ error: Error) -> String {
    guard let error = error as? CKError else { return error.localizedDescription }
    let server = (error.errorUserInfo["ServerErrorDescription"] as? String) ?? ""
    return "CKError \(error.code.rawValue) \(error.localizedDescription) \(server)".trimmingCharacters(in: .whitespaces)
  }

  // MARK: Background refresh

  static func scheduleRefresh() {
    guard BackgroundRefresh.current != .off || breakingOn || followingOn else {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
      return
    }
    let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  /// iOS woke the app: sync when the setting and the network allow (`BackgroundRefresh`),
  /// then alert about what's new.
  static func backgroundRefresh(_ pipeline: FeedSyncPipeline) async {
    scheduleRefresh()
    guard await BackgroundRefresh.allowedNow() else { return }
    await pipeline.sync()
    await notifyNewStories(pipeline, posting: true)
  }

  // MARK: Deciding what to alert about

  /// Stories already alerted about (or seen in the app), so nothing is sent twice.
  private static let seenKey = "alerts.seen"
  private static let sentKey = "alerts.sent"

  /// After a sync. In the foreground (`posting` false) it only marks what's there as seen, so
  /// a later background check doesn't announce what you've already looked at.
  static func notifyNewStories(_ pipeline: FeedSyncPipeline, posting: Bool) async {
    let defaults = UserDefaults.standard
    var seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
    var sent = (defaults.array(forKey: sentKey) as? [Double] ?? []).filter { Date.now.timeIntervalSince1970 - $0 < 86_400 }
    let clusters = ((try? pipeline.context.fetch(FetchDescriptor<StoryCluster>())) ?? []).filter { !$0.isMuted && !$0.articles.isEmpty }

    var candidates: [(cluster: StoryCluster, title: String)] = []
    // Breaking from the device itself only while push isn't set up.
    if breakingOn, !isCloudKitAvailable {
      for cluster in clusters where isBreaking(cluster) { candidates.append((cluster, "Breaking")) }
    }
    if followingOn {
      for cluster in clusters where cluster.isFollowed && isFresh(cluster) {
        candidates.append((cluster, cluster.followedBy ?? "Following"))
      }
    }

    let authorized = await isAuthorizedOffMainActor()
    var posted = 0
    for (cluster, title) in candidates.sorted(by: { $0.cluster.outlets.count > $1.cluster.outlets.count }) {
      let key = cluster.id.uuidString
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      guard posting, authorized, posted < perCheck, sent.count < perDay, let lead = cluster.lead else { continue }
      let content = UNMutableNotificationContent()
      content.title = title
      content.subtitle = "\(cluster.outlets.count) \(cluster.outlets.count == 1 ? "outlet" : "outlets")"
      content.body = lead.title
      content.sound = .default
      content.threadIdentifier = title == "Breaking" ? "breaking" : "following"
      content.userInfo = ["story": key]
      let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
      await addNotificationOffMainActor(req)
      posted += 1
      sent.append(Date.now.timeIntervalSince1970)
    }
    defaults.set(Array(seen.suffix(500)), forKey: seenKey)
    defaults.set(sent, forKey: sentKey)
  }

  static func isBreaking(_ cluster: StoryCluster) -> Bool {
    let recent = cluster.articles.filter { Date.now.timeIntervalSince($0.publishedAt) < breakingWindow }
    return cluster.outlets.count >= breakingOutlets && recent.count >= breakingRecentArticles
  }

  /// A followed story with something in the last two hours.
  static func isFresh(_ cluster: StoryCluster) -> Bool {
    Date.now.timeIntervalSince(cluster.updatedAt) < 2 * 3600
  }
}

/// Where a tapped alert should take the feed.
@MainActor @Observable final class Router {
  static let shared = Router()
  /// A story from a local alert.
  var storyID: UUID?
  /// An article from a push (the story it belongs to is found after the sync it triggers).
  var articleURL: String?
}
