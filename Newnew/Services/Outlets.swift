import Foundation

/// One outlet the reader can choose, from the scraper's `outlets.json` (a copy ships in the app
/// for a first launch offline).
nonisolated struct OutletInfo: Codable, Hashable, Identifiable, Sendable {
  var outlet: String
  var categories: [String]
  var kinds: [String]
  var id: String { outlet }

  /// Where it's listed when choosing: its first category's pillar, or Video / Podcasts for
  /// outlets that only have those.
  var group: OutletGroup {
    let category = categories.first(where: { $0 != "Data" }) ?? categories.first
    // Listed with its news when it has any (BBC News has videos too).
    if kinds.contains("article") || kinds.contains("chart") { return .pillar(Pillar(category: category)) }
    if kinds.contains("podcast") { return .podcasts }
    if kinds.contains("video") { return .video }
    return .pillar(Pillar(category: category))
  }
}

nonisolated enum OutletGroup: Hashable, Identifiable, Sendable {
  case pillar(Pillar)
  case video
  case podcasts

  var id: String { title }
  var title: String {
    switch self {
    case .pillar(let pillar): pillar.title
    case .video: "Video"
    case .podcasts: "Podcasts"
    }
  }

  static let all: [OutletGroup] = Pillar.allCases.map { .pillar($0) } + [.video, .podcasts]
}

/// A feed the reader added: read on this iPhone only, never by the scraper.
nonisolated struct CustomFeed: Codable, Hashable, Identifiable, Sendable {
  var url: String
  var title: String
  var id: String { url }
}

/// Which outlets newnew reads: the reader's choice (onboarding, Settings › Outlets) and their
/// own feeds. Articles from an outlet not chosen are never stored. Kept in UserDefaults.
@MainActor @Observable final class OutletStore {
  static let shared = OutletStore()

  private static let chosenKey = "outlets.chosen"
  private static let onboardedKey = "outlets.onboarded"
  private static let customKey = "outlets.custom"

  private(set) var catalog: [OutletInfo]
  /// Nil until the reader has chosen: everything is read meanwhile (the first launch's sync runs
  /// while onboarding is on screen).
  private(set) var chosen: Set<String>?
  private(set) var customFeeds: [CustomFeed]
  private(set) var hasOnboarded: Bool

  init() {
    let defaults = UserDefaults.standard
    catalog = Self.bundledCatalog()
    chosen = (defaults.array(forKey: Self.chosenKey) as? [String]).map(Set.init)
    hasOnboarded = defaults.bool(forKey: Self.onboardedKey)
    customFeeds = (defaults.data(forKey: Self.customKey)).flatMap { try? JSONDecoder().decode([CustomFeed].self, from: $0) } ?? []
  }

  private static func bundledCatalog() -> [OutletInfo] {
    guard let url = Bundle.main.url(forResource: "outlets", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let list = try? JSONDecoder().decode(Catalog.self, from: data)
    else { return [] }
    return list.outlets
  }

  private struct Catalog: Decodable { var outlets: [OutletInfo] }

  /// The published list, next to the feed's index; keeps the bundled one if it can't be read.
  func refreshCatalog() async {
    guard let base = FeedSyncPipeline.feedURL?.deletingLastPathComponent() else { return }
    guard let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "outlets.json")),
      let list = try? JSONDecoder().decode(Catalog.self, from: data), !list.outlets.isEmpty
    else { return }
    catalog = list.outlets
  }

  func outlets(in group: OutletGroup) -> [OutletInfo] { catalog.filter { $0.group == group } }

  /// Whether articles from this outlet are read. Own feeds always are.
  func reads(_ outlet: String) -> Bool {
    if customFeeds.contains(where: { $0.title == outlet }) { return true }
    return chosen?.contains(outlet) ?? true
  }

  /// The selection being edited: everything until the reader has chosen.
  var selection: Set<String> { chosen ?? Set(catalog.map(\.outlet)) }

  func setChosen(_ outlets: Set<String>) {
    chosen = outlets
    UserDefaults.standard.set(Array(outlets).sorted(), forKey: Self.chosenKey)
  }

  func finishOnboarding() {
    if chosen == nil { setChosen(selection) }
    hasOnboarded = true
    UserDefaults.standard.set(true, forKey: Self.onboardedKey)
  }

  func add(_ feed: CustomFeed) {
    guard !customFeeds.contains(where: { $0.url == feed.url }) else { return }
    customFeeds.append(feed)
    saveCustom()
  }

  func remove(_ feed: CustomFeed) {
    customFeeds.removeAll { $0.url == feed.url }
    saveCustom()
  }

  private func saveCustom() {
    UserDefaults.standard.set(try? JSONEncoder().encode(customFeeds), forKey: Self.customKey)
  }
}

