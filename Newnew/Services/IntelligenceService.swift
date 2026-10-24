import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Apple Intelligence on the device, used only on a tap: one story's perspective brief, or one
/// new mute topic. Never in a loop over the feed (thermal and battery watchdogs), and every
/// result is kept so it's made once.
///
/// Where the model isn't available (older iPhones, Apple Intelligence off, most simulators) it
/// falls back to a plain preview built from the headlines, labelled as such.
enum IntelligenceService {
  /// The headline and snippet of one article: all the model ever sees.
  struct Source: Sendable {
    var outlet: String
    var title: String
    var snippet: String
  }

  /// Nil when available; otherwise why not, in a few words.
  ///
  /// Read once and kept: asking the model for its availability from a view body set off a
  /// redraw loop that froze the page.
  private(set) static var unavailability: String? = currentUnavailability()

  static var isAvailable: Bool { unavailability == nil }
  static var unavailableReason: String { unavailability ?? "" }

  /// Asks again (when the app comes forward, and before each use).
  static func refreshAvailability() {
    unavailability = currentUnavailability()
  }

  private static func currentUnavailability() -> String? {
    #if canImport(FoundationModels)
      switch SystemLanguageModel.default.availability {
      case .available: nil
      case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off"
      case .unavailable(.modelNotReady): "Apple Intelligence is still downloading"
      case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence"
      default: "Apple Intelligence isn't available"
      }
    #else
      "Apple Intelligence isn't available"
    #endif
  }

  // MARK: Perspective brief

  static func brief(for sources: [Source]) async throws -> ClusterPerspectiveBrief {
    refreshAvailability()
    #if canImport(FoundationModels)
      if isAvailable {
        do {
          let session = LanguageModelSession(instructions: briefInstructions)
          let response = try await session.respond(to: briefPrompt(sources), generating: GeneratedBrief.self)
          let brief = response.content
          return ClusterPerspectiveBrief(
            summary: brief.summary, sharedFacts: brief.sharedFacts, differences: brief.differences,
            angles: brief.angles.map { .init(outlet: $0.outlet, focus: $0.focus) },
            sourceCount: sources.count, isGenerated: true, createdAt: .now)
        } catch {
          // The default guardrails refuse a lot of hard news (war, riots, attacks). Comparing
          // headlines someone else wrote is what the permissive setting is for; it only answers
          // in text. Any other failure gets the same second try.
            if let brief = try? await plainTextBrief(sources) { return brief }
          var preview = previewBrief(sources)
          preview.note = isDeclined(error)
            ? "Apple Intelligence declined to compare this story; it avoids some subjects, such as violence. Here is each outlet's headline instead."
            : "Apple Intelligence couldn't compare this story just now. Here is each outlet's headline instead."
          return preview
        }
      }
    #endif
    return previewBrief(sources)
  }

  #if canImport(FoundationModels)
    static func isDeclined(_ error: Error) -> Bool {
      if let error = error as? LanguageModelSession.GenerationError {
        switch error {
        case .guardrailViolation, .refusal: return true
        default: break
        }
      }
      return String(describing: error).localizedCaseInsensitiveContains("refus")
    }

    /// The same brief with the permissive guardrails, in a line format the app parses:
    /// SUMMARY:, AGREE:, DIFFER: and ANGLE: outlet | focus.
    static func plainTextBrief(_ sources: [Source]) async throws -> ClusterPerspectiveBrief? {
      let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
      let session = LanguageModelSession(model: model, instructions: briefInstructions)
      let prompt = briefPrompt(sources) + """


        Answer in exactly this format, one item per line, nothing else:
        SUMMARY: one or two sentences on what happened, using facts most outlets agree on
        AGREE: a fact several outlets report (2 to 4 lines)
        DIFFER: how one outlet's coverage differs, naming it once (1 to 3 lines)
        ANGLE: outlet name | what it focuses on, under 10 words (one line per outlet)
        """
      let text = try await session.respond(to: prompt).content
      var summary = "", agree: [String] = [], differ: [String] = [], angles: [ClusterPerspectiveBrief.Angle] = []
      for line in text.split(whereSeparator: \.isNewline) {
        let line = line.trimmingCharacters(in: .whitespaces)
        func value(_ key: String) -> String? {
          line.uppercased().hasPrefix(key) ? line.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil
        }
        // The model sometimes carries the ANGLE format over ("Outlet | text"): keep it readable.
        func tidy(_ text: String) -> String {
          let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
          return parts.count == 2 ? "\(parts[0]): \(parts[1])" : text
        }
        if let v = value("SUMMARY:") { summary = v }
        else if let v = value("AGREE:"), !v.isEmpty { agree.append(tidy(v)) }
        else if let v = value("DIFFER:"), !v.isEmpty { differ.append(tidy(v)) }
        else if let v = value("ANGLE:") {
          let parts = v.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
          if parts.count == 2 { angles.append(.init(outlet: parts[0], focus: parts[1])) }
        }
      }
      guard !summary.isEmpty else { return nil }
      return ClusterPerspectiveBrief(
        summary: summary, sharedFacts: Array(agree.prefix(4)), differences: Array(differ.prefix(3)),
        angles: angles, sourceCount: sources.count, isGenerated: true, createdAt: .now)
    }
  #endif

