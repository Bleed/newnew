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
  @State private var showsLaunch = !LoadingBoard.hasPlayed
  @Environment(\.scenePhase) var scenePhase
  /// Whether the store had stories at launch; if not, the loading board waits for the feed.
  let hadStories: Bool

  /// For work that starts outside the views: background refresh and pushes.
  static var pipeline: FeedSyncPipeline?

  init() {
    let container: ModelContainer
    do {
      container = try ModelContainer(for: ArticleItem.self, StoryCluster.self, SemanticTopic.self)
    } catch {
      // A store from an older build that can't be migrated: start over (it's only a cache of
      // the feed, plus your topics).
      let url = URL.applicationSupportDirectory.appending(path: "default.store")
      try? FileManager.default.removeItem(at: url)
      container = try! ModelContainer(for: ArticleItem.self, StoryCluster.self, SemanticTopic.self)
    }
    self.container = container
    let pipeline = FeedSyncPipeline(context: container.mainContext)
    _pipeline = State(initialValue: pipeline)
    Self.pipeline = pipeline
    hadStories = pipeline.storyCount > 0
    LaunchState.shared.isShowing = !LoadingBoard.hasPlayed
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        FeedView()
        if showsLaunch { LoadingBoard(isShowing: $showsLaunch, waitsForFeed: !hadStories) }
      }
      .environment(pipeline)
      .task {
        // With stories to show, the sync waits for the board to fade, so its work on the main
        // actor can't hold the board up.
        if hadStories { try? await Task.sleep(for: .seconds(2.4)) }
        await syncInForeground()
        await Alerts.updateSubscriptions()
      }
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        IntelligenceService.refreshAvailability()
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
    return true
  }

  /// A breaking push (CloudKit): sync now, so the story is grouped when the alert is opened.
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil, let pipeline = NewnewApp.pipeline else { return .noData }
    await pipeline.sync()
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
