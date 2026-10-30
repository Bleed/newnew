import Foundation

/// Reads the chosen outlets' feeds on the iPhone itself: no news passes through a server of
/// newnew's. The rules are those the feed list was made for (github-scraper/feeds.json):
///
/// - Each item gives its headline, a very short extract (≤ 150 characters), the link, its
///   picture, time and category. Never the article body: the app links out to the publisher.
/// - News feeds give their newest 30 of the last 48 hours. The lighter pillars (Technology,
///   Entertainment, Fashion & Style, Gaming, Lifestyle & Food) publish many small items, so each
///   of their feeds gives its newest 8, and each of those categories but Technology at most 15
///   in all, the outlets taking turns. Their articles carry a few pictures (`galleryURLs`).
/// - "video" feeds (YouTube) give the video and its HD thumbnail, Shorts skipped; "podcast"
///   feeds the episode's audio and length, no picture, for 7 days; "chart" feeds a chart kept
///   for 14 days.
/// - A feed is read up to 1.5 MB (podcast feeds run to 20 MB; their newest episodes come first),
///   and URLCache asks the publisher whether it changed since the last time.
nonisolated enum FeedFetcher {
  static let maxAge: TimeInterval = 48 * 3600
  static let chartMaxAge: TimeInterval = 14 * 24 * 3600
  /// Most podcasts come weekly.
  static let podcastMaxAge: TimeInterval = 7 * 24 * 3600
  static let perFeed = 30
  static let lightCategories: Set<String> = ["Technology", "Entertainment", "Fashion & Style", "Gaming", "Lifestyle & Food"]
  static let lightPerFeed = 8
  static let lightPerCategory = 15
  static let uncappedCategories: Set<String> = ["Technology"]
  static let snippetLength = 150
  static let galleryLimit = 6
  static let maxBytes = 1_500_000
  static let concurrency = 12
  static let userAgent = "newnew/1.0 (RSS reader on iPhone)"

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 15
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 60_000_000)
    configuration.requestCachePolicy = .reloadRevalidatingCacheData
    return URLSession(configuration: configuration)
  }()

  /// The articles of these feeds, deduplicated and capped. `pictures` are the HD video
  /// thumbnails already checked (link → picture), so only new videos are asked about.
  /// `progress` hears how many feeds have answered.
  static func articles(
    _ feeds: [(outlet: String, feed: FeedSource)], pictures: [String: String],
    progress: @escaping @Sendable (Int, Int) async -> Void
  ) async -> [FeedArticleDTO] {
    let all = await withTaskGroup(of: [FeedArticleDTO].self) { group in
      var next = 0
      var done = 0
      var out: [FeedArticleDTO] = []
      func start() {
        guard next < feeds.count else { return }
        let (outlet, feed) = feeds[next]
        next += 1
        group.addTask { await read(feed, outlet: outlet) }
      }
      for _ in 0..<concurrency { start() }
      for await articles in group {
        out += articles
        done += 1
        await progress(done, feeds.count)
        start()
      }
      return out
    }
    var articles = capped(deduplicated(all))
    // maxresdefault only exists for HD uploads; otherwise the 4:3 hqdefault (with bars).
    await withTaskGroup(of: (Int, String).self) { group in
      for (index, article) in articles.enumerated() {
        guard let id = article.videoID else { continue }
        if let known = pictures[article.url] {
          articles[index].imageURL = known
          continue
        }
        group.addTask {
          let hd = "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"
          var request = URLRequest(url: URL(string: hd)!, timeoutInterval: 6)
          request.httpMethod = "HEAD"
          let status = ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
          return (index, status == 200 ? hd : "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
      }
      for await (index, picture) in group { articles[index].imageURL = picture }
    }
    return articles
  }

  // MARK: One feed

  static func read(_ feed: FeedSource, outlet: String) async -> [FeedArticleDTO] {
    guard let url = URL(string: feed.url), let data = try? await download(url) else { return [] }
    let light = lightCategories.contains(feed.category ?? "")
    let parser = FeedParser()
    parser.limit = 60
    let xml = XMLParser(data: data)
    xml.delegate = parser
    // A feed cut off at `maxBytes` (or stopped at `limit`) ends in an error; the items before
    // it are whole.
    xml.parse()
    let cutoff = Date.now.addingTimeInterval(-(feed.kind == "chart" ? chartMaxAge : feed.kind == "podcast" ? podcastMaxAge : maxAge))
    var out: [FeedArticleDTO] = []
    for item in parser.items {
      guard let article = article(item, feed: feed, outlet: outlet, light: light), article.publishedAt >= cutoff else { continue }
      out.append(article)
      if out.count >= (light ? lightPerFeed : perFeed) { break }
    }
    return out
  }

  /// The feed's first `maxBytes`, revalidated against the cache.
  static func download(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
    var data = Data()
    data.reserveCapacity(min(max(Int(response.expectedContentLength), 16_384), maxBytes))
    var buffer = [UInt8]()
    buffer.reserveCapacity(65_536)
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count == 65_536 {
        data.append(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        if data.count >= maxBytes { bytes.task.cancel(); break }
      }
    }
    data.append(contentsOf: buffer)
    return data
  }

  static func article(_ item: FeedParser.Item, feed: FeedSource, outlet: String, light: Bool) -> FeedArticleDTO? {
    // Titles too can carry entities a feed encoded twice ("Google&#8217;s").
    let title = CustomFeedReader.plain(item.title)
    // Podcast episodes often have no page (Megaphone): their audio is the link.
    let page = item.link.isEmpty && feed.kind == "podcast" ? item.audio ?? "" : item.link
    guard !title.isEmpty, let link = canonicalURL(page), let date = item.date else { return nil }
    var picture = item.image ?? item.inlineImage
    var videoID: String?
    var audio: String?
    switch feed.kind {
    case "video":
      guard let id = item.videoID, !link.contains("/shorts/") else { return nil }
      videoID = id
      picture = "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"
    case "podcast":
      guard let url = item.audio else { return nil }
      audio = url
      // The show's square logo makes a poor news picture: none.
      picture = nil
    default: break
    }
    return FeedArticleDTO(
      title: feed.kind == "video" ? videoTitle(title, outlet: outlet) : title,
      snippet: truncate(CustomFeedReader.plain(item.summary), snippetLength),
      outlet: outlet, url: link,
      imageURL: picture.flatMap { upgrade(absolute($0, base: link)) },
      // Never in the future: some feeds stamp tomorrow's print date.
      publishedAt: min(date, .now),
      category: feed.category, country: feed.country, videoID: videoID,
      audioURL: audio, audioSeconds: audio == nil ? nil : item.seconds,
      isChart: feed.kind == "chart" ? true : nil,
      galleryURLs: light && feed.kind == nil ? gallery(item, base: link) : nil)
  }

  // MARK: The whole

  /// One entry per link, and per outlet and headline (outlets repeat stories across sections).
  static func deduplicated(_ articles: [FeedArticleDTO]) -> [FeedArticleDTO] {
    var urls = Set<String>(), titles = Set<String>()
    return articles.sorted { $0.publishedAt > $1.publishedAt }.filter { article in
      let key = "\(article.outlet)|\(article.title.lowercased())"
      guard !urls.contains(article.url), !titles.contains(key) else { return false }
      urls.insert(article.url)
      titles.insert(key)
      return true
    }
  }

  /// The lighter pillars' caps. Outlets take turns (each one's newest, then each one's second
  /// newest, …), so two busy sneaker blogs don't fill Fashion & Style on their own.
  static func capped(_ articles: [FeedArticleDTO]) -> [FeedArticleDTO] {
    var rank: [String: Int] = [:]
    var perOutlet: [String: Int] = [:]
    for article in articles {
      let key = "\(article.category ?? "")|\(article.outlet)"
      rank[article.url] = perOutlet[key, default: 0]
      perOutlet[key, default: 0] += 1
    }
    var kept = Set<String>()
    for category in lightCategories.subtracting(uncappedCategories) {
      let inCategory = articles.filter { $0.category == category }
        .sorted { (rank[$0.url] ?? 0, $1.publishedAt) < (rank[$1.url] ?? 0, $0.publishedAt) }
      kept.formUnion(inCategory.prefix(lightPerCategory).map(\.url))
    }
    return articles.filter { article in
      guard let category = article.category, lightCategories.contains(category), !uncappedCategories.contains(category) else { return true }
      return kept.contains(article.url)
    }
  }

  // MARK: Text

  /// At most `length` characters, cut at a word.
  static func truncate(_ text: String, _ length: Int) -> String {
    guard text.count > length else { return text }
    let cut = String(text.prefix(length))
    let space = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) } ?? 0
    let kept = String(cut.prefix(max(space, Int(Double(length) * 0.6))))
    return kept.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:–-")) + "…"
  }

  /// YouTube titles carry channel tags: "… | DW News", "… • FRANCE 24 English", "… #BBCNews".
  static func videoTitle(_ title: String, outlet: String) -> String {
    let first = outlet.split(separator: " ").first.map { $0.lowercased() } ?? ""
    var out = title.replacing(/(\s+#[\p{L}\p{N}_]+)+\s*$/, with: "").trimmingCharacters(in: .whitespaces)
    // A last " | x", " • x" or " - x" segment that names the channel.
    if let match = out.firstMatch(of: /^(.*\S)\s+[|•–-]\s+([^|•–-]{1,40})$/), match.output.2.lowercased().contains(first) {
      out = String(match.output.1).trimmingCharacters(in: .whitespaces)
    }
    return out
  }

  // MARK: Links and pictures

  static func canonicalURL(_ raw: String) -> String? {
    guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? "")
    else { return nil }
    if let items = parts.queryItems {
      let kept = items.filter { $0.name.firstMatch(of: /^(utm_|fbclid$|gclid$|mc_|cmpid$|at_|ns_|ocid$|smid$|partner$|traffic_source$)/) == nil }
      parts.queryItems = kept.isEmpty ? nil : kept
    }
    parts.fragment = nil
    return parts.url?.absoluteString
  }

  static func absolute(_ url: String, base: String) -> String? {
    URL(string: url.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: URL(string: base))?.absoluteString
  }

  /// Feeds often carry a small thumbnail where a larger rendition exists at a known address.
  static func upgrade(_ url: String?) -> String? {
    // BBC: ichef.bbci.co.uk/ace/standard/240/… → 976 wide.
    guard let url, url.contains("ichef.bbci.co.uk") else { return url }
    return url.replacing(/\/(standard|branded_news|news)\/\d{2,4}\//) { "/\($0.output.1)/976/" }
  }

  /// Up to 6 distinct pictures from the item, for a lookbook or a recipe's steps; nil for fewer
  /// than two. Tracking pixels, icons and avatars are skipped, and renditions of one picture
  /// (the same path with other sizes) count once.
  static func gallery(_ item: FeedParser.Item, base: String) -> [String]? {
    var candidates = item.pictures
    for tag in item.html.matches(of: /<img\b[^>]*>/.ignoresCase()) {
      let text = String(tag.output)
      guard let src = text.firstMatch(of: /\ssrc=["']([^"']+)["']/.ignoresCase())?.output.1 else { continue }
      let width = text.firstMatch(of: /\swidth=["']?(\d+)/.ignoresCase()).flatMap { Int($0.output.1) } ?? 0
      if width == 0 || width >= 300 { candidates.append(String(src)) }
    }
    var seen = Set<String>()
    var out: [String] = []
    for raw in candidates {
      guard let url = upgrade(absolute(raw, base: base)), url.hasPrefix("https:"),
        url.firstMatch(of: /pixel|feedburner|gravatar|emoji|avatar|logo|icon|\.gif(\?|$)|\.svg(\?|$)/.ignoresCase()) == nil
      else { continue }
      let path = url.replacing(/\?.*$/, with: "")
      // WordPress thumbnails name their size: "-300x200.jpg" is too small to swipe through.
      if let named = path.firstMatch(of: /-(\d+)x\d+\.\w+$/), let width = Int(named.output.1), width < 600 { continue }
      // One picture, many sizes: "photo-1024x683.jpg", "…/w_640/…", "?w=…" all key to the same.
      let key = path.replacing(/-\d+x\d+(?=\.\w+$)/, with: "").replacing(/\/(w|h|c)_[^\/]+/, with: "").lowercased()
      guard seen.insert(key).inserted else { continue }
      out.append(url)
      if out.count >= galleryLimit { break }
    }
    return out.count > 1 ? out : nil
  }
}
