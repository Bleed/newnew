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

  /// Whether the story page compares outlets (news), weighs reviews (releases) or reads the
  /// trend (style and lifestyle). See `IntelligenceService.perspectiveBrief`.
  var briefMode: BriefMode {
    switch self {
    case .briefing: .perspective
    case .tech, .entertainment, .gaming: .verdict
    case .fashion, .lifestyle: .trend
    }
  }
}

nonisolated enum BriefMode: String, Codable, Sendable {
  case perspective, verdict, trend
}
