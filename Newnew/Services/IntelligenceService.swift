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

  /// One story's read, by its pillar's mode: how outlets frame the news (perspective), what
  /// reviewers make of a release (verdict), or the look and why it matters (trend). The three
  /// share one shape: a summary, two lists, each outlet's angle, and for trends the takeaways.
  static func brief(for sources: [Source], mode: BriefMode = .perspective) async throws -> ClusterPerspectiveBrief {
    refreshAvailability()
    #if canImport(FoundationModels)
      if isAvailable {
        do {
          let session = LanguageModelSession(instructions: instructions(mode))
          let prompt = briefPrompt(sources, mode: mode)
          var brief: ClusterPerspectiveBrief
          switch mode {
          case .perspective:
            let r = try await session.respond(to: prompt, generating: GeneratedBrief.self).content
            brief = ClusterPerspectiveBrief(
              summary: r.summary, sharedFacts: r.sharedFacts, differences: r.differences,
              angles: r.angles.map { .init(outlet: $0.outlet, focus: $0.focus) },
              sourceCount: sources.count, isGenerated: true, createdAt: .now)
          case .verdict:
            let r = try await session.respond(to: prompt, generating: GeneratedVerdict.self).content
            brief = ClusterPerspectiveBrief(
              summary: r.verdict, sharedFacts: r.praised, differences: r.criticised,
              angles: r.angles.map { .init(outlet: $0.outlet, focus: $0.focus) },
              sourceCount: sources.count, isGenerated: true, createdAt: .now)
          case .trend:
            let r = try await session.respond(to: prompt, generating: GeneratedTrend.self).content
            brief = ClusterPerspectiveBrief(
              summary: r.shift, sharedFacts: r.names, differences: r.context,
              angles: r.angles.map { .init(outlet: $0.outlet, focus: $0.focus) },
              sourceCount: sources.count, isGenerated: true, createdAt: .now)
            brief.takeaways = r.takeaways
          }
          brief.mode = mode
          return brief
        } catch {
          // The default guardrails refuse a lot of hard news (war, riots, attacks). Comparing
          // headlines someone else wrote is what the permissive setting is for; it only answers
          // in text. Any other failure gets the same second try.
          if let brief = try? await plainTextBrief(sources, mode: mode) { return brief }
          var preview = previewBrief(sources, mode: mode)
          preview.note = isDeclined(error)
            ? "Apple Intelligence declined to compare this story; it avoids some subjects, such as violence. Here is each outlet's headline instead."
            : "Apple Intelligence couldn't compare this story just now. Here is each outlet's headline instead."
          return preview
        }
      }
    #endif
    return previewBrief(sources, mode: mode)
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
    /// SUMMARY:, AGREE:, DIFFER:, TAKE: and ANGLE: outlet | focus.
    static func plainTextBrief(_ sources: [Source], mode: BriefMode = .perspective) async throws -> ClusterPerspectiveBrief? {
      let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
      let session = LanguageModelSession(model: model, instructions: instructions(mode))
      let format: String
      switch mode {
      case .perspective:
        format = """
          SUMMARY: one or two sentences on what happened, using facts most outlets agree on
          AGREE: a fact several outlets report (2 to 4 lines)
          DIFFER: how one outlet's coverage differs, naming it once (1 to 3 lines)
          """
      case .verdict:
        format = """
          SUMMARY: the overall verdict, in one or two sentences
          AGREE: something reviewers praise (1 to 4 lines)
          DIFFER: something reviewers criticise (0 to 3 lines)
          """
      case .trend:
        format = """
          SUMMARY: the key shift in style or taste, in one or two sentences
          AGREE: a designer, brand, piece or place it features (1 to 5 lines)
          DIFFER: why people are talking about it (1 to 2 lines)
          TAKE: something a reader could try or take from it (1 to 3 lines)
          """
      }
      let prompt = briefPrompt(sources, mode: mode) + """


        Answer in exactly this format, one item per line, nothing else:
        \(format)
        ANGLE: outlet name | what it focuses on, under 10 words (one line per outlet)
        """
      let text = try await session.respond(to: prompt).content
      var summary = "", agree: [String] = [], differ: [String] = [], take: [String] = []
      var angles: [ClusterPerspectiveBrief.Angle] = []
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
        else if let v = value("TAKE:"), !v.isEmpty { take.append(tidy(v)) }
        else if let v = value("ANGLE:") {
          let parts = v.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
          if parts.count == 2 { angles.append(.init(outlet: parts[0], focus: parts[1])) }
        }
      }
      guard !summary.isEmpty else { return nil }
      return ClusterPerspectiveBrief(
        summary: summary, sharedFacts: Array(agree.prefix(5)), differences: Array(differ.prefix(3)),
        angles: angles, sourceCount: sources.count, isGenerated: true, createdAt: .now, mode: mode,
        takeaways: take.isEmpty ? nil : Array(take.prefix(3)))
    }
  #endif

  static let briefInstructions = """
    You compare how news outlets cover one event. You only see each outlet's headline and \
    snippet, never the full article. Be neutral and brief. Don't invent facts, quotes or \
    numbers that aren't in the text. Don't take sides.
    """

  static func instructions(_ mode: BriefMode) -> String {
    switch mode {
    case .perspective: briefInstructions
    case .verdict: """
      You sum up what reviewers and outlets make of one release: a gadget, film, show, album \
      or game. You only see each outlet's headline and snippet, never the full review. Say \
      what they praise, what they criticise and the overall verdict. Be brief. Use only what \
      the text says; if it says little, keep the lists short. Don't invent scores or quotes.
      """
    case .trend: """
      You read one fashion, design, food or travel story the way a magazine editor would: the \
      key shift in style or taste, the designers, brands, pieces or places it features, why \
      people are talking about it, and what a reader could take from it. You only see each \
      outlet's headline and snippet. Be brief and concrete. Use only what the text says; if it \
      says little, keep the lists short.
      """
    }
  }

  /// Headlines and snippets only, trimmed so ten outlets fit well inside the context window.
  static func briefPrompt(_ sources: [Source], mode: BriefMode = .perspective) -> String {
    let lines = sources.prefix(10).map { source in
      "- \(source.outlet): \(source.title). \(String(source.snippet.prefix(280)))"
    }
    let heading =
      switch mode {
      case .perspective: "Coverage of one event by \(sources.count) outlets:"
      case .verdict: "What \(sources.count == 1 ? "one outlet says" : "\(sources.count) outlets say") about one release:"
      case .trend: "\(sources.count == 1 ? "One story" : "\(sources.count) stories") about one look, place or dish:"
      }
    return heading + "\n" + lines.joined(separator: "\n")
  }

  /// Without the model: the facts are the snippets, each outlet's angle its own headline.
  static func previewBrief(_ sources: [Source], mode: BriefMode = .perspective) -> ClusterPerspectiveBrief {
    var seen = Set<String>()
    let unique = sources.filter { seen.insert($0.outlet).inserted }
    return ClusterPerspectiveBrief(
      summary: sources.first?.snippet ?? "",
      sharedFacts: [],
      differences: [],
      angles: unique.map { .init(outlet: $0.outlet, focus: $0.title) },
      sourceCount: sources.count, isGenerated: false, createdAt: .now, mode: mode)
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
          list the names and specific terms that only stories about this topic would use: \
          the people, companies, products, places, agencies and events this topic is about. \
          Never broad words like device, service, tool, developer, conference, technology, \
          business, market, news or update.
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
  struct GeneratedVerdict {
    @Guide(description: "The overall verdict in one or two sentences, from what the outlets say.")
    var verdict: String
    @Guide(description: "What reviewers praise, each under 15 words.", .count(1...4))
    var praised: [String]
    @Guide(description: "What reviewers criticise, each under 15 words. Empty if nothing is criticised.", .maximumCount(3))
    var criticised: [String]
    @Guide(description: "Each outlet's take, one entry per outlet.")
    var angles: [GeneratedAngle]
  }

  @Generable
  struct GeneratedTrend {
    @Guide(description: "The key shift in style or taste, in one or two sentences.")
    var shift: String
    @Guide(description: "Designers, brands, pieces, places or dishes it features, each a short phrase.", .count(1...5))
    var names: [String]
    @Guide(description: "Why people are talking about it: the cultural context, each one sentence under 20 words.", .count(1...2))
    var context: [String]
    @Guide(description: "What a reader could try or take from it, each under 15 words.", .count(1...3))
    var takeaways: [String]
    @Guide(description: "Each outlet's angle, one entry per outlet.")
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
    @Guide(description: "Realistic news headlines about the topic, each a different kind of story, each naming a specific person, product or event.", .count(4))
    var exampleHeadlines: [String]
    @Guide(description: "Names of people, products, places or events that rarely appear outside this topic, lower case. Never broad words like device, service or tech.", .maximumCount(6))
    var keywords: [String]
  }
#endif