/// Reads a feed the reader added, on this iPhone: finds the feed behind a site address (its
/// `<link rel="alternate">`, then the usual paths) and turns RSS or Atom items into articles.
nonisolated enum CustomFeedReader {
  struct Found: Sendable {
    var feed: CustomFeed
    var articles: [FeedArticleDTO]
  }

  enum Failure: LocalizedError {
    case badAddress, noFeed
    var errorDescription: String? {
      switch self {
      case .badAddress: "That doesn't look like a web address."
      case .noFeed: "No RSS or Atom feed was found there."
      }
    }
  }

  /// A site or feed address → the feed and its articles.
  static func find(_ input: String) async throws -> Found {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), url.host() != nil else { throw Failure.badAddress }
    if let found = try? await read(url) { return found }
    // A web page: the feed it names, then the usual addresses.
    var candidates: [URL] = []
    if let (data, response) = try? await fetch(url), let html = String(data: data, encoding: .utf8) {
      candidates += alternateLinks(html, base: response.url ?? url)
    }
    let root = URL(string: "\(url.scheme ?? "https")://\(url.host() ?? "")")!
    candidates += ["feed", "rss", "rss.xml", "feed.xml", "atom.xml", "index.xml"].map { root.appending(path: $0) }
    for candidate in candidates {
      if let found = try? await read(candidate) { return found }
    }
    throw Failure.noFeed
  }

  /// The articles of a feed added before.
  static func articles(_ feed: CustomFeed) async -> [FeedArticleDTO] {
    guard let url = URL(string: feed.url), let found = try? await read(url) else { return [] }
    return found.articles.map { var article = $0; article.outlet = feed.title; return article }
  }

  private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("newnew/1.0 (RSS reader on iPhone)", forHTTPHeaderField: "User-Agent")
    return try await URLSession.shared.data(for: request)
  }

  private static func read(_ url: URL) async throws -> Found {
    let (data, response) = try await fetch(url)
    let parser = FeedParser()
    let xml = XMLParser(data: data)
    xml.delegate = parser
    guard xml.parse(), parser.isFeed, !parser.items.isEmpty else { throw Failure.noFeed }
    let title = parser.title.isEmpty ? (url.host() ?? "My feed").replacingOccurrences(of: "www.", with: "") : parser.title
    let feedURL = (response.url ?? url).absoluteString
    let cutoff = Date.now.addingTimeInterval(-72 * 3600)  // FeedSyncPipeline.retention
    let articles = parser.items.compactMap { item -> FeedArticleDTO? in
      guard !item.title.isEmpty, !item.link.isEmpty else { return nil }
      let date = item.date ?? .now
      guard date > cutoff else { return nil }
      return FeedArticleDTO(
        title: item.title, snippet: String(plain(item.summary).prefix(280)), outlet: title, url: item.link,
        imageURL: item.image, publishedAt: min(date, .now), category: nil, country: nil, videoID: nil,
        audioURL: nil, audioSeconds: nil, isChart: nil, galleryURLs: nil)
    }
    return Found(feed: CustomFeed(url: feedURL, title: title), articles: Array(articles.prefix(40)))
  }

  static func alternateLinks(_ html: String, base: URL) -> [URL] {
    let tags = html.matches(of: /<link\b[^>]*>/.ignoresCase()).map { String($0.output) }
    return tags.compactMap { tag in
      guard tag.range(of: #"application/(rss|atom)\+xml"#, options: .regularExpression) != nil,
        let href = tag.firstMatch(of: /href=["']([^"']+)["']/)?.output.1
      else { return nil }
      return URL(string: String(href), relativeTo: base)?.absoluteURL
    }
  }

  /// Text from a feed's HTML summary: tags gone, common entities decoded, whitespace collapsed.
  static func plain(_ html: String) -> String {
    var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
      text = text.replacingOccurrences(of: entity, with: char)
    }
    return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
  }
}

/// RSS 2.0 and Atom, the parts newnew shows.
private nonisolated final class FeedParser: NSObject, XMLParserDelegate, @unchecked Sendable {
  struct Item {
    var title = "", link = "", summary = "", image: String?, date: Date?
  }

  var isFeed = false
  var title = ""
  var items: [Item] = []
  private var current: Item?
  private var text = ""

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
    text = ""
    switch name {
    case "rss", "feed", "rdf:RDF": isFeed = true
    case "item", "entry": current = Item()
    case "link" where current != nil:
      // Atom: <link href="…" rel="alternate"/>.
      if let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" { current?.link = href }
    case "media:content", "media:thumbnail", "enclosure":
      if current?.image == nil, let url = attributes["url"], (attributes["type"] ?? "image").hasPrefix("image") || name != "enclosure" {
        current?.image = url
      }
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    text += String(data: CDATABlock, encoding: .utf8) ?? ""
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if current == nil {
      if name == "title", title.isEmpty { title = CustomFeedReader.plain(value) }
      return
    }
    switch name {
    case "title": current?.title = CustomFeedReader.plain(value)
    case "link": if current?.link.isEmpty == true { current?.link = value }
    case "description", "summary", "content:encoded": if current?.summary.isEmpty == true { current?.summary = value }
    case "pubDate", "published", "updated", "dc:date": if current?.date == nil { current?.date = Self.date(value) }
    case "item", "entry": if let current { items.append(current) }; current = nil
    default: break
    }
  }

  static func date(_ text: String) -> Date? {
    if let date = try? Date(text, strategy: .iso8601) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }
}
