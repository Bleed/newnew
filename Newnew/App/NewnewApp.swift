import SwiftData
import SwiftUI

@main
struct NewnewApp: App {
  let container: ModelContainer
  @State private var pipeline: FeedSyncPipeline
  @State private var showsLaunch = !LaunchBoard.hasPlayed
  @Environment(\.scenePhase) var scenePhase

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
    _pipeline = State(initialValue: FeedSyncPipeline(context: container.mainContext))
    LaunchState.shared.isShowing = !LaunchBoard.hasPlayed
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        FeedView()
        if showsLaunch { LaunchBoard(isShowing: $showsLaunch) }
      }
      .environment(pipeline)
      .task { await pipeline.syncIfNeeded() }
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        IntelligenceService.refreshAvailability()
        Task { await pipeline.syncIfNeeded() }
      }
    }
  }
}
