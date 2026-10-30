import Foundation

/// One outlet the reader can choose, from the scraper's `outlets.json` (a copy ships in the app
/// for a first launch offline).
nonisolated struct OutletInfo: Codable, Hashable, Identifiable, Sendable {
  var outlet: String
  var categories: [String]
  var kinds: [String]
  /// The outlet's feeds, which each iPhone reads itself (`FeedFetcher`).
  var feeds: [FeedSource]?
  var id: String { outlet }

  /// A podcast and nothing else: listed under its category's podcasts, off until chosen
  /// (podcast feeds are large).
  var isPodcast: Bool { kinds == ["podcast"] }

  /// Where it's listed when choosing: its first category's pillar (podcasts too, under the
  /// pillar's podcasts), or Video for outlets that only have videos.
  var group: OutletGroup {
    let category = categories.first(where: { $0 != "Data" }) ?? categories.first
    // Listed with its news when it has any (BBC News has videos too).
    if kinds.contains("article") || kinds.contains("chart") || isPodcast { return .pillar(Pillar(category: category)) }
    if kinds.contains("video") { return .video }
    return .pillar(Pillar(category: category))
  }
}

/// One feed of an outlet: its address, its category and its kind (nil: articles; "video",
/// "podcast", "chart").
nonisolated struct FeedSource: Codable, Hashable, Sendable {
  var url: String
  var category: String?
  var kind: String?
  /// Local-news feeds: the outlet's country.
  var country: String?
}

nonisolated enum OutletGroup: Hashable, Identifiable, Sendable {
  case pillar(Pillar)
  case video

  var id: String { title }
  var title: String {
    switch self {
    case .pillar(let pillar): pillar.title
    case .video: "Video"
    }
  }

  static let all: [OutletGroup] = Pillar.allCases.map { .pillar($0) } + [.video]
}

/// A feed the reader added: read on this iPhone only, never by the scraper.
nonisolated struct CustomFeed: Codable, Hashable, Identifiable, Sendable {
  var url: String
  var title: String
  /// Named by the reader: never renamed after its site.
  var named: Bool?
  var id: String { url }
}

