import Foundation

/// Where a story is about, for the feed's region switch. World is everything.
nonisolated enum Region: String, CaseIterable, Identifiable, Sendable {
  case world, europe, us, middleEast, asia, local

  var id: String { rawValue }

  var title: String {
    switch self {
    case .world: "World"
    case .europe: "Europe"
    case .us: "US"
    case .middleEast: "Middle East"
    case .asia: "Asia"
    case .local: "Local"
    }
  }
}

/// Tags an article with the regions it's about, from the places, people and institutions it
/// names: a word list, not a model, so it's instant for a thousand articles and easy to fix.
/// Local is the iPhone's own country (its region setting), plus articles from outlets the
/// scraper marks with that country.
nonisolated enum RegionTagger {
  /// The country Local means: the iPhone's region setting ("NO").
  static var localCountry: String { Locale.current.region?.identifier ?? "US" }

  static func regions(title: String, snippet: String, country: String?, local: String = localCountry) -> Set<Region> {
    let original = "\(title) \(snippet)"
    let text = " " + original.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
    func mentions(_ terms: [String]) -> Bool { terms.contains { text.contains(" \($0) ") } }
    var regions = Set<Region>()
    if mentions(europe) { regions.insert(.europe) }
    // "US" only in capitals: lower-case "us" is the pronoun.
    if mentions(unitedStates) || original.range(of: #"\bU\.?S\.?\b"#, options: .regularExpression) != nil {
      regions.insert(.us)
    }
    if mentions(middleEast) { regions.insert(.middleEast) }
    if mentions(asia) { regions.insert(.asia) }
    if country == local || mentions(localTerms(local)) { regions.insert(.local) }
    return regions
  }

  /// The local country's name and, for some countries, its cities and institutions.
  static func localTerms(_ country: String) -> [String] {
    let name = Locale(identifier: "en").localizedString(forRegionCode: country)?.lowercased()
    return (name.map { [$0] } ?? []) + (localExtras[country] ?? [])
  }

  static let localExtras: [String: [String]] = [
    "NO": ["norwegian", "norwegians", "oslo", "bergen", "trondheim", "stavanger", "tromsø", "tromso", "kristiansand", "drammen", "storting", "nrk", "equinor", "støre"],
    "SE": ["swedish", "swede", "swedes", "stockholm", "gothenburg", "malmö", "malmo", "uppsala", "riksdag"],
    "DK": ["danish", "dane", "danes", "copenhagen", "aarhus", "odense", "folketing"],
    "FI": ["finnish", "finn", "finns", "helsinki", "tampere", "turku"],
    "GB": ["uk", "british", "britain", "england", "scotland", "wales", "london", "manchester", "birmingham", "glasgow", "edinburgh", "starmer", "westminster"],
    "DE": ["german", "germans", "berlin", "munich", "hamburg", "frankfurt", "cologne", "bundestag", "merz"],
    "US": ["america", "american", "americans", "washington", "white house", "congress"],
  ]

  static let europe = [
    "europe", "european", "europeans", "eu", "brussels", "strasbourg",
    "albania", "austria", "austrian", "belarus", "belgium", "belgian", "bosnia", "bulgaria", "croatia", "cyprus",
    "czech", "czechia", "denmark", "danish", "estonia", "finland", "finnish", "france", "french", "germany",
    "german", "greece", "greek", "hungary", "hungarian", "iceland", "ireland", "irish", "italy", "italian",
    "kosovo", "latvia", "lithuania", "luxembourg", "malta", "moldova", "monaco", "montenegro", "netherlands",
    "dutch", "north macedonia", "norway", "norwegian", "poland", "polish", "portugal", "portuguese", "romania",
    "romanian", "russia", "russian", "serbia", "serbian", "slovakia", "slovenia", "spain", "spanish", "sweden",
    "swedish", "switzerland", "swiss", "ukraine", "ukrainian", "britain", "british", "uk", "england",
    "scotland", "wales", "vatican",
    "paris", "london", "berlin", "rome", "madrid", "kyiv", "kiev", "moscow", "warsaw", "vienna", "amsterdam",
    "stockholm", "oslo", "copenhagen", "helsinki", "athens", "dublin", "lisbon", "prague", "budapest",
    "bucharest", "milan", "barcelona", "munich", "frankfurt", "geneva", "zurich", "marseille", "lyon",
    "macron", "starmer", "merz", "zelensky", "zelenskyy", "putin", "meloni", "kremlin", "pope", "von der leyen",
  ]

  static let unitedStates = [
    "united states", "america", "american", "americans", "washington", "white house", "congress", "senate",
    "senator", "pentagon", "trump", "vance", "republicans", "democrats", "republican", "democrat", "gop",
    "fbi", "cia", "wall street", "midterms", "nfl", "nba", "mlb",
    "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware", "florida",
    "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine", "maryland",
    "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana", "nebraska", "nevada",
    "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio",
    "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee",
    "texas", "utah", "vermont", "virginia", "west virginia", "wisconsin", "wyoming",
    "chicago", "los angeles", "boston", "seattle", "miami", "san francisco", "houston", "atlanta",
    "philadelphia", "detroit",
  ]

  /// "Turkey" is left out (the bird); "Türkiye", "Turkish" and Ankara are in.
  static let middleEast = [
    "middle east", "mideast", "iran", "iranian", "iranians", "tehran", "khamenei", "israel", "israeli",
    "israelis", "netanyahu", "jerusalem", "tel aviv", "idf", "gaza", "west bank", "hebron", "palestine",
    "palestinian", "palestinians", "hamas", "hezbollah", "lebanon", "lebanese", "beirut", "syria", "syrian",
    "damascus", "iraq", "iraqi", "baghdad", "jordan", "jordanian", "amman", "saudi", "saudi arabia", "riyadh",
    "yemen", "yemeni", "houthi", "houthis", "qatar", "qatari", "doha", "uae", "emirates", "emirati", "dubai",
    "abu dhabi", "ras al khaimah", "kuwait", "bahrain", "oman", "egypt", "egyptian", "cairo", "türkiye",
    "turkish", "ankara", "erdogan", "red sea", "strait of hormuz", "hormuz",
  ]

  static let asia = [
    "asia", "asian", "china", "chinese", "beijing", "shanghai", "hong kong", "taiwan", "taiwanese", "japan",
    "japanese", "tokyo", "osaka", "korea", "korean", "seoul", "pyongyang", "kim jong un", "india", "indian",
    "delhi", "new delhi", "mumbai", "pakistan", "pakistani", "bangladesh", "sri lanka", "nepal", "afghanistan",
    "afghan", "taliban", "myanmar", "thailand", "thai", "bangkok", "vietnam", "vietnamese", "hanoi",
    "cambodia", "laos", "malaysia", "malaysian", "singapore", "indonesia", "indonesian", "jakarta",
    "philippines", "philippine", "filipino", "manila", "mongolia", "kazakhstan", "uzbekistan", "asean",
    "xi jinping", "modi", "dandong",
  ]
}
