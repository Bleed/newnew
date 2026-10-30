import AVFoundation
import Foundation
import MediaPlayer

/// Plays one podcast episode at a time, keeps playing in the background, and shows on the Lock
/// Screen with play and pause.
@MainActor @Observable final class AudioPlayer {
  static let shared = AudioPlayer()

  private(set) var current: String?
  private(set) var isPlaying = false
  private var player: AVPlayer?
  private var endObserver: NSObjectProtocol?

  private init() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { _ in
      Task { @MainActor in AudioPlayer.shared.resume() }
      return .success
    }
    center.pauseCommand.addTarget { _ in
      Task { @MainActor in AudioPlayer.shared.pause() }
      return .success
    }
  }

  func isPlaying(_ url: String) -> Bool { current == url && isPlaying }

  /// Listen: the episode in Apple Podcasts when it's there and the app is installed; otherwise
  /// here. Pausing (or resuming) an episode already playing here stays here.
  func listen(_ article: ArticleItem) {
    if current == article.audioURL { toggle(article); return }
    Task {
      guard let url = await PodcastLinks.appleURL(for: article) else { toggle(article); return }
      LinkOpener.open(url) { AudioPlayer.shared.toggle(article) }
    }
  }

  /// Plays the episode, or pauses it if it's the one playing.
  func toggle(_ article: ArticleItem) {
    guard let urlString = article.audioURL, let url = URL(string: urlString) else { return }
    if current == urlString {
      isPlaying ? pause() : resume()
      return
    }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try? AVAudioSession.sharedInstance().setActive(true)
    let item = AVPlayerItem(url: url)
    player = AVPlayer(playerItem: item)
    current = urlString
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
      Task { @MainActor in AudioPlayer.shared.finish() }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: article.title,
      MPMediaItemPropertyArtist: article.outlet,
      MPMediaItemPropertyPlaybackDuration: article.audioSeconds ?? 0,
    ]
    resume()
  }

  func resume() {
    player?.play()
    isPlaying = true
    MPNowPlayingInfoCenter.default().playbackState = .playing
  }

  func pause() {
    player?.pause()
    isPlaying = false
    MPNowPlayingInfoCenter.default().playbackState = .paused
  }

  private func finish() {
    isPlaying = false
    current = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
}
