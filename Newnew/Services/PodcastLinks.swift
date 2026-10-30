import Foundation

/// Finds a podcast episode in Apple Podcasts, so Listen can open it there. Feeds don't carry
/// Apple's IDs, so the show is looked up by name in Apple's public podcast directory (iTunes
/// Search API) and the episode matched by its audio address or title. Only the show's name is
/// sent. Answers are kept for the session.
@MainActor enum PodcastLinks {
  private static var shows: [String: Int?] = [:]
  private static var episodes: [String: URL?] = [:]

  /// The episode's page on podcasts.apple.com (a universal link: the Podcasts app opens it), or
  /// nil when it isn't found.
  static func appleURL(for episode: ArticleItem) async -> URL? {
    guard let audio = episode.audioURL else { return nil }
    if let known = episodes[audio] { return known }
    let url = await lookUp(show: episode.outlet, audio: audio, title: episode.title)
    episodes[audio] = url
    return url
  }

  private static func lookUp(show: String, audio: String, title: String) async -> URL? {
    guard let showID = await showID(show) else { return nil }
    var parts = URLComponents(string: "https://itunes.apple.com/lookup")!
    parts.queryItems = [.init(name: "id", value: "\(showID)"), .init(name: "media", value: "podcast"),
                        .init(name: "entity", value: "podcastEpisode"), .init(name: "limit", value: "50")]
    guard let url = parts.url, let results = await results(url) else { return nil }
    let wantedAudio = Self.audioKey(audio)
    let wantedTitle = title.lowercased()
    let match = results.first { ($0["episodeUrl"] as? String).map(Self.audioKey) == wantedAudio }
      ?? results.first { ($0["trackName"] as? String)?.lowercased() == wantedTitle }
    guard let match, let trackID = match["trackId"] as? Int else { return nil }
    return URL(string: "https://podcasts.apple.com/podcast/id\(showID)?i=\(trackID)")
  }

  private static func showID(_ name: String) async -> Int? {
    if let known = shows[name] { return known }
    var parts = URLComponents(string: "https://itunes.apple.com/search")!
    parts.queryItems = [.init(name: "term", value: name), .init(name: "media", value: "podcast"),
                        .init(name: "entity", value: "podcast"), .init(name: "limit", value: "5")]
    var id: Int?
    if let url = parts.url, let results = await results(url) {
      let exact = results.first { ($0["collectionName"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }
      id = (exact ?? results.first)?["collectionId"] as? Int
    }
    shows[name] = id
    return id
  }

  private static func results(_ url: URL) async -> [[String: Any]]? {
    guard let (data, _) = try? await URLSession.shared.data(from: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["results"] as? [[String: Any]]
  }

  /// The audio file's own name, without tracking redirects in front of it or a query after:
  /// "…/pdst.fm/e/traffic.megaphone.fm/VMP2258517412.mp3?updated=…" → "vmp2258517412.mp3".
  static func audioKey(_ address: String) -> String {
    let path = address.split(separator: "?").first.map(String.init) ?? address
    return (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
  }
}