/// YouTube channels suggested in each group of the outlet picker, read like the reader's own
/// feeds (on the iPhone). Active channels with few Shorts, checked 2026-10-29. A channel that
/// shares an outlet's name is "· YouTube", so its videos stay apart from the outlet's articles.
nonisolated enum YouTubeSuggestions {
  static func feed(_ title: String, _ id: String) -> CustomFeed {
    CustomFeed(url: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)", title: title)
  }

  static func channels(in group: OutletGroup) -> [CustomFeed] {
    switch group {
    case .pillar(.briefing):
      [feed("Vox", "UCLXo7UDZvByw2ixzpQCufnA"), feed("TLDR News Global", "UC-uhvujip5deVcEtLxnW8qg"),
       feed("Kurzgesagt", "UCsXVk37bltHxD1rDPwtNM8Q"), feed("Wendover Productions", "UC9RM-iSvTu1uPJb8X5yp3EQ")]
    case .pillar(.tech):
      [feed("Marques Brownlee", "UCBJycsmduvYEL83R_U4JriQ"), feed("Linus Tech Tips", "UCXuqSBlHAE6Xw-yeJA0Tunw"),
       feed("Dave2D", "UCVYamHliCI9rw1tHR1xbkfw"), feed("Mrwhosetheboss", "UCMiJRAwDNSNzuYeN2uWa0pA")]
    case .pillar(.fashion):
      [feed("Vogue · YouTube", "UCRXiA3h1no_PFkb1JCP0yMA"), feed("Highsnobiety · YouTube", "UCNe161YMUykW264kFe5PWxA")]
    case .pillar(.entertainment):
      [feed("Vanity Fair", "UCIsbLox_y9dCIMLd8tdC6qg"), feed("Pitchfork · YouTube", "UC7kI8WjpCfFoMSNDuRh_4lA"),
       feed("Nerdwriter", "UCJkMlOu7faDgqh4PfzbpLdg")]
    case .pillar(.gaming):
      [feed("IGN", "UCKy1dAqELo0zrOtPkf0eTMw"), feed("Game Maker's Toolkit", "UCqJ-Xo29CKyLTjn6z2XwYAw"),
       feed("Noclip", "UC0fDG3byEcMtbOqPMymDNbw")]
    case .pillar(.lifestyle):
      [feed("Bon Appétit · YouTube", "UCbpMy0Fg74eXXkvxJrtEn3w"), feed("Joshua Weissman", "UChBEbMKI1eCcejTtmI32UEw"),
       feed("Dezeen · YouTube", "UCsWG9ANbrmgR0z-eFk_A3YQ")]
    default: []
    }
  }
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
    await renameGenericFeeds()
    guard let base = FeedSyncPipeline.feedURL?.deletingLastPathComponent() else { return }
    guard let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "outlets.json")),
      let list = try? JSONDecoder().decode(Catalog.self, from: data), !list.outlets.isEmpty,
      // A list from before the feeds were read on the iPhone has no addresses: the bundled one.
      list.outlets.allSatisfy({ !($0.feeds ?? []).isEmpty })
    else { return }
    catalog = list.outlets
  }

  func outlets(in group: OutletGroup) -> [OutletInfo] { catalog.filter { $0.group == group } }

  /// Whether articles from this outlet are read. Own feeds always are.
  func reads(_ outlet: String) -> Bool {
    if customFeeds.contains(where: { $0.title == outlet }) { return true }
    return selection.contains(outlet)
  }

  /// The selection being edited: until the reader has chosen, every outlet but the podcasts
  /// (their feeds are large; each is chosen on its own).
  var selection: Set<String> { chosen ?? Set(catalog.filter { !$0.isPodcast }.map(\.outlet)) }

  /// The chosen outlets' feeds, for `FeedFetcher`.
  var chosenFeeds: [(outlet: String, feed: FeedSource)] {
    catalog.filter { selection.contains($0.outlet) }.flatMap { info in (info.feeds ?? []).map { (info.outlet, $0) } }
  }

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

  /// Own feeds added under a title that doesn't name their site (a section, "International
  /// homepage") get the site's name, by the same rule as when they are added. Their stored
  /// articles keep the old name until the next sync replaces them.
  func renameGenericFeeds() async {
    for feed in customFeeds where !feed.url.contains("youtube.com") && feed.named != true && !namesChecked.contains(feed.url) {
      namesChecked.insert(feed.url)
      guard let url = URL(string: feed.url), let host = url.host() else { continue }
      if let label = CustomFeedReader.siteLabel(url), CustomFeedReader.names(feed.title, label) { continue }
      let found = await CustomFeedReader.Found(feed: feed, articles: CustomFeedReader.articles(feed))
      let renamed = await CustomFeedReader.named(found, site: URL(string: "https://\(host)")!)
      guard renamed.feed.title != feed.title, let index = customFeeds.firstIndex(where: { $0.url == feed.url }) else { continue }
      customFeeds[index].title = renamed.feed.title
      saveCustom()
    }
  }

  /// Own feeds whose name was checked this launch.
  @ObservationIgnored private var namesChecked: Set<String> = []

  /// The reader's own name for a feed; nil when it is empty or taken by another outlet.
  @discardableResult func rename(_ feed: CustomFeed, to name: String) -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != feed.title, let index = customFeeds.firstIndex(where: { $0.url == feed.url }),
      !customFeeds.contains(where: { $0.title == name }), !catalog.contains(where: { $0.outlet == name })
    else { return nil }
    customFeeds[index].title = name
    customFeeds[index].named = true
    saveCustom()
    return name
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
    case badAddress, noFeed, youTubeConsent
    var errorDescription: String? {
      switch self {
      case .badAddress: "That doesn't look like a web address."
      case .noFeed: "No RSS or Atom feed was found there."
      case .youTubeConsent:
        "YouTube asks for cookie consent before it shows channel pages here, so newnew can't look up that name. Paste the channel's ID instead: in YouTube, open the channel, tap its description, then Share channel › Copy channel ID."
      }
    }
  }

  /// A site, feed or YouTube channel address (or just "@name") → the feed and its articles.
  static func find(_ input: String) async throws -> Found {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    // A YouTube handle on its own: the channel page names its feed.
    if text.hasPrefix("@"), !text.contains("/") { text = "https://www.youtube.com/" + text }
    // A bare channel ID ("UC…", 24 characters) or a /channel/UC… link: YouTube's feed by ID.
    if let id = text.firstMatch(of: /(?:^|channel\/)(UC[A-Za-z0-9_-]{22})/)?.output.1 {
      return try await read(URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")!)
    }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), url.host() != nil else { throw Failure.badAddress }
    let root = URL(string: "\(url.scheme ?? "https")://\(url.host() ?? "")")!
    if let found = try? await read(url) { return await named(found, site: root) }
    // A web page: the feed it names, then the usual addresses.
    var candidates: [URL] = []
    var pageName: String?
    if let (data, response) = try? await fetch(url), let html = String(data: data, encoding: .utf8) {
      // In the EU, YouTube puts its cookie-consent page in front of channel pages. newnew
      // doesn't answer it for the reader; it asks for the channel's ID instead.
      if response.url?.host()?.hasPrefix("consent.") == true { throw Failure.youTubeConsent }
      candidates += alternateLinks(html, base: response.url ?? url)
      pageName = siteName(html)
    }
    candidates += ["feed", "rss", "rss.xml", "feed.xml", "atom.xml", "index.xml"].map { root.appending(path: $0) }
    for candidate in candidates {
      if let found = try? await read(candidate) { return await named(found, site: root, known: pageName) }
    }
    throw Failure.noFeed
  }

  /// A feed's own title is often a section, not the publication ("International homepage" for
  /// the Financial Times, "World", "Top stories"). The title is kept only when it names the site
  /// its articles link to ("World | The Guardian" → "The Guardian"); otherwise the site's own
  /// name from its page (og:site_name, application-name, the title before " | ") when that names
  /// the site or agrees with the feed; otherwise the domain, "ft.com" → "FT".
  static func named(_ found: Found, site: URL, known: String? = nil) async -> Found {
    guard !site.absoluteString.contains("youtube.com") else { return found }
    let site = articleSite(found) ?? site
    guard let label = siteLabel(site) else { return found }
    if let part = titleParts(found.feed.title).first(where: { names($0, label) }) { return rename(found, part) }
    var page = known
    if page == nil, let root = URL(string: "https://\(site.host() ?? "")"),
      let (data, _) = try? await fetch(root), let html = String(data: data, encoding: .utf8) {
      page = siteName(html)
    }
    if let page, names(page, label) || (!isGeneric(found.feed.title) && page.lowercased() == found.feed.title.lowercased()) {
      return rename(found, page)
    }
    return domainName(site).map { rename(found, $0) } ?? found
  }

  private static func rename(_ found: Found, _ name: String) -> Found {
    guard name != found.feed.title else { return found }
    var renamed = found
    renamed.feed.title = name
    renamed.articles = found.articles.map { var article = $0; article.outlet = name; return article }
    return renamed
  }

  /// Where the articles live: a feed on feeds.…, feedburner or a CDN links to the publisher.
  static func articleSite(_ found: Found) -> URL? {
    let hosts = found.articles.compactMap { URL(string: $0.url)?.host() }
    guard let host = Dictionary(grouping: hosts, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
    return URL(string: "https://\(host)")
  }

  /// "World | The Guardian", "NYT > Top Stories": each part, then the whole; "Le Monde.fr" →
  /// "Le Monde".
  static func titleParts(_ title: String) -> [String] {
    var parts = [title]
    for separator in [" | ", " - ", " – ", " — ", " · ", " :: ", " > ", ": "] {
      parts = parts.flatMap { $0.components(separatedBy: separator) }
    }
    return (parts + [title]).map {
      $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\.[a-z]{2,3}$"#, with: "", options: .regularExpression)
    }.filter { !$0.isEmpty && !isGeneric($0) }
  }

  /// Whether a name is the site's: "The Guardian" for theguardian.com, "Financial Times" for
  /// ft.com, "The New York Times" for nytimes.com.
  static func names(_ name: String, _ label: String) -> Bool {
    let plain = String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    if plain == label || (label.count >= 4 && plain.contains(label)) || (plain.count >= 5 && label.contains(plain))
      || (plain.count >= 3 && label.hasPrefix(plain)) { return true }
    let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { !["the", "of", "and", "a"].contains($0) }
    if words.contains(label) { return true }
    let initials = String(words.compactMap(\.first))
    return initials.count >= 2 && label.hasPrefix(initials)
  }

  /// The part of a host that names the site: "www.bbc.co.uk" → "bbc", "x.substack.com" → "x".
  static func siteLabel(_ site: URL) -> String? {
    guard let host = site.host()?.lowercased() else { return nil }
    var parts = host.split(separator: ".").map(String.init).filter { !["www", "feeds", "rss", "m", "amp"].contains($0) }
    guard parts.count >= 2 else { return nil }
    parts.removeLast()
    // Second-level country domains: co.uk, com.au, or.jp.
    if parts.count >= 2, ["co", "com", "org", "net", "ac", "gov", "or", "ne"].contains(parts.last!) { parts.removeLast() }
    // Hosted blogs are named by their subdomain.
    if parts.count >= 2, ["substack", "medium", "wordpress", "blogspot", "tumblr", "ghost", "github", "bearblog"].contains(parts.last!) {
      return parts[parts.count - 2]
    }
    return parts.last
  }

  /// Titles that name a section or the feed itself rather than the publication.
  static func isGeneric(_ title: String) -> Bool {
    let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
    if lower.count < 3 { return true }
    let words = ["homepage", "home page", "rss", "feed", "top stories", "latest", "headlines", "all articles", "all stories", "front page", "news feed"]
    return words.contains { lower.contains($0) } || ["home", "news", "articles", "blog", "posts", "stories"].contains(lower)
  }

  /// "ft.com" → "FT", "kottke.org" → "Kottke", "www.bbc.co.uk" → "BBC", "x.substack.com" → "X".
  static func domainName(_ site: URL) -> String? {
    guard let label = siteLabel(site) else { return nil }
    return label.count <= 3 ? label.uppercased() : label.prefix(1).uppercased() + label.dropFirst()
  }

  /// Pages a bot check or an error puts in front of a site: never a name.
  static func isChallenge(_ text: String) -> Bool {
    let lower = text.lowercased()
    return ["security verification", "just a moment", "access denied", "attention required", "are you a robot",
            "verify you are human", "captcha", "403", "404", "not found", "forbidden", "error"].contains { lower.contains($0) }
  }

  /// The publication's name from its page.
  static func siteName(_ html: String) -> String? {
    if let range = html.range(of: #"<title[^>]*>([^<]+)</title>"#, options: [.regularExpression, .caseInsensitive]),
      isChallenge(String(html[range])) { return nil }
    for key in ["og:site_name", "application-name", "apple-mobile-web-app-title"] {
      let pattern = #"<meta[^>]+(?:property|name)=["']"# + NSRegularExpression.escapedPattern(for: key) + #"["'][^>]*content=["']([^"']+)["']"#
      let reversed = #"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']"# + NSRegularExpression.escapedPattern(for: key) + #"["']"#
      for p in [pattern, reversed] {
        if let range = html.range(of: p, options: [.regularExpression, .caseInsensitive]),
          let inner = html[range].range(of: #"content=["']([^"']+)["']"#, options: .regularExpression) {
          let value = html[inner].dropFirst(9).dropLast()
          let name = plain(String(value))
          if !name.isEmpty && !isGeneric(name) { return name }
        }
      }
    }
    if let range = html.range(of: #"<title[^>]*>([^<]+)</title>"#, options: [.regularExpression, .caseInsensitive]) {
      let raw = plain(String(html[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
      // "Home - Financial Times", "Latest news | The Verge": the part that names the site.
      var parts = [raw]
      for separator in [" | ", " - ", " – ", " — ", " · ", " :: "] {
        parts = parts.flatMap { $0.components(separatedBy: separator) }
      }
      let names = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isGeneric($0) && $0.count <= 40 }
      if let best = names.last { return best }
    }
    return nil
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
    // Stopped at the parser's `limit` reads as a failed parse; the items are whole.
    xml.parse()
    guard parser.isFeed, !parser.items.isEmpty else { throw Failure.noFeed }
    let title = parser.title.isEmpty ? (url.host() ?? "My feed").replacingOccurrences(of: "www.", with: "") : parser.title
    let feedURL = (response.url ?? url).absoluteString
    let cutoff = Date.now.addingTimeInterval(-72 * 3600)  // FeedSyncPipeline.retention
    let articles = parser.items.compactMap { item -> FeedArticleDTO? in
      guard !item.title.isEmpty, !item.link.isEmpty else { return nil }
      // YouTube Shorts are vertical and fleeting: not news videos.
      guard !item.link.contains("/shorts/") else { return nil }
      let date = item.date ?? .now
      guard date > cutoff else { return nil }
      // A YouTube channel's videos are videos: Watch opens YouTube, the card shows a play mark.
      let image = item.videoID.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" } ?? item.image ?? item.inlineImage
      return FeedArticleDTO(
        title: plain(item.title), snippet: FeedFetcher.truncate(plain(item.summary), FeedFetcher.snippetLength), outlet: title, url: item.link,
        imageURL: image, publishedAt: min(date, .now), category: nil, country: nil, videoID: item.videoID,
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
    // Numbered entities, in feeds that encode them twice ("Google&#8217;s", "&#x2019;").
    text = text.replacing(/&#(x?)([0-9A-Fa-f]+);/) { match in
      let value = UInt32(match.output.2, radix: match.output.1.isEmpty ? 10 : 16)
      return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
    }
    return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
  }
}

/// RSS 2.0 and Atom, the parts newnew shows. Items stop at `limit`; a feed cut off mid-way
/// (`FeedFetcher` reads at most 1.5 MB) still gives the items before the cut.
nonisolated final class FeedParser: NSObject, XMLParserDelegate, @unchecked Sendable {
  struct Item {
    var title = "", link = "", summary = "", image: String?, date: Date?
    /// The widest picture offered so far (`media:content width`).
    var imageWidth = 0
    /// YouTube's `<yt:videoId>`.
    var videoID: String?
    /// A podcast episode's audio and its length.
    var audio: String?
    var seconds: Int?
    /// The first picture in the item's HTML, if it offers no other.
    var inlineImage: String?
    /// Every picture it offers as media (for galleries) and its full HTML.
    var pictures: [String] = []
    var html = ""
    var guid = ""
  }

  var limit = 60

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
    case "enclosure" where current != nil:
      guard let url = attributes["url"] else { break }
      let type = attributes["type"] ?? ""
      if type.hasPrefix("audio") || url.hasSuffix(".mp3") || url.hasSuffix(".m4a") {
        current?.audio = url
      } else if current?.image == nil, type.isEmpty || type.hasPrefix("image") {
        current?.image = url
      }
    case "media:content", "media:thumbnail":
      guard current != nil, let url = attributes["url"] else { break }
      if let medium = attributes["medium"], medium != "image" { break }
      if let type = attributes["type"], !type.hasPrefix("image") { break }
      let width = Int(attributes["width"] ?? "") ?? 0
      if name == "media:content" { current?.pictures.append(url) }
      if current?.image == nil || width > current?.imageWidth ?? 0 {
        current?.image = url
        current?.imageWidth = width
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
    case "description", "summary", "content:encoded", "media:description", "content":
      if name == "content:encoded" || name == "content" { current?.html = value }
      if current?.inlineImage == nil, let src = value.firstMatch(of: /<img[^>]+src=["']([^"']+)["']/)?.output.1 {
        current?.inlineImage = String(src)
      }
      if current?.summary.isEmpty == true || (name == "description" && current?.summary.hasPrefix("<") == true) {
        current?.summary = value
      }
    case "itunes:duration": current?.seconds = Self.seconds(value)
    case "yt:videoId": current?.videoID = value
    case "pubDate", "published", "updated", "dc:date": if current?.date == nil { current?.date = Self.date(value) }
    case "guid", "id": current?.guid = value
    case "item", "entry":
      // Some feeds give the link only as a permalink guid.
      if let guid = current?.guid, guid.hasPrefix("http"), current?.link.isEmpty == true { current?.link = guid }
      if let current { items.append(current) }
      current = nil
      if items.count >= limit { parser.abortParsing() }
    default: break
    }
  }

  /// "938", "15:38" or "1:02:03" → seconds.
  static func seconds(_ text: String) -> Int? {
    let parts = text.split(separator: ":").map { Int($0) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.reduce(0) { $0 * 60 + $1! }
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
