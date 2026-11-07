import BackgroundTasks
import CloudKit
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

@main
struct NewnewApp: App {
  @UIApplicationDelegateAdaptor var delegate: AppDelegate
  let container: ModelContainer
  @State private var pipeline: FeedSyncPipeline
  /// The full-screen block loader: only with nothing stored to read yet. Every other sync runs in
  /// Today's top while you read (`NewsTop`), and asks before showing what it found.
  @State private var showsLaunch: Bool
  @State private var outlets = OutletStore.shared
  @Environment(\.scenePhase) var scenePhase

  /// For work that starts outside the views: background refresh and pushes.
  static var pipeline: FeedSyncPipeline?

  init() {
    let container: ModelContainer
    // Local only. With iCloud in the app's entitlements (for breaking-news pushes) SwiftData
    // would otherwise try to sync this store to CloudKit, which these models don't allow.
    let configuration = ModelConfiguration(cloudKitDatabase: .none)
    let types: [any PersistentModel.Type] = [ArticleItem.self, StoryCluster.self, SemanticTopic.self]
    do {
      container = try ModelContainer(for: Schema(types), configurations: configuration)
    } catch {
      // A store from an older build that can't be migrated: start over (it's only a cache of
      // the feed, plus your topics).
      let url = URL.applicationSupportDirectory.appending(path: "default.store")
      try? FileManager.default.removeItem(at: url)
      container = try! ModelContainer(for: Schema(types), configurations: configuration)
    }
    self.container = container
    let pipeline = FeedSyncPipeline(context: container.mainContext)
    _pipeline = State(initialValue: pipeline)
    Self.pipeline = pipeline
    let empty = OutletStore.shared.hasOnboarded && !pipeline.hasStories
    _showsLaunch = State(initialValue: empty)
    LaunchState.shared.isShowing = empty
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        FeedView()
        // First launch: choose outlets (and own feeds, alerts) before reading.
        if !outlets.hasOnboarded {
          OnboardingView { withAnimation(.easeOut(duration: 0.3)) {} }
            .transition(.opacity)
        }
        if showsLaunch {
          BlockLoader {
            withAnimation(.easeOut(duration: 0.3)) { showsLaunch = false } completion: { LaunchState.shared.isShowing = false }
          }
          .transition(.opacity)
        }
      }
      .environment(pipeline)
      .task {
        await outlets.refreshCatalog()
        await syncInForeground()
        await Alerts.updateSubscriptions()
      }
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        IntelligenceService.refreshAvailability()
        // Back after hours away too: the sync runs in Today's top, under what you were reading.
        Task { await syncInForeground() }
      case .background:
        Alerts.scheduleRefresh()
      default:
        break
      }
    }
    .backgroundTask(.appRefresh(Alerts.refreshTaskID)) {
      guard let pipeline = await Self.pipeline else { return }
      await Alerts.backgroundRefresh(pipeline)
    }
  }

  /// What's on screen counts as seen: no alert for it later.
  func syncInForeground() async {
    await pipeline.syncIfNeeded()
    await Alerts.notifyNewStories(pipeline, posting: false)
  }
}

/// Alert taps and pushes.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // Zen mode is gone: its "edition ready" reminders and settings go too.
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["edition.7", "edition.18"])
    for key in ["todayMode", "editionSize", "editionReady", "edition.current"] { UserDefaults.standard.removeObject(forKey: key) }
    // The longer background sync (the short refresh is the scene's `.backgroundTask`).
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Alerts.syncTaskID, using: .main) { task in
      MainActor.assumeIsolated { Alerts.runProcessing(task as! BGProcessingTask) }
    }
    return true
  }

  /// A breaking push (CloudKit): sync now, so the story is grouped when the alert is opened.
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil, let pipeline = NewnewApp.pipeline else { return .noData }
    // The alert shows either way; reading the feeds waits for what the setting allows.
    guard await BackgroundRefresh.allowedNow() else { return .noData }
    await pipeline.sync(inStages: true)
    return .newData
  }

  /// In the app already: still show it, quietly.
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let userInfo = response.notification.request.content.userInfo
    if let story = userInfo["story"] as? String, let id = UUID(uuidString: story) {
      Router.shared.storyID = id
    } else if let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
      let url = query.recordFields?["url"] as? String
    {
      Router.shared.articleURL = url
    }
  }
}
