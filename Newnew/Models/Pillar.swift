import Foundation

/// The editorial mix: news, and the lighter pillars that keep the page from reading like a wire
/// terminal. The scraper's feed categories map onto them; Today mixes them by `share`.
nonisolated enum Pillar: String, CaseIterable, Identifiable, Sendable {
  case briefing, tech, fashion, entertainment, gaming, lifestyle

  var id: String { rawValue }

  init(category: String?) {
    switch category {
    case "Technology": self = .tech
    case "Fashion & Style": self = .fashion
    case "Entertainment", "Culture": self = .entertainment
    case "Gaming": self = .gaming
    case "Lifestyle & Food": self = .lifestyle
    // World, Business, Science, Politics, US, Local, Sport, Data, the news podcasts.
    default: self = .briefing
    }
  }

  var title: String {
    switch self {
    case .briefing: "Briefing"
    case .tech: "Tech & Gear"
    case .fashion: "Fashion & Style"
    case .entertainment: "Entertainment"
    case .gaming: "Gaming"
    case .lifestyle: "Lifestyle & Food"
    }
  }

  /// Its share of Today's top stories.
  var share: Double {
    switch self {
    case .briefing: 0.25
    case .tech: 0.20
    case .fashion, .entertainment, .gaming: 0.15
    case .lifestyle: 0.10
    }
  }

  /// Photography that is mostly portrait (runway, street style, editorial): taller pictures,
  /// cropped from the top so heads and shoes stay.
  var isPortrait: Bool { self == .fashion }

  /// Fallback brief mode when only the pillar is known. Prefer `cluster.briefMode` so news stories
  /// in Tech, Entertainment, and Gaming aren't misclassified as product/critic reviews.
  var briefMode: BriefMode {
    switch self {
    case .briefing, .tech, .entertainment, .gaming: .perspective
    case .fashion, .lifestyle: .trend
    }
  }
}

nonisolated enum BriefMode: String, Codable, Sendable {
  case perspective, verdict, trend
}

// MARK: - Smart Review vs. News Classifier

/// Distinguishes genuine critic/product reviews from regular news stories in Tech, Gaming,
/// Entertainment, and Lifestyle.
nonisolated enum ReviewClassifier {

  /// Phrases where "review" means an investigation, audit, or recap—never a critic review.
  private static let institutionalExclusions: [String] = [
    "under review", "in review", "year in review", "week in review", "peer review", "peer-reviewed",
    "judicial review", "strategic review", "spending review", "security review", "safety review",
    "independent review", "internal review", "government review", "policy review", "regulatory review",
    "court to review", "court reviews", "judge reviews", "regulator", "antitrust", "lawsuit",
    "subpoena", "probe", "investigation", "layoffs", "cuts jobs", "earnings", "quarterly",
    "stock", "shares", "acquires", "acquisition", "merger", "ceo", "resigns", "arrested", "charged"
  ]

  /// Roundups, buying guides, deals, and news announcements that should never be treated as a review.
  private static let guideAndNewsExclusions: [String] = [
    "best ", "top 10", "top 5", "buying guide", "gift guide", "where to buy", "how to ",
    "deal:", "deals", "price drop", "discount", "black friday", "prime day",
    "trailer", "teaser", "release date", "announces", "announced", "unveils", "unveiled",
    "launches", "launched", "delayed", "delays", "cancelled", "cancels", "box office",
    "rumor", "rumour", "leaked", "leak", "everything we know", "what to expect", "patch notes"
  ]

  static func isGenuineReview(title: String, snippet: String, url: String) -> Bool {
    let lowerTitle = title.lowercased()
    let lowerSnippet = snippet.lowercased()
    let lowerURL = url.lowercased()
    let combined = lowerTitle + " " + lowerSnippet

    // 1. Disqualify institutional/legal "reviews", corporate news, and buying guides
    if institutionalExclusions.contains(where: { combined.contains($0) }) {
      return false
    }
    if guideAndNewsExclusions.contains(where: { lowerTitle.contains($0) }) {
      return false
    }

    // 2. Strong URL path signal (/reviews/, /review/, -review)
    if lowerURL.contains("/reviews/") || lowerURL.contains("/review/")
      || lowerURL.hasSuffix("-review") || lowerURL.contains("-review-") || lowerURL.contains("-review/") {
      return true
    }

    // 3. Explicit critic headline patterns ("X review:", "Review: X", "X — review", "Hands-on:", "Tested:")
    let headlinePatterns = [
      #"\breview\s*[:\-–—|]"#,
      #"[:\-–—|]\s*review\b"#,
      #"\breview$"#,
      #"^review\b"#,
      #"\breviewed\s*[:\-–—]"#,
      #"\bhands[\-\s]on\s*[:\-–—]"#,
      #"\btested\s*[:\-–—]"#,
      #"\bour verdict\b"#
    ]
    for pattern in headlinePatterns {
      if lowerTitle.range(of: pattern, options: .regularExpression) != nil {
        return true
      }
    }

    // 4. Explicit star rating or numeric review score ("4/5", "8/10", "★★★★")
    let scorePattern = #"\b([1-5]\s*/\s*5|([1-9]|10)(\.[0-9])?\s*/\s*10)\b|[★☆]{3,5}"#
    if combined.range(of: scorePattern, options: .regularExpression) != nil {
      return true
    }

    return false
  }
}

extension StoryCluster {
  /// Determines whether this specific story cluster is a true critic/product review (`.verdict`),
  /// a style/lifestyle trend piece (`.trend`), or a news story to compare across outlets (`.perspective`).
  var briefMode: BriefMode {
    let written = sortedArticles.filter { !$0.isMedia }
    let pool = written.isEmpty ? sortedArticles : written
    guard !pool.isEmpty else { return pillar.briefMode }

    // Count how many articles in the cluster actually read like genuine reviews
    let reviewHits = pool.filter {
      ReviewClassifier.isGenuineReview(title: $0.title, snippet: $0.snippet, url: $0.url)
    }.count

    // If at least half of the articles (or the lead of a single-source story) are genuine reviews, use `.verdict`
    if reviewHits * 2 >= pool.count && reviewHits > 0 {
      return .verdict
    }

    // Fashion & Lifestyle non-news stories use `.trend` unless multiple outlets are reporting a hard news event
    if pillar == .fashion || pillar == .lifestyle {
      return .trend
    }

    // Everything else (including Tech, Gaming & Entertainment news!) compares coverage as `.perspective`
    return .perspective
  }
}