  static let briefInstructions = """
    You compare how news outlets cover one event. You only see each outlet's headline and \
    snippet, never the full article. Be neutral and brief. Don't invent facts, quotes or \
    numbers that aren't in the text. Don't take sides.
    """

  /// Headlines and snippets only, trimmed so ten outlets fit well inside the context window.
  static func briefPrompt(_ sources: [Source]) -> String {
    let lines = sources.prefix(10).map { source in
      "- \(source.outlet): \(source.title). \(String(source.snippet.prefix(280)))"
    }
    return "Coverage of one event by \(sources.count) outlets:\n" + lines.joined(separator: "\n")
  }

  /// Without the model: the facts are the snippets, each outlet's angle its own headline.
  static func previewBrief(_ sources: [Source]) -> ClusterPerspectiveBrief {
    var seen = Set<String>()
    let unique = sources.filter { seen.insert($0.outlet).inserted }
    return ClusterPerspectiveBrief(
      summary: sources.first?.snippet ?? "",
      sharedFacts: [],
      differences: [],
      angles: unique.map { .init(outlet: $0.outlet, focus: $0.title) },
      sourceCount: sources.count, isGenerated: false, createdAt: .now)
  }

  // MARK: Topics

  /// A followed or muted topic as example headlines (compared with stories by meaning) and a
  /// few telling words or names (matched exactly).
  static func topicExamples(_ phrase: String) async -> (headlines: [String], keywords: [String]) {
    refreshAvailability()
    #if canImport(FoundationModels)
      if isAvailable {
        let session = LanguageModelSession(instructions: """
          You help someone describe a topic for their news feed, to follow or to hide. Write \
          realistic, varied, neutral headlines a news site might publish about the topic, and \
          list words that only stories about this topic would use.
          """)
        if let response = try? await session.respond(to: "Topic: \(phrase)", generating: GeneratedMuteTopic.self) {
          let keywords = response.content.keywords.map { $0.lowercased() }.filter { $0.count > 2 }
          return (response.content.exampleHeadlines, keywords)
        }
      }
    #endif
    // Without the model the phrase itself stands in for the headlines; its words for keywords.
    return ([phrase], [phrase.lowercased()])
  }
}

#if canImport(FoundationModels)
  @Generable
  struct GeneratedBrief {
    @Guide(description: "One or two sentences on what happened, using only facts most outlets agree on.")
    var summary: String
    @Guide(description: "Facts several outlets report, each under 15 words.", .count(2...4))
    var sharedFacts: [String]
    @Guide(description: "How the coverage differs: emphasis, framing, or details only some outlets mention. Each is one sentence that names the outlet once, as its subject, like \"Fjord Herald focuses on the cost.\" Under 20 words.", .count(1...3))
    var differences: [String]
    @Guide(description: "Each outlet's angle on the story, one entry per outlet.")
    var angles: [GeneratedAngle]
  }

  @Generable
  struct GeneratedAngle {
    @Guide(description: "The outlet's name, exactly as given.")
    var outlet: String
    @Guide(description: "What this outlet focuses on, under 10 words.")
    var focus: String
  }

  @Generable
  struct GeneratedMuteTopic {
    @Guide(description: "Realistic news headlines about the topic, each a different kind of story.", .count(4))
    var exampleHeadlines: [String]
    @Guide(description: "Single words or names that strongly signal this topic, lower case.", .maximumCount(6))
    var keywords: [String]
  }
#endif
