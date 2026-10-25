import Accelerate
import Foundation
import NaturalLanguage

/// Groups articles about the same event.
///
/// Mean-pooled sentence vectors say what kind of story something is (weather, a strike), not
/// which one, so on their own they merge unrelated stories. What ties coverage of one event
/// together is shared names and words: "Storm Elin", "Halden Semiconductor". So the score is
/// mostly TF-IDF over lemmas (names count double), with a little of the centred embedding for
/// rewrites that share no names. Clusters are average-linkage: a story joins a cluster when it
/// is close to its members on average, not just to one of them.
///
/// Tuned on a real run of the scraper (897 articles, 46 feeds): at 0.12, with same-outlet pairs
/// at half weight, nearly every multi-outlet cluster is one event (161 of them); at 0.08 broad
/// themes chained into 40-article blobs. On the tiny bundled sample it splits one story in
/// three, which is fine: TF-IDF needs a real corpus.
nonisolated enum StoryClusterer {
  static let threshold: Float = 0.12
  static let embeddingWeight: Float = 0.1
  /// One outlet rarely covers one event many times, but often writes many stories on one theme
  /// (a politics desk, a cricket section), which chained them into one "story".
  static let sameOutletWeight: Float = 0.5
  /// Articles further apart in time than this are never the same story.
  static let window: TimeInterval = 36 * 3600
  /// Telling words two articles must share to be compared at all: words few articles that day
  /// use (see `rareShare`). With short texts one rare word was enough: "Dutch" put a Dutch
  /// Design Week table next to a Dutch researcher's electric planes, "Poland" an abortion law
  /// next to gold sales; and two common ones ("police", "dies") joined unrelated crime stories.
  /// A name counts as its words.
  static let minSharedWords = 2
  /// A word is telling when at most this share of the articles use it (at least 8 articles).
  static let rareShare: Float = 0.015

  struct Input: Sendable {
    var text: String
    /// The outlet: pairs from one outlet count for less (see `sameOutletWeight`).
    var outlet: String = ""
    var publishedAt: Date
    /// Centred, normalised; nil if the article couldn't be embedded.
    var vector: [Float]?
  }

  /// Indices of `inputs`, grouped; every input is in exactly one group.
  static func groups(
    _ inputs: [Input], threshold: Float = threshold, sameOutletWeight: Float = sameOutletWeight,
    minSharedWords: Int = minSharedWords, rareShare: Float = rareShare
  ) -> [[Int]] {
    let n = inputs.count
    guard n > 1 else { return inputs.indices.map { [$0] } }
    let similarity = pairwise(inputs, sameOutletWeight: sameOutletWeight, minSharedWords: minSharedWords, rareShare: rareShare)

    // Average linkage over the pairs that have any similarity at all (most have none).
    var members = (0..<n).map { [$0] }
    var alive = Set(0..<n)
    var sums: [Int: [Int: Float]] = [:]
    for (pair, s) in similarity {
      sums[pair.a, default: [:]][pair.b] = s
      sums[pair.b, default: [:]][pair.a] = s
    }
    while true {
      var best: (score: Float, a: Int, b: Int) = (threshold, -1, -1)
      for a in alive {
        for (b, sum) in sums[a] ?? [:] where a < b {
          let average = sum / Float(members[a].count * members[b].count)
          if average >= best.score { best = (average, a, b) }
        }
      }
      guard best.a >= 0 else { break }
      let (a, b) = (best.a, best.b)
      members[a] += members[b]
      members[b] = []
      alive.remove(b)
      for (other, sum) in sums[b] ?? [:] where other != a {
        sums[a, default: [:]][other, default: 0] += sum
        sums[other, default: [:]][a, default: 0] += sum
        sums[other]?[b] = nil
      }
      sums[a]?[b] = nil
      sums[b] = nil
    }
    return alive.sorted().map { members[$0] }
  }

  struct Pair: Hashable { var a: Int, b: Int }

  /// Similarity of every pair that has any, within the time window.
  static func pairwise(
    _ inputs: [Input], sameOutletWeight: Float = sameOutletWeight, minSharedWords: Int = minSharedWords,
    rareShare: Float = rareShare
  ) -> [Pair: Float] {
    let documents = inputs.map { terms($0.text) }
    // The plain words of each article ("#dutch design week" is dutch, design, week), and how
    // many telling ones each pair shares.
    let words = documents.map { document in
      Set(document.flatMap { $0.hasPrefix("#") ? $0.dropFirst().split(separator: " ").map(String.init) : [$0] })
    }
    var wordPostings: [String: [Int]] = [:]
    for (index, set) in words.enumerated() { for word in set { wordPostings[word, default: []].append(index) } }
    var shared: [Pair: Int] = [:]
    let rareLimit = max(8, Int(Float(inputs.count) * rareShare))
    for (_, list) in wordPostings where list.count > 1 && list.count <= rareLimit {
      for x in 0..<list.count { for y in (x + 1)..<list.count { shared[Pair(a: list[x], b: list[y]), default: 0] += 1 } }
    }
    var frequency: [String: Int] = [:]
    for document in documents { for term in Set(document) { frequency[term, default: 0] += 1 } }
    let count = Float(documents.count)

    // Normalised TF-IDF, sparse, and an inverted index to find pairs that share a term.
    let weights: [[String: Float]] = documents.map { document in
      var weights: [String: Float] = [:]
      for term in document { weights[term, default: 0] += log((count + 1) / Float(frequency[term]! + 1)) + 1 }
      let length = sqrt(weights.values.reduce(0) { $0 + $1 * $1 })
      return length > 0 ? weights.mapValues { $0 / length } : weights
    }
    var postings: [String: [Int]] = [:]
    for (index, document) in weights.enumerated() { for term in document.keys { postings[term, default: []].append(index) } }

    var lexical: [Pair: Float] = [:]
    for (term, list) in postings where list.count > 1 {
      for x in 0..<list.count {
        for y in (x + 1)..<list.count {
          let (a, b) = (list[x], list[y])
          lexical[Pair(a: a, b: b), default: 0] += weights[a][term]! * weights[b][term]!
        }
      }
    }

    var result: [Pair: Float] = [:]
    let lexicalWeight = 1 - embeddingWeight
    for a in 0..<inputs.count {
      for b in (a + 1)..<inputs.count {
        guard abs(inputs[a].publishedAt.timeIntervalSince(inputs[b].publishedAt)) <= window,
          shared[Pair(a: a, b: b), default: 0] >= minSharedWords
        else { continue }
        let words = lexical[Pair(a: a, b: b)] ?? 0
        let score: Float
        if let va = inputs[a].vector, let vb = inputs[b].vector {
          score = lexicalWeight * words + embeddingWeight * Vec.cosine(va, vb)
        } else {
          score = words
        }
        let weighted = inputs[a].outlet == inputs[b].outlet ? score * sameOutletWeight : score
        if weighted > 0.01 { result[Pair(a: a, b: b)] = weighted }
      }
    }
    return result
  }

  /// Lemmas of the nouns, verbs and adjectives, plus each name (people, places, organisations)
  /// twice, since names are what tie coverage of one event together.
  static func terms(_ text: String) -> [String] {
    var terms: [String] = []
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma, .nameType])
    tagger.string = text
    let range = text.startIndex..<text.endIndex
    let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace]
    tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, wordRange in
      let word = text[wordRange]
      guard let tag, [.noun, .verb, .adjective, .otherWord].contains(tag) || word.first?.isUppercase == true else { return true }
      let lemma = tagger.tag(at: wordRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? String(word)
      if lemma.count > 2 { terms.append(lemma.lowercased()) }
      return true
    }
    tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options.union(.joinNames)) { tag, nameRange in
      if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
        let name = "#" + text[nameRange].lowercased()
        terms += [name, name]
      }
      return true
    }
    return terms
  }
}
